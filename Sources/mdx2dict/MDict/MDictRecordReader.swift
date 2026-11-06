//
//  MDictRecordReader.swift
//  MDict
//
//  解析 Record Section 元数据，并按 recordOffset 取出释义。2.0 布局：
//    4 × UInt64 BE（blocks、entries、info 大小、blocks 总大小）
//    + 每块 (compSize, decompSize)（各 UInt64 BE）+ 首尾相接的 record blocks。
//  释义到下一个 \0 为止（UTF-16 为 00 00），末条记录可能没有终止符。
//

import Foundation

final class MDictRecordReader {
    private let file: MDictFile
    private let header: MDictHeader
    private let blocks: [RecordBlockInfo]
    /// 所有 record block 解压后的总长度，最后一条记录用它作结束边界。
    let totalDecompressedSize: UInt64
    private let encoding: String.Encoding
    private let unitSize: Int
    /// 最近解压过的 record block。全量导出时相邻词条往往落在同一块，
    /// 缓存少量块可以避免重复解压。
    private var blockCache: [(offset: UInt64, data: Data)] = []
    private let blockCacheLimit = 8

    init(file: MDictFile, header: MDictHeader) throws {
        self.file = file
        self.header = header
        self.encoding = header.encoding == "UTF-16" ? .utf16LittleEndian : .utf8
        self.unitSize = header.encoding == "UTF-16" ? 2 : 1

        let recordStart = try MDictKeyIndex.keywordSectionEnd(file: file, header: header)
        try file.seek(to: recordStart)
        let numBlocks = try file.readUInt64BE()
        let numEntries = try file.readUInt64BE()
        let infoSize = try file.readUInt64BE()
        let blocksTotalSize = try file.readUInt64BE()
        _ = numEntries

        let (expectedInfoSize, infoOverflow) = numBlocks.multipliedReportingOverflow(by: 16)
        guard !infoOverflow, infoSize == expectedInfoSize else {
            throw MDictError.recordCorrupted(
                reason: "record info size \(infoSize) does not match \(numBlocks) blocks"
            )
        }
        let (afterPreamble, preambleOverflow) = recordStart.addingReportingOverflow(32)
        let (blocksStart, tableOverflow) = afterPreamble.addingReportingOverflow(infoSize)
        guard !preambleOverflow, !tableOverflow, blocksStart <= file.fileSize else {
            throw MDictError.recordCorrupted(
                reason: "record block table extends beyond file size \(file.fileSize)"
            )
        }

        var infos: [RecordBlockInfo] = []
        infos.reserveCapacity(Int(min(numBlocks, 65_536)))
        var cursor = blocksStart
        var decompressed: UInt64 = 0
        for _ in 0..<numBlocks {
            let compSize = try file.readUInt64BE()
            let decompSize = try file.readUInt64BE()
            guard compSize >= 8, compSize <= UInt64(Int.max) else {
                throw MDictError.recordCorrupted(reason: "record block size \(compSize) is invalid")
            }
            infos.append(RecordBlockInfo(
                compSize: compSize,
                decompSize: decompSize,
                fileOffset: cursor
            ))
            let (nextCursor, cursorOverflow) = cursor.addingReportingOverflow(compSize)
            let (nextDecompressed, decompOverflow) = decompressed.addingReportingOverflow(decompSize)
            guard !cursorOverflow, !decompOverflow else {
                throw MDictError.recordCorrupted(reason: "record block sizes overflow")
            }
            cursor = nextCursor
            decompressed = nextDecompressed
        }

        let (expectedEnd, endOverflow) = blocksStart.addingReportingOverflow(blocksTotalSize)
        guard !endOverflow else {
            throw MDictError.recordCorrupted(reason: "record block section size overflows")
        }
        guard cursor == expectedEnd else {
            throw MDictError.recordCorrupted(
                reason: "record blocks span \(cursor - blocksStart) bytes, preamble declares \(blocksTotalSize)"
            )
        }
        guard cursor <= file.fileSize else {
            throw MDictError.recordCorrupted(
                reason: "record blocks end at \(cursor), beyond file size \(file.fileSize)"
            )
        }

        self.blocks = infos
        self.totalDecompressedSize = decompressed
    }

