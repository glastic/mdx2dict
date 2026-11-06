import Compression
import Foundation

/// Writes a minimal MDict 2.0 file for parser tests.
/// The fixture contains only synthetic content; no dictionary data is used.
enum MDictFixture {
    static func make(path: String) throws {
        let entries: [(key: String, html: String)] = [
            (
                "apple",
                """
                <html><body><div class="entry" id="apple">
                <h1>apple</h1><p>A fruit.</p>
                </div></body></html>
                """
            ),
            ("apples", "@@@LINK=apple"),
            (
                "run",
                """
                <html><body><div class="entry" id="run">
                <h1>run</h1><p>Move fast.</p>
                </div></body></html>
                """
            )
        ]

        var recordData = Data()
        var offsets: [String: UInt64] = [:]
        for entry in entries {
            offsets[entry.key] = UInt64(recordData.count)
            if let bytes = entry.html.data(using: .utf8) {
                recordData.append(bytes)
            }
            recordData.append(0)
        }

        var keyBlock = Data()
        for entry in entries {
            appendU64BE(&keyBlock, offsets[entry.key] ?? 0)
            if let bytes = entry.key.data(using: .utf8) {
                keyBlock.append(bytes)
            }
            keyBlock.append(0)
        }
        let keyBlockBlock = block(keyBlock)

        var keyIndex = Data()
        appendU64BE(&keyIndex, UInt64(entries.count))
        appendU16BE(&keyIndex, UInt16(entries.first?.key.utf8.count ?? 0))
        if let first = entries.first?.key.data(using: .utf8) {
            keyIndex.append(first)
        }
        keyIndex.append(0)
        appendU16BE(&keyIndex, UInt16(entries.last?.key.utf8.count ?? 0))
        if let last = entries.last?.key.data(using: .utf8) {
            keyIndex.append(last)
        }
        keyIndex.append(0)
        appendU64BE(&keyIndex, UInt64(keyBlockBlock.count))
        appendU64BE(&keyIndex, UInt64(keyBlock.count))
        let keyIndexBlock = block(keyIndex)

        let headerXML = """
        <Dictionary GeneratedByEngineVersion="2.0" RequiredEngineVersion="2.0" \
        Encrypted="No" Encoding="UTF-8" Format="Html" KeyCaseSensitive="No" \
        StripKey="No" Title="Fixture" />
        """
        let headerBytes = headerXML.data(using: .utf16LittleEndian) ?? Data()

        var file = Data()
        appendU32BE(&file, UInt32(headerBytes.count))
        file.append(headerBytes)
        appendU32LE(&file, adler32(headerBytes))

        let keywordStart = file.count
        appendU64BE(&file, 1) // key blocks
        appendU64BE(&file, UInt64(entries.count))
        appendU64BE(&file, UInt64(keyIndex.count))
        appendU64BE(&file, UInt64(keyIndexBlock.count))
        appendU64BE(&file, UInt64(keyBlockBlock.count))

        let preamble = file[keywordStart..<(keywordStart + 40)]
        appendU32BE(&file, adler32(Data(preamble)))

        file.append(keyIndexBlock)
        file.append(keyBlockBlock)

        let recordBlock = block(recordData)
        appendU64BE(&file, 1) // record blocks
        appendU64BE(&file, UInt64(entries.count))
        appendU64BE(&file, 16) // info size: one block * 16
        appendU64BE(&file, UInt64(recordBlock.count))
        appendU64BE(&file, UInt64(recordBlock.count))
        appendU64BE(&file, UInt64(recordData.count))
        file.append(recordBlock)

        try file.write(to: URL(fileURLWithPath: path))
    }

    // MARK: - Block encoding

    private static func block(_ data: Data) -> Data {
        var result = Data()
        result.append(contentsOf: [2, 0, 0, 0]) // compression type 2 (zlib), little endian
        appendU32BE(&result, adler32(data))
        result.append(zlibDeflate(data))
        return result
    }

    private static func zlibDeflate(_ data: Data) -> Data {
        var output = Data(count: max(1024, data.count * 2 + 1024))
        let capacity = output.count
        let written = output.withUnsafeMutableBytes { destination -> Int in
            data.withUnsafeBytes { source -> Int in
                guard let destinationBase = destination.bindMemory(to: UInt8.self).baseAddress,
                      let sourceBase = source.bindMemory(to: UInt8.self).baseAddress
                else { return 0 }
                return compression_encode_buffer(
                    destinationBase,
                    capacity,
                    sourceBase,
                    data.count,
                    nil,
                    COMPRESSION_ZLIB
                )
            }
        }
        var result = Data([0x78, 0x9C])
        result.append(output.prefix(written))
        appendU32BE(&result, adler32(data))
        return result
    }

    static func adler32(_ data: Data) -> UInt32 {
        var a: UInt32 = 1
        var b: UInt32 = 0
        for byte in data {
            a = (a + UInt32(byte)) % 65521
            b = (b + a) % 65521
        }
        return (b << 16) | a
    }

    // MARK: - Endian helpers

    private static func appendU16BE(_ data: inout Data, _ value: UInt16) {
        data.append(UInt8(value >> 8))
        data.append(UInt8(value & 0xFF))
    }

    private static func appendU32BE(_ data: inout Data, _ value: UInt32) {
        data.append(UInt8((value >> 24) & 0xFF))
        data.append(UInt8((value >> 16) & 0xFF))
        data.append(UInt8((value >> 8) & 0xFF))
        data.append(UInt8(value & 0xFF))
    }

    private static func appendU32LE(_ data: inout Data, _ value: UInt32) {
        data.append(UInt8(value & 0xFF))
        data.append(UInt8((value >> 8) & 0xFF))
        data.append(UInt8((value >> 16) & 0xFF))
        data.append(UInt8((value >> 24) & 0xFF))
    }

    private static func appendU64BE(_ data: inout Data, _ value: UInt64) {
        for shift in stride(from: 56, through: 0, by: -8) {
            data.append(UInt8((value >> UInt64(shift)) & 0xFF))
        }
    }
}
