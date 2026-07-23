import Foundation
import Testing
@testable import AudiobookMaker

struct SpeechSwiftPlatformSupportTests {
    @Test("Native Apple Silicon with a supported system, Metal, and resources is available")
    func supported() {
        #expect(support().status() == .supported)
    }

    @Test("A non-native process is rejected deterministically")
    func nonNativeProcessRejected() {
        #expect(support(native: false).status() == .requiresNativeAppleSilicon)
    }

    @Test("Older macOS reports the minimum supported release")
    func oldSystemRejected() {
        #expect(support(
            system: .init(majorVersion: 14, minorVersion: 7, patchVersion: 6)
        ).status() == .requiresNewerSystem(minimum: SpeechSwiftPlatformSupport.minimumSystemVersion))
    }

    @Test("A missing Metal device is distinct from system failures")
    func missingMetalRejected() {
        #expect(support(metal: false).status() == .metalUnavailable)
    }

    @Test("Damaged runtime resources fail before model initialization")
    func missingRuntimeResourcesRejected() {
        #expect(support(resources: false).status() == .runtimeResourcesMissing)
    }

    private func support(
        native: Bool = true,
        system: SpeechSwiftPlatformSupport.SystemVersion = .init(
            majorVersion: 26,
            minorVersion: 0,
            patchVersion: 0
        ),
        metal: Bool = true,
        resources: Bool = true
    ) -> SpeechSwiftPlatformSupport {
        SpeechSwiftPlatformSupport {
            .init(
                isNativeAppleSilicon: native,
                operatingSystemVersion: system,
                hasMetalDevice: metal,
                hasRuntimeResources: resources
            )
        }
    }
}
