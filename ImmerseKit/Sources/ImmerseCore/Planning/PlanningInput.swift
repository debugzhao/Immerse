import Foundation

/// ⌘K prefixes for capturing ideas and goals (pure, easy to test)
public enum PlanningInput {
    private static let ideaPrefixes = ["想法", "灵感", "idea"]
    private static let goalPrefixes: [(String, GoalPeriod)] = [("本周目标", .week), ("本月目标", .month), ("目标", .month)]
    private static let separators = CharacterSet(charactersIn: ":：,， ")

    /// "想法：找全球工作的 Agent" → true
    public static func isExplicitIdea(_ text: String) -> Bool {
        ideaPrefixes.contains { text.lowercased().hasPrefix($0) && text.count > $0.count }
    }

    /// Title to store for an idea: drops a leading "想法：" if present
    public static func idea(from text: String) -> String {
        for prefix in ideaPrefixes where text.lowercased().hasPrefix(prefix) {
            let rest = String(text.dropFirst(prefix.count)).trimmingCharacters(in: separators)
            if !rest.isEmpty { return rest }
        }
        return text
    }

    /// "本月目标：读完《纳瓦尔宝典》" → (读完《纳瓦尔宝典》, .month). nil when there's no goal prefix
    public static func goal(from text: String) -> (title: String, period: GoalPeriod)? {
        for (prefix, period) in goalPrefixes where text.hasPrefix(prefix) {
            let rest = String(text.dropFirst(prefix.count)).trimmingCharacters(in: separators)
            if !rest.isEmpty { return (rest, period) }
        }
        return nil
    }
}
