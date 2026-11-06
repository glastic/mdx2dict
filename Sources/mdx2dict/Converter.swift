import Darwin
import Foundation

enum ResourcePolicy: String {
    case skip
    case drop
    case strict
}

struct ConvertOptions {
    var input: URL
    var limit: Int
    var name: String?
    var outDir: URL
    var ddk: DDK
    var install: Bool
    var verbose: Bool
    var words: [String]
    var cssPath: String?
    var cssExtra: String?
    var imagePolicy: HTMLSanitizer.ImagePolicy
    var audioPolicy: HTMLSanitizer.AudioPolicy
    var audioExclude: String?
    var cleanWork: Bool
    var jobs: Int
    var resources: ResourcePolicy
}

struct Converter {
    func run(_ options: ConvertOptions) throws -> URL {
        let startedAt = Date()
        let reader = try MDictReader(path: options.input.path)
        try reader.open()

        let name = sanitizeBundleName(options.name ?? reader.header.title)
        let workDir = try makeWorkDir(in: options.outDir, name: name)

        let plans: [PlannedEntry]
        let linkIndex: EntryIndex
        if options.limit == 0 && options.words.isEmpty {
            let planned = try planFullEntries(reader: reader)
            plans = planned.entries
            linkIndex = planned.index
        } else {
            var rawEntries = options.words.isEmpty
                ? try collectRawEntries(reader: reader, limit: options.limit)
                : try collectRawWords(reader: reader, words: options.words)
            guard !rawEntries.isEmpty else {
                throw Mdx2DictError.usage("no convertible entries found in \(options.input.path)")
            }
            if options.limit != 0 || !options.words.isEmpty {
                expandLinkTargets(reader: reader, entries: &rawEntries, maxExtra: 200)
            }
            plans = rawEntries.map {
                PlannedEntry(id: $0.id, keys: $0.keys, source: .raw($0.raw))
            }
            linkIndex = EntryIndex(entries: rawEntries)
        }
        guard !plans.isEmpty else {
            throw Mdx2DictError.usage("no convertible entries found in \(options.input.path)")
        }
        let collectedAt = Date()

        let imageStore = options.imagePolicy == .none
            ? nil
            : ImageStore(mdxURL: options.input, policy: options.resources)
        let audioExclude: NSRegularExpression?
        if let pattern = options.audioExclude {
            do {
                audioExclude = try NSRegularExpression(
                    pattern: pattern,
                    options: [.caseInsensitive]
                )
            } catch {
                throw Mdx2DictError.invalidOption(
                    "invalid --audio-exclude regex: \(error.localizedDescription)"
                )
            }
        } else {
            audioExclude = nil
        }
        let audioStore = options.audioPolicy == .none
            ? nil
            : AudioStore(mdxURL: options.input, policy: options.resources)

        if options.verbose {
            print("dictionary: \(reader.header.title)")
            print("entries exported: \(plans.count)")
            print("work dir: \(workDir.path)")
            print("jobs: \(options.jobs == 0 ? "auto" : "\(options.jobs)")")
            print("resources: \(options.resources.rawValue)")
            fflush(stdout)
        }

        let xmlWriter = try XMLWriter(url: workDir.appendingPathComponent("dict.xml"))
        try writePlannedEntries(
            plans: plans,
            reader: reader,
            linkIndex: linkIndex,
            imageStore: imageStore,
            audioStore: audioStore,
            imagePolicy: options.imagePolicy,
            audioPolicy: options.audioPolicy,
            audioExclude: audioExclude,
            writer: xmlWriter,
            verbose: options.verbose,
            jobs: options.jobs
        )
        xmlWriter.finish()
        let xmlAt = Date()

        if options.resources == .strict {
            var missing = (imageStore?.missingKeys ?? []) + (audioStore?.missingKeys ?? [])
            missing = Array(Set(missing)).sorted()
            if !missing.isEmpty {
                throw Mdx2DictError.missingResources(missing)
            }
        }

        if options.resources == .drop {
            let droppedImages = imageStore?.missingKeys.count ?? 0
            let droppedAudio = audioStore?.missingKeys.count ?? 0
            if options.verbose && (droppedImages > 0 || droppedAudio > 0) {
                print("resources: dropped \(droppedImages) image / \(droppedAudio) audio missing reference(s)")
                fflush(stdout)
            }
        }
        let cssURL = try resolveCSS(input: options.input, explicit: options.cssPath)
        if options.verbose {
            print("css: \(cssURL?.path ?? "(built-in minimal)")")
        }
        try writeCSS(
            from: cssURL,
            extraPath: options.cssExtra,
            to: workDir.appendingPathComponent("style.css")
        )
        try writeInfoPlist(name: name, to: workDir.appendingPathComponent("Info.plist"))

        if options.verbose {
            print("building dictionary with DDK...")
            fflush(stdout)
        }
        let dictionary = try options.ddk.build(workDir: workDir, name: name)
        let builtAt = Date()

        // 直接写进构建产物，避免 DDK 再从 OtherResources 复制一遍（音频可能有 GB 级）。
        let resources = dictionary.appendingPathComponent(
            "Contents/Resources",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: resources,
            withIntermediateDirectories: true
        )

        if let imageStore {
            if options.verbose {
                print("writing images...")
                fflush(stdout)
            }
            let stats = try imageStore.write(to: resources, jobs: options.jobs)
            if options.verbose {
                let formatted = ByteCountFormatter.string(
                    fromByteCount: Int64(stats.bytes),
                    countStyle: .file
                )
                print("images: \(stats.count) files, \(formatted), skipped \(stats.skipped)")
            }
        }

        if let audioStore {
            if options.verbose {
                print("writing audio...")
                fflush(stdout)
            }
            let stats = try audioStore.write(to: resources, jobs: options.jobs)
            if options.verbose {
                let formatted = ByteCountFormatter.string(
                    fromByteCount: Int64(stats.bytes),
                    countStyle: .file
                )
                print("audio: \(stats.count) files, \(formatted), skipped \(stats.skipped)")
            }
        }
        let resourcesAt = Date()

        if options.verbose {
            print("built: \(dictionary.path)")
            print(String(
                format: "timing: collect=%.2fs stream=%.2fs ddk=%.2fs resources=%.2fs total=%.2fs",
                collectedAt.timeIntervalSince(startedAt),
                xmlAt.timeIntervalSince(collectedAt),
                builtAt.timeIntervalSince(xmlAt),
                resourcesAt.timeIntervalSince(builtAt),
                resourcesAt.timeIntervalSince(startedAt)
            ))
        }

        var finalURL = dictionary
        if options.install {
            let installed = try install(dictionary)
            finalURL = installed
            print("installed: \(installed.path)")
            print("Open Dictionary.app and enable \"\(name)\" in Settings.")
        } else {
            print(dictionary.path)
        }

        if options.cleanWork {
            if options.install {
                try? FileManager.default.removeItem(at: workDir)
                if options.verbose {
                    print("work dir removed: \(workDir.path)")
                }
            } else {
                // 未安装时产物在 work 目录里，先搬到 outDir 再清理。
                let stable = uniqueOutputURL(
                    in: options.outDir,
                    name: dictionary.lastPathComponent
                )
                do {
                    try FileManager.default.createDirectory(
                        at: options.outDir,
                        withIntermediateDirectories: true
                    )
                    try FileManager.default.moveItem(at: dictionary, to: stable)
                    finalURL = stable
                    try? FileManager.default.removeItem(at: workDir)
                    print("dictionary: \(stable.path)")
                    if options.verbose {
                        print("work dir removed: \(workDir.path)")
                    }
                } catch {
                    print("warning: could not clean work dir: \(error.localizedDescription)")
                    print("work dir: \(workDir.path)")
                }
            }
        } else if options.verbose {
            print("work dir kept: \(workDir.path)")
        }
        return finalURL
    }

