import CryptoKit
import Foundation

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

    var signedPayload: Data {
        Data("\(id)|\(displayName)|\(version)|\(runtimeVersion)|\(downloadURL.absoluteString)|\(downloadBytes)|\(expandedBytes)|\(sha256)|\(requiredPaths.joined(separator: ","))".utf8)
    }

    func verifySignature() -> Bool {
        guard let publicData = Data(base64Encoded: TTSModelCatalog.manifestPublicKeyBase64),
              let signature = Data(base64Encoded: signatureBase64),
              let key = try? Curve25519.Signing.PublicKey(rawRepresentation: publicData) else { return false }
        return key.isValidSignature(signature, for: signedPayload)
    }
}

nonisolated enum TTSModelCatalog {
    static let systemID = "com.audiobookmaker.apple-system-speech"
    static let kokoroID = "sherpa-onnx/kokoro-multi-lang-v1_1-int8"
    static let kokoroDefaultVoiceID = "zf_001"
    static let manifestPublicKeyBase64 = "6cnfbMU7/3mSpbCGAaZtLbCoPhRd9oclLQ+AxY/BPJU="

    static let kokoro = DownloadableModelManifest(
        id: kokoroID,
        displayName: "Kokoro 多语言 Int8",
        version: "1.1-int8",
        runtimeVersion: "1.13.2",
        downloadURL: URL(string: "https://github.com/k2-fsa/sherpa-onnx/releases/download/tts-models/kokoro-int8-multi-lang-v1_1.tar.bz2")!,
        downloadBytes: 147_031_220,
        expandedBytes: 215_321_602,
        sha256: "a1e94694776049035c4f2c6529f003aaece993c76aae9a78995831c3c4dcafc6",
        requiredPaths: [
            "model.int8.onnx", "voices.bin", "tokens.txt", "espeak-ng-data",
            "lexicon-us-en.txt", "lexicon-zh.txt", "LICENSE"
        ],
        signatureBase64: "24Q2u86G8rmMOopCH51NAsCGUCcf6x5ynvcBvNEXwXR8Miovhwta74Do05bldWtY5UlQs3LuU9a9VXzm5KiHBQ=="
    )

    static let kokoroVoices: [TTSVoiceDescriptor] = {
        let names = """
        af_maple af_sol bf_vale zf_001 zf_002 zf_003 zf_004 zf_005 zf_006 zf_007 zf_008 zf_017 zf_018 zf_019 zf_021 zf_022 zf_023 zf_024 zf_026 zf_027 zf_028 zf_032 zf_036 zf_038 zf_039 zf_040 zf_042 zf_043 zf_044 zf_046 zf_047 zf_048 zf_049 zf_051 zf_059 zf_060 zf_067 zf_070 zf_071 zf_072 zf_073 zf_074 zf_075 zf_076 zf_077 zf_078 zf_079 zf_083 zf_084 zf_085 zf_086 zf_087 zf_088 zf_090 zf_092 zf_093 zf_094 zf_099 zm_009 zm_010 zm_011 zm_012 zm_013 zm_014 zm_015 zm_016 zm_020 zm_025 zm_029 zm_030 zm_031 zm_033 zm_034 zm_035 zm_037 zm_041 zm_045 zm_050 zm_052 zm_053 zm_054 zm_055 zm_056 zm_057 zm_058 zm_061 zm_062 zm_063 zm_064 zm_065 zm_066 zm_068 zm_069 zm_080 zm_081 zm_082 zm_089 zm_091 zm_095 zm_096 zm_097 zm_098 zm_100
        """.split(separator: " ").map(String.init)
        return names.enumerated().map { index, name in
            let language = name.hasPrefix("z") ? "zh-CN" : "en-US"
            let family = name.hasPrefix("zf") ? "中文女声" : name.hasPrefix("zm") ? "中文男声" : "English"
            return TTSVoiceDescriptor(id: name, displayName: "\(family) · \(name)", languageCode: language, speakerID: Int32(index))
        }
    }()
}
