//
//  MDictKeyIndex.swift
//  MDict
//
//  解析 Keyword Section 元数据并按词定位 recordOffset。2.0 布局：
//    5 × UInt64 BE（blocks、entries、index 解压/压缩大小、key blocks 总大小）
//    + UInt32 BE（前 40 字节的 Adler-32）+ key index block + 首尾相接的 key blocks。
//  Encrypted bit1 时，key index block 先经 MDictFastDecrypt 再解压；其余部分不受影响。
//

import Foundation

final class MDictKeyIndex {
    private let file: MDictFile
    private let header: MDictHeader
    private let keyBlocks: [KeyBlockInfo]
    /// 与 keyBlocks 一一对应；大小写不敏感时统一小写，用于 block 定位
    private let blockFirstKeys: [String]
    private let blockLastKeys: [String]
    private let encoding: String.Encoding
    /// UTF-8 单元为 1 字节，UTF-16 为 2 字节；key 长度字段按单元计数
    private let unitSize: Int
    /// `allRecordOffsets()` 的惰性缓存；由持有者串行访问。
    private var cachedRecordOffsets: [UInt64]?
    /// 最近解压过的 key block；大量 lookup 时避免重复解压。
    private var keyBlockCache: [UInt64: Data] = [:]
    private var keyBlockCacheOrder: [UInt64] = []
    private let keyBlockCacheLimit = 256

    let entryCount: UInt64
    let recordSectionOffset: UInt64

    init(file: MDictFile, header: MDictHeader) throws {
        self.file = file
        self.header = header
        self.encoding = header.encoding == "UTF-16" ? .utf16LittleEndian : .utf8
        self.unitSize = header.encoding == "UTF-16" ? 2 : 1

        let keywordStart = 4 + UInt64(header.headerLength) + 4
        try file.seek(to: keywordStart)
        let preamble = try file.read(count: 40)
        let storedChecksum = try file.readUInt32BE()
        let computedChecksum = Adler32.checksum(preamble)
        guard storedChecksum == computedChecksum else {
            throw MDictError.checksumMismatch(expected: storedChecksum, actual: computedChecksum)
        }

        let numKeyBlocks = Self.uint64BE(preamble, at: 0)
        self.entryCount = Self.uint64BE(preamble, at: 8)
        let keyIndexDecompSize = Self.uint64BE(preamble, at: 16)
        let keyIndexCompSize = Self.uint64BE(preamble, at: 24)
        let keyBlocksTotalSize = Self.uint64BE(preamble, at: 32)

        guard keyIndexCompSize >= 8, keyIndexCompSize <= UInt64(Int.max) else {
            throw MDictError.indexCorrupted(reason: "key index compressed size \(keyIndexCompSize) is invalid")
        }
        let keyIndexBlock = try file.read(count: Int(keyIndexCompSize))
        let keyIndexData: Data
        if header.isKeyIndexEncrypted {
            keyIndexData = try Self.decryptAndDecompressKeyIndex(
                keyIndexBlock,
                expectedDecompSize: keyIndexDecompSize
            )
        } else {
            keyIndexData = try Self.decompress(
                keyIndexBlock,
                expectedDecompSize: keyIndexDecompSize,
                context: "key index"
            )
        }

        var reader = ByteReader(keyIndexData)
        var blocks: [KeyBlockInfo] = []
        blocks.reserveCapacity(Int(min(numKeyBlocks, 4096)))
        var entriesSeen: UInt64 = 0
        for _ in 0..<numKeyBlocks {
            let entries = try reader.readUInt64BE()
            let (entriesTotal, entriesOverflow) = entriesSeen.addingReportingOverflow(entries)
            guard !entriesOverflow else {
                throw MDictError.indexCorrupted(reason: "entry count overflows")
            }
            entriesSeen = entriesTotal

            let firstSize = Int(try reader.readUInt16BE())
            let firstBytes = try reader.readBytes(firstSize * unitSize)
            try reader.skip(unitSize)   // 结尾的 \0 不计入长度
            let firstKey = try Self.decode(firstBytes, encoding: encoding, headerEncoding: header.encoding)

            let lastSize = Int(try reader.readUInt16BE())
            let lastBytes = try reader.readBytes(lastSize * unitSize)
            try reader.skip(unitSize)
            let lastKey = try Self.decode(lastBytes, encoding: encoding, headerEncoding: header.encoding)

            let compSize = try reader.readUInt64BE()
            let decompSize = try reader.readUInt64BE()

            blocks.append(KeyBlockInfo(
                numEntries: entries,
                firstKey: firstKey,
                lastKey: lastKey,
                compSize: compSize,
                decompSize: decompSize,
                fileOffset: 0
            ))
        }

        guard entriesSeen == entryCount else {
            throw MDictError.indexCorrupted(
                reason: "key blocks contain \(entriesSeen) entries, expected \(entryCount)"
            )
        }

        let keyBlocksStart = keywordStart + 44 + keyIndexCompSize
        var offset = keyBlocksStart
        var assigned: [KeyBlockInfo] = []
        assigned.reserveCapacity(blocks.count)
        for block in blocks {
            guard block.compSize >= 8, block.compSize <= UInt64(Int.max) else {
                throw MDictError.indexCorrupted(
                    reason: "key block size \(block.compSize) is invalid"
                )
            }
            assigned.append(KeyBlockInfo(
                numEntries: block.numEntries,
                firstKey: block.firstKey,
                lastKey: block.lastKey,
                compSize: block.compSize,
                decompSize: block.decompSize,
                fileOffset: offset
            ))
            let (next, overflowed) = offset.addingReportingOverflow(block.compSize)
            guard !overflowed else {
                throw MDictError.indexCorrupted(reason: "key block offsets overflow")
            }
            offset = next
        }

        let (expectedEnd, endOverflow) = keyBlocksStart.addingReportingOverflow(keyBlocksTotalSize)
        guard !endOverflow else {
            throw MDictError.indexCorrupted(reason: "key block section size overflows")
        }
        guard offset == expectedEnd else {
            throw MDictError.indexCorrupted(
                reason: "key blocks span \(offset - keyBlocksStart) bytes, preamble declares \(keyBlocksTotalSize)"
            )
        }
        guard offset <= file.fileSize else {
            throw MDictError.indexCorrupted(
                reason: "key blocks end at \(offset), beyond file size \(file.fileSize)"
            )
        }

        self.keyBlocks = assigned
        self.recordSectionOffset = offset
        // 二分依赖 block 范围有序；必须先按词典的比较规则归一化（大小写 + Stripkey）
        self.blockFirstKeys = assigned.map {
            Self.normalize($0.firstKey, caseSensitive: header.keyCaseSensitive, stripKey: header.stripKey)
        }
        self.blockLastKeys = assigned.map {
            Self.normalize($0.lastKey, caseSensitive: header.keyCaseSensitive, stripKey: header.stripKey)
        }
    }