    // MARK: - Raw entries

    private struct RawEntry {
        let id: String
        let keys: [String]
        let raw: String
    }

    private struct Entry {
        let id: String
        let keys: [String]
        let html: String
    }

    private struct PlannedEntry {
        enum Source {
            case offset(UInt64)
            case raw(String)
        }

        let id: String
        let keys: [String]
        let source: Source
    }

    private func collectRawEntries(reader: MDictReader, limit: Int) throws -> [RawEntry] {
        var groups: [UInt64: [String]] = [:]
        var order: [UInt64] = []
        var simpleOrder: [UInt64] = []
        var simpleSeen: Set<UInt64> = []
        var keyToOffset: [String: UInt64] = [:]

        let simpleTarget = limit > 0 ? max(limit * 2, 200) : Int.max
        do {
            try reader.forEachEntry { key, offset in
                if groups[offset] == nil {
                    order.append(offset)
                }
                groups[offset, default: []].append(key)

                let normalizedKey = key.lowercased()
                if keyToOffset[normalizedKey] == nil {
                    keyToOffset[normalizedKey] = offset
                }

                if isSimpleHeadword(key), !simpleSeen.contains(offset) {
                    simpleSeen.insert(offset)
                    simpleOrder.append(offset)
                    if simpleOrder.count >= simpleTarget { throw StopIteration() }
                }
            }
        } catch is StopIteration {
            // 已达到目标数量，正常提前结束。
        }

        var candidates = simpleOrder
        var seen = simpleSeen
        for offset in order where !seen.contains(offset) {
            candidates.append(offset)
            seen.insert(offset)
        }

        var realEntries: [(offset: UInt64, keys: [String], raw: String)] = []
        var redirects: [(offset: UInt64, target: String, keys: [String])] = []

        for offset in candidates {
            if limit > 0 && realEntries.count >= limit { break }
            let raw = try reader.rawDefinition(at: offset)

            if let target = Self.redirectTarget(raw) {
                redirects.append((
                    offset: offset,
                    target: target,
                    keys: groups[offset] ?? []
                ))
            } else {
                realEntries.append((
                    offset: offset,
                    keys: Array(Set(groups[offset] ?? [])).sorted(),
                    raw: raw
                ))
            }
        }

        // 第一遍读完后，重定向链只靠内存映射解析，不再重复读 record block。
        var offsetToTarget: [UInt64: String] = [:]
        for redirect in redirects {
            offsetToTarget[redirect.offset] = redirect.target
        }
        let realOffsets = Set(realEntries.map(\.offset))

        var redirectKeys: [UInt64: [String]] = [:]
        for redirect in redirects {
            if let finalOffset = try resolveFinalOffset(
                for: redirect.target,
                reader: reader,
                keyToOffset: keyToOffset,
                offsetToTarget: offsetToTarget,
                realOffsets: realOffsets
            ) {
                redirectKeys[finalOffset, default: []]
                    .append(contentsOf: redirect.keys)
            }
        }

        return realEntries.map { item in
            let extra = redirectKeys[item.offset] ?? []
            let keys = Array(Set(item.keys + extra)).sorted()
            return RawEntry(id: "e\(item.offset)", keys: keys, raw: item.raw)
        }
    }

