//
//  MDictFastDecrypt.swift
//  MDict
//
//  Keyword Index 的 Fast XOR 解密（Header Encrypted bit1）。
//  块布局：4 字节 comp_type + 4 字节 Adler-32 + 密文；前 8 字节不加密，
//  comp_type 决定解压方式，Adler-32 参与密钥推导并校验解压结果。
//  逐字节规则（i 为 payload 内偏移，从 0 开始）：
//    key  = RIPEMD-128(Adler-32 的 4 字节 + 95 36 00 00)
//    prev = 0x36
//    t    = nibble_swap(cipher) ^ prev ^ (i & 0xFF) ^ key[i % 16]
//    prev = cipher（解密前的密文字节）
//  只作用于 key index，key block 正文与 record 不加密。
//

import Foundation

enum MDictFastDecrypt {
    /// 解密一个完整的 key index 压缩块；前 8 字节保持原样，结果可交给 `BlockCompression`。
    static func decryptKeyIndexBlock(_ encryptedBlock: Data) throws -> Data {
        guard encryptedBlock.count >= 8 else {
            throw MDictError.invalidBlock(
                reason: "encrypted key index block is \(encryptedBlock.count) bytes, need at least 8"
            )
        }

        // 密钥种子由块头的 Adler-32 大端字节与魔数 0x3695 组成；
        // 先复制成独立缓冲，兼容 startIndex 非零的切片。
        let start = encryptedBlock.startIndex
        var seed = Data(encryptedBlock[(start + 4)..<(start + 8)])
        seed.append(contentsOf: [0x95, 0x36, 0x00, 0x00])
        let key = [UInt8](RIPEMD128.hash(seed))
        guard key.count == 16 else {
            throw MDictError.invalidBlock(
                reason: "RIPEMD-128 returned \(key.count) bytes, expected 16"
            )
        }

        var output = Data(encryptedBlock)
        let didDecrypt = output.withUnsafeMutableBytes { raw -> Bool in
            guard let bytes = raw.bindMemory(to: UInt8.self).baseAddress else {
                return false
            }
            var previous: UInt8 = 0x36
            for index in 8..<raw.count {
                // 算法中的 i 从 payload 开头算起，直接用绝对下标会错开 8 位
                let payloadIndex = index - 8
                let cipher = bytes[index]
                let swapped = (cipher >> 4) | (cipher << 4)
                bytes[index] = swapped
                    ^ previous
                    ^ UInt8(truncatingIfNeeded: payloadIndex)
                    ^ key[payloadIndex & 0x0F]
                previous = cipher
            }
            return true
        }
        guard didDecrypt else {
            throw MDictError.invalidBlock(reason: "key index block memory is unavailable")
        }
        return output
    }
}
