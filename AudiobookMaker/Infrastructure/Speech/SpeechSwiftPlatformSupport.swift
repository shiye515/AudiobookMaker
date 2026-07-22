import Darwin
import Foundation
import Metal

nonisolated struct SpeechSwiftPlatformSupport: Sendable {
    nonisolated enum Architecture: String, Codable, Equatable, Sendable {
        case arm64
        case x86_64
        case other
    }

    nonisolated struct SystemVersion: Codable, Equatable, Sendable {
        let majorVersion: Int
        let minorVersion: Int
        let patchVersion: Int

        init(majorVersion: Int, minorVersion: Int, patchVersion: Int) {
            self.majorVersion = majorVersion
            self.minorVersion = minorVersion
            self.patchVersion = patchVersion
        }

        init(_ version: OperatingSystemVersion) {
            self.init(
                majorVersion: version.majorVersion,
                minorVersion: version.minorVersion,
                patchVersion: version.patchVersion
            )
        }
    }

    nonisolated struct Snapshot: Equatable, Sendable {
        let architecture: Architecture
        let isRosettaTranslated: Bool
        let operatingSystemVersion: SystemVersion
        let hasMetalDevice: Bool
    }

    nonisolated enum Status: Equatable, Sendable {
        case supported
        case requiresNativeAppleSilicon
        case requiresNewerSystem(minimum: SystemVersion)
        case metalUnavailable

        var isSupported: Bool { self == .supported }
    }

    static let minimumSystemVersion = SystemVersion(
        majorVersion: 15,
        minorVersion: 0,
        patchVersion: 0
    )

    private let snapshotProvider: @Sendable () -> Snapshot

    init(snapshotProvider: @escaping @Sendable () -> Snapshot = Self.liveSnapshot) {
        self.snapshotProvider = snapshotProvider
    }

    func status() -> Status {
        let snapshot = snapshotProvider()
        guard snapshot.architecture == .arm64, !snapshot.isRosettaTranslated else {
            return .requiresNativeAppleSilicon
        }
        guard Self.isAtLeast(snapshot.operatingSystemVersion, minimum: Self.minimumSystemVersion) else {
            return .requiresNewerSystem(minimum: Self.minimumSystemVersion)
        }
        guard snapshot.hasMetalDevice else { return .metalUnavailable }
        return .supported
    }

    static func liveSnapshot() -> Snapshot {
        #if arch(arm64)
        let architecture = Architecture.arm64
        #elseif arch(x86_64)
        let architecture = Architecture.x86_64
        #else
        let architecture = Architecture.other
        #endif

        var translated: Int32 = 0
        var translatedSize = MemoryLayout<Int32>.size
        let translatedResult = sysctlbyname(
            "sysctl.proc_translated",
            &translated,
            &translatedSize,
            nil,
            0
        )

        return Snapshot(
            architecture: architecture,
            isRosettaTranslated: translatedResult == 0 && translated == 1,
            operatingSystemVersion: SystemVersion(ProcessInfo.processInfo.operatingSystemVersion),
            hasMetalDevice: MTLCreateSystemDefaultDevice() != nil
        )
    }

    private static func isAtLeast(
        _ version: SystemVersion,
        minimum: SystemVersion
    ) -> Bool {
        let value = (version.majorVersion, version.minorVersion, version.patchVersion)
        let required = (minimum.majorVersion, minimum.minorVersion, minimum.patchVersion)
        if value.0 != required.0 { return value.0 > required.0 }
        if value.1 != required.1 { return value.1 > required.1 }
        return value.2 >= required.2
    }
}
