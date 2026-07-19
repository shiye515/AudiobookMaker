import Foundation

nonisolated struct AppDirectories: Sendable {
    let root: URL
    let cacheRoot: URL

    var books: URL { root.appending(path: "Books", directoryHint: .isDirectory) }
    var staging: URL { root.appending(path: ".Staging", directoryHint: .isDirectory) }
    var trash: URL { root.appending(path: ".Trash", directoryHint: .isDirectory) }
    var runtime: URL { root.appending(path: "Runtime", directoryHint: .isDirectory) }
    var models: URL { runtime.appending(path: "Models", directoryHint: .isDirectory) }
    var modelStaging: URL { runtime.appending(path: ".ModelStaging", directoryHint: .isDirectory) }
    var modelResumeData: URL { runtime.appending(path: ".ModelResumeData", directoryHint: .isDirectory) }
    var importCaches: URL { cacheRoot.appending(path: "Imports", directoryHint: .isDirectory) }

    static func live(fileManager: FileManager = .default) throws -> AppDirectories {
        let applicationSupport = try fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let caches = try fileManager.url(
            for: .cachesDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let directories = AppDirectories(
            root: applicationSupport.appending(path: "AudiobookMaker", directoryHint: .isDirectory),
            cacheRoot: caches.appending(path: "AudiobookMaker", directoryHint: .isDirectory)
        )
        try directories.createIfNeeded(fileManager: fileManager)
        return directories
    }

    func createIfNeeded(fileManager: FileManager = .default) throws {
        // Keep these calls explicit. XCTest may initialize independent app hosts in
        // parallel; avoiding first-use generic Array metadata here also sidesteps a
        // Swift x86_64 runtime metadata race observed during XPC crash-recovery tests.
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: books, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: staging, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: trash, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: runtime, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: models, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: modelStaging, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: modelResumeData, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: cacheRoot, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: importCaches, withIntermediateDirectories: true)
    }

    func bookDirectory(id: UUID) -> URL {
        books.appending(path: id.uuidString, directoryHint: .isDirectory)
    }

    func modelDirectory(id: String) -> URL {
        let safeID = id
            .replacingOccurrences(of: "/", with: "--")
            .replacingOccurrences(of: ":", with: "-")
        return models.appending(path: safeID, directoryHint: .isDirectory)
    }

    func modelVersionDirectory(id: String, version: String) throws -> URL {
        let safeVersion = try safeModelComponent(version)
        return modelDirectory(id: id).appending(path: safeVersion, directoryHint: .isDirectory)
    }

    func modelStagingDirectory(id: String, version: String) throws -> URL {
        let safeID = try safeModelComponent(id.replacingOccurrences(of: "/", with: "--"))
        let safeVersion = try safeModelComponent(version)
        return modelStaging.appending(path: "\(safeID)-\(safeVersion)", directoryHint: .isDirectory)
    }

    func modelResumeDataURL(id: String, version: String) throws -> URL {
        let safeID = try safeModelComponent(id.replacingOccurrences(of: "/", with: "--"))
        let safeVersion = try safeModelComponent(version)
        return modelResumeData.appending(path: "\(safeID)-\(safeVersion).resume")
    }

    private func safeModelComponent(_ value: String) throws -> String {
        guard !value.isEmpty,
              value.range(of: "^[A-Za-z0-9._-]+$", options: .regularExpression) != nil,
              value != ".", value != ".." else {
            throw AppDirectoryError.unsafeRelativePath
        }
        return value
    }

    func relativePath(for url: URL) throws -> String {
        let standardizedRoot = root.standardizedFileURL
        let standardizedURL = url.standardizedFileURL
        let rootComponents: [String] = standardizedRoot.pathComponents
        let components: [String] = standardizedURL.pathComponents
        guard components.starts(with: rootComponents) else {
            throw AppDirectoryError.pathOutsideApplicationSupport
        }
        let relativeComponents = Array(components[rootComponents.count...])
        try rejectSymbolicLinks(in: relativeComponents)
        return relativeComponents.joined(separator: "/")
    }

    func resolve(relativePath: String) throws -> URL {
        guard !relativePath.isEmpty,
              !relativePath.hasPrefix("/"),
              !relativePath.hasPrefix("~"),
              !relativePath.contains("\\"),
              !relativePath.split(separator: "/").contains(".."),
              !relativePath.unicodeScalars.contains(where: {
                  CharacterSet.controlCharacters.contains($0)
              })
        else {
            throw AppDirectoryError.unsafeRelativePath
        }
        let resolved = relativePath.split(separator: "/").reduce(root) { url, component in
            url.appending(path: String(component))
        }.standardizedFileURL
        let components = relativePath.split(separator: "/").map(String.init)
        guard resolved.pathComponents.starts(with: root.standardizedFileURL.pathComponents) else {
            throw AppDirectoryError.unsafeRelativePath
        }
        try rejectSymbolicLinks(in: components)
        return resolved
    }

    private func rejectSymbolicLinks(in components: [String]) throws {
        var current = root.standardizedFileURL
        for component in components {
            current.append(path: component)
            guard FileManager.default.fileExists(atPath: current.path) else { continue }
            let attributes = try FileManager.default.attributesOfItem(atPath: current.path)
            if attributes[.type] as? FileAttributeType == .typeSymbolicLink {
                throw AppDirectoryError.unsafeRelativePath
            }
        }
    }
}

nonisolated enum AppDirectoryError: LocalizedError, Equatable {
    case pathOutsideApplicationSupport
    case unsafeRelativePath

    var errorDescription: String? {
        switch self {
        case .pathOutsideApplicationSupport: "文件不在 AudiobookMaker 的管理目录中。"
        case .unsafeRelativePath: "检测到不安全的相对路径。"
        }
    }
}
