import Foundation

/// Which tool results an app may draw as a result card (SPEC D77).
///
/// Off by default: a fresh install, and an install that never saved a value,
/// returns plain text everywhere. When cards are on, each tool family can be
/// turned off on its own. A catalog-authored `automatic: false` presentation
/// still suppresses the card regardless of this choice.
///
/// This is presentation only. It never changes a tool's contract, security
/// fingerprint, permission epoch, or anything in `tools.json`.
struct ResultCardPreferences: Equatable, Sendable {
    static let showsCardsKey = "MacRemote.resultCards.enabled"
    static let hiddenFamiliesKey = "MacRemote.resultCards.hiddenFamilies"

    /// Every eligible tool shows its card. For tests and embedders that do
    /// not read the owner's saved choice.
    static let everyTool = ResultCardPreferences(showsCards: true)

    var showsCards: Bool
    /// `ToolFamily.id`s whose cards the owner turned off.
    var hiddenFamilyIDs: Set<String>

    init(showsCards: Bool = false, hiddenFamilyIDs: Set<String> = []) {
        self.showsCards = showsCards
        self.hiddenFamilyIDs = hiddenFamilyIDs
    }

    /// The owner's saved choice. A missing value means off.
    init(userDefaults: UserDefaults) {
        self.init(
            showsCards: userDefaults.bool(forKey: Self.showsCardsKey),
            hiddenFamilyIDs: Set(userDefaults.stringArray(forKey: Self.hiddenFamiliesKey) ?? [])
        )
    }

    func save(to userDefaults: UserDefaults) {
        userDefaults.set(showsCards, forKey: Self.showsCardsKey)
        userDefaults.set(hiddenFamilyIDs.sorted(), forKey: Self.hiddenFamiliesKey)
    }

    func showsCards(forFamily familyID: String) -> Bool {
        showsCards && !hiddenFamilyIDs.contains(familyID)
    }

    /// The owner's side of the decision. The server also requires the tool
    /// to be eligible for a card at all.
    func allowsCard(for tool: ToolDefinition) -> Bool {
        guard showsCards else { return false }
        return hiddenFamilyIDs.isEmpty || !hiddenFamilyIDs.contains(ToolFamily(tool).id)
    }
}
