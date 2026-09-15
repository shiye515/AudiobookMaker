//
//  EPUBImportService.swift
//  abm
//
//  导入管线：解析 → 落盘书籍目录（清单/封面/章节文本）→ 返回 BookProject。
//

import Foundation

enum EPUBImportService {

    struct ImportError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    /// 后台解析并入库；返回书籍项目。
    static func `import`(fileURL url: URL, defaultVoiceName: String) async throws -> BookProject {
        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }

        guard url.pathExtension.lowercased() == "epub" else {
            throw ImportError(message: "仅支持 .epub 文件：\(url.lastPathComponent)")
        }
        guard let fingerprint = LibraryStore.contentFingerprint(url: url) else {
            throw ImportError(message: "无法读取文件信息：\(url.lastPathComponent)")
        }
        let bookID = String(fingerprint.prefix(16))

        let parsed = try await Task.detached(priority: .userInitiated) {
            try EPUBParser.parse(url: url)
        }.value

        var chapters: [Chapter] = []
        for parsedChapter in parsed.chapters {
            let id = "ch\(parsedChapter.index + 1)"
            try LibraryStore.saveChapterText(
                parsedChapter.plainText, bookID: bookID, chapterID: id)
            chapters.append(Chapter(
                id: id,
                index: parsedChapter.index + 1,
                title: parsedChapter.title,
                parentPath: parsedChapter.parentPath,
                wordCount: parsedChapter.plainText.count))
        }

        var coverFileName: String?
        if let coverData = parsed.coverData {
            let ext = parsed.coverFileExtension ?? "jpg"
            let coverURL = LibraryStore.directory(for: bookID)
                .appendingPathComponent("cover.\(ext)")
            try? FileManager.default.createDirectory(
                at: coverURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? coverData.write(to: coverURL, options: [.atomic])
            coverFileName = coverURL.lastPathComponent
        }

        return BookProject(
            id: bookID,
            title: parsed.title,
            author: parsed.author,
            totalWordCount: chapters.reduce(0) { $0 + $1.wordCount },
            defaultVoiceName: defaultVoiceName,
            chapters: chapters,
            coverFileName: coverFileName,
            createdAt: Date(),
            completedAt: nil,
            sourceFileName: url.lastPathComponent)
    }
}
