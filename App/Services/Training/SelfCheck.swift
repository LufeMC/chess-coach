//
//  SelfCheck.swift
//  ChessCoach
//

#if DEBUG

import Foundation

// MARK: - Why a hand-rolled harness
//
// This project has no unit-test target: `project.yml` declares the app and
// nothing else, and adding one is not this layer's call. The parts of the
// training and coaching services that are worth testing are nevertheless pure
// and load-bearing — a FEN transform that produces an illegal board, a solve
// machine that accepts a wrong move, a request builder that blows the moment cap
// — and shipping them unverified because the build file does not have a slot for
// XCTest would be the wrong trade.
//
// So the checks live here, in plain Swift with no framework import, behind
// `#if DEBUG`. They can be run three ways:
//
//   * from a debug menu or a preview: `TrainingSelfTests.run()`,
//   * from a future XCTest target, by calling the same entry point,
//   * standalone, by compiling these files with a `main.swift` that prints the
//     failures — which is how they were run while being written.
//
// When a test target exists, each `check.expect` becomes an `#expect` and this
// file goes away.

/// Collects failures instead of trapping, so one bad assertion does not hide the
/// rest of the suite.
struct SelfCheck {

    private(set) var failures: [String] = []
    private let suite: String

    init(_ suite: String) {
        self.suite = suite
    }

    mutating func expect(
        _ condition: Bool,
        _ message: @autoclosure () -> String,
        line: UInt = #line
    ) {
        guard !condition else { return }
        failures.append("\(suite):\(line) — \(message())")
    }

    mutating func equal<T: Equatable>(
        _ actual: T,
        _ expected: T,
        _ label: @autoclosure () -> String = "",
        line: UInt = #line
    ) {
        guard actual != expected else { return }
        let prefix = label().isEmpty ? "" : "\(label()): "
        failures.append("\(suite):\(line) — \(prefix)expected \(expected), got \(actual)")
    }

    mutating func close(
        _ actual: Double,
        _ expected: Double,
        tolerance: Double = 0.0001,
        _ label: @autoclosure () -> String = "",
        line: UInt = #line
    ) {
        guard abs(actual - expected) > tolerance else { return }
        let prefix = label().isEmpty ? "" : "\(label()): "
        failures.append("\(suite):\(line) — \(prefix)expected ≈\(expected), got \(actual)")
    }

    mutating func absorb(_ other: SelfCheck) {
        failures.append(contentsOf: other.failures)
    }
}

/// Result of a suite run.
struct SelfCheckReport: Sendable {
    var failures: [String]
    var checks: Int

    var passed: Bool { failures.isEmpty }

    var summary: String {
        passed
            ? "✓ \(checks) suites passed"
            : "✗ \(failures.count) failure(s)\n" + failures.map { "  • \($0)" }.joined(separator: "\n")
    }
}

#endif
