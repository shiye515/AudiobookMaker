import Foundation

nonisolated protocol StableAppError: LocalizedError, Sendable {
    var code: String { get }
    var recoverySuggestion: String? { get }
}
