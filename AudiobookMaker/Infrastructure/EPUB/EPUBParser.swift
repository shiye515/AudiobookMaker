import Foundation
import ImageIO

nonisolated struct ParsedEPUB: Sendable, Equatable {
    let title: String
    let author: String?
    let language: String?
    let chapters: [ParsedEPUBChapter]
    let coverData: Data?
    let coverExtension: String?
}

nonisolated struct ParsedEPUBChapter: Sendable, Equatable {
    let index: Int
    let title: String
    let sourceHref: String
    let plainText: String
}

nonisolated enum EPUBParserError: LocalizedError, Equatable {
    case invalidMimetype
    case unsafeArchive(String)
    case missingContainer
    case missingPackageDocument
    case invalidPackageDocument
    case encryptedContent
    case noReadableChapters

    var errorDescription: String? {
        switch self {
        case .invalidMimetype: "文件不是有效的 EPUB。"
        case .unsafeArchive(let message): "EPUB 安全校验失败：\(message)"
        case .missingContainer: "EPUB 缺少 META-INF/container.xml。"
        case .missingPackageDocument: "EPUB 未声明 OPF 包文档。"
        case .invalidPackageDocument: "EPUB 的 OPF 元数据或阅读顺序无效。"
        case .encryptedContent: "暂不支持带 DRM 或加密内容的 EPUB。"
        case .noReadableChapters: "EPUB 中没有可朗读的正文。"
        }
    }
}

