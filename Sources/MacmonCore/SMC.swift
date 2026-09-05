//
//  SMC.swift
//  只读 SMC 访问 (温度 / 风扇),基于 exelban/stats 的 SMC.swift 精简改写 (MIT License)
//  https://github.com/exelban/stats/blob/master/SMC/smc.swift
//
//  原理: 通过 IOKit 打开 AppleSMC 服务, 用 io_connect 结构体方法读写 SMC key。
//  只保留读取, 去掉风扇/模式等写操作。
//

import Foundation
import IOKit

// 从 SMC 返回的 dataType (四字符码) 解码数值时的类型对照
enum SMCDataType: String {
    case UI8  = "ui8 "
    case UI16 = "ui16"
    case UI32 = "ui32"
    case SP1E = "sp1e"
    case SP3C = "sp3c"
    case SP4B = "sp4b"
    case SP5A = "sp5a"
    case SPA5 = "spa5"
    case SP69 = "sp69"
    case SP78 = "sp78"
    case SP87 = "sp87"
    case SP96 = "sp96"
    case SPB4 = "spb4"
    case SPF0 = "spf0"
    case FLT  = "flt "
    case FPE2 = "fpe2"
    case FP2E = "fp2e"
}

// SMC 命令号 (写入 data8 字段)
enum SMCCommand: UInt8 {
    case kernelIndex = 2
    case readBytes   = 5
    case writeBytes  = 6
    case readIndex   = 8
    case readKeyInfo = 9
    case readPLimit  = 11
    case readVers    = 12
}

// 与内核 SMCKeyData_t 布局一致的 Swift 结构体 (共 80 字节)
struct SMCKeyData_t {
    typealias SMCBytes_t = (UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                            UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                            UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                            UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                            UInt8, UInt8, UInt8, UInt8)

    struct vers_t {
        var major: UInt8 = 0
        var minor: UInt8 = 0
        var build: UInt8 = 0
        var reserved: UInt8 = 0
        var release: UInt16 = 0
    }

    struct LimitData_t {
        var version: UInt16 = 0
        var length: UInt16 = 0
        var cpuPLimit: UInt32 = 0
        var gpuPLimit: UInt32 = 0
        var memPLimit: UInt32 = 0
    }

    struct keyInfo_t {
        var dataSize: UInt32 = 0
        var dataType: UInt32 = 0
        var dataAttributes: UInt8 = 0
    }

    var key: UInt32 = 0
    var vers = vers_t()
    var pLimitData = LimitData_t()
    var keyInfo = keyInfo_t()
    var padding: UInt16 = 0
    var result: UInt8 = 0
    var status: UInt8 = 0
    var data8: UInt8 = 0
    var data32: UInt32 = 0
    var bytes: SMCBytes_t = (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
                             0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
}

// 读取结果
public struct SMCValue {
    public let key: String
    public let dataSize: UInt32
    public let dataType: String
    public let bytes: [UInt8]
}

extension UInt32 {
    init(fromFourChar str: String) {
        self = str.utf8.reduce(0) { $0 << 8 | UInt32($1) }
    }
    func fourCharString() -> String {
        return String(describing: UnicodeScalar(self >> 24 & 0xff)!) +
               String(describing: UnicodeScalar(self >> 16 & 0xff)!) +
               String(describing: UnicodeScalar(self >> 8  & 0xff)!) +
               String(describing: UnicodeScalar(self       & 0xff)!)
    }
}

extension UInt16 {
    init(bigEndianBytes b: (UInt8, UInt8)) {
        self = UInt16(b.0) << 8 | UInt16(b.1)
    }
}

extension UInt32 {
    init(bigEndianBytes b: (UInt8, UInt8, UInt8, UInt8)) {
        self = UInt32(b.0) << 24 | UInt32(b.1) << 16 | UInt32(b.2) << 8 | UInt32(b.3)
    }
}

/// 只读 SMC 客户端
public final class SMC {
    private var conn: io_connect_t = 0

    public init?() {
        var result: kern_return_t
        var iterator: io_iterator_t = 0

        let matching = IOServiceMatching("AppleSMC")
        result = IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator)
        guard result == kIOReturnSuccess else {
            print("[SMC] IOServiceGetMatchingServices 失败: \(result)")
            return nil
        }

        let device = IOIteratorNext(iterator)
        IOObjectRelease(iterator)
        guard device != 0 else {
            print("[SMC] 未找到 AppleSMC 设备")
            return nil
        }

        result = IOServiceOpen(device, mach_task_self_, 0, &conn)
        IOObjectRelease(device)
        guard result == kIOReturnSuccess else {
            print("[SMC] IOServiceOpen 失败: \(result)")
            return nil
        }
    }

    deinit {
        if conn != 0 {
            IOServiceClose(conn)
        }
    }