    /// 沿 `@@@LINK=` 链找到最终真实记录的 offset。
    private func resolveFinalOffset(
        for word: String,
        reader: MDictReader,
        keyToOffset: [String: UInt64],
        offsetToTarget: [UInt64: String],
        realOffsets: Set<UInt64>
    ) throws -> UInt64? {
        var target = word
        var visitedKeys: Set<String> = []
        var visitedOffsets: Set<UInt64> = []

        for _ in 0..<8 {
            let normalized = target.lowercased()
            if visitedKeys.contains(normalized) { return nil }
            visitedKeys.insert(normalized)

            let offset: UInt64?
            if let cached = keyToOffset[normalized] {
                offset = cached
            } else {
                offset = try reader.recordOffset(for: target)
            }
            guard let offset else { return nil }
            if visitedOffsets.contains(offset) { return nil }
            visitedOffsets.insert(offset)

            if let next = offsetToTarget[offset] {
                target = next
                continue
            }
            if realOffsets.contains(offset) {
                return offset
            }

            // 子集模式可能没扫描到目标 offset，读一次确认。
            let raw = try reader.rawDefinition(at: offset)
            if let next = Self.redirectTarget(raw) {
                target = next
                continue
            }
            return offset
        }
        return nil
    }

    private static func redirectTarget(_ raw: String) -> String? {
        var text = raw
        if text.hasPrefix("\u{FEFF}") { text.removeFirst() }
        let marker = "@@@LINK="
        guard text.lowercased().hasPrefix(marker.lowercased()) else { return nil }
        let rest = text.dropFirst(marker.count)
        let firstLine = rest.prefix { !$0.isNewline }
        let target = firstLine.trimmingCharacters(in: .whitespacesAndNewlines)
        return target.isEmpty ? nil : target
    }

    /// 全量模式的规划阶段：只保留 key/offset/锚点，不保留 raw HTML。
    private func planFullEntries(
        reader: MDictReader
    ) throws -> (entries: [PlannedEntry], index: EntryIndex) {
        var groups: [UInt64: [String]] = [:]
        var order: [UInt64] = []
        var keyToOffset: [String: UInt64] = [:]

        try reader.forEachEntry { key, offset in
            if groups[offset] == nil {
                order.append(offset)
            }
            groups[offset, default: []].append(key)
            let normalized = key.lowercased()
            if keyToOffset[normalized] == nil {
                keyToOffset[normalized] = offset
            }
        }

        var realEntries: [(offset: UInt64, keys: [String])] = []
        var redirects: [(offset: UInt64, target: String, keys: [String])] = []
        var anchorToID: [String: String] = [:]
        var realOffsets: Set<UInt64> = []

        for offset in order {
            let raw = try reader.rawDefinition(at: offset)
            if let target = Self.redirectTarget(raw) {
                redirects.append((
                    offset: offset,
                    target: target,
                    keys: groups[offset] ?? []
                ))
            } else {
                let id = "e\(offset)"
                realEntries.append((offset: offset, keys: groups[offset] ?? []))
                realOffsets.insert(offset)
                for anchor in HTMLSanitizer.anchorIDs(raw) {
                    anchorToID[anchor] = id
                }
            }
        }

        var offsetToTarget: [UInt64: String] = [:]
        for redirect in redirects {
            offsetToTarget[redirect.offset] = redirect.target
        }

        var extraKeys: [UInt64: [String]] = [:]
        for redirect in redirects {
            if let finalOffset = resolveFinalOffsetStrict(
                for: redirect.target,
                keyToOffset: keyToOffset,
                offsetToTarget: offsetToTarget,
                realOffsets: realOffsets
            ) {
                extraKeys[finalOffset, default: []].append(contentsOf: redirect.keys)
            }
        }

        var keyToID: [String: String] = [:]
        var entries: [PlannedEntry] = []
        entries.reserveCapacity(realEntries.count)

        for item in realEntries {
            let id = "e\(item.offset)"
            let keys = Array(Set(item.keys + (extraKeys[item.offset] ?? []))).sorted()
            for key in keys {
                keyToID[key] = id
                keyToID[key.lowercased()] = id
            }
            entries.append(PlannedEntry(id: id, keys: keys, source: .offset(item.offset)))
        }

        return (entries, EntryIndex(keyToID: keyToID, anchorToID: anchorToID))
    }

