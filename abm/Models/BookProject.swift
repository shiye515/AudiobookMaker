//
//  BookProject.swift
//  abm
//
//  书籍项目与章节模型（清单 book.json 的编解码结构）。
//

import Foundation

enum ChapterStatus: String, Codable, Sendable {
    case waiting
    case generating
    case done
    case failed
}

struct Chapter: Identifiable, Codable, Sendable, Equatable {
    var id: String              // "ch1"…
    var index: Int              // 1-based
    var title: String           // 叶子标题
    var parentPath: [String]    // 祖先层级链（根在前；章级为空）
    var wordCount: Int
    var voiceName: String?      // 章节音色覆盖；nil = 继承全书默认
    var status: ChapterStatus = .waiting
    var durationSeconds: Double?
    var audioFileName: String?  // 相对书籍目录（audio/ch1.wav）
    var errorMessage: String?
    var completedSegments: Int? // 断点已完成分段数
    var totalSegments: Int?     // 文本切分总分段数

    var effectiveVoiceName: String? { voiceName }

    /// 全路径展示名（祖先链 · 叶子标题）
    var fullTitle: String { (parentPath + [title]).joined(separator: " · ") }
}

struct BookProject: Identifiable, Codable, Sendable, Equatable {
    let id: String              // 内容哈希前 16 位
    var title: String
    var author: String
    var totalWordCount: Int
    var defaultVoiceName: String
    var chapters: [Chapter]
    var coverFileName: String?  // 相对书籍目录（cover.jpg / cover.png）
    var createdAt: Date
    var completedAt: Date?
    var sourceFileName: String

    // MARK: - 派生状态

    var doneCount: Int { chapters.filter { $0.status == .done }.count }

    var isFinished: Bool { !chapters.isEmpty && chapters.allSatisfy { $0.status == .done } }

    var isGenerating: Bool { chapters.contains { $0.status == .generating } }

    var isInitialState: Bool {
        !isGenerating &&
        doneCount == 0 &&
        chapters.allSatisfy { $0.status == .waiting && ($0.completedSegments ?? 0) == 0 }
    }

    var progress: Double {
        guard !chapters.isEmpty else { return 0 }
        return Double(doneCount) / Double(chapters.count)
    }

    func chapter(id: String) -> Chapter? {
        chapters.first { $0.id == id }
    }
}