    /// 精确匹配，找到则返回 recordOffset。
    /// 同一归一化 key 可能有多条记录（如 `24/7` 与 `24-7`）：优先返回原文与查询词
    /// 完全一致的条目，否则退回第一条，避免重定向在大小写别名之间来回跳。
    /// 命中一个 block 后必须扫完整个 block：某些词典最后一个 block 里 `Å` 排在
    /// `à-la` 前，提前按「已越过目标」返回会让 9 个 `à*` 词条查不到。
    func recordOffset(for word: String) throws -> UInt64? {
        guard !keyBlocks.isEmpty else { return nil }
        let target = normalize(word)

        // 先找第一个 lastKey >= target 的 block；重复词/边界词可能跨块，继续向后检查
        var low = 0
        var high = keyBlocks.count
        while low < high {
            let mid = (low + high) / 2
            if Self.compareKeys(blockLastKeys[mid], target) < 0 {
                low = mid + 1
            } else {
                high = mid
            }
        }
        var fallback: UInt64?
        var index = low
        while index < keyBlocks.count, Self.compareKeys(blockFirstKeys[index], target) <= 0 {
            for item in try items(in: keyBlocks[index]) {
                let normalizedKey = normalize(item.key)
                guard normalizedKey == target else { continue }
                if item.key == word {
                    return item.recordOffset
                }
                if fallback == nil {
                    fallback = item.recordOffset
                }
            }
            index += 1
        }
        return fallback
    }

