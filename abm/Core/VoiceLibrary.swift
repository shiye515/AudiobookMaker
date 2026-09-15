//
//  VoiceLibrary.swift
//  abm
//
//  内置音色库：固定 10 个有声书音色（随 App 打包 audiobook_voices.json + mp3）。
//  范围已确认：不支持用户导入。提供性别/题材分类标签与默认旁白偏好。
//

import Foundation

@MainActor
@Observable
final class VoiceLibrary {
    private(set) var voices: [VoiceSample] = []

    /// 全局默认旁白（音色名称），音色中心设置，新导入书籍使用。
    var defaultNarratorName: String {
        get { UserDefaults.standard.string(forKey: "abm.defaultNarrator") ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: "abm.defaultNarrator") }
    }

    init() {
        do {
            voices = try Self.loadBuiltIn()
        } catch {
            print("[VoiceLibrary] 内置音色清单加载失败: \(error)")
        }
    }

    static func loadBuiltIn() throws -> [VoiceSample] {
        guard let url = Bundle.main.url(forResource: "audiobook_voices", withExtension: "json") else {
            throw NSError(domain: "VoiceLibrary", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Bundle 中找不到 audiobook_voices.json"])
        }
        return try JSONDecoder().decode([VoiceSample].self, from: Data(contentsOf: url))
    }

    /// 参考音频在 Bundle 中的位置。
    nonisolated static func audioURL(for voice: VoiceSample) -> URL? {
        let base = (voice.audioFile as NSString).deletingPathExtension
        return Bundle.main.url(forResource: base, withExtension: "mp3")
    }

    // MARK: - 分类标签（音色中心筛选用）

    enum VoiceCategory: String, CaseIterable, Identifiable {
        case all = "全部"
        case male = "男声"
        case female = "女声"
        case storytelling = "评书评话"
        case romance = "情感言情"
        var id: String { rawValue }
    }

    func categories(for voice: VoiceSample) -> [VoiceCategory] {
        var tags: [VoiceCategory] = voice.trait.contains("男") ? [.male] : [.female]
        switch voice.name {
        case "龙三叔", "龙老伯", "龙修": tags.append(.storytelling)
        case "龙婉君", "龙媛", "龙老姨", "龙悦": tags.append(.romance)
        default: break
        }
        return tags
    }

    /// 获取特定分类下的音色数量
    func count(for category: VoiceCategory) -> Int {
        if category == .all { return voices.count }
        return voices.filter { categories(for: $0).contains(category) }.count
    }

    /// 音色推荐适合的有声书题材
    func genre(for voice: VoiceSample) -> String {
        switch voice.name {
        case "龙妙": return "现代散文 · 诗歌抒情"
        case "龙三叔": return "历史传记 · 纪实叙事"
        case "龙媛": return "都市情感 · 治愈言情"
        case "龙悦": return "哲学思辨 · 人文社科"
        case "龙修": return "经典评书 · 文学名著"
        case "龙楠": return "地理游记 · 悬疑推理"
        case "龙婉君": return "古典言情 · 细腻叙事"
        case "龙逸尘": return "玄幻武侠 · 热血冒险"
        case "龙老伯": return "传统说书 · 沧桑纪实"
        case "龙老姨": return "年代纪实 · 市井温情"
        default: return "有声小说 · 精彩朗读"
        }
    }

    /// 音色展示标签集
    func tags(for voice: VoiceSample) -> [String] {
        var result: [String] = []
        if let age = voice.age, !age.isEmpty {
            result.append(age)
        }
        result.append(voice.trait.contains("男") ? "男声" : "女声")
        return result
    }

    func voice(named name: String) -> VoiceSample? {
        voices.first { $0.name == name }
    }
}
