import CryptoKit
import Foundation

nonisolated enum ModelArtifactKind: String, Codable, Equatable, Sendable {
    case archive
    case file
}

nonisolated struct ModelArtifactManifest: Codable, Equatable, Sendable {
    let relativePath: String
    let downloadURL: URL
    let downloadBytes: Int64
    let sha256: String
    let kind: ModelArtifactKind
    let archiveRoot: String?

    init(
        relativePath: String,
        downloadURL: URL,
        downloadBytes: Int64,
        sha256: String,
        kind: ModelArtifactKind = .file,
        archiveRoot: String? = nil
    ) {
        self.relativePath = relativePath
        self.downloadURL = downloadURL
        self.downloadBytes = downloadBytes
        self.sha256 = sha256
        self.kind = kind
        self.archiveRoot = archiveRoot
    }
}

nonisolated struct DownloadableModelManifest: Codable, Sendable, Equatable {
    let id: String
    let displayName: String
    let version: String
    let runtimeVersion: String
    let downloadURL: URL
    let downloadBytes: Int64
    let expandedBytes: Int64
    let sha256: String
    let requiredPaths: [String]
    let signatureBase64: String
    let formatVersion: Int
    let variant: String
    let platformRequirement: RuntimePlatformRequirement
    let minimumSystemMajorVersion: Int
    let runtimeRevision: String
    let licenseIdentifier: String
    let sourceURL: URL
    let allowedHosts: [String]
    let stagingBytes: Int64
    let artifacts: [ModelArtifactManifest]

    init(
        id: String,
        displayName: String,
        version: String,
        runtimeVersion: String,
        downloadURL: URL,
        downloadBytes: Int64,
        expandedBytes: Int64,
        sha256: String,
        requiredPaths: [String],
        signatureBase64: String,
        formatVersion: Int = 1,
        variant: String = "",
        platformRequirement: RuntimePlatformRequirement = .anyMac,
        minimumSystemMajorVersion: Int = 0,
        runtimeRevision: String = "",
        licenseIdentifier: String = "",
        sourceURL: URL? = nil,
        allowedHosts: [String] = [
            "github.com", "release-assets.githubusercontent.com", "objects.githubusercontent.com"
        ],
        stagingBytes: Int64? = nil,
        artifacts: [ModelArtifactManifest] = []
    ) {
        self.id = id
        self.displayName = displayName
        self.version = version
        self.runtimeVersion = runtimeVersion
        self.downloadURL = downloadURL
        self.downloadBytes = downloadBytes
        self.expandedBytes = expandedBytes
        self.sha256 = sha256
        self.requiredPaths = requiredPaths
        self.signatureBase64 = signatureBase64
        self.formatVersion = formatVersion
        self.variant = variant
        self.platformRequirement = platformRequirement
        self.minimumSystemMajorVersion = minimumSystemMajorVersion
        self.runtimeRevision = runtimeRevision
        self.licenseIdentifier = licenseIdentifier
        self.sourceURL = sourceURL ?? downloadURL
        self.allowedHosts = allowedHosts
        self.stagingBytes = stagingBytes ?? expandedBytes
        self.artifacts = artifacts
    }

    var effectiveArtifacts: [ModelArtifactManifest] {
        if !artifacts.isEmpty { return artifacts }
        return [ModelArtifactManifest(
            relativePath: "model-archive",
            downloadURL: downloadURL,
            downloadBytes: downloadBytes,
            sha256: sha256,
            kind: .archive
        )]
    }

    var signedPayload: Data {
        if formatVersion == 1 {
            return Data("\(id)|\(displayName)|\(version)|\(runtimeVersion)|\(downloadURL.absoluteString)|\(downloadBytes)|\(expandedBytes)|\(sha256)|\(requiredPaths.joined(separator: ","))".utf8)
        }
        let artifactPayload = artifacts.map {
            [
                $0.relativePath,
                $0.downloadURL.absoluteString,
                String($0.downloadBytes),
                $0.sha256,
                $0.kind.rawValue,
                $0.archiveRoot ?? ""
            ].joined(separator: "|")
        }.joined(separator: "\n")
        return Data([
            "manifest-v\(formatVersion)", id, displayName, version, runtimeVersion,
            variant, platformRequirement.rawValue, String(minimumSystemMajorVersion),
            runtimeRevision, licenseIdentifier, sourceURL.absoluteString,
            allowedHosts.joined(separator: ","), String(downloadBytes), String(expandedBytes),
            String(stagingBytes), requiredPaths.joined(separator: ","), artifactPayload
        ].joined(separator: "\n").utf8)
    }

    func verifySignature() -> Bool {
        let publicKey = formatVersion == 1
            ? TTSModelCatalog.manifestPublicKeyBase64
            : TTSModelCatalog.manifestV2PublicKeyBase64
        guard let publicData = Data(base64Encoded: publicKey),
              let signature = Data(base64Encoded: signatureBase64),
              let key = try? Curve25519.Signing.PublicKey(rawRepresentation: publicData) else { return false }
        return key.isValidSignature(signature, for: signedPayload)
    }
}

