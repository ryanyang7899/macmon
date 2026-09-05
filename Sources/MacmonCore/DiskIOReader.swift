//
//  DiskIOReader.swift
//  磁盘 I/O 采集: 复刻 exelban/stats Modules/Disk/readers.swift 的数据源
//  遍历 IOBlockStorageDriver 服务, 读取 Statistics 里的累计读写字节, 差值算速率
//

import Foundation
import IOKit

struct DiskIOBytes {
    var readBytes: UInt64 = 0
    var writeBytes: UInt64 = 0
}

/// 遍历所有 IOBlockStorageDriver, 汇总累计读写字节
func sampleDiskIOBytes() -> DiskIOBytes {
    var result = DiskIOBytes()
    let matching = IOServiceMatching("IOBlockStorageDriver")
    var iterator: io_iterator_t = 0
    guard IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator) == kIOReturnSuccess else {
        return result
    }
    defer { IOObjectRelease(iterator) }

    var service = IOIteratorNext(iterator)
    while service != 0 {
        var cfProps: Unmanaged<CFMutableDictionary>?
        if IORegistryEntryCreateCFProperties(service, &cfProps, kCFAllocatorDefault, 0) == kIOReturnSuccess,
           let props = cfProps?.takeRetainedValue() as? [String: Any],
           let statistics = props["Statistics"] as? [String: Any] {
            result.readBytes += UInt64(statistics["Bytes (Read)"] as? Int64 ?? 0)
            result.writeBytes += UInt64(statistics["Bytes (Write)"] as? Int64 ?? 0)
        }
        IOObjectRelease(service)
        service = IOIteratorNext(iterator)
    }
    return result
}
