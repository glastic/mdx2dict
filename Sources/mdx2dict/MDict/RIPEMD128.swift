//
//  RIPEMD128.swift
//  MDict
//
//  RIPEMD-128（128-bit 输出），用于从 key index 块头推导 Fast XOR 解密密钥。
//  不是 RIPEMD-160：4 个字、4 轮，左右两条线各 64 步。
//  实现依据公开规范；标准测试向量（Bosselaers）覆盖空串、字母数字与 1,000,000 个 "a"。
//

import Foundation

enum RIPEMD128 {
    /// 计算 RIPEMD-128；返回值恰好 16 字节。
    static func hash(_ data: Data) -> Data {
        var message = [UInt8](data)
        // 与 MD4/MD5 相同的填充：0x80、补零到 56 (mod 64)、再写 64-bit 小端位长
        let bitLength = UInt64(message.count) &* 8
        message.append(0x80)
        while message.count % 64 != 56 {
            message.append(0)
        }
        for shift in stride(from: 0, to: 64, by: 8) {
            message.append(UInt8(truncatingIfNeeded: bitLength >> UInt64(shift)))
        }

        var state: [UInt32] = [
            0x6745_2301,
            0xEFCD_AB89,
            0x98BA_DCFE,
            0x1032_5476,
        ]

        var offset = 0
        while offset < message.count {
            var words = [UInt32](repeating: 0, count: 16)
            for index in 0..<16 {
                let base = offset + index * 4
                words[index] = UInt32(message[base])
                    | (UInt32(message[base + 1]) << 8)
                    | (UInt32(message[base + 2]) << 16)
                    | (UInt32(message[base + 3]) << 24)
            }
            compress(state: &state, words: words)
            offset += 64
        }

        var digest = Data(capacity: 16)
        for word in state {
            digest.append(UInt8(truncatingIfNeeded: word))
            digest.append(UInt8(truncatingIfNeeded: word >> 8))
            digest.append(UInt8(truncatingIfNeeded: word >> 16))
            digest.append(UInt8(truncatingIfNeeded: word >> 24))
        }
        return digest
    }

    // MARK: - 轮函数与常量

    /// 左线第 round 轮使用的 f；右线按 f4, f3, f2, f1 的顺序取用。
    private static func f(_ round: Int, _ x: UInt32, _ y: UInt32, _ z: UInt32) -> UInt32 {
        switch round {
        case 0: return x ^ y ^ z
        case 1: return (x & y) | (~x & z)
        case 2: return (x | ~y) ^ z
        default: return (x & z) | (y & ~z)
        }
    }

    private static let leftConstants: [UInt32] = [
        0x0000_0000,
        0x5A82_7999,
        0x6ED9_EBA1,
        0x8F1B_BCDC,
    ]

    /// 右线 4 轮的加法常量；最后一个是 0
    private static let rightConstants: [UInt32] = [
        0x50A2_8BE6,
        0x5C4D_D124,
        0x6D70_3EF3,
        0x0000_0000,
    ]

    private static let leftWordOrder: [Int] = [
        0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15,
        7, 4, 13, 1, 10, 6, 15, 3, 12, 0, 9, 5, 2, 14, 11, 8,
        3, 10, 14, 4, 9, 15, 8, 1, 2, 7, 0, 6, 13, 11, 5, 12,
        1, 9, 11, 10, 0, 8, 12, 4, 13, 3, 7, 15, 14, 5, 6, 2,
    ]

    private static let rightWordOrder: [Int] = [
        5, 14, 7, 0, 9, 2, 11, 4, 13, 6, 15, 8, 1, 10, 3, 12,
        6, 11, 3, 7, 0, 13, 5, 10, 14, 15, 8, 12, 4, 9, 1, 2,
        15, 5, 1, 3, 7, 14, 6, 9, 11, 8, 12, 2, 10, 0, 4, 13,
        8, 6, 4, 1, 3, 11, 15, 0, 5, 12, 2, 13, 9, 7, 10, 14,
    ]

    private static let leftShifts: [Int] = [
        11, 14, 15, 12, 5, 8, 7, 9, 11, 13, 14, 15, 6, 7, 9, 8,
        7, 6, 8, 13, 11, 9, 7, 15, 7, 12, 15, 9, 11, 7, 13, 12,
        11, 13, 6, 7, 14, 9, 13, 15, 14, 8, 13, 6, 5, 12, 7, 5,
        11, 12, 14, 15, 14, 15, 9, 8, 9, 14, 5, 6, 8, 6, 5, 12,
    ]

    private static let rightShifts: [Int] = [
        8, 9, 9, 11, 13, 15, 15, 5, 7, 7, 8, 11, 14, 14, 12, 6,
        9, 13, 15, 7, 12, 8, 9, 11, 7, 7, 12, 7, 6, 15, 13, 11,
        9, 7, 15, 11, 8, 6, 6, 14, 12, 13, 5, 14, 13, 13, 7, 5,
        15, 5, 8, 11, 14, 14, 6, 14, 6, 9, 12, 9, 12, 5, 15, 8,
    ]

    // MARK: - 压缩函数

    private static func compress(state: inout [UInt32], words: [UInt32]) {
        var a = state[0], b = state[1], c = state[2], d = state[3]
        var aa = a, bb = b, cc = c, dd = d

        for index in 0..<64 {
            let round = index / 16

            // 左线：左移后轮换变量，等价于参考实现的 FF(a,b,c,d) / FF(d,a,b,c) ...
            let left = rotateLeft(
                a &+ f(round, b, c, d) &+ words[leftWordOrder[index]] &+ leftConstants[round],
                by: leftShifts[index]
            )
            a = d
            d = c
            c = b
            b = left

            // 右线：轮函数顺序相反（f4, f3, f2, f1）
            let right = rotateLeft(
                aa &+ f(3 - round, bb, cc, dd) &+ words[rightWordOrder[index]] &+ rightConstants[round],
                by: rightShifts[index]
            )
            aa = dd
            dd = cc
            cc = bb
            bb = right
        }

        // 合并两条线；先取旧值再写回，避免顺序依赖出错
        let combined = state[1] &+ c &+ dd
        state[1] = state[2] &+ d &+ aa
        state[2] = state[3] &+ a &+ bb
        state[3] = state[0] &+ b &+ cc
        state[0] = combined
    }

    private static func rotateLeft(_ value: UInt32, by amount: Int) -> UInt32 {
        (value << amount) | (value >> (32 - amount))
    }
}