    func readDefinition(recordOffset: UInt64) throws -> String {
        guard recordOffset < totalDecompressedSize else {
            throw MDictError.recordCorrupted(
                reason: "record offset \(recordOffset) is outside 0..<\(totalDecompressedSize)"
            )
        }

        var blockStart: UInt64 = 0
        for block in blocks {
            let blockEnd = blockStart + block.decompSize
            if recordOffset < blockEnd {
                let localOffset = recordOffset - blockStart
                guard localOffset <= UInt64(Int.max) else {
                    throw MDictError.recordCorrupted(reason: "local offset is too large")
                }
                let data = try readBlock(block)
                let bytes = try definitionBytes(in: data, from: Int(localOffset))
                guard let text = String(data: bytes, encoding: encoding) else {
                    throw MDictError.decodeFailed(encoding: header.encoding)
                }
                return text
            }
            blockStart = blockEnd
        }
        throw MDictError.recordCorrupted(reason: "no record block contains offset \(recordOffset)")
    }

    /// 读取任意一段原始记录数据（MDD 的图片 / 音频 / CSS 等）。
    ///
    /// 资源记录没有 `\0` 终止符，长度必须由调用方给出；记录可能跨 block，
    /// 这里按块拼接，且不把结果当字符串解码。
    func recordData(recordOffset: UInt64, length: Int) throws -> Data {
        guard length >= 0 else {
            throw MDictError.recordCorrupted(reason: "negative record length \(length)")
        }
        guard recordOffset <= totalDecompressedSize else {
            throw MDictError.recordCorrupted(
                reason: "record offset \(recordOffset) is outside 0...\(totalDecompressedSize)"
            )
        }
        let length64 = UInt64(length)
        guard length64 <= totalDecompressedSize - recordOffset else {
            throw MDictError.recordCorrupted(
                reason: "record span \(recordOffset)+\(length) exceeds \(totalDecompressedSize)"
            )
        }
        guard length > 0 else { return Data() }

        let end = recordOffset + length64
        var result = Data()
        result.reserveCapacity(length)
        var blockStart: UInt64 = 0

        for block in blocks {
            let blockEnd = blockStart + block.decompSize
            if recordOffset < blockEnd, end > blockStart {
                let sliceStart = max(recordOffset, blockStart)
                let sliceEnd = min(end, blockEnd)
                let localStart = Int(sliceStart - blockStart)
                let localEnd = Int(sliceEnd - blockStart)
                let data = try readBlock(block)
                guard localEnd <= data.count else {
                    throw MDictError.recordCorrupted(
                        reason: "record slice ends at \(localEnd), block holds \(data.count) bytes"
                    )
                }
                let base = data.startIndex
                result.append(data[(base + localStart)..<(base + localEnd)])
            }
            if blockEnd >= end { break }
            blockStart = blockEnd
        }

        guard result.count == length else {
            throw MDictError.recordCorrupted(
                reason: "record span \(recordOffset)+\(length) yielded \(result.count) bytes"
            )
        }
        return result
    }

    private func readBlock(_ block: RecordBlockInfo) throws -> Data {
        if let hit = blockCache.first(where: { $0.offset == block.fileOffset }) {
            return hit.data
        }
        do {
            try file.seek(to: block.fileOffset)
            let compressed = try file.read(count: Int(block.compSize))
            let data = try BlockCompression.decompressBlock(
                compressed,
                expectedDecompSize: block.decompSize
            )
            guard data.count == block.decompSize else {
                throw MDictError.recordCorrupted(
                    reason: "block at \(block.fileOffset) decoded \(data.count) bytes, expected \(block.decompSize)"
                )
            }
            blockCache.insert((block.fileOffset, data), at: 0)
            if blockCache.count > blockCacheLimit {
                blockCache.removeLast()
            }
            return data
        } catch let error as MDictError {
            throw MDictError.recordCorrupted(
                reason: "record block at \(block.fileOffset) failed: \(error.localizedDescription)"
            )
        }
    }

    /// 从 localOffset 截到下一个终止符；末条记录允许没有终止符。
    private func definitionBytes(in data: Data, from start: Int) throws -> Data {
        guard start < data.count else {
            throw MDictError.recordCorrupted(
                reason: "local offset \(start) is past block size \(data.count)"
            )
        }
        let base = data.startIndex
        var index = start
        if unitSize == 1 {
            while index < data.count {
                if data[base + index] == 0 {
                    return data[(base + start)..<(base + index)]
                }
                index += 1
            }
        } else {
            while index + 1 < data.count {
                if data[base + index] == 0, data[base + index + 1] == 0 {
                    return data[(base + start)..<(base + index)]
                }
                index += 2
            }
        }
        return data[(base + start)..<(base + data.count)]
    }
}
