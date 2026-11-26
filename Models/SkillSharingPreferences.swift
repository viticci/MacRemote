import Foundation

/// Which skills the server offers to connected apps (SPEC D84).
///
/// Skill text reaches an app's model as instructions, so sharing is the
/// owner's choice and fail-closed: MacRemote's own skill is shared until the
/// owner turns it off, and every other skill is not shared until the owner
/// turns it on. Choices are keyed by `Skill.id`, which names the source and
/// the skill, so a refreshed skill keeps its choice.
struct SkillSharingPreferences: Equatable, Sendable {
    static let choicesKey = "MacRemote.skills.shared"

    /// The owner's explicit choices. A skill with none uses its default.
    var choices: [String: Bool]

    init(choices: [String: Bool] = [:]) {
        self.choices = choices
    }

    init(userDefaults: UserDefaults) {
        self.init(choices: userDefaults.dictionary(forKey: Self.choicesKey) as? [String: Bool] ?? [:])
    }

    func save(to userDefaults: UserDefaults) {
        userDefaults.set(choices, forKey: Self.choicesKey)
    }

    func isShared(_ skill: Skill) -> Bool {
        choices[skill.id] ?? (skill.origin == .builtIn)
    }
}
