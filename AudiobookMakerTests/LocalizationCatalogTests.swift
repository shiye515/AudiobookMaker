import Foundation
import Testing
@testable import AudiobookMaker

struct LocalizationCatalogTests {
    @Test func everyExtractedStringHasCompletedEnglishTranslation() throws {
        let catalogURL = URL(filePath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appending(path: "AudiobookMaker/Resources/Localizable.xcstrings")
        let object = try #require(
            try JSONSerialization.jsonObject(with: Data(contentsOf: catalogURL))
                as? [String: Any]
        )
        #expect(object["sourceLanguage"] as? String == "zh-Hans")
        let strings = try #require(object["strings"] as? [String: Any])
        #expect(strings.count >= 120)
        for (key, rawEntry) in strings {
            let entry = try #require(rawEntry as? [String: Any], "无效条目：\(key)")
            let localizations = try #require(
                entry["localizations"] as? [String: Any],
                "缺少本地化：\(key)"
            )
            let english = try #require(
                localizations["en"] as? [String: Any],
                "缺少英文：\(key)"
            )
            let unit = try #require(english["stringUnit"] as? [String: Any])
            #expect(unit["state"] as? String == "translated", "英文未完成：\(key)")
            #expect((unit["value"] as? String)?.isEmpty == false, "英文为空：\(key)")
        }
    }

    @Test func unknownAuthorErrorsAndFormattedLimitsResolveInEnglish() {
        guard let englishPath = Bundle.main.path(forResource: "en", ofType: "lproj"),
              let englishBundle = Bundle(path: englishPath) else {
            Issue.record("测试包缺少英文资源")
            return
        }
        #expect(englishBundle.localizedString(forKey: "未知作者", value: nil, table: nil)
            == "Unknown Author")
        #expect(englishBundle.localizedString(forKey: "语音生成超时。", value: nil, table: nil)
            == "Speech generation timed out.")
        let limitFormat = englishBundle.localizedString(
            forKey: "文本片段超过运行时上限（%lld 个字符）。",
            value: nil,
            table: nil
        )
        #expect(String(format: limitFormat, 36).contains("36 characters"))
    }
}
