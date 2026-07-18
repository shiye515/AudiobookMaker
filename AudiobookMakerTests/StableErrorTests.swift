import Testing
@testable import AudiobookMaker

struct StableErrorTests {
    @Test
    func publicErrorsExposeStableCodesAndRecoveryText() {
        let errors: [any StableAppError] = [
            ImportError.unsupportedEPUB,
            RuntimeError.invalidAudio,
            PackagingError.validationFailed("fixture"),
            ExportError.invalidDestination,
        ]
        for error in errors {
            #expect(!error.code.isEmpty)
            #expect(error.code.contains("."))
            #expect(error.errorDescription?.isEmpty == false)
            #expect(error.recoverySuggestion?.isEmpty == false)
        }
        #expect(RuntimeError.textTooLong(maximum: 36).code == "runtime.textTooLong")
        #expect(PackagingError.validationFailed("one").code
            == PackagingError.validationFailed("two").code)
    }
}
