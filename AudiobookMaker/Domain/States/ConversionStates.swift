import Foundation

nonisolated enum BookStatus: String, Codable, CaseIterable, Sendable {
    case ready, queued, converting, paused, interrupted, completed, failed
}

nonisolated enum ChapterStatus: String, Codable, CaseIterable, Sendable {
    case pending, queued, synthesizing, packaging, paused, completed, failed
}

nonisolated enum JobState: String, Codable, CaseIterable, Sendable {
    case queued, preparing, running, pausing, paused
    case completing, completed, failed, cancelled, interrupted

    func canTransition(to destination: JobState) -> Bool {
        Self.allowedTransitions[self, default: []].contains(destination)
    }

    private static let allowedTransitions: [JobState: Set<JobState>] = [
        .queued: [.preparing, .cancelled],
        .preparing: [.running, .failed, .cancelled, .interrupted],
        .running: [.pausing, .completing, .failed, .interrupted],
        .pausing: [.paused, .failed, .interrupted],
        .paused: [.queued, .cancelled],
        .completing: [.completed, .failed, .interrupted],
        .failed: [.queued, .cancelled],
        .interrupted: [.queued, .cancelled],
        .completed: [],
        .cancelled: [],
    ]
}

nonisolated enum DomainStateError: LocalizedError, Equatable, Sendable {
    case illegalJobTransition(from: JobState, to: JobState)

    var errorDescription: String? {
        switch self {
        case .illegalJobTransition(let from, let to):
            "任务不能从 \(from.rawValue) 变为 \(to.rawValue)。"
        }
    }
}
