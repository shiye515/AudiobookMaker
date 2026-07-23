import Foundation
import Metal

nonisolated struct SpeechSwiftPlatformSupport: Sendable {
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
        let isNativeAppleSilicon: Bool
        let operatingSystemVersion: SystemVersion
        let hasMetalDevice: Bool
        let hasRuntimeResources: Bool
    }

    nonisolated enum Status: Equatable, Sendable {
        case supported
        case requiresNativeAppleSilicon
        case requiresNewerSystem(minimum: SystemVersion)
        case metalUnavailable
        case runtimeResourcesMissing

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
        guard snapshot.isNativeAppleSilicon else {
            return .requiresNativeAppleSilicon
        }
        guard Self.isAtLeast(snapshot.operatingSystemVersion, minimum: Self.minimumSystemVersion) else {
            return .requiresNewerSystem(minimum: Self.minimumSystemVersion)
        }
        guard snapshot.hasMetalDevice else { return .metalUnavailable }
        guard snapshot.hasRuntimeResources else { return .runtimeResourcesMissing }
        return .supported
    }

    static func liveSnapshot() -> Snapshot {
        #if arch(arm64)
        let isNativeAppleSilicon = true
        #else
        let isNativeAppleSilicon = false
        #endif
        let metallib = Bundle.main.url(
            forResource: "mlx",
            withExtension: "metallib",
            subdirectory: "MLX"
        )
        return Snapshot(
            isNativeAppleSilicon: isNativeAppleSilicon,
            operatingSystemVersion: SystemVersion(ProcessInfo.processInfo.operatingSystemVersion),
            hasMetalDevice: MTLCreateSystemDefaultDevice() != nil,
            hasRuntimeResources: metallib.map {
                FileManager.default.isReadableFile(atPath: $0.path)
            } ?? false
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
