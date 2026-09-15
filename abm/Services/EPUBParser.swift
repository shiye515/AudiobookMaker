//
//  EPUBParser.swift
//  abm
//
//  EPUB 解析：容器读取（ZIPFoundation 垫片）+ XMLParser 委托式解析。
//  目录树形解析（nav toc / ncx）→ 叶子切分计划 → 正文锚点增量偏移切分。
//

import Foundation
import ImageIO
import ZIPFoundation

// MARK: - 容器读取垫片

struct ZipSecurityLimits: Sendable {
    var maximumEntryCount = 10_000
    var maximumSingleEntrySize: UInt64 = 128 * 1_024 * 1_024
    var maximumTotalUncompressedSize: UInt64 = 1_024 * 1_024 * 1_024

    static let epub = ZipSecurityLimits()
}

enum ZipContainerError: LocalizedError {
    case invalidArchive
    case tooManyEntries(Int)
    case entryTooLarge(String)
    case archiveTooLarge

    var errorDescription: String? {
        switch self {
        case .invalidArchive: return "ZIP 归档结构无效。"
        case .tooManyEntries(let n): return "ZIP 文件数量超过安全限制（\(n)）。"
        case .entryTooLarge(let p): return "ZIP 条目超过单文件安全限制：\(p)"
        case .archiveTooLarge: return "ZIP 展开后的总大小超过安全限制。"
        }
    }
}

struct ZipContainerReader: Sendable {
    let archive: Archive
    private let entriesByName: [String: Entry]
    private let limits: ZipSecurityLimits

    init(url: URL, limits: ZipSecurityLimits = .epub) throws {
        guard let archive = Archive(url: url, accessMode: .read) else {
            throw ZipContainerError.invalidArchive
        }
        self.archive = archive
        self.limits = limits

        var byName: [String: Entry] = [:]
        var total: UInt64 = 0
        var count = 0
        for entry in archive {
            count += 1
            if count > limits.maximumEntryCount { throw ZipContainerError.tooManyEntries(count) }
            if entry.uncompressedSize > limits.maximumSingleEntrySize {
                throw ZipContainerError.entryTooLarge(entry.path)
            }
            total += entry.uncompressedSize
            if total > limits.maximumTotalUncompressedSize { throw ZipContainerError.archiveTooLarge }
            byName[Self.normalized(entry.path)] = entry
        }
        entriesByName = byName
    }

    static func normalized(_ path: String) -> String {
        var parts: [String] = []
        for component in path.split(separator: "/") where component != "." {
            if component == ".." {
                if !parts.isEmpty { parts.removeLast() }
            } else {
                parts.append(String(component))
            }
        }
        return parts.joined(separator: "/")
    }

    func contains(_ path: String) -> Bool {
        entriesByName[Self.normalized(path)] != nil
    }

    func data(for path: String) throws -> Data {
        guard let entry = entriesByName[Self.normalized(path)] else {
            throw CocoaError(.fileNoSuchFile)
        }
        var data = Data()
        _ = try archive.extract(entry, bufferSize: 1 << 20) { chunk in
            data.append(chunk)
        }
        return data
    }
}

// MARK: - 解析结果

struct ParsedEPUBChapter: Sendable {
    let index: Int
    let title: String          // 叶子标题
    let parentPath: [String]   // 祖先链（根在前）
    let plainText: String

    var fullTitle: String { (parentPath + [title]).joined(separator: " · ") }
}

struct ParsedEPUB: Sendable {
    let title: String
    let author: String
    let chapters: [ParsedEPUBChapter]
    let coverData: Data?
    let coverFileExtension: String?
}

// MARK: - 目录节点（href 已解析为包内路径）

struct TOCNode {
    var title: String
    var path: String
    var fragment: String?
    var children: [TOCNode] = []
}

private struct TOCEntry {
    let path: String
    let fragment: String?
    let title: String
    let parentPath: [String]
    let isLeaf: Bool
}

