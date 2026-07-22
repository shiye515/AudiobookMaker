import SwiftUI

extension Notification.Name {
    static let importEPUB = Notification.Name("AudiobookMaker.importEPUB")
    static let showConversionQueue = Notification.Name("AudiobookMaker.showConversionQueue")
    static let startOrContinueConversion = Notification.Name("AudiobookMaker.startOrContinueConversion")
    static let pauseConversion = Notification.Name("AudiobookMaker.pauseConversion")
    static let deleteSelectedBook = Notification.Name("AudiobookMaker.deleteSelectedBook")
    static let exportSelectedBook = Notification.Name("AudiobookMaker.exportSelectedBook")
    static let selectSystemModel = Notification.Name("AudiobookMaker.selectSystemModel")
    static let selectKokoroModel = Notification.Name("AudiobookMaker.selectKokoroModel")
    static let selectCosyVoiceModel = Notification.Name("AudiobookMaker.selectCosyVoiceModel")
    static let selectQwen3TTSModel = Notification.Name("AudiobookMaker.selectQwen3TTSModel")
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

        CommandMenu("Model") {
            Button("Apple 系统语音") { post(.selectSystemModel) }
            Button("Kokoro 多语言 Int8") { post(.selectKokoroModel) }
            Button("CosyVoice3 0.5B MLX 8-bit") { post(.selectCosyVoiceModel) }
            Button("Qwen3-TTS 0.6B CustomVoice") { post(.selectQwen3TTSModel) }
            Divider()
            SettingsLink { Text("模型设置…") }
        }
    }

    private func post(_ name: Notification.Name) {
        NotificationCenter.default.post(name: name, object: nil)
    }
}
