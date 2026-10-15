#if canImport(XCTest)
import XCTest
@testable import NoteObs

/// Forwards into the shared scenario list in `NoteObs/Verification.swift`.
///
/// The suite itself is reachable without XCTest through `NoteObs --verify`, which is what runs on
/// a Command Line Tools installation; this file only exists so the same scenarios also show up in
/// Xcode's test navigator when Xcode is installed.
@MainActor
final class NotesRegressionTests: XCTestCase {
    func testAllScenarios() async {
        var failures: [String] = []
        for testCase in NotesVerificationSuite.cases {
            do {
                try await testCase.run()
            } catch {
                failures.append("\(testCase.name): \(error)")
            }
        }
        for failure in failures {
            XCTFail(failure)
        }
    }
}
#endif