// MARK: - 解析器

enum EPUBParserError: LocalizedError {
    case invalidMimetype
    case encryptedContent
    case missingContainer
    case missingPackageDocument
    case invalidPackageDocument
    case noReadableChapters

    var errorDescription: String? {
        switch self {
        case .invalidMimetype: return "文件不是有效的 EPUB。"
        case .encryptedContent: return "暂不支持带 DRM 或加密内容的 EPUB。"
        case .missingContainer: return "EPUB 缺少 META-INF/container.xml。"
        case .missingPackageDocument: return "EPUB 未声明 OPF 包文档。"
        case .invalidPackageDocument: return "EPUB 的 OPF 元数据或阅读顺序无效。"
        case .noReadableChapters: return "EPUB 中没有可朗读的正文。"
        }
    }
}

enum EPUBParser {
    static func parse(url: URL) throws -> ParsedEPUB {
        let archive = try ZipContainerReader(url: url, limits: .epub)

        if archive.contains("mimetype") {
            let mimetype = try String(decoding: archive.data(for: "mimetype"), as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard mimetype == "application/epub+zip" else { throw EPUBParserError.invalidMimetype }
        }
        if archive.contains("META-INF/encryption.xml") {
            throw EPUBParserError.encryptedContent
        }
        guard archive.contains("META-INF/container.xml") else {
            throw EPUBParserError.missingContainer
        }
        let containerDelegate = ContainerXMLDelegate()
        try parseXML(archive.data(for: "META-INF/container.xml"), delegate: containerDelegate)
        guard let packagePath = containerDelegate.packagePath,
              archive.contains(packagePath)
        else { throw EPUBParserError.missingPackageDocument }

        let packageDelegate = PackageDocumentDelegate()
        try parseXML(archive.data(for: packagePath), delegate: packageDelegate)
        guard !packageDelegate.spine.isEmpty else { throw EPUBParserError.invalidPackageDocument }
        if ProcessInfo.processInfo.environment["ABM_EPUB_DEBUG"] == "1" {
            print("[epub-debug] package=\(packagePath) title=\(packageDelegate.title ?? "nil") spine=\(packageDelegate.spine) manifest=\(packageDelegate.manifest.keys.sorted())")
        }

        let toc = navigationTree(
            archive: archive, packagePath: packagePath, manifest: packageDelegate.manifest)
        let entries = collectEntries(from: toc)
        var entriesByPath: [String: [TOCEntry]] = [:]
        for entry in entries {
            entriesByPath[entry.path, default: []].append(entry)
        }

        var chapters: [ParsedEPUBChapter] = []
        for idref in packageDelegate.spine {
            guard let item = packageDelegate.manifest[idref], item.isHTML else { continue }
            guard let itemPath = resolvedArchivePath(item.href, relativeTo: packagePath),
                  archive.contains(itemPath),
                  let data = try? archive.data(for: itemPath)
            else { continue }

            let textDelegate = XHTMLTextDelegate()
            guard (try? parseXML(data, delegate: textDelegate)) != nil else { continue }

            let anchors = textDelegate.anchorOffsets
            let docEntries = entriesByPath[itemPath] ?? []
            let text = normalizeText(textDelegate.rawBody)

            // 仅当叶子锚点解析出 ≥2 个不同偏移时才按锚点切分；
            // Calibre 书大量「同文件无 fragment / #calibre_pb_*」条目无法可靠切开。
            var cuts: [(entry: TOCEntry, offset: Int)] = []
            var seenOffsets = Set<Int>()
            let leafOffsets: [(TOCEntry, Int)] = docEntries.compactMap { entry in
                guard entry.isLeaf, let frag = entry.fragment, let off = anchors[frag] else { return nil }
                return (entry, off)
            }.sorted { $0.1 < $1.1 }
            for (entry, off) in leafOffsets where seenOffsets.insert(off).inserted {
                cuts.append((entry, off))
            }

            if cuts.count >= 2 {
                let rawChars = Array(textDelegate.rawBody)
                for (i, cut) in cuts.enumerated() {
                    let from = cut.offset
                    let to = i + 1 < cuts.count ? cuts[i + 1].offset : rawChars.count
                    guard from < to else { continue }
                    let slice = normalizeText(String(rawChars[from..<to]))
                    guard !slice.isEmpty else { continue }
                    chapters.append(ParsedEPUBChapter(
                        index: chapters.count,
                        title: cut.entry.title,
                        parentPath: cut.entry.parentPath,
                        plainText: slice))
                }
                continue
            }

            // 整文档单章：NCX src 可能与正文错位（Calibre 常见）。
            // 仅当 TOC 标题与文档首行/独立行一致时才信任 TOC，否则信正文首行。
            guard !text.isEmpty else { continue }
            let heading = extractDocumentHeading(from: text, bookTitle: packageDelegate.title)
            var resolvedTitle = heading ?? textDelegate.documentTitle ?? "第 \(chapters.count + 1) 章"
            var resolvedParent: [String] = []

            if let heading {
                if let exact = docEntries.first(where: { $0.title == heading }) {
                    resolvedTitle = exact.title
                    resolvedParent = exact.parentPath
                } else if let lineMatch = docEntries.first(where: { entry in
                    titleAppearsAsLine(entry.title, in: text)
                }) {
                    resolvedTitle = lineMatch.title
                    resolvedParent = lineMatch.parentPath
                } else if docEntries.isEmpty {
                    // 无目录指向：<title> 常与全书同名，不能当章名
                    if let docTitle = textDelegate.documentTitle,
                       docTitle != packageDelegate.title,
                       !docTitle.isEmpty {
                        resolvedTitle = docTitle
                    } else {
                        resolvedTitle = heading
                    }
                    // NCX src 错位时仍按同名条目借层级链
                    resolvedParent = entries.first(where: { $0.title == resolvedTitle })?.parentPath ?? []
                } else {
                    // 有目录但与正文对不上 → 信正文；同名条目借层级
                    resolvedTitle = heading
                    resolvedParent = entries.first(where: { $0.title == heading })?.parentPath ?? []
                }
            } else if let best = shallowestEntry(docEntries) {
                resolvedTitle = best.title
                resolvedParent = best.parentPath
            }

            if isTableOfContentsPage(title: resolvedTitle, body: text) { continue }

            chapters.append(ParsedEPUBChapter(
                index: chapters.count,
                title: resolvedTitle,
                parentPath: resolvedParent,
                plainText: text))
        }
        guard !chapters.isEmpty else { throw EPUBParserError.noReadableChapters }

        var coverData: Data?
        var coverExtension: String?
        if let coverItem = packageDelegate.coverItem,
           let coverPath = resolvedArchivePath(coverItem.href, relativeTo: packagePath),
           archive.contains(coverPath),
           let candidate = try? archive.data(for: coverPath),
           CGImageSourceCreateWithData(candidate as CFData, nil) != nil {
            coverData = candidate
            coverExtension = URL(fileURLWithPath: coverPath).pathExtension.lowercased()
        }

        return ParsedEPUB(
            title: packageDelegate.title ?? url.deletingPathExtension().lastPathComponent,
            author: packageDelegate.author ?? "未知作者",
            chapters: chapters,
            coverData: coverData,
            coverFileExtension: coverExtension)
    }

    // MARK: - 内部

    /// nav 树非空则整棵采用，否则 ncx；禁止条目级混写。
    private static func navigationTree(
        archive: ZipContainerReader,
        packagePath: String,
        manifest: [String: PackageDocumentDelegate.ManifestItem]
    ) -> [TOCNode] {
        if let navItem = manifest.values.first(where: { $0.properties.contains("nav") }),
           let navPath = resolvedArchivePath(navItem.href, relativeTo: packagePath),
           archive.contains(navPath),
           let data = try? archive.data(for: navPath) {
            let delegate = NavigationDocumentDelegate()
            if (try? parseXML(data, delegate: delegate)) != nil {
                let resolved = resolveTree(delegate.rawRoots, baseURL: navPath)
                if !resolved.isEmpty { return resolved }
            }
        }

        if let ncxItem = manifest.values.first(where: { $0.mediaType == "application/x-dtbncx+xml" }),
           let ncxPath = resolvedArchivePath(ncxItem.href, relativeTo: packagePath),
           archive.contains(ncxPath),
           let data = try? archive.data(for: ncxPath) {
            let delegate = NavigationDocumentDelegate()
            if (try? parseXML(data, delegate: delegate)) != nil {
                let resolved = resolveTree(delegate.rawRoots, baseURL: ncxPath)
                if !resolved.isEmpty { return resolved }
            }
        }
        return []
    }

    /// 把原始 href（相对 nav/ncx 文件）解析为包内 path + fragment。
    private static func resolveTree(_ nodes: [RawTOCNode], baseURL: String) -> [TOCNode] {
        var result: [TOCNode] = []
        for node in nodes {
            guard let pair = resolvedArchivePathAndFragment(node.href, relativeTo: baseURL) else { continue }
            result.append(TOCNode(
                title: node.title,
                path: pair.path,
                fragment: pair.fragment,
                children: resolveTree(node.children, baseURL: baseURL)))
        }
        return result
    }

    /// 收集全部目录条目（含中间节点）。中间节点指向独立文档时仍参与整文档标题回退。
    private static func collectEntries(from nodes: [TOCNode]) -> [TOCEntry] {
        var entries: [TOCEntry] = []
        func walk(_ nodes: [TOCNode], parents: [String]) {
            for node in nodes {
                let isLeaf = node.children.isEmpty
                entries.append(TOCEntry(
                    path: node.path,
                    fragment: node.fragment,
                    title: node.title,
                    parentPath: parents,
                    isLeaf: isLeaf))
                if !isLeaf {
                    walk(node.children, parents: parents + [node.title])
                }
            }
        }
        walk(nodes, parents: [])
        return entries
    }

    private static func shallowestEntry(_ entries: [TOCEntry]) -> TOCEntry? {
        var best: TOCEntry?
        for entry in entries {
            if best == nil || entry.parentPath.count < best!.parentPath.count {
                best = entry
            }
        }
        return best
    }

    /// 从正文抽取文档自带头标题：跳过与全书同名的行、目录/封面页。
    private static func extractDocumentHeading(from normalizedBody: String, bookTitle: String?) -> String? {
        for rawLine in normalizedBody.split(separator: "\n", omittingEmptySubsequences: true) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard line.count >= 1, line.count <= 48 else { continue }
            if let bookTitle, line == bookTitle { continue }
            if isTableOfContentsPage(title: line, body: "") { continue }
            if line == "Cover" || line == "封面" { continue }
            return line
        }
        return nil
    }