    /// 返回所有归一化后等于 word 的条目（保持文件顺序）。
    /// 仅用于重定向环的兜底：多个别名中的一个成环时，从中找真正的释义。
    func entries(matching word: String) throws -> [KeyItem] {
        guard !keyBlocks.isEmpty else { return [] }
        let target = normalize(word)

        var low = 0
        var high = keyBlocks.count
        while low < high {
            let mid = (low + high) / 2
            if Self.compareKeys(blockLastKeys[mid], target) < 0 {
                low = mid + 1
            } else {
                high = mid
            }
        }

        var results: [KeyItem] = []
        var index = low
        while index < keyBlocks.count, Self.compareKeys(blockFirstKeys[index], target) <= 0 {
            for item in try items(in: keyBlocks[index]) {
                if normalize(item.key) == target {
                    results.append(item)
                }
            }
            index += 1
        }
        return results
    }

    /// 返回按文件顺序、以 prefix 开头的前 limit 个 key（保留原始大小写）。
    /// 前缀比较同样走 normalize；若 prefix 全由标点/空白组成，归一化后为空串，
    /// 此时退回「只忽略大小写」，避免把整本词典都当成候选。
    func keys(withPrefix prefix: String, limit: Int) throws -> [String] {
        guard limit > 0, !keyBlocks.isEmpty else { return [] }

        let normalizedPrefix = normalize(prefix)
        let prefixIsPurePunctuation = normalizedPrefix.isEmpty && !prefix.isEmpty
        let target = prefixIsPurePunctuation ? caseNormalized(prefix) : normalizedPrefix

        var startBlock = 0
        if !prefixIsPurePunctuation {
            // 与精确查找相同：第一个 lastKey >= target 的 block 才可能包含目标
            var low = 0
            var high = keyBlocks.count
            while low < high {
                let mid = (low + high) / 2
                if Self.compareKeys(blockLastKeys[mid], target) < 0 {
                    low = mid + 1
                } else {
                    high = mid
                }
            }
            startBlock = low
        }

        var results: [String] = []
        results.reserveCapacity(limit)
        var lastResult: String?
        var index = startBlock
        while index < keyBlocks.count, results.count < limit {
            for item in try items(in: keyBlocks[index]) {
                let comparable = prefixIsPurePunctuation ? caseNormalized(item.key) : normalize(item.key)
                if comparable.hasPrefix(target) {
                    // 同一原始 key 可能在单个 block 内重复出现，建议列表只保留一次
                    if item.key != lastResult {
                        results.append(item.key)
                        lastResult = item.key
                        if results.count == limit { return results }
                    }
                } else if !prefixIsPurePunctuation, Self.compareKeys(comparable, target) > 0 {
                    // 前缀区间已经走完，后面的 key 只会更大
                    return results
                }
            }
            index += 1
        }
        return results
    }

    /// 按文件顺序排列的去重 record 偏移。
    ///
    /// MDD 的二进制记录没有终止符，长度只能由下一条记录的 offset 界定；
    /// key 顺序与 record 顺序不一致，别名还可能指向同一 offset，因此要排序去重。
    /// 第一次调用解压全部 key block，之后走缓存。
    func allRecordOffsets() throws -> [UInt64] {
        if let cachedRecordOffsets {
            return cachedRecordOffsets
        }

        var offsets: [UInt64] = []
        offsets.reserveCapacity(Int(min(entryCount, 1_000_000)))
        for block in keyBlocks {
            for item in try items(in: block) {
                offsets.append(item.recordOffset)
            }
        }
        offsets.sort()
        if offsets.count > 1 {
            var unique: [UInt64] = []
            unique.reserveCapacity(offsets.count)
            for offset in offsets where unique.last != offset {
                unique.append(offset)
            }
            offsets = unique
        }

        cachedRecordOffsets = offsets
        return offsets
    }

    /// 按文件顺序遍历全部 (key, recordOffset)。每个 key block 只解压一次。
    func forEachItem(_ body: (KeyItem) throws -> Void) throws {
        for block in keyBlocks {
            for item in try items(in: block) {
                try body(item)
            }
        }
    }

    /// 读取并解压一个 key block，解析出其中全部 (key, recordOffset)。
    private func items(in block: KeyBlockInfo) throws -> [KeyItem] {
        let data = try decompressedBlock(block)
        var reader = ByteReader(data)
        var items: [KeyItem] = []
        items.reserveCapacity(Int(min(block.numEntries, 100_000)))
        for _ in 0..<block.numEntries {
            let recordOffset = try reader.readUInt64BE()
            let keyBytes = try reader.readTerminatedKey(unitSize: unitSize)
            let key = try Self.decode(keyBytes, encoding: encoding, headerEncoding: header.encoding)
            items.append(KeyItem(key: key, recordOffset: recordOffset))
        }
        return items
    }

