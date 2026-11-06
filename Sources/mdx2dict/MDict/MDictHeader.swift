//
//  MDictHeader.swift
//  MDict
//
//  解析 MDX/MDD 文件头。布局：4 字节 BE headerLen + headerLen 字节 UTF-16LE XML
//  + 4 字节 LE Adler-32。Adler-32 覆盖完整 header 字节（含 XML 末尾的 "\n\0\0"），
//  不能先去掉尾零再算。
//

import Foundation

struct MDictHeader {
    /// 根元素名：MDX 是 `Dictionary`，MDD 是 `Library_Data`。
    let rootElement: String
    let title: String
    let description: String
    /// 归一化为 "UTF-8" 或 "UTF-16"（MDict 的 UTF-16 实际是 UTF-16LE）
    let encoding: String
    let format: String
    let encrypted: Int
    let keyCaseSensitive: Bool
    /// Stripkey=Yes 时 key 比较忽略 ASCII 标点与空白；部分词典的 key 按此规则升序，
    /// 忽略它会导致二分定位错块。
    let stripKey: Bool
    let version: Double
    /// 第一个 keyword block 的偏移 = 4 + headerLength + 4
    let headerLength: UInt32

    var isResourceArchive: Bool {
        rootElement == "Library_Data"
    }

    /// Encrypted bit1：key index 的压缩数据被 Fast XOR 加密，密钥可由文件推导。
    var isKeyIndexEncrypted: Bool {
        (encrypted & 0x02) != 0
    }

    /// Encrypted bit0：Keyword Section 前 40 字节被 Salsa20/8 加密，需要密码 / RegCode。
    var isKeywordHeaderEncrypted: Bool {
        (encrypted & 0x01) != 0
    }
}

extension MDictHeader {
    static func parse(from file: MDictFile) throws -> MDictHeader {
        try file.seek(to: 0)
        let headerLength = try file.readUInt32BE()
        guard headerLength > 0, UInt64(headerLength) + 8 <= file.fileSize else {
            throw MDictError.invalidHeader(
                reason: "header length \(headerLength) does not fit file size \(file.fileSize)"
            )
        }

        let headerBytes = try file.read(count: Int(headerLength))
        let storedChecksum = try file.readUInt32LE()
        let computedChecksum = Adler32.checksum(headerBytes)
        guard storedChecksum == computedChecksum else {
            throw MDictError.checksumMismatch(expected: storedChecksum, actual: computedChecksum)
        }

        let xml = try decodeXML(headerBytes)
        let (rootElement, attributes) = try parseRoot(from: xml)

        guard let versionText = attributes["GeneratedByEngineVersion"]
            ?? attributes["RequiredEngineVersion"],
            let version = Double(versionText)
        else {
            throw MDictError.invalidHeader(reason: "engine version is missing or malformed")
        }
        // 只支持 2.x；1.x/3.x 的文件结构不同，明确失败而不猜测
        guard version >= 2.0, version < 3.0 else {
            throw MDictError.unsupportedVersion(version)
        }

        let encrypted = try parseEncrypted(attributes["Encrypted"])
        // bit0 需要密码，无法继续；bit1 只加密 key index，由 MDictKeyIndex 处理。
        guard (encrypted & 0x01) == 0 else {
            throw MDictError.unsupportedHeaderEncryption(encrypted)
        }

        return MDictHeader(
            rootElement: rootElement,
            title: attributes["Title"] ?? "",
            description: attributes["Description"] ?? "",
            encoding: try normalizeEncoding(attributes["Encoding"], rootElement: rootElement),
            format: attributes["Format"] ?? "Html",
            encrypted: encrypted,
            keyCaseSensitive: parseBool(attributes["KeyCaseSensitive"]),
            // 真实文件里两种拼写都存在
            stripKey: parseBool(attributes["Stripkey"] ?? attributes["StripKey"]),
            version: version,
            headerLength: headerLength
        )
    }

    private static func decodeXML(_ bytes: Data) throws -> String {
        guard var xml = String(data: bytes, encoding: .utf16LittleEndian) else {
            throw MDictError.invalidHeader(reason: "header is not valid UTF-16LE")
        }
        while xml.hasSuffix("\u{0}") {
            xml.removeLast()
        }
        if xml.hasPrefix("\u{FEFF}") {
            xml.removeFirst()
        }
        return xml
    }

    private static func parseRoot(from xml: String) throws -> (String, [String: String]) {
        guard let data = xml.data(using: .utf8) else {
            throw MDictError.invalidHeader(reason: "header XML cannot be encoded as UTF-8")
        }
        let collector = RootAttributeCollector()
        let parser = XMLParser(data: data)
        parser.delegate = collector
        parser.parse()
        guard let attributes = collector.attributes, let name = collector.elementName else {
            let reason = collector.error.map { "XML parse failed: \($0.localizedDescription)" }
                ?? "root element has no attributes"
            throw MDictError.invalidHeader(reason: reason)
        }
        return (name, attributes)
    }

    private static func parseEncrypted(_ raw: String?) throws -> Int {
        guard let raw = raw?.trimmingCharacters(in: .whitespaces), !raw.isEmpty else {
            return 0
        }
        switch raw.lowercased() {
        case "no", "false":
            return 0
        case "yes", "true":
            return 1
        default:
            guard let value = Int(raw) else {
                throw MDictError.invalidHeader(reason: "Encrypted attribute is not a number: \(raw)")
            }
            return value
        }
    }

    private static func normalizeEncoding(_ raw: String?, rootElement: String) throws -> String {
        guard let raw = raw?.trimmingCharacters(in: .whitespaces), !raw.isEmpty else {
            // MDX 缺省 UTF-8；MDD 的 `<Library_Data Encoding="">` key 是 UTF-16LE
            // （部分词典为空 Encoding）。
            return rootElement == "Library_Data" ? "UTF-16" : "UTF-8"
        }
        let value = raw.uppercased()
            .replacingOccurrences(of: "_", with: "-")
            .replacingOccurrences(of: " ", with: "")
        switch value {
        case "UTF-8", "UTF8":
            return "UTF-8"
        case "UTF-16", "UTF-16LE", "UTF-16-LE", "UTF16", "UTF16LE":
            return "UTF-16"
        default:
            throw MDictError.unsupportedEncoding(raw)
        }
    }

    private static func parseBool(_ raw: String?) -> Bool {
        guard let raw = raw?.trimmingCharacters(in: .whitespaces).lowercased() else {
            return false
        }
        return raw == "yes" || raw == "true" || raw == "1"
    }
}

/// 只取根元素属性：元数据全在根标签上，不必遍历整个 XML。
private final class RootAttributeCollector: NSObject, XMLParserDelegate {
    private(set) var elementName: String?
    private(set) var attributes: [String: String]?
    private(set) var error: Error?
    private var aborted = false

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        guard attributes == nil else { return }
        self.elementName = elementName
        attributes = attributeDict
        aborted = true
        parser.abortParsing()
    }

    func parser(_ parser: XMLParser, parseErrorOccurred parseError: Error) {
        // abortParsing() 会回调 NSXMLParserDelegateAbortedParseError，属于预期流程
        guard !aborted else { return }
        error = parseError
    }
}

enum Adler32 {
    static func checksum(_ data: Data) -> UInt32 {
        var a: UInt32 = 1
        var b: UInt32 = 0
        for byte in data {
            a += UInt32(byte)
            if a >= 65521 { a -= 65521 }
            b += a
            if b >= 65521 { b -= 65521 }
        }
        return (b << 16) | a
    }
}
