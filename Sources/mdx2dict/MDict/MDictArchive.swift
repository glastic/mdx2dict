//
//  MDictArchive.swift
//  MDict
//
//  MDD 资源归档：把 .mdd 内的资源 key 映射为原始二进制数据。
//  record 是图片 / 音频 / CSS 等二进制，没有终止符，长度由下一条记录的 offset
//  界定（见 MDictKeyIndex.allRecordOffsets）；只读 Data，不解码为 String。
//  该类持有 FileHandle，不能并发读，由调用方串行化。
//

import Foundation

final class MDictArchive {
    let path: String
    let header: MDictHeader
    private let keyIndex: MDictKeyIndex
    private let records: MDictRecordReader

    init(path: String) throws {
        let file = try MDictFile(path: path)
        let header = try MDictHeader.parse(from: file)
        let keyIndex = try MDictKeyIndex(file: file, header: header)
        let records = try MDictRecordReader(file: file, header: header)
        self.path = path
        self.header = header
        self.keyIndex = keyIndex
        self.records = records
    }

    var entryCount: UInt64 { keyIndex.entryCount }

    /// 按 MDD 内的 key 读取原始记录；key 常见形态是 `\colimg\x.jpg`。
    func data(forKey key: String) throws -> Data? {
        guard let offset = try keyIndex.recordOffset(for: key) else { return nil }
        // keyIndex 缓存了全部偏移，重复请求不会重复解压 key block。
        let offsets = try keyIndex.allRecordOffsets()
        let end = Self.firstOffset(after: offset, in: offsets)
            ?? records.totalDecompressedSize
        guard offset <= end else {
            throw MDictError.recordCorrupted(
                reason: "record offset \(offset) is after its end \(end)"
            )
        }
        let length = end - offset
        guard length <= UInt64(Int.max) else {
            throw MDictError.recordCorrupted(reason: "record length \(length) is too large")
        }
        return try records.recordData(recordOffset: offset, length: Int(length))
    }

    /// 只查 key index，不读取 record 数据；用于 --resources drop/strict 的校验。
    func containsResource(key: String) throws -> Bool {
        try keyIndex.recordOffset(for: key) != nil
    }

    /// 第一个严格大于 `offset` 的记录偏移；没有则返回 nil（最后一条记录）。
    private static func firstOffset(after offset: UInt64, in offsets: [UInt64]) -> UInt64? {
        var low = 0
        var high = offsets.count
        while low < high {
            let mid = (low + high) / 2
            if offsets[mid] <= offset {
                low = mid + 1
            } else {
                high = mid
            }
        }
        return low < offsets.count ? offsets[low] : nil
    }
}

/// 一本 MDX 对应的 `.mdd` 分卷集合：`base.mdd`、`base.1.mdd` …。
/// 首次请求时才打开分卷，按序号顺序查找；单卷缺失或损坏只跳过该卷。
final class MDictArchiveSet {
    struct Volume: Equatable, Sendable {
        /// 0 = base `.mdd`，n = `.n.mdd`
        let number: Int
        let url: URL
    }

    let mdxURL: URL
    let volumes: [Volume]

    private var archives: [Int: MDictArchive] = [:]
    private var unavailableVolumes: Set<Int> = []

    /// `mdxURL` 同时决定分卷的目录与文件名前缀。
    init(mdxURL: URL) {
        self.mdxURL = mdxURL
        self.volumes = Self.discoverVolumes(for: mdxURL)
    }

    /// 按规范化后的资源路径读取（`colimg/x.jpg` 或 `\colimg\x.jpg` 均可）。
    /// 找不到、路径非法、分卷损坏都返回 nil。
    func data(forResourcePath path: String) -> Data? {
        let keys = Self.candidateKeys(for: path)
        guard !keys.isEmpty else { return nil }

        for volume in volumes {
            guard let archive = archive(for: volume) else { continue }
            for key in keys {
                if let data = try? archive.data(forKey: key) {
                    return data
                }
            }
        }
        return nil
    }

    /// 只检查资源是否存在，不读取图片/音频数据。
    func contains(resourcePath path: String) -> Bool {
        let keys = Self.candidateKeys(for: path)
        guard !keys.isEmpty else { return false }

        for volume in volumes {
            guard let archive = archive(for: volume) else { continue }
            for key in keys {
                if (try? archive.containsResource(key: key)) == true {
                    return true
                }
            }
        }
        return false
    }

    private static func candidateKeys(for path: String) -> [String] {
        let trimmed = path.trimmingCharacters(in: CharacterSet(charactersIn: "/\\"))
        guard !trimmed.isEmpty, !trimmed.contains("..") else { return [] }

        let normalized = trimmed.replacingOccurrences(of: "\\", with: "/")
        let components = normalized.split(separator: "/", omittingEmptySubsequences: true)
        guard !components.isEmpty else { return [] }

        let joined = components.joined(separator: "\\")
        return ["\\" + joined, joined]
    }

    private func archive(for volume: Volume) -> MDictArchive? {
        if let archive = archives[volume.number] { return archive }
        guard !unavailableVolumes.contains(volume.number) else { return nil }

        do {
            let archive = try MDictArchive(path: volume.url.path)
            archives[volume.number] = archive
            return archive
        } catch {
            // 单卷损坏不应让整本词典不可用；后续请求直接跳过它。
            unavailableVolumes.insert(volume.number)
            return nil
        }
    }

    private static func discoverVolumes(for mdxURL: URL) -> [Volume] {
        let directory = mdxURL.deletingLastPathComponent()
        let stem = mdxURL.deletingPathExtension().lastPathComponent
        guard !stem.isEmpty else { return [] }

        let contents = (try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        )) ?? []

        var byNumber: [Int: URL] = [:]
        for url in contents {
            guard let number = volumeNumber(for: url.lastPathComponent, stem: stem),
                  byNumber[number] == nil
            else { continue }
            byNumber[number] = url
        }

        return byNumber
            .sorted { $0.key < $1.key }
            .map { Volume(number: $0.key, url: $0.value) }
    }

    /// `base.mdd` → 0；`base.1.mdd` → 1；其它文件 → nil。
    private static func volumeNumber(for name: String, stem: String) -> Int? {
        let lowerName = name.lowercased()
        let lowerStem = stem.lowercased()
        guard lowerName.hasSuffix(".mdd") else { return nil }
        if lowerName == lowerStem + ".mdd" { return 0 }

        let prefix = lowerStem + "."
        guard lowerName.hasPrefix(prefix) else { return nil }
        let middle = lowerName.dropFirst(prefix.count).dropLast(4)
        guard !middle.isEmpty,
              middle.allSatisfy({ $0.isASCII && $0.isNumber }),
              let number = Int(middle), number > 0
        else { return nil }
        return number
    }
}