    private func resolveFinalOffsetStrict(
        for word: String,
        keyToOffset: [String: UInt64],
        offsetToTarget: [UInt64: String],
        realOffsets: Set<UInt64>
    ) -> UInt64? {
        var target = word
        var visitedKeys: Set<String> = []
        var visitedOffsets: Set<UInt64> = []

        for _ in 0..<8 {
            let normalized = target.lowercased()
            if visitedKeys.contains(normalized) { return nil }
            visitedKeys.insert(normalized)

            guard let offset = keyToOffset[normalized] else { return nil }
            if visitedOffsets.contains(offset) { return nil }
            visitedOffsets.insert(offset)

            if let next = offsetToTarget[offset] {
                target = next
                continue
            }
            return realOffsets.contains(offset) ? offset : nil
        }
        return nil
    }

    private func collectRawWords(reader: MDictReader, words: [String]) throws -> [RawEntry] {
        var entries: [RawEntry] = []
        for (index, word) in words.enumerated() {
            let trimmed = word.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            guard let raw = try reader.lookup(trimmed, followRedirects: true) else { continue }
            entries.append(RawEntry(id: "w\(index)", keys: [trimmed], raw: raw))
        }
        return entries
    }

    /// 从现有词条 HTML 中收集 `entry://` 目标，补成真正的词条。
    /// 纯 UI 链接（`@topic...`、带 `=` 的）跳过。
    private func expandLinkTargets(
        reader: MDictReader,
        entries: inout [RawEntry],
        maxExtra: Int
    ) {
        var knownKeys = Set(entries.flatMap { $0.keys.map { $0.lowercased() } })
        var extra = 0
        var cursor = 0
        var nextID = 0

        while cursor < entries.count, extra < maxExtra {
            for target in HTMLSanitizer.entryLinkTargets(entries[cursor].raw) {
                let decoded = target.removingPercentEncoding ?? target
                if decoded.hasPrefix("@") || decoded.contains("=") { continue }
                let lower = decoded.lowercased()
                if knownKeys.contains(lower) { continue }
                guard let raw = try? reader.lookup(decoded, followRedirects: true) else { continue }

                entries.append(RawEntry(id: "x\(nextID)", keys: [decoded], raw: raw))
                nextID += 1
                extra += 1
                knownKeys.insert(lower)
                if extra >= maxExtra { break }
            }
            cursor += 1
        }
    }

    private func isSimpleHeadword(_ key: String) -> Bool {
        guard let first = key.first, first.isASCII, first.isLowercase else { return false }
        guard (2...20).contains(key.count) else { return false }
        return key.allSatisfy { $0.isASCII && $0.isLowercase }
    }

    // MARK: - Link index

    private struct EntryIndex {
        private var keyToID: [String: String] = [:]
        private var anchorToID: [String: String] = [:]

        init(keyToID: [String: String], anchorToID: [String: String]) {
            self.keyToID = keyToID
            self.anchorToID = anchorToID
        }

        init(entries: [RawEntry]) {
            for entry in entries {
                for key in entry.keys {
                    keyToID[key] = entry.id
                    keyToID[key.lowercased()] = entry.id
                }
                for anchor in HTMLSanitizer.anchorIDs(entry.raw) {
                    anchorToID[anchor] = entry.id
                }
            }
        }

        func resolve(_ target: String) -> String? {
            let decoded = target.removingPercentEncoding ?? target
            if let id = keyToID[decoded] ?? keyToID[decoded.lowercased()] { return id }
            if let id = anchorToID[decoded] { return id }
            return nil
        }
    }

    // MARK: - Files

