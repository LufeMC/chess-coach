import Testing

@testable import ChessCoach

/// Surfaces the training and coaching services' own self-checks in the real test
/// target.
///
/// Those suites were written before this target existed, as a `#if DEBUG`
/// harness inside the service files. Rather than rewrite eleven suites of
/// working assertions, this runs them and reports the aggregate — the checks
/// still live next to the code they exercise, and a failure names which one
/// broke.
@Suite("Service self-checks")
struct ServiceSelfTestBridge {

    @Test("Training and coaching service self-checks pass")
    func serviceSelfChecks() {
        let report = ServiceSelfTests.run()
        #expect(report.passed, "\(report.summary)")
    }
}
