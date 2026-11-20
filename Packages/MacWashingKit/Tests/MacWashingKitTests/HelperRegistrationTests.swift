import MacWashingXPC
import Testing

/// Settings ▸ Доступ shows a registration error under the helper row only when registering really failed.
@Suite("Helper registration error")
struct HelperRegistrationTests {
    static let denied = "Не удалось завершить операцию. Operation not permitted"

    @Test func approvalPendingIsNotAnError() {
        // The first `register()` throws while the daemon waits for approval in Login Items (macOS 14.8.7).
        #expect(HelperRegistration.errorToShow(thrown: Self.denied, awaitingApproval: true, enabled: false) == nil)
    }

    @Test func runningHelperHidesAnOldError() {
        #expect(HelperRegistration.errorToShow(thrown: Self.denied, awaitingApproval: false, enabled: true) == nil)
    }

    @Test func realFailureIsShown() {
        // Registration failed and the helper is neither waiting for approval nor running.
        #expect(HelperRegistration.errorToShow(thrown: Self.denied, awaitingApproval: false, enabled: false) == Self.denied)
    }

    @Test func nothingThrownNothingShown() {
        #expect(HelperRegistration.errorToShow(thrown: nil, awaitingApproval: false, enabled: false) == nil)
    }
}
