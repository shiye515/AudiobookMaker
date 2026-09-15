//
//  abmApp.swift
//  abm
//
//  应用入口：AppStore 注入 + 全局快捷键（⌘N 导入 EPUB）。
//

import SwiftUI

@main
struct abmApp: App {
    @State private var store = AppStore()

    init() {
        // 无头解析校验：abm --verify-epub-split <fixturesDir>
        if let idx = CommandLine.arguments.firstIndex(of: "--verify-epub-split") {
            let dir = CommandLine.arguments.indices.contains(idx + 1)
                ? URL(fileURLWithPath: CommandLine.arguments[idx + 1])
                : URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            let code = EPUBSplitVerifier.run(fixturesDir: dir)
            fflush(stdout)
            exit(code)
        }
        OutputManager.appendLog("应用启动（有声书版）")
    }

    var body: some Scene {
        WindowGroup {
            MainSplitView(store: store)
        }
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("导入 EPUB…") {
                    NotificationCenter.default.post(name: .abmImportEPUB, object: nil)
                }
                .keyboardShortcut("n", modifiers: .command)
            }
        }
    }
}

extension Notification.Name {
    static let abmImportEPUB = Notification.Name("abm.importEPUB")
}