nonisolated struct EPUBParser: Sendable {
    let limits: ZipSecurityLimits

    init(limits: ZipSecurityLimits = .epub) {
        self.limits = limits
    }

    func parse(url: URL) throws -> ParsedEPUB {
        let archive: ZipContainerReader
        do {
            archive = try ZipContainerReader(url: url, limits: limits)
        } catch let error as ZipContainerError {
            throw EPUBParserError.unsafeArchive(error.localizedDescription)
        }

        if archive.contains("mimetype") {
            let mimetype = try String(decoding: archive.data(for: "mimetype"), as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard mimetype == "application/epub+zip" else {
                throw EPUBParserError.invalidMimetype
            }
        }
        if archive.contains("META-INF/encryption.xml") {
            throw EPUBParserError.encryptedContent
        }

        guard archive.contains("META-INF/container.xml") else {
            throw EPUBParserError.missingContainer
        }
        let containerDelegate = ContainerXMLDelegate()
        try parseXML(archive.data(for: "META-INF/container.xml"), delegate: containerDelegate)
        guard let packagePath = containerDelegate.packagePath else {
            throw EPUBParserError.missingPackageDocument
        }
        let normalizedPackagePath = try resolvedArchivePath(
            packagePath,
            relativeTo: nil
        )
        guard archive.contains(normalizedPackagePath) else {
            throw EPUBParserError.missingPackageDocument
        }

        let packageDelegate = PackageDocumentDelegate()
        try parseXML(archive.data(for: normalizedPackagePath), delegate: packageDelegate)
        guard !packageDelegate.spine.isEmpty else {
            throw EPUBParserError.invalidPackageDocument
        }

        let navigationTitles = navigationTitleMap(
            archive: archive,
            packagePath: normalizedPackagePath,
            manifest: packageDelegate.manifest
        )
        var chapters: [ParsedEPUBChapter] = []
        for idref in packageDelegate.spine {
            guard let item = packageDelegate.manifest[idref], item.isHTML else { continue }
            let itemPath = try resolvedArchivePath(item.href, relativeTo: normalizedPackagePath)
            guard archive.contains(itemPath),
                  let data = try? archive.data(for: itemPath)
            else { continue }

            let textDelegate = XHTMLTextDelegate()
            guard (try? parseXML(data, delegate: textDelegate)) != nil else { continue }
            let text = textDelegate.normalizedText.precomposedStringWithCanonicalMapping
            guard !text.isEmpty else { continue }
            let title = navigationTitles[itemPath]?.trimmedNonEmpty
                ?? textDelegate.documentTitle?.trimmedNonEmpty
                ?? "第 \(chapters.count + 1) 章"
            chapters.append(
                ParsedEPUBChapter(
                    index: chapters.count,
                    title: title,
                    sourceHref: item.href,
                    plainText: text
                )
            )
        }
        guard !chapters.isEmpty else { throw EPUBParserError.noReadableChapters }

        var coverData: Data?
        var coverExtension: String?
        if let coverItem = packageDelegate.coverItem,
           let coverPath = try? resolvedArchivePath(coverItem.href, relativeTo: normalizedPackagePath),
           archive.contains(coverPath),
           let candidate = try? archive.data(for: coverPath),
           CGImageSourceCreateWithData(candidate as CFData, nil) != nil {
            coverData = candidate
            coverExtension = URL(filePath: coverPath).pathExtension.lowercased().trimmedNonEmpty
        }

        return ParsedEPUB(
            title: packageDelegate.title?.trimmedNonEmpty
                ?? url.deletingPathExtension().lastPathComponent,
            author: packageDelegate.author?.trimmedNonEmpty,
            language: packageDelegate.language?.trimmedNonEmpty,
            chapters: chapters,
            coverData: coverData,
            coverExtension: coverExtension
        )
    }

    private func navigationTitleMap(
        archive: ZipContainerReader,
        packagePath: String,
        manifest: [String: PackageDocumentDelegate.ManifestItem]
    ) -> [String: String] {
        let candidates = manifest.values.filter {
            $0.properties.contains("nav") || $0.mediaType == "application/x-dtbncx+xml"
        }
        var result: [String: String] = [:]
        for item in candidates {
            guard let navigationPath = try? resolvedArchivePath(item.href, relativeTo: packagePath),
                  archive.contains(navigationPath),
                  let data = try? archive.data(for: navigationPath)
            else { continue }
            let delegate = NavigationDocumentDelegate()
            guard (try? parseXML(data, delegate: delegate)) != nil else { continue }
            for (reference, title) in delegate.titles {
                guard let path = try? resolvedArchivePath(reference, relativeTo: navigationPath),
                      let normalizedTitle = title.trimmedNonEmpty
                else { continue }
                result[path] = normalizedTitle
            }
        }
        return result
    }

    private func parseXML(_ data: Data, delegate: XMLParserDelegate) throws {
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        parser.shouldProcessNamespaces = true
        guard parser.parse() else {
            throw parser.parserError ?? EPUBParserError.invalidPackageDocument
        }
    }

    /// Resolves an EPUB href relative to the directory containing `baseFile`.
    /// Parent components are allowed only while they remain inside the archive.
    private func resolvedArchivePath(_ reference: String, relativeTo baseFile: String?) throws -> String {
        let withoutFragment = reference.split(separator: "#", maxSplits: 1).first.map(String.init) ?? reference
        let decoded = (withoutFragment.removingPercentEncoding ?? withoutFragment)
            .replacingOccurrences(of: "\\", with: "/")
        guard !decoded.hasPrefix("/") else {
            throw EPUBParserError.unsafeArchive(reference)
        }
        var components = baseFile.map {
            Array($0.split(separator: "/").dropLast()).map(String.init)
        } ?? []
        for component in decoded.split(separator: "/", omittingEmptySubsequences: true) {
            switch component {
            case ".": continue
            case "..":
                guard !components.isEmpty else { throw EPUBParserError.unsafeArchive(reference) }
                components.removeLast()
            default:
                let value = String(component)
                guard !value.contains(":"),
                      !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
                else { throw EPUBParserError.unsafeArchive(reference) }
                components.append(value)
            }
        }
        guard !components.isEmpty else { throw EPUBParserError.unsafeArchive(reference) }
        return components.joined(separator: "/")
    }
}

nonisolated private extension String {
    var trimmedNonEmpty: String? {
        let value = trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }
}

nonisolated private final class ContainerXMLDelegate: NSObject, XMLParserDelegate {
    var packagePath: String?

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        if epubLocalName(elementName, qName) == "rootfile", packagePath == nil {
            packagePath = attributeDict["full-path"]
        }
    }
}