nonisolated enum TTSModelCatalog {
    static let systemID = "com.audiobookmaker.apple-system-speech"
    static let cosyVoiceID = "soniqo.speech-swift/cosyvoice3-0.5b-mlx-8bit-full"
    static let qwen3TTSID = "soniqo.speech-swift/qwen3-tts-12hz-0.6b-customvoice-mlx-bf16"
    static let cosyVoiceRepositoryID = "aufklarer/CosyVoice3-0.5B-MLX-8bit-full"
    static let qwen3TTSRepositoryID = "aufklarer/Qwen3-TTS-12Hz-0.6B-CustomVoice-MLX-bf16"
    static let manifestPublicKeyBase64 = "6cnfbMU7/3mSpbCGAaZtLbCoPhRd9oclLQ+AxY/BPJU="
    static let manifestV2PublicKeyBase64 = "JoOlwM/ezCU1w7+ZWbBPAXZrb6779+GYQUTjjXyYAII="

    private static let huggingFaceHosts = [
        "huggingface.co", "cdn-lfs.hf.co", "cdn-lfs-us-1.hf.co",
        "cdn-lfs-eu-1.hf.co", "cas-bridge.xethub.hf.co", "us.aws.cdn.hf.co"
    ]

    private static let speechSwiftRevision = "c1aa219bc2284239ff6917d675a3e1978c840260"

    private static func huggingFaceURL(repo: String, revision: String, path: String) -> URL {
        URL(string: "https://huggingface.co/\(repo)/resolve/\(revision)/\(path)?download=true")!
    }

    private static func file(
        repo: String,
        revision: String,
        path: String,
        destination: String? = nil,
        bytes: Int64,
        sha256: String
    ) -> ModelArtifactManifest {
        ModelArtifactManifest(
            relativePath: destination ?? path,
            downloadURL: huggingFaceURL(repo: repo, revision: revision, path: path),
            downloadBytes: bytes,
            sha256: sha256
        )
    }

    static let cosyVoice = DownloadableModelManifest(
        id: cosyVoiceID,
        displayName: "CosyVoice3 0.5B MLX 8-bit",
        version: "b52fc1c3bf5f3b947d40c250639e5ebe347ece11",
        runtimeVersion: "speech-swift-0.0.23",
        downloadURL: huggingFaceURL(
            repo: cosyVoiceRepositoryID,
            revision: "b52fc1c3bf5f3b947d40c250639e5ebe347ece11",
            path: "config.json"
        ),
        downloadBytes: 1_121_605_600,
        expandedBytes: 1_121_605_600,
        sha256: "b1baa4f071e5f6f51eea602581ff3b887018d3565a3a30dda1a019368ecf43c9",
        requiredPaths: [
            "README.md", "config.json", "flow.safetensors", "flow_noise.bin",
            "hifigan.safetensors", "llm.safetensors", "merges.txt",
            "tokenizer_config.json", "vocab.json"
        ],
        signatureBase64: "VaQV3WJm8GcjjoBx4vZcH8zd5ku0JTCVMuGkVHWdqZkuqjFUK/w9TMPW/iY7Z9cK2UjSZ3Y3qgUX5GuncFpvCw==",
        formatVersion: 2,
        variant: "CosyVoice3-0.5B-MLX-8bit-full",
        platformRequirement: .nativeAppleSilicon,
        minimumSystemMajorVersion: 15,
        runtimeRevision: speechSwiftRevision,
        licenseIdentifier: "Apache-2.0",
        sourceURL: URL(string: "https://huggingface.co/\(cosyVoiceRepositoryID)/tree/b52fc1c3bf5f3b947d40c250639e5ebe347ece11")!,
        allowedHosts: huggingFaceHosts,
        stagingBytes: 1_121_605_600,
        artifacts: {
            let repo = cosyVoiceRepositoryID
            let revision = "b52fc1c3bf5f3b947d40c250639e5ebe347ece11"
            return [
                file(repo: repo, revision: revision, path: "README.md", bytes: 2_877, sha256: "3e45fb12c2ecafbef0b1a9f0ae82e523066af6827b4838596fae58fd4e821a4b"),
                file(repo: repo, revision: revision, path: "config.json", bytes: 2_346, sha256: "b1baa4f071e5f6f51eea602581ff3b887018d3565a3a30dda1a019368ecf43c9"),
                file(repo: repo, revision: revision, path: "flow.safetensors", bytes: 358_312_720, sha256: "14ed72f45c9b55e6de8df86d349ca5ef3d220648db452845795bf5184f39fca1"),
                file(repo: repo, revision: revision, path: "flow_noise.bin", bytes: 4_800_000, sha256: "3ebc526a5163d79f14b760e978e05e86dc83d9685f24a537a494cb1a5cf06c6f"),
                file(repo: repo, revision: revision, path: "hifigan.safetensors", bytes: 83_086_548, sha256: "840350956a8403245c738504a0da2a0c2047d5e705173930030013f28d4e3a1e"),
                file(repo: repo, revision: revision, path: "llm.safetensors", bytes: 671_220_880, sha256: "49b3b2ecc7bcff7d554a80012721a2283187477dd5371a140c1c1a89b13b1063"),
                file(repo: repo, revision: revision, path: "merges.txt", bytes: 1_402_109, sha256: "ac8ff86a72bee70828fbc1119bc4398c6f3a9a6e490d7b0dbe917be025478bd0"),
                file(repo: repo, revision: revision, path: "tokenizer_config.json", bytes: 1_287, sha256: "482bd979881423375ca5414e4e0d94cd7c5349dbb17fffd46b4d36d71e62a1bc"),
                file(repo: repo, revision: revision, path: "vocab.json", bytes: 2_776_833, sha256: "ca10d7e9fb3ed18575dd1e277a2579c16d108e32f27439684afa0e10b1440910")
            ]
        }()
    )

    static let qwen3TTS = DownloadableModelManifest(
        id: qwen3TTSID,
        displayName: "Qwen3-TTS 0.6B CustomVoice MLX bf16",
        version: "3affbf656d9d6aa9255ec0b31cc90055605170bc+tokenizer-7dd38ad4",
        runtimeVersion: "speech-swift-0.0.23",
        downloadURL: huggingFaceURL(
            repo: qwen3TTSRepositoryID,
            revision: "3affbf656d9d6aa9255ec0b31cc90055605170bc",
            path: "config.json"
        ),
        downloadBytes: 2_498_418_367,
        expandedBytes: 2_498_418_367,
        sha256: "81aca2b6fac304944d8acf345272d8a9a727d5fc2e2e66b222ab4729340c7455",
        requiredPaths: [
            "README.md", "config.json", "merges.txt", "model.safetensors",
            "model.safetensors.index.json", "tokenizer_config.json", "vocab.json",
            "runtime-cache/qwen3-speech/models/Qwen/Qwen3-TTS-Tokenizer-12Hz/config.json",
            "runtime-cache/qwen3-speech/models/Qwen/Qwen3-TTS-Tokenizer-12Hz/configuration.json",
            "runtime-cache/qwen3-speech/models/Qwen/Qwen3-TTS-Tokenizer-12Hz/model.safetensors",
            "runtime-cache/qwen3-speech/models/Qwen/Qwen3-TTS-Tokenizer-12Hz/preprocessor_config.json"
        ],
        signatureBase64: "Rpg+NWPBemldjCtyP3zTmJSSG3NjMutTmu6IpnZWYEHNT//AVS3pGrmnN50lEw52BKVPfj7KCOPYgPyIPS7tBA==",
        formatVersion: 2,
        variant: "Qwen3-TTS-12Hz-0.6B-CustomVoice-MLX-bf16",
        platformRequirement: .nativeAppleSilicon,
        minimumSystemMajorVersion: 15,
        runtimeRevision: speechSwiftRevision,
        licenseIdentifier: "Apache-2.0",
        sourceURL: URL(string: "https://huggingface.co/\(qwen3TTSRepositoryID)/tree/3affbf656d9d6aa9255ec0b31cc90055605170bc")!,
        allowedHosts: huggingFaceHosts,
        stagingBytes: 2_498_418_367,
        artifacts: {
            let repo = qwen3TTSRepositoryID
            let revision = "3affbf656d9d6aa9255ec0b31cc90055605170bc"
            let tokenizerRepo = "Qwen/Qwen3-TTS-Tokenizer-12Hz"
            let tokenizerRevision = "7dd38ad4e9bad454aae9cd937d0cd577604fe229"
            let tokenizerRoot = "runtime-cache/qwen3-speech/models/Qwen/Qwen3-TTS-Tokenizer-12Hz"
            return [
                file(repo: repo, revision: revision, path: "README.md", bytes: 1_449, sha256: "75fc2338c8c83a6bc3d24f2505a4f50772d8ba881b6f681073b697e15bd2641f"),
                file(repo: repo, revision: revision, path: "config.json", bytes: 4_908, sha256: "81aca2b6fac304944d8acf345272d8a9a727d5fc2e2e66b222ab4729340c7455"),
                file(repo: repo, revision: revision, path: "merges.txt", bytes: 1_671_839, sha256: "599bab54075088774b1733fde865d5bd747cbcc7a547c5bc12610e874e26f5e3"),
                file(repo: repo, revision: revision, path: "model.safetensors", bytes: 1_811_626_144, sha256: "465675a36380251e143cfbca8d693f375c47ba6bf0ae334966cb529ef1be34d9"),
                file(repo: repo, revision: revision, path: "model.safetensors.index.json", bytes: 30_630, sha256: "463127e455292c8f002a9bfe67ec165235ecc107017228e3fb64e28fdb145f6f"),
                file(repo: repo, revision: revision, path: "tokenizer_config.json", bytes: 7_344, sha256: "dc3c31c3bdaedd5016382bb3cbe07323026775ad51f5a4fb564505992ae4a670"),
                file(repo: repo, revision: revision, path: "vocab.json", bytes: 2_776_833, sha256: "ca10d7e9fb3ed18575dd1e277a2579c16d108e32f27439684afa0e10b1440910"),
                file(repo: tokenizerRepo, revision: tokenizerRevision, path: "README.md", destination: "\(tokenizerRoot)/README.md", bytes: 3_482, sha256: "1d9016fbb07873cd720d008423c3da275eac7a20c3997a525594025608d3e1cf"),
                file(repo: tokenizerRepo, revision: tokenizerRevision, path: "config.json", destination: "\(tokenizerRoot)/config.json", bytes: 2_336, sha256: "ee65bb901c876664ab8707c487157aa1a6ee57c65969b28fb5ec9dc211e68167"),
                file(repo: tokenizerRepo, revision: tokenizerRevision, path: "configuration.json", destination: "\(tokenizerRoot)/configuration.json", bytes: 76, sha256: "6bc26d64eb5024b4d1dab5a52371958b429256d6c9d59787f1f5294a54e0cebd"),
                file(repo: tokenizerRepo, revision: tokenizerRevision, path: "model.safetensors", destination: "\(tokenizerRoot)/model.safetensors", bytes: 682_293_092, sha256: "836b7b357f5ea43e889936a3709af68dfe3751881acefe4ecf0dbd30ba571258"),
                file(repo: tokenizerRepo, revision: tokenizerRevision, path: "preprocessor_config.json", destination: "\(tokenizerRoot)/preprocessor_config.json", bytes: 234, sha256: "fcb3805e597e786d4067706e602f6688524640f8d3396790e2e09b5942fcbdfb")
            ]
        }()
    )

    static let manifestsByID: [String: DownloadableModelManifest] = [
        cosyVoice.id: cosyVoice,
        qwen3TTS.id: qwen3TTS
    ]

    static let downloadableModels = [cosyVoice, qwen3TTS]

    static let cosyVoiceVoices = [
        TTSVoiceDescriptor(id: "default", displayName: "默认音色", languageCode: "zh-CN", speakerID: 0)
    ]

    static let qwen3TTSVoices: [TTSVoiceDescriptor] = [
        ("vivian", "Vivian · 中文女声", "zh-CN"),
        ("serena", "Serena · 中文女声", "zh-CN"),
        ("uncle_fu", "Uncle Fu · 中文男声", "zh-CN"),
        ("ryan", "Ryan · English", "en-US"),
        ("aiden", "Aiden · English", "en-US"),
        ("ono_anna", "Ono Anna · 日本語", "ja-JP"),
        ("sohee", "Sohee · 한국어", "ko-KR"),
        ("eric", "Eric · English", "en-US"),
        ("dylan", "Dylan · English", "en-US")
    ].enumerated().map { index, voice in
        TTSVoiceDescriptor(id: voice.0, displayName: voice.1, languageCode: voice.2, speakerID: Int32(index))
    }
}
