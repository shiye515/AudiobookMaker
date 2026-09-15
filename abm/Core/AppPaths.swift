//
//  AppPaths.swift
//  abm
//
//  外部资源路径的唯一收敛点。M1 阶段直接读仓库目录；改为 Bundle/Application Support
//  分发时只改这里。
//

import Foundation

enum AppPaths {
    /// 模型不再随仓库分发，首次初始化自动下载到系统缓存（~/Library/Caches/qwen3-speech/）。

    /// 合成输出与运行日志（用户可通过界面按钮在访达打开）。
    static let appSupportDir: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("abm", isDirectory: true)
    }()
    static let logsDir = appSupportDir.appendingPathComponent("logs", isDirectory: true)
    static var logFile: URL { logsDir.appendingPathComponent("abm.log") }

    static func ensureOutputDirectories() throws {
        let fm = FileManager.default
        try fm.createDirectory(at: logsDir, withIntermediateDirectories: true)
    }
}
