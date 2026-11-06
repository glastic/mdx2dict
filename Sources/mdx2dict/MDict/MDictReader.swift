//
//  MDictReader.swift
//  MDict
//
//  对外入口：组装 Header / KeyIndex / RecordReader。
//  init 只解析 header；open() 解析 key/record 元数据，可重复调用，
//  lookup/suggest 会在需要时自动 open()。
//
//  支持 Encrypted=0 与 Encrypted=2（bit1：key index 用 Fast XOR 加密，密钥由块头
//  推导）；Encrypted=1/3（bit0）需要密码 / RegCode，init 时抛错。MDict v3、LZO
//  压缩、UTF-8 / UTF-16LE 之外的编码同样明确抛错。
//  重定向：record 以 `@@@LINK=` 开头时表示别名（例如
//  `10-gallon-hat -> @@@LINK=ten-gallon hat`）。lookup 默认沿别名跳转并返回目标
//  释义，支持多级跳转、大小写差异与自指/成环；followRedirects: false 取原始 record。
//

import Foundation

final class MDictReader {
    private let file: MDictFile
    let header: MDictHeader

    /// 索引与 record 表一起赋值，任一失败都不留下半初始化状态
    private var opened: Opened?

    private struct Opened {
        let keyIndex: MDictKeyIndex
        let recordReader: MDictRecordReader
    }

    init(path: String) throws {
        let file = try MDictFile(path: path)
        self.file = file
        self.header = try MDictHeader.parse(from: file)
    }

    /// 解析 key index 与 record block 表，只解压元数据。
    func open() throws {
        guard opened == nil else { return }
        let keyIndex = try MDictKeyIndex(file: file, header: header)
        let recordReader = try MDictRecordReader(file: file, header: header)
        opened = Opened(keyIndex: keyIndex, recordReader: recordReader)
    }

    /// open() 前恒为 0。
    var entryCount: UInt64 {
        opened?.keyIndex.entryCount ?? 0
    }

    /// 精确查词，找不到返回 nil。默认跟随 `@@@LINK=` 别名；目标不存在或成环且
    /// 没有可用释义时返回 nil。`followRedirects: false` 返回原始 record。
    func lookup(_ word: String, followRedirects: Bool = true) throws -> String? {
        let state = try ensureOpen()
        guard let offset = try state.keyIndex.recordOffset(for: word) else {
            return nil
        }
        let definition = try state.recordReader.readDefinition(recordOffset: offset)
        guard followRedirects else { return definition }
        return try resolveRedirects(
            from: definition,
            state: state,
            visited: [offset],
            depth: 0
        )
    }

    /// 前缀建议，按词典顺序返回最多 limit 个 key（原始大小写，去重）。
    func suggest(_ prefix: String, limit: Int = 20) throws -> [String] {
        let state = try ensureOpen()
        return try state.keyIndex.keys(withPrefix: prefix, limit: limit)
    }

    /// 按文件顺序遍历全部 (key, recordOffset)。每个 key block 只解压一次，
    /// 适合整本导出；调用方需要自己按 recordOffset 去重/分组。
    func forEachEntry(_ body: (String, UInt64) throws -> Void) throws {
        let state = try ensureOpen()
        try state.keyIndex.forEachItem { try body($0.key, $0.recordOffset) }
    }

    /// 读取指定 offset 的原始释义，不跟随 `@@@LINK=` 别名。
    func rawDefinition(at offset: UInt64) throws -> String {
        let state = try ensureOpen()
        return try state.recordReader.readDefinition(recordOffset: offset)
    }

    /// 解析 key 对应的原始 record offset，不跟随 `@@@LINK=`。
    func recordOffset(for word: String) throws -> UInt64? {
        let state = try ensureOpen()
        return try state.keyIndex.recordOffset(for: word)
    }

    private func ensureOpen() throws -> Opened {
        if let opened {
            return opened
        }
        try open()
        guard let opened else {
            throw MDictError.indexCorrupted(reason: "dictionary failed to open")
        }
        return opened
    }

    // MARK: - 重定向

    /// MDX 约定：释义以 `@@@LINK=目标词` 开头时，这条记录只是别名。
    private static let redirectMarker = "@@@LINK="
    /// 正常词典很少超过 2–3 级；留足余量同时防止畸形数据无限跳转。
    private static let maxRedirectHops = 8

    /// 沿别名链递归。visited 记录已读过的 recordOffset：成环时改在同归一化 key 的
    /// 其它条目里找真正释义（部分词典存在这种自指数据）。
    private func resolveRedirects(
        from definition: String,
        state: Opened,
        visited: Set<UInt64>,
        depth: Int
    ) throws -> String? {
        guard let target = Self.redirectTarget(in: definition) else {
            return definition
        }
        guard depth < Self.maxRedirectHops else {
            return try concreteDefinition(for: target, state: state, visited: visited)
        }
        guard let offset = try state.keyIndex.recordOffset(for: target) else {
            // 别名指向不存在的词条：按查不到处理，不把 @@@LINK= 原文漏给调用方
            return nil
        }
        guard !visited.contains(offset) else {
            return try concreteDefinition(for: target, state: state, visited: visited)
        }
        let next = try state.recordReader.readDefinition(recordOffset: offset)
        return try resolveRedirects(
            from: next,
            state: state,
            visited: visited.union([offset]),
            depth: depth + 1
        )
    }

    /// 重定向成环/超深时的兜底：同归一化 key 下通常还有一条非别名的释义。
    private func concreteDefinition(
        for word: String,
        state: Opened,
        visited: Set<UInt64>
    ) throws -> String? {
        for item in try state.keyIndex.entries(matching: word) {
            guard !visited.contains(item.recordOffset) else { continue }
            let definition = try state.recordReader.readDefinition(recordOffset: item.recordOffset)
            if Self.redirectTarget(in: definition) == nil {
                return definition
            }
        }
        return nil
    }

    /// 解析别名目标。允许开头有 BOM（整本记录的第一条可能出现）；
    /// 目标只取第一行并去掉首尾空白，兼容 `@@@LINK=word\r\n`。
    private static func redirectTarget(in definition: String) -> String? {
        var text = definition
        if text.hasPrefix("\u{FEFF}") {
            text.removeFirst()
        }
        guard text.count >= redirectMarker.count else { return nil }
        let prefix = text.prefix(redirectMarker.count)
        guard prefix.lowercased() == redirectMarker.lowercased() else { return nil }
        let remainder = text.dropFirst(redirectMarker.count)
        let firstLine = remainder.prefix { !$0.isNewline }
        let target = firstLine.trimmingCharacters(in: .whitespacesAndNewlines)
        return target.isEmpty ? nil : target
    }
}
