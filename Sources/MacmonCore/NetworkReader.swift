//
//  NetworkReader.swift
//  网络采集: 复刻 exelban/stats Modules/Net/readers.swift 的数据源
//  - 主物理接口识别: SCDynamicStore 的 ServiceOrder, 回退 getifaddrs
//  - 上下行累计字节: ifmib sysctl (NET_RT_IFLIST2 / if_msghdr2)
//  - WiFi 连接速率: CWWiFiClient
//  - 本地 IP
//

import Foundation
import Darwin
import SystemConfiguration
import CoreWLAN

struct NetworkSnapshot {
    var interface: String?
    var status: Bool                // IFF_UP
    var rxBytes: UInt64
    var txBytes: UInt64
    var localIP: String?
    var wifiRateMbps: Double?
    var isVirtual: Bool
}

/// 判断是否为虚拟/回环接口 (utun/tap/bridge/vlan/awdl/lo/p2p 等)
func isVirtualInterface(_ name: String) -> Bool {
    let lower = name.lowercased()
    if lower == "lo0" { return true }
    if lower.hasPrefix("utun") || lower.hasPrefix("tap") ||
       lower.hasPrefix("bridge") || lower.hasPrefix("vlan") ||
       lower.hasPrefix("awdl") || lower.hasPrefix("llw") ||
       lower.hasPrefix("p2p") || lower.hasPrefix("ipsec") ||
       lower.hasPrefix("ppp") || lower.hasPrefix("gif") ||
       lower.hasPrefix("stf") || lower.hasPrefix("ap1") {
        return true
    }
    return false
}

/// 找主物理接口: SCDynamicStore ServiceOrder 优先, 回退 getifaddrs
func findPrimaryInterface() -> String? {
    if let setup = SCDynamicStoreCopyValue(nil, "Setup:/Network/Global/IPv4" as CFString),
       let order = setup["ServiceOrder"] as? [String] {
        for serviceID in order {
            guard let service = SCDynamicStoreCopyValue(nil, "State:/Network/Service/\(serviceID)/IPv4" as CFString) as? [String: Any],
                  service["Router"] != nil,
                  let name = service["InterfaceName"] as? String,
                  !isVirtualInterface(name) else { continue }
            return name
        }
    }

    var ifaddr: UnsafeMutablePointer<ifaddrs>?
    guard getifaddrs(&ifaddr) == 0 else { return nil }
    defer { freeifaddrs(ifaddr) }

    var ptr = ifaddr
    while let p = ptr {
        let flags = p.pointee.ifa_flags
        if (flags & UInt32(IFF_UP)) != 0,
           (flags & UInt32(IFF_LOOPBACK)) == 0,
           (flags & UInt32(IFF_POINTOPOINT)) == 0,
           let addr = p.pointee.ifa_addr, addr.pointee.sa_family == UInt8(AF_INET) {
            let name = String(cString: p.pointee.ifa_name)
            if !isVirtualInterface(name) { return name }
        }
        ptr = p.pointee.ifa_next
    }
    return nil
}

/// 通过 ifmib sysctl 读取指定接口的累计收发字节 (与 Stats getBytesInfo 同法)
func interfaceBytes(_ interface: String) -> (rx: UInt64, tx: UInt64)? {
    let index = if_nametoindex(interface)
    guard index != 0 else { return nil }

    var mib: [Int32] = [CTL_NET, PF_ROUTE, 0, 0, NET_RT_IFLIST2, Int32(index)]
    var size: size_t = 0
    guard sysctl(&mib, u_int(mib.count), nil, &size, nil, 0) == 0, size > 0 else { return nil }

    var buffer = [UInt8](repeating: 0, count: size)
    guard sysctl(&mib, u_int(mib.count), &buffer, &size, nil, 0) == 0 else { return nil }

    var offset = 0
    while offset + MemoryLayout<if_msghdr>.size <= size {
        var header = if_msghdr()
        buffer.withUnsafeBytes { src in
            _ = memcpy(&header, src.baseAddress?.advanced(by: offset), MemoryLayout<if_msghdr>.size)
        }
        guard header.ifm_msglen > 0 else { return nil }

        if Int32(header.ifm_type) == RTM_IFINFO2, offset + MemoryLayout<if_msghdr2>.size <= size {
            var header2 = if_msghdr2()
            buffer.withUnsafeBytes { src in
                _ = memcpy(&header2, src.baseAddress?.advanced(by: offset), MemoryLayout<if_msghdr2>.size)
            }
            if UInt32(header2.ifm_index) == index {
                return (rx: UInt64(header2.ifm_data.ifi_ibytes),
                        tx: UInt64(header2.ifm_data.ifi_obytes))
            }
        }
        offset += Int(header.ifm_msglen)
    }
    return nil
}

/// 采样一次网络状态 (接口 / 累计字节 / 本地 IP / WiFi 速率)
func sampleNetworkSnapshot() -> NetworkSnapshot {
    var interface = findPrimaryInterface()

    // 若 SCDynamicStore 未返回, 回退到第一个 en* 接口
    if interface == nil {
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        if getifaddrs(&ifaddr) == 0 {
            var ptr = ifaddr
            while let p = ptr {
                let name = String(cString: p.pointee.ifa_name)
                if name.hasPrefix("en"), !isVirtualInterface(name),
                   (p.pointee.ifa_flags & UInt32(IFF_UP)) != 0 {
                    interface = name
                    break
                }
                ptr = p.pointee.ifa_next
            }
            freeifaddrs(ifaddr)
        }
    }

    guard let iface = interface else {
        return NetworkSnapshot(interface: nil, status: false, rxBytes: 0, txBytes: 0,
                               localIP: nil, wifiRateMbps: nil, isVirtual: false)
    }

    // 接口状态 + 本地 IP
    var status = false
    var localIP: String?
    var ifaddr: UnsafeMutablePointer<ifaddrs>?
    if getifaddrs(&ifaddr) == 0 {
        var ptr = ifaddr
        while let p = ptr {
            if String(cString: p.pointee.ifa_name) == iface {
                status = (p.pointee.ifa_flags & UInt32(IFF_UP)) != 0
                if let addr = p.pointee.ifa_addr, addr.pointee.sa_family == UInt8(AF_INET) {
                    var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                    if getnameinfo(addr, socklen_t(addr.pointee.sa_len), &host, socklen_t(host.count),
                                   nil, 0, NI_NUMERICHOST) == 0 {
                        localIP = String(cString: host)
                    }
                }
            }
            ptr = p.pointee.ifa_next
        }
        freeifaddrs(ifaddr)
    }

    // WiFi 连接速率 (仅 en 接口, 非 WiFi 时 nil)
    var wifiRate: Double?
    if let wifi = CWWiFiClient.shared().interface(withName: iface) {
        let rate = wifi.transmitRate()
        if rate > 0 { wifiRate = rate }
    }

    let bytes = interfaceBytes(iface)
    return NetworkSnapshot(interface: iface,
                           status: status,
                           rxBytes: bytes?.rx ?? 0,
                           txBytes: bytes?.tx ?? 0,
                           localIP: localIP,
                           wifiRateMbps: wifiRate,
                           isVirtual: isVirtualInterface(iface))
}
