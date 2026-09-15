//
//  Telemetry.swift
//  abm
//
//  性能遥测：进程物理内存 + 近期合成 RTF 滚动均值。
//

import Darwin
import Foundation

enum Telemetry {

    nonisolated static func physFootprintMB() -> Int {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<task_vm_info_data_t>.stride / MemoryLayout<integer_t>.stride)
        let kr = withUnsafeMutablePointer(to: &info) { ptr in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        guard kr == KERN_SUCCESS else { return -1 }
        return Int(info.phys_footprint) >> 20
    }

    /// 系统总显存 / 物理内存容量（MB）
    nonisolated static var totalPhysicalMemoryMB: Int {
        Int(ProcessInfo.processInfo.physicalMemory >> 20)
    }

    /// 显存自适应高水位阈值：最大为当前系统最大显存的一半，最小 5GB (5,000 MB)
    nonisolated static var adaptiveMemoryThresholdMB: Int {
        let half = totalPhysicalMemoryMB / 2
        return max(5_000, half)
    }
}

/// 近期 RTF 滚动均值（指数移动平均）。
struct RollingRTF: Sendable {
    private(set) var value: Double = 0
    private var hasValue = false

    mutating func record(rtf: Double) {
        guard rtf > 0, rtf.isFinite else { return }
        if hasValue {
            value = value * 0.7 + rtf * 0.3
        } else {
            value = rtf
            hasValue = true
        }
    }
}
