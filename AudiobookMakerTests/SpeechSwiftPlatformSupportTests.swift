import Foundation
import Testing
@testable import AudiobookMaker

struct SpeechSwiftPlatformSupportTests {
    @Test("Native Apple Silicon with a supported system and Metal is available")
    func supported() {
        #expect(support(
            architecture: .arm64,
            system: .init(majorVersion: 15, minorVersion: 0, patchVersion: 0),
            metal: true
        ).status() == .supported)
    }

    @Test("Intel architecture is rejected deterministically")
    func intelRejected() {
        #expect(support(architecture: .x86_64).status() == .requiresNativeAppleSilicon)
    }

    @Test("Rosetta translation is rejected even when the injected slice is arm64")
    func rosettaRejected() {
        #expect(support(architecture: .arm64, translated: true).status() == .requiresNativeAppleSilicon)
    }

    @Test("Older macOS reports the minimum supported release")
    func oldSystemRejected() {
        #expect(support(
            architecture: .arm64,
            system: .init(majorVersion: 14, minorVersion: 7, patchVersion: 6)
        ).status() == .requiresNewerSystem(minimum: SpeechSwiftPlatformSupport.minimumSystemVersion))
    }

    @Test("A missing Metal device is distinct from architecture and OS failures")
    func missingMetalRejected() {
        #expect(support(architecture: .arm64, metal: false).status() == .metalUnavailable)
    }

    private func support(
        architecture: SpeechSwiftPlatformSupport.Architecture,
        translated: Bool = false,
        system: SpeechSwiftPlatformSupport.SystemVersion = .init(majorVersion: 26, minorVersion: 0, patchVersion: 0),
        metal: Bool = true
    ) -> SpeechSwiftPlatformSupport {
        SpeechSwiftPlatformSupport {
            .init(
                architecture: architecture,
                isRosettaTranslated: translated,
                operatingSystemVersion: system,
                hasMetalDevice: metal
            )
        }
    }
}