    /// 读取一个 SMC key 的原始值
    public func read(_ key: String) -> SMCValue? {
        var input = SMCKeyData_t()
        var output = SMCKeyData_t()

        input.key = UInt32(fromFourChar: key)
        input.data8 = SMCCommand.readKeyInfo.rawValue
        guard call(SMCCommand.kernelIndex.rawValue, input: &input, output: &output) == kIOReturnSuccess else {
            return nil
        }

        let dataSize = output.keyInfo.dataSize
        // 关键: dataType 必须在 readBytes 调用之前保存,
        // 第二次 call 会整体覆盖 output, 其 keyInfo 会被冲掉。
        let dataType = output.keyInfo.dataType.fourCharString()
        guard dataSize > 0 else { return nil }

        input.keyInfo.dataSize = dataSize
        input.data8 = SMCCommand.readBytes.rawValue
        guard call(SMCCommand.kernelIndex.rawValue, input: &input, output: &output) == kIOReturnSuccess else {
            return nil
        }

        // 从 32 字节元组安全拷贝到数组
        let raw = withUnsafeBytes(of: output.bytes) { Array($0) }
        let bytes = Array(raw.prefix(Int(min(dataSize, 32))))

        return SMCValue(
            key: key,
            dataSize: dataSize,
            dataType: dataType,
            bytes: bytes
        )
    }

    /// 读取并解码为 Double (温度 / 风扇转速等)
    public func getValue(_ key: String) -> Double? {
        guard let val = read(key) else { return nil }

        // 全 0 数据视为无效 (风扇模式等 key 除外, 这里只读不涉及)
        if val.bytes.allSatisfy({ $0 == 0 }) { return nil }

        switch val.dataType {
        case SMCDataType.UI8.rawValue:
            return Double(val.bytes[0])
        case SMCDataType.UI16.rawValue:
            return Double(UInt16(bigEndianBytes: (val.bytes[0], val.bytes[1])))
        case SMCDataType.UI32.rawValue:
            return Double(UInt32(bigEndianBytes: (val.bytes[0], val.bytes[1], val.bytes[2], val.bytes[3])))
        case SMCDataType.SP1E.rawValue:
            return Double(UInt16(val.bytes[0]) * 256 + UInt16(val.bytes[1])) / 16384
        case SMCDataType.SP3C.rawValue:
            return Double(UInt16(val.bytes[0]) * 256 + UInt16(val.bytes[1])) / 4096
        case SMCDataType.SP4B.rawValue:
            return Double(UInt16(val.bytes[0]) * 256 + UInt16(val.bytes[1])) / 2048
        case SMCDataType.SP5A.rawValue:
            return Double(UInt16(val.bytes[0]) * 256 + UInt16(val.bytes[1])) / 1024
        case SMCDataType.SP69.rawValue:
            return Double(UInt16(val.bytes[0]) * 256 + UInt16(val.bytes[1])) / 512
        case SMCDataType.SP78.rawValue:   // 温度 (定点小数, 256 分之一度)
            return Double(Int(val.bytes[0]) * 256 + Int(val.bytes[1])) / 256
        case SMCDataType.SP87.rawValue:
            return Double(Int(val.bytes[0]) * 256 + Int(val.bytes[1])) / 128
        case SMCDataType.SP96.rawValue:
            return Double(Int(val.bytes[0]) * 256 + Int(val.bytes[1])) / 64
        case SMCDataType.SPA5.rawValue:
            return Double(UInt16(val.bytes[0]) * 256 + UInt16(val.bytes[1])) / 32
        case SMCDataType.SPB4.rawValue:
            return Double(Int(val.bytes[0]) * 256 + Int(val.bytes[1])) / 16
        case SMCDataType.SPF0.rawValue:
            return Double(Int(val.bytes[0]) * 256 + Int(val.bytes[1]))
        case SMCDataType.FLT.rawValue:
            guard val.bytes.count >= 4 else { return nil }
            return Double(val.bytes.withUnsafeBytes { $0.load(as: Float.self) })
        case SMCDataType.FPE2.rawValue:   // 风扇转速 (定点 4 位小数)
            return Double((Int(val.bytes[0]) << 6) + (Int(val.bytes[1]) >> 2))
        case SMCDataType.FP2E.rawValue:
            return Double(val.bytes[0] * 64 + val.bytes[1] / 4) / 16384
        default:
            return nil
        }
    }

    /// 枚举全部 SMC key 名称 (用于探测某台机器上有哪些传感器)
    public func getAllKeys() -> [String] {
        guard let keysNum = getValue("#KEY") else { return [] }

        var list: [String] = []
        for i in 0...Int(keysNum) {
            var input = SMCKeyData_t()
            var output = SMCKeyData_t()
            input.data8 = SMCCommand.readIndex.rawValue
            input.data32 = UInt32(i)
            guard call(SMCCommand.kernelIndex.rawValue, input: &input, output: &output) == kIOReturnSuccess else {
                continue
            }
            list.append(output.key.fourCharString())
        }
        return list
    }

    // MARK: - 底层调用

    private func call(_ index: UInt8, input: inout SMCKeyData_t, output: inout SMCKeyData_t) -> kern_return_t {
        let inputSize = MemoryLayout<SMCKeyData_t>.stride
        var outputSize = MemoryLayout<SMCKeyData_t>.stride
        return IOConnectCallStructMethod(conn, UInt32(index), &input, inputSize, &output, &outputSize)
    }
}