    private static func isTableOfContentsPage(title: String, body: String) -> Bool {
        let t = title.trimmingCharacters(in: .whitespaces)
        if t == "Table of Contents" || t == "目录" || t == "Contents" { return true }
        // 大量短行且几乎无长段 → 目录页
        let lines = body.split(separator: "\n", omittingEmptySubsequences: true)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        if lines.count >= 12, lines.allSatisfy({ $0.count <= 36 }) { return true }
        return false
    }

    /// 标题是否作为独立行出现在正文前部（避免「一」等短词被子串误匹配）。
    private static func titleAppearsAsLine(_ title: String, in text: String) -> Bool {
        let head = String(text.prefix(1200))
        return head.split(separator: "\n", omittingEmptySubsequences: true).contains {
            $0.trimmingCharacters(in: .whitespaces) == title
        }
    }

    private static func parseXML(_ data: Data, delegate: XMLParserDelegate) throws {
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        parser.shouldProcessNamespaces = true
        guard parser.parse() else {
            if ProcessInfo.processInfo.environment["ABM_EPUB_DEBUG"] == "1" {
                print("[epub-debug] XMLParser error=\(parser.parserError?.localizedDescription ?? "nil") line=\(parser.lineNumber) col=\(parser.columnNumber) bytes=\(data.count) head=\(String(data: data.prefix(80), encoding: .utf8) ?? "nil")")
            }
            throw EPUBParserError.invalidPackageDocument
        }
    }

