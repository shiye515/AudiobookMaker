import Testing
@testable import AudiobookMaker

struct ConversionStateTests {
    @Test func everyLegalAndIllegalJobTransitionIsStable() {
        let legal: Set<String> = [
            "queued>preparing", "queued>cancelled",
            "preparing>running", "preparing>failed", "preparing>cancelled", "preparing>interrupted",
            "running>pausing", "running>completing", "running>failed", "running>interrupted",
            "pausing>paused", "pausing>failed", "pausing>interrupted",
            "paused>queued", "paused>cancelled",
            "completing>completed", "completing>failed", "completing>interrupted",
            "failed>queued", "failed>cancelled", "interrupted>queued", "interrupted>cancelled",
        ]
        for source in JobState.allCases {
            for destination in JobState.allCases {
                let key = "\(source.rawValue)>\(destination.rawValue)"
                #expect(source.canTransition(to: destination) == legal.contains(key), Comment(rawValue: key))
            }
        }
    }
}
