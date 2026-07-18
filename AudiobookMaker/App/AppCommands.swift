import SwiftUI

extension Notification.Name {
    static let importEPUB = Notification.Name("AudiobookMaker.importEPUB")
    static let showConversionQueue = Notification.Name("AudiobookMaker.showConversionQueue")
    static let startOrContinueConversion = Notification.Name("AudiobookMaker.startOrContinueConversion")
    static let pauseConversion = Notification.Name("AudiobookMaker.pauseConversion")
    static let deleteSelectedBook = Notification.Name("AudiobookMaker.deleteSelectedBook")
    static let exportSelectedBook = Notification.Name("AudiobookMaker.exportSelectedBook")
    static let focusBookSearch = Notification.Name("AudiobookMaker.focusBookSearch")
}

struct AppCommands: Commands {
    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("导入 EPUB…") {
                post(.importEPUB)
            }
            .keyboardShortcut("o", modifiers: .command)
        }

        CommandGroup(after: .sidebar) {
            Divider()
            Button("显示转换队列") {
                post(.showConversionQueue)
            }
        }

        CommandGroup(after: .textEditing) {
            Button("搜索书籍") {
                post(.focusBookSearch)
            }
            .keyboardShortcut("f", modifiers: .command)
        }

        CommandMenu("Book") {
            Button("开始或继续转换") {
                post(.startOrContinueConversion)
            }
            .keyboardShortcut(.return, modifiers: .command)

            Button("暂停当前任务") {
                post(.pauseConversion)
            }
            .keyboardShortcut(".", modifiers: .command)

            Divider()

            Button("导出有声书…") {
                post(.exportSelectedBook)
            }
                .keyboardShortcut("e", modifiers: [.command, .shift])

            Button("删除选中书籍…", role: .destructive) {
                post(.deleteSelectedBook)
            }
            .keyboardShortcut(.delete, modifiers: [])
        }
    }

    private func post(_ name: Notification.Name) {
        NotificationCenter.default.post(name: name, object: nil)
    }
}