    private func decompressedBlock(_ block: KeyBlockInfo) throws -> Data {
        if let cached = keyBlockCache[block.fileOffset] {
            return cached
        }

        let compressed: Data
        do {
            try file.seek(to: block.fileOffset)
            compressed = try file.read(count: Int(block.compSize))
        } catch let error as MDictError {
            throw MDictError.indexCorrupted(
                reason: "cannot read key block at \(block.fileOffset): \(error.localizedDescription)"
            )
        }
        let data = try Self.decompress(
            compressed,
            expectedDecompSize: block.decompSize,
            context: "key block at \(block.fileOffset)"
        )

        keyBlockCache[block.fileOffset] = data
        keyBlockCacheOrder.append(block.fileOffset)
        if keyBlockCacheOrder.count > keyBlockCacheLimit {
            let oldest = keyBlockCacheOrder.removeFirst()
            keyBlockCache.removeValue(forKey: oldest)
        }
        return data
    }

    private func normalize(_ key: String) -> String {
        Self.normalize(key, caseSensitive: header.keyCaseSensitive, stripKey: header.stripKey)
    }

    /// 只做大小写归一化（Stripkey 前的形式），用于同一归一化 key 的精确优先匹配。
    private func caseNormalized(_ key: String) -> String {
        header.keyCaseSensitive ? key : key.lowercased()
    }

    /// 词典用于比较 / 排序的 key 形式。
    /// - KeyCaseSensitive=No：统一小写。
    /// - Stripkey=Yes：再去掉 ASCII 标点与空白，保留 Unicode 字符（如破折号）。
    ///   部分词典的全部 key 均按此规则升序；只做大小写归一化会让部分词定位到错误 block。
    private static func normalize(_ key: String, caseSensitive: Bool, stripKey: Bool) -> String {
        let base = caseSensitive ? key : key.lowercased()
        guard stripKey else { return base }
        let kept = base.unicodeScalars.filter { !isStrippable($0) }
        return String(kept.map { Character($0) })
    }

    private static func isStrippable(_ scalar: Unicode.Scalar) -> Bool {
        guard scalar.isASCII else { return false }
        switch scalar.value {
        case 0x00...0x20,   // 控制字符与空白
             0x21...0x2F,   // ! " # $ % & ' ( ) * + , - . /
             0x3A...0x40,   // : ; < = > ? @
             0x5B...0x60,   // [ \ ] ^ _ `
             0x7B...0x7E:   // { | } ~
            return true
        default:
            return false
        }
    }

    /// 按 Unicode 码点比较，不能用 Swift 的 `<`：后者遵循 Unicode 排序规则，
    /// 会把分解形式的 "e + ◌́" 当成 "é"，而 MDX 写入器按码点排序。
    /// 某些含组合字符的词条会因此判断反序，导致二分后整段查不到。
    private static func compareKeys(_ lhs: String, _ rhs: String) -> Int {
        var left = lhs.unicodeScalars.makeIterator()
        var right = rhs.unicodeScalars.makeIterator()
        while true {
            switch (left.next(), right.next()) {
            case (nil, nil):
                return 0
            case (nil, _):
                return -1
            case (_, nil):
                return 1
            case let (leftScalar?, rightScalar?):
                if leftScalar.value != rightScalar.value {
                    return leftScalar.value < rightScalar.value ? -1 : 1
                }
            }
        }
    }

    private static func decode(
        _ bytes: Data,
        encoding: String.Encoding,
        headerEncoding: String
    ) throws -> String {
        guard let text = String(data: bytes, encoding: encoding) else {
            throw MDictError.decodeFailed(encoding: headerEncoding)
        }
        return text
    }

