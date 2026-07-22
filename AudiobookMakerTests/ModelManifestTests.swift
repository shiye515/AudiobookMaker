import Foundation
import Testing
@testable import AudiobookMaker

struct ModelManifestTests {
    @Test("Every built-in downloadable model has a valid signature", arguments: TTSModelCatalog.downloadableModels)
    func signature(manifest: DownloadableModelManifest) {
        #expect(manifest.verifySignature())
    }

    @Test("Speech-swift artifact totals and paths are internally consistent", arguments: [
        TTSModelCatalog.cosyVoice,
        TTSModelCatalog.qwen3TTS
    ])
    func artifactIntegrity(manifest: DownloadableModelManifest) {
        #expect(manifest.formatVersion == 2)
        #expect(manifest.platformRequirement == .nativeAppleSilicon)
        #expect(manifest.artifacts.reduce(Int64(0)) { $0 + $1.downloadBytes } == manifest.downloadBytes)
        #expect(Set(manifest.artifacts.map(\.relativePath)).count == manifest.artifacts.count)
        #expect(Set(manifest.requiredPaths).isSubset(of: Set(manifest.artifacts.map(\.relativePath))))
        #expect(manifest.artifacts.allSatisfy { artifact in
            artifact.downloadURL.scheme == "https"
                && manifest.allowedHosts.contains(artifact.downloadURL.host ?? "")
                && artifact.sha256.count == 64
                && artifact.downloadBytes > 0
                && isSafeRelativePath(artifact.relativePath)
        })
    }

    @Test("The catalog retains stable system and Kokoro identifiers")
    func stableExistingIdentifiers() {
        #expect(TTSModelCatalog.systemID == "com.audiobookmaker.apple-system-speech")
        #expect(TTSModelCatalog.kokoroID == "sherpa-onnx/kokoro-multi-lang-v1_1-int8")
        #expect(TTSModelCatalog.manifestsByID[TTSModelCatalog.kokoroID] == TTSModelCatalog.kokoro)
    }

    private func isSafeRelativePath(_ path: String) -> Bool {
        !path.isEmpty
            && !path.hasPrefix("/")
            && !path.contains("\\")
            && path.split(separator: "/", omittingEmptySubsequences: false).allSatisfy {
                !$0.isEmpty && $0 != "." && $0 != ".."
            }
    }
}
