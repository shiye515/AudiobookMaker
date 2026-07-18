import Foundation
import Testing

struct AppearanceComplianceTests {
    @Test
    func viewsUseSemanticSystemStylingWithoutCustomBlurOrUnconditionalAnimation() throws {
        let root = URL(filePath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let sources = [
            "AudiobookMaker/ContentView.swift",
            "AudiobookMaker/Features/Settings/SettingsView.swift",
        ]
        let forbidden = [
            "NSVisualEffectView", "CABackdropLayer", ".blur(radius:",
            ".animation(", "withAnimation(",
        ]
        for path in sources {
            let source = try String(contentsOf: root.appending(path: path), encoding: .utf8)
            for fragment in forbidden {
                #expect(!source.contains(fragment), "外观不适配系统设置：\(path) 包含 \(fragment)")
            }
        }
    }
}
