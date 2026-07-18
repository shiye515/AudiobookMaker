import Testing
@testable import AudiobookMaker

@Suite("AudiobookMaker baseline")
struct AudiobookMakerTests {
    @Test("Test target loads the application module")
    func moduleLoads() {
        #expect(JobState.allCases.contains(.queued))
    }
}