    /// Header Encrypted bit1：key index 压缩块的前 8 字节不加密，从第 9 字节起是
    /// Fast XOR 密文。解密或随后解压失败都报 decryptFailed，因为两者都表示密文与
    /// 推导出的密钥不匹配，而不是普通结构错误。key block 正文与 record 不走这条路径。
    private static func decryptAndDecompressKeyIndex(
        _ block: Data,
        expectedDecompSize: UInt64
    ) throws -> Data {
        let decrypted: Data
        do {
            decrypted = try MDictFastDecrypt.decryptKeyIndexBlock(block)
        } catch {
            throw MDictError.decryptFailed(reason: error.localizedDescription)
        }
        do {
            return try BlockCompression.decompressBlock(
                decrypted,
                expectedDecompSize: expectedDecompSize
            )
        } catch {
            throw MDictError.decryptFailed(
                reason: "decrypted data could not be decompressed: \(error.localizedDescription)"
            )
        }
    }

    private static func decompress(_ block: Data, expectedDecompSize: UInt64, context: String) throws -> Data {
        do {
            return try BlockCompression.decompressBlock(block, expectedDecompSize: expectedDecompSize)
        } catch {
            throw MDictError.indexCorrupted(
                reason: "\(context) failed to decompress: \(error.localizedDescription)"
            )
        }
    }

    private static func uint64BE(_ data: Data, at offset: Int) -> UInt64 {
        var value: UInt64 = 0
        for index in offset..<(offset + 8) {
            value = (value << 8) | UInt64(data[data.startIndex + index])
        }
        return value
    }

    /// Keyword Section 的结束偏移，也就是 Record Section 的起点；无需重新解析 key index。
    static func keywordSectionEnd(file: MDictFile, header: MDictHeader) throws -> UInt64 {
        let keywordStart = 4 + UInt64(header.headerLength) + 4
        try file.seek(to: keywordStart)
        let preamble = try file.read(count: 40)
        let storedChecksum = try file.readUInt32BE()
        let computedChecksum = Adler32.checksum(preamble)
        guard storedChecksum == computedChecksum else {
            throw MDictError.checksumMismatch(expected: storedChecksum, actual: computedChecksum)
        }
        let keyIndexCompSize = uint64BE(preamble, at: 24)
        let keyBlocksTotalSize = uint64BE(preamble, at: 32)

        var end = keywordStart
        for addition in [UInt64(44), keyIndexCompSize, keyBlocksTotalSize] {
            let (next, overflow) = end.addingReportingOverflow(addition)
            guard !overflow, next <= file.fileSize else {
                throw MDictError.indexCorrupted(
                    reason: "keyword section extends beyond file size \(file.fileSize)"
                )
            }
            end = next
        }
        return end
    }
}

/// 带边界检查的顺序读取器；越界统一定义为 indexCorrupted。
private struct ByteReader {
    private let data: Data
    private(set) var position: Int = 0

    init(_ data: Data) {
        self.data = data
    }

    mutating func readUInt16BE() throws -> UInt16 {
        let bytes = try readBytes(2)
        return UInt16(bytes[bytes.startIndex]) << 8 | UInt16(bytes[bytes.startIndex + 1])
    }

    mutating func readUInt64BE() throws -> UInt64 {
        let bytes = try readBytes(8)
        var value: UInt64 = 0
        for index in 0..<8 {
            value = (value << 8) | UInt64(bytes[bytes.startIndex + index])
        }
        return value
    }

    mutating func readBytes(_ count: Int) throws -> Data {
        guard count >= 0, count <= data.count - position else {
            throw MDictError.indexCorrupted(
                reason: "unexpected end of key index at byte \(position), need \(count) more"
            )
        }
        let start = data.startIndex + position
        position += count
        return data[start..<(start + count)]
    }

    mutating func skip(_ count: Int) throws {
        _ = try readBytes(count)
    }

    /// key 以空字符结尾：UTF-8 是 1 字节，UTF-16 是 2 字节（按单元对齐扫描）。
    mutating func readTerminatedKey(unitSize: Int) throws -> Data {
        let start = position
        var index = position
        if unitSize == 1 {
            while index < data.count {
                if data[data.startIndex + index] == 0 {
                    position = index + 1
                    return data[(data.startIndex + start)..<(data.startIndex + index)]
                }
                index += 1
            }
        } else {
            while index + 1 < data.count {
                if data[data.startIndex + index] == 0,
                   data[data.startIndex + index + 1] == 0 {
                    position = index + 2
                    return data[(data.startIndex + start)..<(data.startIndex + index)]
                }
                index += 2
            }
        }
        throw MDictError.indexCorrupted(reason: "key block ends without a null terminator")
    }
}
