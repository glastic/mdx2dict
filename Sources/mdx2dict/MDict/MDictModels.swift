//
//  MDictModels.swift
//  MDict
//
//  解析过程中的中间数据结构；只存放元数据，不持有文件句柄。
//

import Foundation

/// 一个 key block 的元数据；不包含解压后的词条内容。
struct KeyBlockInfo {
    let numEntries: UInt64
    let firstKey: String
    let lastKey: String
    /// 含 8 字节块头；payload 长度 = compSize - 8
    let compSize: UInt64
    let decompSize: UInt64
    /// 指向 8 字节块头的文件偏移
    let fileOffset: UInt64
}

struct RecordBlockInfo {
    /// 含 8 字节块头
    let compSize: UInt64
    let decompSize: UInt64
    /// 指向 8 字节块头的文件偏移
    let fileOffset: UInt64
}

/// key block 解压后的一条词条：key 与它在全局解压后 record 数据中的偏移。
struct KeyItem {
    let key: String
    let recordOffset: UInt64
}
