//
//  EPUBSplitVerifier.swift
//  abm
//
//  解析层可执行校验：`abm --verify-epub-split <fixturesDir>`。
//  覆盖：同文件锚点切分、层级全展开、无目录退化、锚点缺失回退、空正文跳过、page-list 不入树。
//

import Foundation

enum EPUBSplitVerifier {
    struct Expectation {
        let fixture: String
        let minChapters: Int
        let requiredTitles: [String]
        let forbiddenTitles: [String]

        init(_ fixture: String, minChapters: Int = 1, required: [String] = [], forbidden: [String] = []) {
            self.fixture = fixture
            self.minChapters = minChapters
            self.requiredTitles = required
            self.forbiddenTitles = forbidden
        }
    }

    static func run(fixturesDir: URL) -> Int32 {
        if fixturesDir.pathExtension.lowercased() == "epub" {
            do {
                let parsed = try EPUBParser.parse(url: fixturesDir)
                print("title=\(parsed.title) chapters=\(parsed.chapters.count)")
                for (i, ch) in parsed.chapters.enumerated() {
                    print(String(format: "%3d  %@  | %d字 | parent=[%@]",
                                 i + 1, ch.fullTitle, ch.plainText.count,
                                 ch.parentPath.joined(separator: "/")))
                }
                return 0
            } catch {
                print("FAIL \(error)")
                return 1
            }
        }

        let expectations: [Expectation] = [
            .init("nav_toc_split.epub",
                  minChapters: 3,
                  required: [
                      "第一章 引子 · 第一节 启程",
                      "第一章 引子 · 第二节 风暴",
                      "卷二 · 独立章"
                  ]),
            .init("no_toc.epub",
                  minChapters: 2,
                  required: ["第一章 文档甲", "第二章 文档乙"]),
            .init("missing_anchor.epub",
                  minChapters: 2,
                  required: ["第一节 有效", "第二节 后继"]),
            .init("pagelist_nav.epub",
                  minChapters: 1,
                  required: ["第一章 正文"],
                  forbidden: ["页码 1", "封面"]),
        ]

        var failures = 0
        for exp in expectations {
            let url = fixturesDir.appendingPathComponent(exp.fixture)
            guard FileManager.default.fileExists(atPath: url.path) else {
                print("FAIL \(exp.fixture): fixture missing")
                failures += 1
                continue
            }
            do {
                let parsed = try EPUBParser.parse(url: url)
                let titles = parsed.chapters.map(\.fullTitle)
                print("--- \(exp.fixture) ---")
                for (i, ch) in parsed.chapters.enumerated() {
                    print("  [\(i + 1)] \(ch.fullTitle) | \(ch.plainText.count)字 | parent=\(ch.parentPath)")
                }
                if parsed.chapters.count < exp.minChapters {
                    print("FAIL \(exp.fixture): chapters \(parsed.chapters.count) < \(exp.minChapters)")
                    failures += 1
                }
                for need in exp.requiredTitles where !titles.contains(need) {
                    print("FAIL \(exp.fixture): missing title 「\(need)」")
                    failures += 1
                }
                for ban in exp.forbiddenTitles where titles.contains(ban) {
                    print("FAIL \(exp.fixture): forbidden title 「\(ban)」 present")
                    failures += 1
                }
                if failures == 0 { print("OK \(exp.fixture)") }
            } catch {
                print("FAIL \(exp.fixture): \(error)")
                failures += 1
            }
        }
        if failures == 0 {
            print("ALL PASS")
            return 0
        }
        print("FAILED count=\(failures)")
        return 1
    }
}
