//
//  MDictError.swift
//  MDict
//
//  解析层统一错误类型；文案面向调试而非用户界面。
//

import Foundation

enum MDictError: Error, LocalizedError {
    case fileNotFound(path: String)
    /// 文件存在但无法打开（权限、目录、解码失败等）
    case cannotOpen(path: String, reason: String)

    /// Header 长度 / XML / 属性缺失等结构性错误
    case invalidHeader(reason: String)
    case checksumMismatch(expected: UInt32, actual: UInt32)
    /// 读取越过文件末尾（文件被截断或偏移计算错误）
    case readBeyondEOF(offset: UInt64, count: Int, fileSize: UInt64)
    case invalidOffset(offset: UInt64, fileSize: UInt64)
    /// 底层 I/O 调用失败，区别于结构层面的损坏
    case ioFailure(operation: String, reason: String)

    case unsupportedVersion(Double)
    case unsupportedHeaderEncryption(Int)
    case unsupportedEncoding(String)
    case unsupportedCompression(type: UInt8)

    /// `lookup` 按约定返回 nil；此 case 留给需要区分的调用方
    case keyNotFound(String)
    case decodeFailed(encoding: String)
    case indexCorrupted(reason: String)
    case recordCorrupted(reason: String)
    /// key index 解密失败，或解密后无法解压（两者都表示密文/密钥不匹配）
    case decryptFailed(reason: String)
    /// 单个压缩块的块头 / payload 结构不合法
    case invalidBlock(reason: String)

    var errorDescription: String? {
        switch self {
        case let .fileNotFound(path):
            return "Dictionary file not found: \(path)"
        case let .cannotOpen(path, reason):
            return "Cannot open dictionary file at \(path): \(reason)"
        case let .invalidHeader(reason):
            return "Invalid MDict header: \(reason)"
        case let .checksumMismatch(expected, actual):
            return String(
                format: "Checksum mismatch: expected %08x, got %08x",
                expected, actual
            )
        case let .readBeyondEOF(offset, count, fileSize):
            return "Read of \(count) bytes at offset \(offset) exceeds file size \(fileSize)"
        case let .invalidOffset(offset, fileSize):
            return "Offset \(offset) is outside file bounds (file size \(fileSize))"
        case let .ioFailure(operation, reason):
            return "I/O failure during \(operation): \(reason)"
        case let .unsupportedVersion(version):
            return "Unsupported MDict version \(version); only 2.0 is supported"
        case let .unsupportedHeaderEncryption(value):
            return "Encrypted=\(value) requires header decryption (password/RegCode); "
                + "only key-index encryption (Encrypted bit1) is supported"
        case let .unsupportedEncoding(encoding):
            return "Unsupported text encoding \(encoding); only UTF-8 and UTF-16LE are supported"
        case let .unsupportedCompression(type):
            return "Unsupported block compression type \(type); only none (0) and zlib (2) are supported"
        case let .keyNotFound(key):
            return "Key not found in dictionary: \(key)"
        case let .decodeFailed(encoding):
            return "Failed to decode text as \(encoding)"
        case let .indexCorrupted(reason):
            return "Keyword index is corrupted: \(reason)"
        case let .recordCorrupted(reason):
            return "Record data is corrupted: \(reason)"
        case let .decryptFailed(reason):
            return "Failed to decrypt key index: \(reason)"
        case let .invalidBlock(reason):
            return "Invalid compressed block: \(reason)"
        }
    }
}
