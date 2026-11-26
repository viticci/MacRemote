/// A count with its noun, singular only for exactly one: "1 tool", "3 tools".
/// Use it wherever a live count is shown, so a single item never reads "1 tools".
func counted(_ count: Int, _ noun: String) -> String {
    count == 1 ? "1 \(noun)" : "\(count) \(noun)s"
}
