//
//  Compression.swift
//  MDict
//
//  解压单个数据 block（zlib / 无压缩）。块布局为 4 字节 comp_type（LE）
//  + 4 字节 Adler-32（BE，针对解压后数据）+ payload。MDict 的 zlib 是 RFC 1950
//  封装，而 COMPRESSION_ZLIB 只接受 raw DEFLATE，因此要先剥掉 2 字节头和 4 字节尾。
//

import Compression
import Foundation

enum BlockCompression {
    static func decompressBlock(_ data: Data, expectedDecompSize: UInt64) throws -> Data {
        guard data.count >= 8 else {
            throw MDictError.invalidBlock(reason: "block is \(data.count) bytes, need at least 8")
        }
        guard expectedDecompSize <= UInt64(Int.max) else {
            throw MDictError.invalidBlock(reason: "decompressed size \(expectedDecompSize) is too large")
        }

        let header = Data(data.prefix(8))
        let info = UInt32(header[0])
            | UInt32(header[1]) << 8
            | UInt32(header[2]) << 16
            | UInt32(header[3]) << 24
        let compressionType = UInt8(info & 0x0F)
        let storedChecksum = UInt32(header[4]) << 24
            | UInt32(header[5]) << 16
            | UInt32(header[6]) << 8
            | UInt32(header[7])
        let payload = Data(data.dropFirst(8))
        let expectedSize = Int(expectedDecompSize)

        let result: Data
        switch compressionType {
        case 0:
            guard payload.count == expectedSize else {
                throw MDictError.invalidBlock(
                    reason: "uncompressed payload is \(payload.count) bytes, expected \(expectedSize)"
                )
            }
            result = payload
        case 2:
            result = try inflateZlib(payload, expectedSize: expectedSize)
        default:
            throw MDictError.unsupportedCompression(type: compressionType)
        }

        guard result.count == expectedSize else {
            throw MDictError.invalidBlock(
                reason: "decoded \(result.count) bytes, expected \(expectedSize)"
            )
        }
        let actualChecksum = Adler32.checksum(result)
        guard actualChecksum == storedChecksum else {
            throw MDictError.checksumMismatch(expected: storedChecksum, actual: actualChecksum)
        }
        return result
    }

    private static func inflateZlib(_ payload: Data, expectedSize: Int) throws -> Data {
        guard payload.count >= 6 else {
            throw MDictError.invalidBlock(reason: "zlib payload is \(payload.count) bytes, too short")
        }
        let cmf = payload[0]
        let flg = payload[1]
        guard cmf & 0x0F == 8 else {
            throw MDictError.invalidBlock(reason: "zlib CM is not deflate")
        }
        guard (UInt16(cmf) << 8 | UInt16(flg)) % 31 == 0 else {
            throw MDictError.invalidBlock(reason: "zlib header check bits are invalid")
        }
        guard flg & 0x20 == 0 else {
            throw MDictError.invalidBlock(reason: "zlib preset dictionary is not supported")
        }

        // 块头自带 Adler-32；zlib 尾只做封装，不参与本层校验
        let deflate = payload.dropFirst(2).dropLast(4)
        guard !deflate.isEmpty else {
            throw MDictError.invalidBlock(reason: "deflate stream is empty")
        }
        guard expectedSize > 0 else {
            return Data()
        }

        var output = Data(count: expectedSize)
        let decoded = output.withUnsafeMutableBytes { destination -> Int in
            guard let destinationBase = destination.bindMemory(to: UInt8.self).baseAddress else {
                return 0
            }
            return deflate.withUnsafeBytes { source -> Int in
                guard let sourceBase = source.bindMemory(to: UInt8.self).baseAddress else {
                    return 0
                }
                return compression_decode_buffer(
                    destinationBase,
                    expectedSize,
                    sourceBase,
                    deflate.count,
                    nil,
                    COMPRESSION_ZLIB
                )
            }
        }
        guard decoded == expectedSize else {
            throw MDictError.invalidBlock(
                reason: "zlib decoded \(decoded) bytes, expected \(expectedSize)"
            )
        }
        return output
    }
}
