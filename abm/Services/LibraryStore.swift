//
//  LibraryStore.swift
//  abm
//
//  书籍项目持久化：~/Library/Application Support/abm/library/<bookID>/
//    book.json（清单 = 唯一事实来源）、cover.<ext>、text/ch<N>.txt、audio/ch<N>.wav
//

import AVFoundation
import CryptoKit
import Foundation

enum LibraryStore {

    static var libraryRoot: URL {
        AppPaths.appSupportDir.appendingPathComponent("library", isDirectory: true)
    }

    static func directory(for bookID: String) -> URL {
        libraryRoot.appendingPathComponent(bookID, isDirectory: true)
    }

    static func manifestURL(for bookID: String) -> URL {
        directory(for: bookID).appendingPathComponent("book.json")
    }

    /// 内容标识：文件大小 + 修改时间的 SHA256 前缀（用于重复导入判断与 bookID）
    static func contentFingerprint(url: URL) -> String? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attrs[.size] as? Int,
              let modified = attrs[.modificationDate] as? Date else { return nil }
        let payload = "\(url.lastPathComponent)|\(size)|\(modified.timeIntervalSince1970)"
        let digest = SHA256.hash(data: Data(payload.utf8))
        return digest.prefix(16).map { String(format: "%02x", $0) }.joined()
    }

    struct LoadResult {
        var books: [BookProject]
        /// 解码失败（含结构升级）的书目录 ID，供 UI 提示重新导入
        var failedBookIDs: [String]
    }

    /// 扫描书库重建书架；音频文件缺失的章节自动回退等待态（断点保护）。
    static func loadAll() -> LoadResult {
        let fm = FileManager.default
        guard let bookIDs = try? fm.contentsOfDirectory(atPath: libraryRoot.path) else {
            return LoadResult(books: [], failedBookIDs: [])
        }
        var books: [BookProject] = []
        var failed: [String] = []
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601   // 与 save 的编码策略对称，否则解码必然失败
        for bookID in bookIDs.sorted() {
            let manifestURL = manifestURL(for: bookID)
            guard let data = try? Data(contentsOf: manifestURL) else { continue }
            do {
                var book = try decoder.decode(BookProject.self, from: data)
                reconcile(&book, directory: directory(for: bookID))
                books.append(book)
            } catch {
                // 结构升级或清单损坏：收集后由 UI 可见提示，不静默吞书
                OutputManager.appendLog("书籍清单解码失败 \(bookID): \(error.localizedDescription)")
                failed.append(bookID)
            }
        }
        return LoadResult(books: books, failedBookIDs: failed)
    }

    /// 启动一致性对账（生成中回退、音频缺失回退、孤儿音频恢复为已完成）。
    private static func reconcile(_ book: inout BookProject, directory dir: URL) {
        let fm = FileManager.default
        // ① 生成中章节回退等待态（崩溃残留）
        // ② 完成章节音频缺失 → 回退等待态
        // ③ 磁盘有音频但清单丢失状态（崩溃发生在回写前）→ 恢复为已完成并回填实测时长
        for i in book.chapters.indices {
            if book.chapters[i].status == .generating {
                book.chapters[i].status = .waiting
            }
            if book.chapters[i].status == .done,
               let file = book.chapters[i].audioFileName,
               !fm.fileExists(atPath: dir.appendingPathComponent(file).path) {
                book.chapters[i].status = .waiting
                book.chapters[i].audioFileName = nil
                book.chapters[i].durationSeconds = nil
            }
            let canonical = dir.appendingPathComponent("audio/\(book.chapters[i].id).wav")
            if book.chapters[i].status != .done, fm.fileExists(atPath: canonical.path) {
                var duration: Double?
                if let audioFile = try? AVAudioFile(forReading: canonical) {
                    duration = Double(audioFile.length) / audioFile.processingFormat.sampleRate
                }
                book.chapters[i].status = .done
                book.chapters[i].audioFileName = canonical.lastPathComponent
                book.chapters[i].durationSeconds = duration
                book.chapters[i].errorMessage = nil
                book.chapters[i].completedSegments = nil
                book.chapters[i].totalSegments = nil
            } else if book.chapters[i].status == .waiting {
                // ④ 校验分段断点状态：若磁盘存在断点缓存且分段文件有效，同步分段数
                let segDir = segmentsDirectory(bookID: book.id, chapterID: book.chapters[i].id)
                let metaURL = segDir.appendingPathComponent("meta.json")
                if fm.fileExists(atPath: metaURL.path),
                   let data = try? Data(contentsOf: metaURL) {
                    let decoder = JSONDecoder()
                    decoder.dateDecodingStrategy = .iso8601
                    let cp = (try? decoder.decode(ChapterCheckpoint.self, from: data))
                        ?? (try? JSONDecoder().decode(ChapterCheckpoint.self, from: data))
                    if let cp {
                        let validCount = cp.completedIndices.filter { idx in
                            fm.fileExists(atPath: segDir.appendingPathComponent(String(format: "seg_%04d.raw", idx)).path)
                        }.count
                        if validCount > 0 {
                            book.chapters[i].completedSegments = validCount
                            book.chapters[i].totalSegments = cp.totalSegments
                        }
                    }
                }
            }
        }
        if book.isFinished, book.completedAt == nil { book.completedAt = Date() }
    }

    static func save(_ book: BookProject) throws {
        try AppPaths.ensureOutputDirectories()
        let dir = directory(for: book.id)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(book)
        try data.write(to: manifestURL(for: book.id), options: [.atomic])
    }

    // MARK: - 章节文本 / 音频 / 封面

    static func chapterTextURL(bookID: String, chapterID: String) -> URL {
        directory(for: bookID).appendingPathComponent("text/\(chapterID).txt")
    }

    static func saveChapterText(_ text: String, bookID: String, chapterID: String) throws {
        let url = chapterTextURL(bookID: bookID, chapterID: chapterID)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    static func loadChapterText(bookID: String, chapterID: String) -> String? {
        try? String(contentsOf: chapterTextURL(bookID: bookID, chapterID: chapterID), encoding: .utf8)
    }

    static func audioURL(book: BookProject, chapter: Chapter) -> URL? {
        guard let file = chapter.audioFileName else { return nil }
        let url = directory(for: book.id).appendingPathComponent(file)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    static func coverURL(for book: BookProject) -> URL? {
        guard let file = book.coverFileName else { return nil }
        let url = directory(for: book.id).appendingPathComponent(file)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    static func removeChapterAudio(book: BookProject, chapter: Chapter) {
        if let file = chapter.audioFileName {
            try? FileManager.default.removeItem(at: directory(for: book.id).appendingPathComponent(file))
        }
        clearChapterSegments(bookID: book.id, chapterID: chapter.id)
    }

    /// 章节分段临时缓存目录（output/books/<bookID>/segments/<chapterID>）
    static func segmentsDirectory(bookID: String, chapterID: String) -> URL {
        directory(for: bookID)
            .appendingPathComponent("segments", isDirectory: true)
            .appendingPathComponent(chapterID, isDirectory: true)
    }

    /// 清理章节分段临时缓存
    static func clearChapterSegments(bookID: String, chapterID: String) {
        let dir = segmentsDirectory(bookID: bookID, chapterID: chapterID)
        try? FileManager.default.removeItem(at: dir)
    }

    static func deleteBook(_ book: BookProject) {
        try? FileManager.default.removeItem(at: directory(for: book.id))
    }
}