    private func resolveCSS(input: URL, explicit: String?) throws -> URL? {
        if let explicit {
            let url = URL(fileURLWithPath: (explicit as NSString).expandingTildeInPath)
            guard FileManager.default.fileExists(atPath: url.path) else {
                throw Mdx2DictError.invalidOption("--css file not found: \(url.path)")
            }
            return url
        }

        let directory = input.deletingLastPathComponent()
        let stem = input.deletingPathExtension().lastPathComponent
        let exact = directory.appendingPathComponent(stem + ".css")
        if FileManager.default.fileExists(atPath: exact.path) { return exact }

        guard let files = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.fileSizeKey]
        ) else { return nil }

        let cssFiles = files.filter { $0.pathExtension.lowercased() == "css" }
        return cssFiles.max { lhs, rhs in
            let left = (try? lhs.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            let right = (try? rhs.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            return left < right
        }
    }

    private func writeCSS(
        from cssURL: URL?,
        extraPath: String?,
        to url: URL
    ) throws {
        let base = cssURL.flatMap { try? String(contentsOf: $0, encoding: .utf8) }
            ?? minimalCSS

        let extra: String
        if let extraPath {
            let path = (extraPath as NSString).expandingTildeInPath
            guard let content = try? String(contentsOfFile: path, encoding: .utf8) else {
                throw Mdx2DictError.invalidOption("cannot read --css-extra file: \(path)")
            }
            extra = content
        } else {
            extra = ""
        }

        let override = """
        /* mdx2dict generic overrides */
        body {
            max-width: 900px;
            margin: 0 auto !important;
            padding: 8px 14px 20px !important;
            overflow: visible !important;
        }
        img { max-width: 100%; height: auto; }
        a.mdx2dict-audio {
            display: inline-block;
            margin: 0 .15em;
            text-decoration: none;
            cursor: pointer;
            vertical-align: middle;
        }
        a.mdx2dict-audio::after { content: "🔊"; font-size: .95em; }
        @media (prefers-color-scheme: dark) {
            body { background: Canvas; color: CanvasText; }
        }
        """

        let combined = [base, override, extra]
            .filter { !$0.isEmpty }
            .joined(separator: "\n\n")
        try (combined + "\n").write(to: url, atomically: true, encoding: .utf8)
    }

    private var minimalCSS: String {
        """
        body {
            font-family: -apple-system, "Helvetica Neue", sans-serif;
            font-size: 14px;
            line-height: 1.55;
            color: #222;
            padding: 8px 12px;
        }
        h1 { font-size: 22px; margin: 0 0 8px; }
        h2 { font-size: 17px; margin: 14px 0 6px; }
        h3 { font-size: 15px; margin: 12px 0 4px; }
        p { margin: 6px 0; }
        """
    }

    /// 按批次读取、并行 sanitize、按顺序增量写 XML；峰值内存只保留一个批次。
    private func writePlannedEntries(
        plans: [PlannedEntry],
        reader: MDictReader,
        linkIndex: EntryIndex,
        imageStore: ImageStore?,
        audioStore: AudioStore?,
        imagePolicy: HTMLSanitizer.ImagePolicy,
        audioPolicy: HTMLSanitizer.AudioPolicy,
        audioExclude: NSRegularExpression?,
        writer: XMLWriter,
        verbose: Bool,
        jobs: Int
    ) throws {
        let total = plans.count
        let batchSize = 128
        let progressStep = max(500, total / 20)
        var nextProgress = progressStep
        var processed = 0
        let progressStart = Date()

        var index = 0
        while index < total {
            let end = min(index + batchSize, total)
            let batch = Array(plans[index..<end])
            var rawBatch = [String?](repeating: nil, count: batch.count)

            for (i, plan) in batch.enumerated() {
                switch plan.source {
                case .offset(let offset):
                    rawBatch[i] = try? reader.rawDefinition(at: offset)
                case .raw(let raw):
                    rawBatch[i] = raw
                }
            }

            var htmlBatch = [String?](repeating: nil, count: batch.count)
            let requestedJobs = jobs > 0 ? jobs : ProcessInfo.processInfo.activeProcessorCount
            let jobCount = max(1, min(requestedJobs, batch.count))

            if jobCount == 1 {
                for i in 0..<batch.count {
                    guard let raw = rawBatch[i] else { continue }
                    htmlBatch[i] = HTMLSanitizer.sanitize(
                        raw,
                        linkResolver: linkIndex.resolve,
                        imagePolicy: imagePolicy,
                        imageResolver: imageStore?.resolve,
                        audioPolicy: audioPolicy,
                        audioExclude: audioExclude,
                        audioResolver: audioStore?.resolve
                    )
                }
            } else {
                htmlBatch.withUnsafeMutableBufferPointer { buffer in
                    guard let base = buffer.baseAddress else { return }
                    DispatchQueue.concurrentPerform(iterations: jobCount) { job in
                        var i = job
                        while i < batch.count {
                            if let raw = rawBatch[i] {
                                base[i] = HTMLSanitizer.sanitize(
                                    raw,
                                    linkResolver: linkIndex.resolve,
                                    imagePolicy: imagePolicy,
                                    imageResolver: imageStore?.resolve,
                                    audioPolicy: audioPolicy,
                                    audioExclude: audioExclude,
                                    audioResolver: audioStore?.resolve
                                )
                            }
                            i += jobCount
                        }
                    }
                }
            }

            for (i, plan) in batch.enumerated() {
                guard let html = htmlBatch[i] else { continue }
                writer.write(Entry(id: plan.id, keys: plan.keys, html: html))
                processed += 1
            }

            if verbose && (processed >= nextProgress || end == total) {
                let elapsed = Date().timeIntervalSince(progressStart)
                let rate = elapsed > 0 ? Double(processed) / elapsed : 0
                let eta = rate > 0 ? Double(total - processed) / rate : 0
                print(String(
                    format: "progress: %d/%d (%.1f%%) elapsed %.0fs eta %.0fs",
                    processed,
                    total,
                    total > 0 ? Double(processed) / Double(total) * 100 : 0,
                    elapsed,
                    eta
                ))
                fflush(stdout)
                while nextProgress <= processed {
                    nextProgress += progressStep
                }
            }

            index = end
        }
    }

    private final class XMLWriter {
        private let writer: TextFileWriter

        init(url: URL) throws {
            writer = try TextFileWriter(url: url)
            writer.write("""
            <?xml version="1.0" encoding="UTF-8"?>
            <d:dictionary xmlns="http://www.w3.org/1999/xhtml" xmlns:d="http://www.apple.com/DTDs/DictionaryService-1.0.rng">

            """)
        }

        func write(_ entry: Entry) {
            let title = entry.keys.first ?? entry.id
            let escapedTitle = HTMLSanitizer.escapeAttribute(title)
            var indexXML = ""
            for key in entry.keys.prefix(30) {
                let value = HTMLSanitizer.escapeAttribute(key)
                indexXML += "<d:index d:value=\"\(value)\"/>"
            }
            let body = entry.html.isEmpty ? "<p></p>" : entry.html
            let safeBody = body.replacingOccurrences(
                of: "</d:entry>",
                with: "&lt;/d:entry&gt;"
            )
            let opening = "<d:entry id=\"\(entry.id)\" d:title=\"\(escapedTitle)\">"
            writer.write(opening + indexXML + safeBody + "</d:entry>\n")
        }

        func finish() {
            writer.write("</d:dictionary>\n")
            writer.close()
        }
    }

    private func writeInfoPlist(name: String, to url: URL) throws {
        let identifier = "com.mdx2dict." + slug(name)
        let plist = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>CFBundleDevelopmentRegion</key>
            <string>English</string>
            <key>CFBundleIdentifier</key>
            <string>\(HTMLSanitizer.escapeText(identifier))</string>
            <key>CFBundleName</key>
            <string>\(HTMLSanitizer.escapeText(name))</string>
            <key>CFBundleShortVersionString</key>
            <string>1.0</string>
            <key>DCSDictionaryCopyright</key>
            <string>Personal use only</string>
            <key>DCSDictionaryManufacturerName</key>
            <string>mdx2dict</string>
            <key>DCSDictionaryCSS</key>
            <string>DefaultStyle.css</string>
            <key>DCSDictionaryDefaultPrefs</key>
            <dict>
                <key>display-chinese</key>
                <string>1</string>
                <key>version</key>
                <string>1</string>
            </dict>
            <key>DCSDictionaryUseSystemAppearance</key>
            <true/>
        </dict>
        </plist>
        """
        try plist.write(to: url, atomically: true, encoding: .utf8)
    }

    // MARK: - Paths

    private func uniqueOutputURL(in directory: URL, name: String) -> URL {
        var url = directory.appendingPathComponent(name)
        var suffix = 2
        while FileManager.default.fileExists(atPath: url.path) {
            let base = name.replacingOccurrences(of: ".dictionary", with: "")
            url = directory.appendingPathComponent("\(base)-\(suffix).dictionary")
            suffix += 1
        }
        return url
    }

    private func makeWorkDir(in outDir: URL, name: String) throws -> URL {        try FileManager.default.createDirectory(
            at: outDir,
            withIntermediateDirectories: true
        )
        let stamp = Int(Date().timeIntervalSince1970)
        let unique = UUID().uuidString.prefix(6)
        let dir = outDir.appendingPathComponent(
            "\(slug(name))-\(stamp)-\(unique)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func install(_ dictionary: URL) throws -> URL {
        let dictionaries = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Dictionaries", isDirectory: true)
        try FileManager.default.createDirectory(
            at: dictionaries,
            withIntermediateDirectories: true
        )

        var destination = dictionaries.appendingPathComponent(dictionary.lastPathComponent)
        var suffix = 2
        while FileManager.default.fileExists(atPath: destination.path) {
            let base = dictionary.lastPathComponent.replacingOccurrences(
                of: ".dictionary",
                with: ""
            )
            destination = dictionaries.appendingPathComponent("\(base)-\(suffix).dictionary")
            suffix += 1
        }

        do {
            try FileManager.default.copyItem(at: dictionary, to: destination)
            try? FileManager.default.setAttributes(
                [.modificationDate: Date()],
                ofItemAtPath: dictionaries.path
            )
            return destination
        } catch {
            throw Mdx2DictError.installFailed(error.localizedDescription)
        }
    }

    private func sanitizeBundleName(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleaned = trimmed
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
        let name = cleaned.isEmpty ? "MDX2Dict Test" : cleaned
        return String(name.prefix(60))
    }

    private func slug(_ raw: String) -> String {
        let allowed = CharacterSet.alphanumerics
        var result = ""
        for scalar in raw.lowercased().unicodeScalars {
            if allowed.contains(scalar) {
                result.unicodeScalars.append(scalar)
            } else if result.last != "-" {
                result.append("-")
            }
        }
        let trimmed = result.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return trimmed.isEmpty ? "dictionary" : trimmed
    }
}

/// 从 `.mdd` 中按需提取图片，并记录 HTML 里需要的资源路径。
private final class ImageStore {
    private let mdxURL: URL
    private let policy: ResourcePolicy
    private let archiveSet: MDictArchiveSet
    private let lock = NSLock()
    private let checkLock = NSLock()
    private var missing: Set<String> = []
    private let missingLock = NSLock()
    private(set) var requests: [String: String] = [:]

    init(mdxURL: URL, policy: ResourcePolicy) {
        self.mdxURL = mdxURL
        self.policy = policy
        self.archiveSet = MDictArchiveSet(mdxURL: mdxURL)
    }

    var missingKeys: [String] {
        missingLock.lock()
        defer { missingLock.unlock() }
        return missing.sorted()
    }

    /// 输入原始 `<img src>`，返回写入 bundle 资源目录后的相对路径。
    /// drop/strict 模式会先查 key index；缺失时返回 nil，让 sanitizer 删除引用。
    func resolve(_ raw: String) -> String? {
        let key = Self.normalize(raw)
        guard !key.isEmpty else { return nil }

        if policy != .skip {
            checkLock.lock()
            let exists = archiveSet.contains(resourcePath: key)
            checkLock.unlock()
            if !exists {
                missingLock.lock()
                missing.insert(key)
                missingLock.unlock()
                return nil
            }
        }

        lock.lock()
        defer { lock.unlock() }

        if let existing = requests[key] {
            return existing
        }
        let output = Self.safeRelativePath(key)
        requests[key] = output
        return output
    }

    func write(to directory: URL, jobs: Int = 0) throws -> (count: Int, bytes: Int, skipped: Int) {
        let entries = requests.map { (key: $0.key, output: $0.value) }
        return writeResources(entries: entries, mdxURL: mdxURL, to: directory, jobs: jobs)
    }

    private static func normalize(_ raw: String) -> String {
        var value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        for prefix in ["rondo-dict://resource/", "file://"]
        where value.lowercased().hasPrefix(prefix) {
            value = String(value.dropFirst(prefix.count))
            break
        }
        if let hash = value.firstIndex(of: "#") {
            value = String(value[..<hash])
        }
        if let query = value.firstIndex(of: "?") {
            value = String(value[..<query])
        }
        value = value.removingPercentEncoding ?? value
        value = value.replacingOccurrences(of: "\\", with: "/")
        while value.hasPrefix("/") {
            value.removeFirst()
        }
        return value
    }

    private static func safeRelativePath(_ key: String) -> String {
        let components = key.split(separator: "/")
            .map(String.init)
            .filter { !$0.isEmpty && $0 != "." && $0 != ".." }
        let invalid = CharacterSet(charactersIn: "\\:*?\"<>|#%")
        let sanitized = components.map { component -> String in
            var result = ""
            for scalar in component.unicodeScalars {
                result.append(invalid.contains(scalar) ? "_" : String(scalar))
            }
            return result
        }
        return sanitized.isEmpty ? "image.bin" : sanitized.joined(separator: "/")
    }
}

/// 从 `.mdd` 中按需提取音频，并生成 Dictionary.app 可执行的 JS 播放链接。
private final class AudioStore {
    private let mdxURL: URL
    private let policy: ResourcePolicy
    private let archiveSet: MDictArchiveSet
    private let lock = NSLock()
    private let checkLock = NSLock()
    private var missing: Set<String> = []
    private let missingLock = NSLock()
    private(set) var requests: [String: String] = [:]

    init(mdxURL: URL, policy: ResourcePolicy) {
        self.mdxURL = mdxURL
        self.policy = policy
        self.archiveSet = MDictArchiveSet(mdxURL: mdxURL)
    }

    var missingKeys: [String] {
        missingLock.lock()
        defer { missingLock.unlock() }
        return missing.sorted()
    }

    /// 输入 `sound://` 后面的 key，返回写入 bundle 资源目录后的相对路径。
    /// drop/strict 模式会先查 key index；缺失时返回 nil，让 sanitizer 删除引用。
    func resolve(_ raw: String) -> String? {
        let key = Self.normalize(raw)
        guard !key.isEmpty else { return nil }

        if policy != .skip {
            checkLock.lock()
            let exists = archiveSet.contains(resourcePath: key)
            checkLock.unlock()
            if !exists {
                missingLock.lock()
                missing.insert(key)
                missingLock.unlock()
                return nil
            }
        }

        lock.lock()
        defer { lock.unlock() }

        if let existing = requests[key] {
            return existing
        }
        let output = "audio/" + Self.safeRelativePath(key)
        requests[key] = output
        return output
    }

    func write(to directory: URL, jobs: Int = 0) throws -> (count: Int, bytes: Int, skipped: Int) {
        let entries = requests.map { (key: $0.key, output: $0.value) }
        return writeResources(entries: entries, mdxURL: mdxURL, to: directory, jobs: jobs)
    }

    private static func normalize(_ raw: String) -> String {
        var value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        for prefix in ["sound://", "rondo-dict://resource/", "file://"]
        where value.lowercased().hasPrefix(prefix) {
            value = String(value.dropFirst(prefix.count))
            break
        }
        if let hash = value.firstIndex(of: "?") {
            value = String(value[..<hash])
        }
        value = value.removingPercentEncoding ?? value
        value = value.replacingOccurrences(of: "\\", with: "/")
        while value.hasPrefix("/") {
            value.removeFirst()
        }
        return value
    }

    private static func safeRelativePath(_ key: String) -> String {
        let components = key.split(separator: "/")
            .map(String.init)
            .filter { !$0.isEmpty && $0 != "." && $0 != ".." }
        let invalid = CharacterSet(charactersIn: "\\:*?\"<>|#%")
        let sanitized = components.map { component -> String in
            var result = ""
            for scalar in component.unicodeScalars {
                result.append(invalid.contains(scalar) ? "_" : String(scalar))
            }
            return result
        }
        return sanitized.isEmpty ? "audio.mp3" : sanitized.joined(separator: "/")
    }
}

/// 多线程提取资源；每个 worker 使用独立的 MDictArchiveSet，避免 FileHandle 竞争。
private func writeResources(
    entries: [(key: String, output: String)],
    mdxURL: URL,
    to directory: URL,
    jobs: Int
) -> (count: Int, bytes: Int, skipped: Int) {
    guard !entries.isEmpty else { return (0, 0, 0) }
    try? FileManager.default.createDirectory(
        at: directory,
        withIntermediateDirectories: true
    )

    let requestedJobs = jobs > 0 ? jobs : ProcessInfo.processInfo.activeProcessorCount
    let jobCount = entries.count < 64 ? 1 : max(1, min(requestedJobs, entries.count))

    if jobCount == 1 {
        let archives = MDictArchiveSet(mdxURL: mdxURL)
        var count = 0
        var bytes = 0
        var skipped = 0
        for entry in entries {
            guard let data = archives.data(forResourcePath: entry.key) else {
                skipped += 1
                continue
            }
            let destination = directory.appendingPathComponent(entry.output)
            do {
                try FileManager.default.createDirectory(
                    at: destination.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                try data.write(to: destination)
                count += 1
                bytes += data.count
            } catch {
                skipped += 1
            }
        }
        return (count, bytes, skipped)
    }

    let chunkSize = (entries.count + jobCount - 1) / jobCount
    var totalCount = 0
    var totalBytes = 0
    var totalSkipped = 0
    let lock = NSLock()

    DispatchQueue.concurrentPerform(iterations: jobCount) { job in
        let start = job * chunkSize
        let end = min(start + chunkSize, entries.count)
        guard start < end else { return }

        let archives = MDictArchiveSet(mdxURL: mdxURL)
        var count = 0
        var bytes = 0
        var skipped = 0

        for index in start..<end {
            let entry = entries[index]
            guard let data = archives.data(forResourcePath: entry.key) else {
                skipped += 1
                continue
            }
            let destination = directory.appendingPathComponent(entry.output)
            do {
                try FileManager.default.createDirectory(
                    at: destination.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                try data.write(to: destination)
                count += 1
                bytes += data.count
            } catch {
                skipped += 1
            }
        }

        lock.lock()
        totalCount += count
        totalBytes += bytes
        totalSkipped += skipped
        lock.unlock()
    }

    return (totalCount, totalBytes, totalSkipped)
}

/// 简单的带缓冲文本写入，避免把整本 XML 放进内存。
final class TextFileWriter {
    private let handle: FileHandle
    private var buffer = Data()

    init(url: URL) throws {
        FileManager.default.createFile(atPath: url.path, contents: nil)
        self.handle = try FileHandle(forWritingTo: url)
    }

    func write(_ text: String) {
        buffer.append(Data(text.utf8))
        if buffer.count >= 1 << 20 {
            flush()
        }
    }

    func flush() {
        guard !buffer.isEmpty else { return }
        handle.write(buffer)
        buffer.removeAll(keepingCapacity: true)
    }

    func close() {
        flush()
        try? handle.close()
    }
}
