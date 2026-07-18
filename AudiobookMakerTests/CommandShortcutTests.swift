import Foundation
import Testing

struct CommandShortcutTests {
    @Test
    func everySpecifiedMenuCommandDeclaresItsKeyboardShortcut() throws {
        let source = try String(
            contentsOf: URL(filePath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appending(path: "AudiobookMaker/App/AppCommands.swift"),
            encoding: .utf8
        )
        let requiredFragments = [
            ".keyboardShortcut(\"o\", modifiers: .command)",
            ".keyboardShortcut(\"f\", modifiers: .command)",
            ".keyboardShortcut(.return, modifiers: .command)",
            ".keyboardShortcut(\".\", modifiers: .command)",
            ".keyboardShortcut(\"e\", modifiers: [.command, .shift])",
            ".keyboardShortcut(.delete, modifiers: [])",
        ]
        for fragment in requiredFragments {
            #expect(source.contains(fragment), "缺少快捷键声明：\(fragment)")
        }
    }
}