nonisolated private final class PackageDocumentDelegate: NSObject, XMLParserDelegate {
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
    var language: String?
    var manifest: [String: ManifestItem] = [:]
    var spine: [String] = []
    private var coverID: String?
    private var textTarget: String?
    private var textBuffer = ""

    var coverItem: ManifestItem? {
        manifest.values.first(where: { $0.properties.contains("cover-image") })
            ?? coverID.flatMap { manifest[$0] }
    }

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        let name = epubLocalName(elementName, qName)
        if ["title", "creator", "language"].contains(name) {
            textTarget = name
            textBuffer = ""
        } else if name == "item", let id = attributeDict["id"], let href = attributeDict["href"] {
            manifest[id] = ManifestItem(
                id: id,
                href: href,
                mediaType: attributeDict["media-type"] ?? "",
                properties: Set((attributeDict["properties"] ?? "").split(separator: " ").map(String.init))
            )
        } else if name == "itemref", let idref = attributeDict["idref"] {
            spine.append(idref)
        } else if name == "meta", attributeDict["name"]?.lowercased() == "cover" {
            coverID = attributeDict["content"]
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if textTarget != nil { textBuffer += string }
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?
    ) {
        let name = epubLocalName(elementName, qName)
        guard name == textTarget else { return }
        let value = textBuffer.trimmingCharacters(in: .whitespacesAndNewlines)
        if name == "title", title == nil { title = value }
        if name == "creator", author == nil { author = value }
        if name == "language", language == nil { language = value }
        textTarget = nil
    }
}

nonisolated private final class XHTMLTextDelegate: NSObject, XMLParserDelegate {
    private var buffer = ""
    private var titleBuffer = ""
    private var ignoredDepth = 0
    private var ignoredElementStack: [Bool] = []
    private var inTitle = false
    private var inBody = false

    var documentTitle: String? { titleBuffer.trimmedNonEmpty }
    var normalizedText: String {
        buffer
            .replacingOccurrences(of: "[ \\t]+", with: " ", options: .regularExpression)
            .replacingOccurrences(of: " *\\n *", with: "\n", options: .regularExpression)
            .replacingOccurrences(of: "\n{3,}", with: "\n\n", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        let name = epubLocalName(elementName, qName)
        let style = attributeDict["style"]?.lowercased() ?? ""
        let isHidden = attributeDict["hidden"] != nil
            || attributeDict["aria-hidden"]?.lowercased() == "true"
            || style.contains("display:none")
            || style.contains("display: none")
            || style.contains("visibility:hidden")
            || style.contains("visibility: hidden")
        let beginsIgnoring = ["script", "style", "svg"].contains(name) || isHidden
        ignoredElementStack.append(beginsIgnoring)
        if beginsIgnoring { ignoredDepth += 1 }
        if name == "title" { inTitle = true }
        if name == "body" { inBody = true }
        if ignoredDepth == 0, Self.blockElements.contains(name) { appendBreak() }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if inTitle { titleBuffer += string }
        if ignoredDepth == 0, inBody { buffer += string }
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?
    ) {
        let name = epubLocalName(elementName, qName)
        if ignoredDepth == 0, Self.blockElements.contains(name), name != "br" { appendBreak() }
        if ignoredElementStack.popLast() == true, ignoredDepth > 0 { ignoredDepth -= 1 }
        if name == "title" { inTitle = false }
        if name == "body" { inBody = false }
    }

    private static let blockElements: Set<String> = [
        "p", "div", "section", "article", "h1", "h2", "h3", "h4", "h5", "h6", "li", "br"
    ]

    private func appendBreak() {
        if !buffer.hasSuffix("\n") { buffer += "\n" }
    }
}

nonisolated private final class NavigationDocumentDelegate: NSObject, XMLParserDelegate {
    var titles: [String: String] = [:]
    private var linkReference: String?
    private var linkText = ""
    private var ncxText = ""
    private var ncxReference: String?
    private var inNCXText = false

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        let name = epubLocalName(elementName, qName)
        if name == "a", let href = attributeDict["href"] {
            linkReference = href
            linkText = ""
        } else if name == "content", let source = attributeDict["src"] {
            ncxReference = source
        } else if name == "text" {
            inNCXText = true
            ncxText = ""
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if linkReference != nil { linkText += string }
        if inNCXText { ncxText += string }
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?
    ) {
        let name = epubLocalName(elementName, qName)
        if name == "a", let reference = linkReference {
            if let title = linkText.trimmedNonEmpty { titles[reference] = title }
            linkReference = nil
        } else if name == "text" {
            inNCXText = false
        } else if name == "navpoint", let reference = ncxReference {
            if let title = ncxText.trimmedNonEmpty { titles[reference] = title }
            ncxReference = nil
            ncxText = ""
        }
    }
}

nonisolated private func epubLocalName(_ elementName: String, _ qualifiedName: String?) -> String {
    let candidate = qualifiedName ?? elementName
    return candidate.split(separator: ":").last.map(String.init)?.lowercased() ?? candidate.lowercased()
}
