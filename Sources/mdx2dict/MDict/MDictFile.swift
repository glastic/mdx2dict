//
//  MDictFile.swift
//  MDict
//
//  词典文件的随机读取封装。位置由本类记录，每次 read 前再对齐 FileHandle，
//  避免两处状态不同步。
//

import Foundation

final class MDictFile {
    private let handle: FileHandle
    private let path: String
    private var offset: UInt64 = 0

    let fileSize: UInt64

    init(path: String) throws {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) else {
            throw MDictError.fileNotFound(path: path)
        }
        guard !isDirectory.boolValue else {
            throw MDictError.cannotOpen(path: path, reason: "path is a directory")
        }

        let size: UInt64
        do {
            let attributes = try FileManager.default.attributesOfItem(atPath: path)
            guard let number = attributes[.size] as? NSNumber else {
                throw MDictError.cannotOpen(path: path, reason: "file size is unavailable")
            }
            size = number.uint64Value
        } catch let error as MDictError {
            throw error
        } catch {
            throw MDictError.cannotOpen(path: path, reason: error.localizedDescription)
        }

        do {
            self.handle = try FileHandle(forReadingFrom: URL(fileURLWithPath: path))
        } catch {
            throw MDictError.cannotOpen(path: path, reason: error.localizedDescription)
        }
        self.path = path
        self.fileSize = size
    }

    deinit {
        try? handle.close()
    }

    /// 只记录目标位置，真正的 handle 移动推迟到下一次 read。
    func seek(to offset: UInt64) throws {
        guard offset <= fileSize else {
            throw MDictError.invalidOffset(offset: offset, fileSize: fileSize)
        }
        self.offset = offset
    }

    func read(count: Int) throws -> Data {
        guard count >= 0 else {
            throw MDictError.ioFailure(operation: "read", reason: "negative byte count \(count)")
        }
        guard offset <= fileSize, UInt64(count) <= fileSize - offset else {
            throw MDictError.readBeyondEOF(offset: offset, count: count, fileSize: fileSize)
        }
        guard count > 0 else {
            return Data()
        }

        do {
            try handle.seek(toOffset: offset)
            guard let data = try handle.read(upToCount: count), data.count == count else {
                throw MDictError.readBeyondEOF(offset: offset, count: count, fileSize: fileSize)
            }
            offset += UInt64(count)
            return data
        } catch let error as MDictError {
            throw error
        } catch {
            throw MDictError.ioFailure(operation: "read", reason: error.localizedDescription)
        }
    }

    func readUInt32BE() throws -> UInt32 {
        let data = try read(count: 4)
        var value: UInt32 = 0
        for byte in data {
            value = (value << 8) | UInt32(byte)
        }
        return value
    }

    func readUInt64BE() throws -> UInt64 {
        let data = try read(count: 8)
        var value: UInt64 = 0
        for byte in data {
            value = (value << 8) | UInt64(byte)
        }
        return value
    }

    func readUInt32LE() throws -> UInt32 {
        let data = try read(count: 4)
        var value: UInt32 = 0
        for byte in data.reversed() {
            value = (value << 8) | UInt32(byte)
        }
        return value
    }
}
