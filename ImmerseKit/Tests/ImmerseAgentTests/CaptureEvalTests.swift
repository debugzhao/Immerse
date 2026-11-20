import Foundation
import ImmerseCore
import Testing
@testable import ImmerseAgent

/// Live accuracy check of AI capture against `Fixtures/capture-eval.json`.
/// Opt-in because every run calls the API and costs money: set IMMERSE_EVAL_API_KEY to run it
/// (through xcodebuild: TEST_RUNNER_IMMERSE_EVAL_API_KEY=… scripts/test-kit.sh). Target: ≥ 90% of cases pass.
struct CaptureEvalTests {
    @Test func 数据集格式正确() throws {
        let cases = try Self.loadCases()
        #expect(cases.count == 20)
        #expect(cases.allSatisfy { !$0.text.isEmpty && !$0.expect.isEmpty })
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["IMMERSE_EVAL_API_KEY"] != nil))
    func AI收集准确率() async throws {
        let key = try #require(ProcessInfo.processInfo.environment["IMMERSE_EVAL_API_KEY"])
        let provider = AnthropicHTTPProvider(apiKey: key)
        let now = try DateText.parse("2026-11-18T08:00:00+08:00")
        var passed = 0
        var failures: [String] = []
        for item in try Self.loadCases() {
            let drafts = try await StructuredCalls.capture(item.text, provider: provider, now: now, calendar: Fixture.calendar).drafts
            let problems = Self.check(drafts, against: item.expect)
            if problems.isEmpty { passed += 1 } else { failures.append("\(item.text): \(problems.joined(separator: ", "))") }
        }
        print("Capture eval: \(passed)/20 passed\n" + failures.joined(separator: "\n"))
        #expect(passed >= 18)
    }

    struct Case: Decodable {
        let text: String
        let expect: [String: JSONValue]
    }

    static func loadCases() throws -> [Case] {
        let url = try #require(Bundle.module.url(forResource: "capture-eval", withExtension: "json", subdirectory: "Fixtures"))
        let json = try JSONDecoder().decode(JSONValue.self, from: Data(contentsOf: url))
        return try (json["cases"] ?? []).decode([Case].self)
    }

    static func check(_ drafts: [CaptureDraft], against expect: [String: JSONValue]) -> [String] {
        if let count = expect["items"]?.int, drafts.count != count { return ["items \(drafts.count) ≠ \(count)"] }
        guard let first = drafts.first else { return ["no items"] }
        let calendar = Fixture.calendar
        var problems: [String] = []
        func mismatch(_ field: String, _ actual: String?, _ expected: String?) {
            if actual != expected { problems.append("\(field) \(actual ?? "nil") ≠ \(expected ?? "nil")") }
        }
        for (field, value) in expect {
            switch field {
            case "kind": mismatch(field, first.kind.rawValue, value.string)
            case "start": mismatch(field, first.start.map { DateText.iso($0, calendar: calendar) }, value.string)
            case "date": mismatch(field, first.start.map { DateText.day($0, calendar: calendar) }, value.string)
            case "deadline_date": mismatch(field, first.deadline.map { DateText.day($0, calendar: calendar) }, value.string)
            case "minutes": mismatch(field, first.minutes.map(String.init), value.int.map(String.init))
            case "priority": mismatch(field, first.priority.map { ["urgent", "important", "normal"][$0.rawValue] }, value.string)
            case "category": if !drafts.contains(where: { $0.category?.rawValue == value.string }) { mismatch(field, first.category?.rawValue, value.string) }
            case "effort": mismatch(field, first.effort.map { ["", "light", "medium", "hard"][$0.rawValue] }, value.string)
            case "all_day": mismatch(field, String(first.isAllDay), value.bool.map(String.init))
            case "place": if !(first.place ?? "").contains(value.string ?? "") { mismatch(field, first.place, value.string) }
            case "goal_period": mismatch(field, first.goalPeriod?.rawValue, value.string)
            case "is_large": mismatch(field, String(first.isLarge), value.bool.map(String.init))
            case "items": break
            default: problems.append("unknown field \(field)")
            }
        }
        return problems
    }
}
