import CXML2
import Foundation

enum HTMLSanitizer {
    typealias LinkResolver = (String) -> String?
    typealias ImageResolver = (String) -> String?
    typealias AudioResolver = (String) -> String?

    enum ImagePolicy {
        case none
        case thumbnail
        case all
    }

    enum AudioPolicy {
        case none
        case all
    }

    /// 把 MDX 记录里的 HTML 变成适合 Apple Dictionary 的 XHTML 片段。
    ///
    /// 优先用 libxml2 解析：它保留原词典的自定义标签和 CSS 结构。
    /// 解析失败时退回 Foundation 的 tidy 路径（会丢自定义标签，但仍可读）。
    static func sanitize(
        _ html: String,
        linkResolver: LinkResolver? = nil,
        imagePolicy: ImagePolicy = .none,
        imageResolver: ImageResolver? = nil,
        audioPolicy: AudioPolicy = .none,
        audioExclude: NSRegularExpression? = nil,
        audioResolver: AudioResolver? = nil
    ) -> String {
        if let bodyXML = bodyXMLUsingLibxml2(html),
           let document = try? XMLDocument(
                xmlString: "<root>\(bodyXML)</root>",
                options: [.nodePreserveAll]
           ) {
            removeUnwantedNodes(in: document)
            removeUnwantedAttributes(in: document)
            processImages(in: document, policy: imagePolicy, resolver: imageResolver)
            processAudio(
                in: document,
                policy: audioPolicy,
                exclude: audioExclude,
                resolver: audioResolver
            )
            rewriteLinks(in: document, resolver: linkResolver)
            let content = (document.rootElement()?.children ?? [])
                .map(\.xmlString)
                .joined()
            if !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return cleanXMLCharacters(content)
            }
        }