    /// 解析 href → (归档路径, fragment?)。
    static func resolvedArchivePathAndFragment(
        _ reference: String, relativeTo baseFile: String?
    ) -> (path: String, fragment: String?)? {
        let parts = reference.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)
        let hrefPart = parts.first.map(String.init) ?? reference
        let fragment = parts.count > 1 ? String(parts[1]) : nil

        // 纯 fragment（#s1）：相对当前文档
        if hrefPart.isEmpty {
            guard let base = baseFile, !base.isEmpty else { return nil }
            let frag = fragment ?? String(reference.drop(while: { $0 == "#" }))
            return (base, frag.isEmpty ? nil : frag)
        }

        let decoded = (hrefPart.removingPercentEncoding ?? hrefPart)
            .replacingOccurrences(of: "\\", with: "/")
        guard !decoded.hasPrefix("/") else { return nil }
        var components = baseFile.map { Array($0.split(separator: "/").dropLast()).map(String.init) } ?? []
        for component in decoded.split(separator: "/", omittingEmptySubsequences: true) {
            switch component {
            case ".": continue
            case "..":
                guard !components.isEmpty else { return nil }
                components.removeLast()
            default:
                let value = String(component)
                guard !value.contains(":") else { return nil }
                components.append(value)
            }
        }
        guard !components.isEmpty else { return nil }
        return (components.joined(separator: "/"), fragment?.isEmpty == true ? nil : fragment)
    }

    /// 解析 href 相对基准文档目录的归档路径。
    static func resolvedArchivePath(_ reference: String, relativeTo baseFile: String?) -> String? {
        resolvedArchivePathAndFragment(reference, relativeTo: baseFile)?.path
    }

    /// 区间独立规范化（与原 normalizedText 同一正则链）。
    static func normalizeText(_ text: String) -> String {
        text
            .replacingOccurrences(of: "[ \\t]+", with: " ", options: .regularExpression)
            .replacingOccurrences(of: " *\\n *", with: "\n", options: .regularExpression)
            .replacingOccurrences(of: "\n{3,}", with: "\n\n", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// MARK: - XML 委托

private func epubLocalName(_ elementName: String, _ qualifiedName: String?) -> String {
    let candidate = qualifiedName ?? elementName
    return candidate.split(separator: ":").last.map(String.init)?.lowercased() ?? candidate.lowercased()
}

private extension String {
    var trimmedNonEmpty: String? {
        let value = trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }
}

private final class ContainerXMLDelegate: NSObject, XMLParserDelegate {
    var packagePath: String?

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
        if epubLocalName(elementName, qName) == "rootfile", packagePath == nil {
            packagePath = attributeDict["full-path"]
        }
    }
}

private final class PackageDocumentDelegate: NSObject, XMLParserDelegate {
    struct ManifestItem {
        let id: String
        let href: String
        let mediaType: String
        let properties: Set<String>

        var isHTML: Bool {
            mediaType == "application/xhtml+xml"
                || href.lowercased().hasSuffix(".html")
                || href.lowercased().hasSuffix(".xhtml")
        }
    }

    var title: String?
    var author: String?
    var manifest: [String: ManifestItem] = [:]
    var spine: [String] = []
    private var coverID: String?
    private var textTarget: String?
    private var textBuffer = ""

    var coverItem: ManifestItem? {
        manifest.values.first(where: { $0.properties.contains("cover-image") })
            ?? coverID.flatMap { manifest[$0] }
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
        let name = epubLocalName(elementName, qName)
        if ["title", "creator", "language", "date"].contains(name) {
            textTarget = name
            textBuffer = ""
        } else if name == "item", let id = attributeDict["id"], let href = attributeDict["href"] {
            manifest[id] = ManifestItem(
                id: id, href: href,
                mediaType: attributeDict["media-type"] ?? "",
                properties: Set((attributeDict["properties"] ?? "").split(separator: " ").map(String.init)))
        } else if name == "itemref", let idref = attributeDict["idref"] {
            spine.append(idref)
        } else if name == "meta", attributeDict["name"]?.lowercased() == "cover" {
            coverID = attributeDict["content"]
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if textTarget != nil { textBuffer += string }
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?,
                qualifiedName qName: String?) {
        let name = epubLocalName(elementName, qName)
        guard name == textTarget else { return }
        let value = textBuffer.trimmingCharacters(in: .whitespacesAndNewlines)
        if name == "title", title == nil { title = value }
        if name == "creator", author == nil { author = value }
        textTarget = nil
    }
}

private final class XHTMLTextDelegate: NSObject, XMLParserDelegate {
    private var buffer = ""
    private var characterCount = 0
    private var titleBuffer = ""
    private var ignoredDepth = 0
    private var ignoredElementStack: [Bool] = []
    private var inTitle = false
    private var inBody = false

    /// id → 正文字符偏移（首次出现；增量计数，禁止 buffer.count）
    private(set) var anchorOffsets: [String: Int] = [:]

    var documentTitle: String? { titleBuffer.trimmedNonEmpty }
    var rawBody: String { buffer }

    private func appendToBuffer(_ s: String) {
        buffer += s
        characterCount += s.count
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
        let name = epubLocalName(elementName, qName)
        let style = attributeDict["style"]?.lowercased() ?? ""
        let isHidden = attributeDict["hidden"] != nil
            || attributeDict["aria-hidden"]?.lowercased() == "true"
            || style.contains("display:none") || style.contains("display: none")
            || style.contains("visibility:hidden") || style.contains("visibility: hidden")
        let beginsIgnoring = ["script", "style", "svg"].contains(name) || isHidden
        ignoredElementStack.append(beginsIgnoring)
        if beginsIgnoring { ignoredDepth += 1 }
        if name == "title" { inTitle = true }
        if name == "body" { inBody = true }
        if ignoredDepth == 0, Self.blockElements.contains(name), !buffer.isEmpty, !buffer.hasSuffix("\n") {
            appendToBuffer("\n")
        }
        if let id = attributeDict["id"], !id.isEmpty,
           ignoredDepth == 0, inBody,
           anchorOffsets[id] == nil {
            anchorOffsets[id] = characterCount
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if inTitle { titleBuffer += string }
        if ignoredDepth == 0, inBody { appendToBuffer(string) }
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?,
                qualifiedName qName: String?) {
        let name = epubLocalName(elementName, qName)
        if ignoredDepth == 0, Self.blockElements.contains(name), name != "br", !buffer.hasSuffix("\n") {
            appendToBuffer("\n")
        }
        if ignoredElementStack.popLast() == true, ignoredDepth > 0 { ignoredDepth -= 1 }
        if name == "title" { inTitle = false }
        if name == "body" { inBody = false }
    }

    private static let blockElements: Set<String> = [
        "p", "div", "section", "article", "h1", "h2", "h3", "h4", "h5", "h6", "li", "br"
    ]
}

/// 未解析 href 的原始目录树
struct RawTOCNode {
    var title: String
    var href: String
    var children: [RawTOCNode] = []
}

/// nav（仅 epub:type="toc"）与 ncx 的树形解析。
private final class NavigationDocumentDelegate: NSObject, XMLParserDelegate {
    private(set) var rawRoots: [RawTOCNode] = []

    private enum Mode {
        case idle
        case nav
        case ncx
    }
    private var mode: Mode = .idle

    // nav
    private var tocNavDepth = 0
    private var navStack: [[RawTOCNode]] = []
    private var linkHref: String?
    private var linkText = ""
    private var inLink = false

    // ncx
    private var ncxStack: [[RawTOCNode]] = []
    private var ncxMetaStack: [(title: String, href: String)] = []
    private var ncxText = ""
    private var inNCXText = false

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
        let name = epubLocalName(elementName, qName)

        if name == "nav" {
            mode = .nav
            let type = attributeDict["epub:type"] ?? attributeDict["type"]
            if type == "toc" { tocNavDepth += 1 }
            return
        }
        if name == "ncx" {
            mode = .ncx
            return
        }

        switch mode {
        case .nav:
            if tocNavDepth > 0, name == "ol" || name == "ul" {
                navStack.append([])
            } else if tocNavDepth > 0, name == "a", let href = attributeDict["href"] {
                inLink = true
                linkHref = href
                linkText = ""
            }
        case .ncx:
            if name == "navpoint" {
                ncxStack.append([])
                ncxMetaStack.append((title: "", href: ""))
                ncxText = ""
            } else if name == "content", !ncxMetaStack.isEmpty, let src = attributeDict["src"] {
                ncxMetaStack[ncxMetaStack.count - 1].href = src
            } else if name == "text", !ncxMetaStack.isEmpty {
                inNCXText = true
                ncxText = ""
            }
        case .idle:
            break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if inLink { linkText += string }
        if inNCXText { ncxText += string }
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?,
                qualifiedName qName: String?) {
        let name = epubLocalName(elementName, qName)

        switch mode {
        case .nav:
            if name == "a", inLink {
                if let href = linkHref, let title = linkText.trimmedNonEmpty, !navStack.isEmpty {
                    navStack[navStack.count - 1].append(RawTOCNode(title: title, href: href))
                }
                inLink = false
                linkHref = nil
            } else if name == "ol" || name == "ul" {
                guard tocNavDepth > 0, !navStack.isEmpty else { return }
                let children = navStack.removeLast()
                attachNav(children)
            } else if name == "nav" {
                if tocNavDepth > 0 { tocNavDepth -= 1 }
                if tocNavDepth == 0 { mode = .idle }
            }
        case .ncx:
            if name == "text" {
                inNCXText = false
                if !ncxMetaStack.isEmpty {
                    ncxMetaStack[ncxMetaStack.count - 1].title = ncxText.trimmedNonEmpty ?? ""
                }
            } else if name == "navpoint" {
                let children = ncxStack.isEmpty ? [] : ncxStack.removeLast()
                let meta = ncxMetaStack.isEmpty ? (title: "", href: "") : ncxMetaStack.removeLast()
                let node = RawTOCNode(
                    title: meta.title.trimmedNonEmpty ?? "（未命名）",
                    href: meta.href,
                    children: children)
                if ncxStack.isEmpty {
                    rawRoots.append(node)
                } else {
                    ncxStack[ncxStack.count - 1].append(node)
                }
            } else if name == "ncx" {
                mode = .idle
            }
        case .idle:
            if name == "nav" { /* nested nav without toc */ }
            break
        }
    }

    /// 把结束的 ol/ul 子节点挂到父列表最后一个 li 节点上。
    private func attachNav(_ children: [RawTOCNode]) {
        if navStack.isEmpty {
            rawRoots.append(contentsOf: children)
            return
        }
        if !navStack[navStack.count - 1].isEmpty {
            navStack[navStack.count - 1][navStack[navStack.count - 1].count - 1].children.append(contentsOf: children)
        } else {
            navStack[navStack.count - 1].append(contentsOf: children)
        }
    }
}