        return sanitizeUsingTidy(
            html,
            linkResolver: linkResolver,
            imagePolicy: imagePolicy,
            imageResolver: imageResolver,
            audioPolicy: audioPolicy,
            audioExclude: audioExclude,
            audioResolver: audioResolver
        )
    }

    private static func bodyXMLUsingLibxml2(_ html: String) -> String? {
        html.withCString { pointer -> String? in
            let length = strlen(pointer)
            guard length > 0,
                  let output = mdx2dict_html_body_xml(pointer, length) else {
                return nil
            }
            defer { mdx2dict_free(output) }
            return String(cString: output)
        }
    }

    private static func sanitizeUsingTidy(
        _ html: String,
        linkResolver: LinkResolver?,
        imagePolicy: ImagePolicy,
        imageResolver: ImageResolver?,
        audioPolicy: AudioPolicy,
        audioExclude: NSRegularExpression?,
        audioResolver: AudioResolver?
    ) -> String {
        let wrapper = bodyWrapper(from: html)
        let prepared = ensureUTF8Declaration(html)
        guard let data = prepared.data(using: .utf8),
              let document = try? XMLDocument(
                data: data,
                options: [.documentTidyHTML, .nodeLoadExternalEntitiesNever]
              ) else {
            return escapeText(stripTags(html))
        }

        removeUnwantedNodes(in: document)
        removeUnwantedAttributes(in: document)
        processImages(in: document, policy: imagePolicy, resolver: imageResolver)
        processAudio(
            in: document,
            policy: audioPolicy,
            exclude: audioExclude,
            resolver: audioResolver
        )
        rewriteLinks(in: document, resolver: linkResolver)

        let content = bodyContent(from: document)
        var result = content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? escapeText(stripTags(html))
            : content

        if let wrapper, !startsWithElement(result, tag: wrapper.tag) {
            result = wrapper.opening + result + wrapper.closing
        }
        return cleanXMLCharacters(result)
    }

    // MARK: - Wrapper

    private struct Wrapper {
        let tag: String
        let opening: String
        let closing: String
    }

    /// 取 `<body>` 的第一个自定义子元素作为 wrapper；标准内容标签不重复包装。
    private static func bodyWrapper(from html: String) -> Wrapper? {
        let regex = bodyWrapperRegex
        let range = NSRange(html.startIndex..., in: html)
        guard let match = regex.firstMatch(in: html, range: range),
              let tagRange = Range(match.range(at: 1), in: html),
              let attrRange = Range(match.range(at: 2), in: html)
        else { return nil }

        let tag = String(html[tagRange])
        let standard: Set<String> = [
            "div", "span", "p", "h1", "h2", "h3", "h4", "h5", "h6",
            "ul", "ol", "li", "table", "tbody", "thead", "tr", "td", "th",
            "a", "b", "i", "em", "strong", "section", "article", "header",
            "footer", "main", "dl", "dt", "dd", "blockquote"
        ]
        guard !standard.contains(tag.lowercased()) else { return nil }

        var attrs = String(html[attrRange])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if attrs.hasSuffix("/") { attrs.removeLast() }
        attrs = cleanXMLCharacters(attrs)
        let opening = attrs.isEmpty ? "<\(tag)>" : "<\(tag) \(attrs)>"
        return Wrapper(tag: tag, opening: opening, closing: "</\(tag)>")
    }

    private static func startsWithElement(_ content: String, tag: String) -> Bool {
        content.trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .hasPrefix("<\(tag.lowercased())")
    }

    private static func bodyContent(from document: XMLDocument) -> String {
        if let body = (try? document.nodes(forXPath: "//body"))?.first {
            return (body.children ?? []).map(\.xmlString).joined()
        }
        if let root = document.rootElement() {
            return root.xmlString
        }
        return ""
    }

    // MARK: - Cleanup

    private static let unwantedElements = [
        "script", "link", "style", "audio", "source", "iframe",
        "object", "embed", "video", "svg", "noscript"
    ]

    private static func removeUnwantedNodes(in document: XMLDocument) {
        for name in unwantedElements {
            guard let nodes = try? document.nodes(forXPath: "//\(name)") else { continue }
            for node in nodes { node.detach() }
        }
    }

    /// 处理 `<img>`：按策略保留图片，并把 src 重写为资源相对路径。
    /// `.thumbnail` 使用通用命名启发式：保留名字/类名含 thumb 的图，跳过 fullsize。
    private static func processImages(
        in document: XMLDocument,
        policy: ImagePolicy,
        resolver: ImageResolver?
    ) {
        guard let images = try? document.nodes(forXPath: "//img") else { return }

        for case let image as XMLElement in images {
            if policy == .none {
                image.detach()
                continue
            }

            let cls = image.attribute(forName: "class")?.stringValue?.lowercased() ?? ""
            let src = image.attribute(forName: "src")?.stringValue
                ?? image.attribute(forName: "data-src")?.stringValue
                ?? ""
            guard !src.isEmpty else {
                image.detach()
                continue
            }

            if policy == .thumbnail {
                let lower = src.lowercased()
                if cls.contains("fullsize") || lower.contains("fullsize") {
                    image.detach()
                    continue
                }
                if !(cls.contains("thumb") || lower.contains("thumb")) {
                    image.detach()
                    continue
                }
            }

            guard let resolver, let output = resolver(src) else {
                image.detach()
                continue
            }

            setAttribute(image, name: "src", value: output)
            image.removeAttribute(forName: "data-src")
            image.removeAttribute(forName: "srcset")
        }
    }

    private static func setAttribute(_ element: XMLElement, name: String, value: String) {
        if let existing = element.attribute(forName: name) {
            existing.stringValue = value
        } else if let attribute = XMLNode.attribute(withName: name, stringValue: value) as? XMLNode {
            element.addAttribute(attribute)
        }
    }

    /// 把 `<a href="sound://...">` 改成 Dictionary.app 可执行的 JS 播放链接。
    /// `exclude` 可用来过滤例句音频或特定资源，匹配对象是 `key + class`。
    private static func processAudio(
        in document: XMLDocument,
        policy: AudioPolicy,
        exclude: NSRegularExpression?,
        resolver: AudioResolver?
    ) {
        guard let anchors = try? document.nodes(forXPath: "//a") else { return }
        for case let anchor as XMLElement in anchors {
            guard let hrefNode = anchor.attribute(forName: "href"),
                  let href = hrefNode.stringValue,
                  href.lowercased().hasPrefix("sound://") else { continue }

            if policy == .none {
                anchor.detach()
                continue
            }

            var key = String(href.dropFirst("sound://".count))
            key = key.removingPercentEncoding ?? key
            let classes = anchor.attribute(forName: "class")?.stringValue ?? ""

            if let exclude {
                let probe = "\(key) \(classes)"
                let range = NSRange(probe.startIndex..., in: probe)
                if exclude.firstMatch(in: probe, range: range) != nil {
                    anchor.detach()
                    continue
                }
            }

            guard let resolver, let output = resolver(key) else {
                anchor.detach()
                continue
            }

            setAttribute(
                anchor,
                name: "href",
                value: "javascript:new Audio(\"\(output)\").play();"
            )
            setAttribute(anchor, name: "class", value: "mdx2dict-audio")
            if anchor.attribute(forName: "title")?.stringValue?.isEmpty != false {
                setAttribute(anchor, name: "title", value: "Play audio")
            }
            anchor.removeAttribute(forName: "style")
        }
    }

    private static func removeUnwantedAttributes(in document: XMLDocument) {
        guard let elements = try? document.nodes(forXPath: "//*") else { return }
        for case let element as XMLElement in elements {
            for attribute in element.attributes ?? [] {
                guard let name = attribute.name else { continue }
                let lower = name.lowercased()
                if lower.hasPrefix("on") {
                    element.removeAttribute(forName: name)
                    continue
                }
                if lower == "href" {
                    let elementName = element.name?.lowercased() ?? ""
                    if elementName != "a" {
                        element.removeAttribute(forName: name)
                        continue
                    }
                    if let value = attribute.stringValue?.lowercased() {
                        if value.hasPrefix("javascript:") || value.hasPrefix("mailto:") {
                            element.removeAttribute(forName: name)
                        }
                    }
                }
            }
        }
    }

    // MARK: - Links

    private static func rewriteLinks(in document: XMLDocument, resolver: LinkResolver?) {
        guard let anchors = try? document.nodes(forXPath: "//a") else { return }

        // 一次收集本词条所有 id，避免每条链接都跑一次 XPath。
        let localIDs: Set<String> = {
            guard let nodes = try? document.nodes(forXPath: "//*[@id]") else { return [] }
            var result = Set<String>()
            for case let element as XMLElement in nodes {
                if let id = element.attribute(forName: "id")?.stringValue {
                    result.insert(id)
                }
            }
            return result
        }()

        for case let anchor as XMLElement in anchors {
            guard let hrefNode = anchor.attribute(forName: "href"),
                  let href = hrefNode.stringValue else { continue }
            let trimmed = href.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
                anchor.removeAttribute(forName: "href")
                continue
            }

            if trimmed.lowercased().hasPrefix("entry://") {
                var target = String(trimmed.dropFirst("entry://".count))
                target = target.removingPercentEncoding ?? target
                if target.hasPrefix("@") || target.contains("=") {
                    anchor.removeAttribute(forName: "href")
                } else if let id = resolver?(target) {
                    hrefNode.stringValue = "x-dictionary:r:\(id)"
                } else {
                    anchor.removeAttribute(forName: "href")
                }
                continue
            }

            if trimmed.lowercased().hasPrefix("http://")
                || trimmed.lowercased().hasPrefix("https://")
                || trimmed.hasPrefix("#") {
                continue
            }

            if trimmed.lowercased().hasPrefix("javascript:") {
                let classes = (anchor.attribute(forName: "class")?.stringValue ?? "").lowercased()
                if classes.contains("mdx2dict-audio") {
                    continue
                }
                anchor.removeAttribute(forName: "href")
                continue
            }

            if trimmed.lowercased().hasPrefix("sound://") {
                anchor.removeAttribute(forName: "href")
                continue
            }

            // 裸 href：可能是本词条锚点，也可能是其它词条的锚点。'
            if localIDs.contains(trimmed) {
                hrefNode.stringValue = "#\(trimmed)"
            } else if let id = resolver?(trimmed) {
                hrefNode.stringValue = "x-dictionary:r:\(id)"
            } else {
                anchor.removeAttribute(forName: "href")
            }
        }
    }

    // MARK: - Helpers used by Converter

    /// 原始 HTML 里所有 id，用于跨词条锚点兜底。
    static func anchorIDs(_ html: String) -> Set<String> {
        var result: Set<String> = []
        let range = NSRange(html.startIndex..., in: html)
        for match in idAttrRegex.matches(in: html, range: range) {
            if let r = Range(match.range(at: 1), in: html) {
                result.insert(String(html[r]))
            }
        }
        return result
    }

    /// 原始 HTML 里的 `entry://` 链接目标（用于自动补全链接目标词条）。
    static func entryLinkTargets(_ html: String) -> [String] {
        var result: [String] = []
        let range = NSRange(html.startIndex..., in: html)
        for match in entryLinkRegex.matches(in: html, range: range) {
            if let r = Range(match.range(at: 1), in: html) {
                result.append(String(html[r]))
            }
        }
        return result
    }

    // MARK: - Cached regexes

    private static let bodyWrapperRegex = try! NSRegularExpression(
        pattern: "<body[^>]*>[\\s\\r\\n]*<([A-Za-z][A-Za-z0-9-]*)([^>]*)>",
        options: [.caseInsensitive, .dotMatchesLineSeparators]
    )
    private static let idAttrRegex = try! NSRegularExpression(
        pattern: "id=\"([^\"]+)\"",
        options: [.caseInsensitive]
    )
    private static let entryLinkRegex = try! NSRegularExpression(
        pattern: "href=\"entry://([^\"]+)\"",
        options: [.caseInsensitive]
    )

    // MARK: - Encoding

    private static func ensureUTF8Declaration(_ html: String) -> String {
        let lower = html.lowercased()
        if lower.contains("charset") { return html }
        let meta = "<meta http-equiv=\"Content-Type\" content=\"text/html; charset=utf-8\">"
        if let head = lower.range(of: "<head") {
            if let close = html[head.lowerBound...].firstIndex(of: ">") {
                var result = html
                result.insert(contentsOf: meta, at: html.index(after: close))
                return result
            }
        }
        return meta + html
    }

    private static func stripTags(_ html: String) -> String {
        html.replacingOccurrences(
            of: "<[^>]+>",
            with: " ",
            options: .regularExpression
        )
    }

    static func escapeText(_ text: String) -> String {
        cleanXMLCharacters(text)
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    static func escapeAttribute(_ text: String) -> String {
        escapeText(text).replacingOccurrences(of: "\"", with: "&quot;")
    }

    /// XML 1.0 不允许大部分 C0 控制字符；MDX 源数据里偶尔会出现。
    static func cleanXMLCharacters(_ text: String) -> String {
        var output = String.UnicodeScalarView()
        for scalar in text.unicodeScalars {
            switch scalar.value {
            case 0x09, 0x0A, 0x0D,
                 0x20...0xD7FF,
                 0xE000...0xFFFD,
                 0x10000...0x10FFFF:
                output.append(scalar)
            default:
                output.append(" ")
            }
        }
        return String(output)
    }
}
