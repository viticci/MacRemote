import Foundation

/// Result cards (SPEC D77): one global switch plus a per-family switch, read by
/// the server on every request. Presentation only; no tool definition changes.
extension AppModel {
    /// Families of the shared tools that can show a card, sorted by name.
    var resultCardFamilies: [ToolFamily] {
        ToolFamily.families(of: allTools.filter { tool in
            isToolExposed(tool) && LocalMCPServer.widgetEligible(tool: tool)
        })
    }

    /// The family's own switch, regardless of the global one.
    func isResultCardFamilyOn(_ family: ToolFamily) -> Bool {
        !resultCardPreferences.hiddenFamilyIDs.contains(family.id)
    }

    func setResultCardFamily(_ family: ToolFamily, isOn: Bool) {
        if isOn {
            resultCardPreferences.hiddenFamilyIDs.remove(family.id)
        } else {
            resultCardPreferences.hiddenFamilyIDs.insert(family.id)
        }
    }

    /// One line for the Tools inspector saying whether this tool's results
    /// show as a card, and why not.
    func resultCardStatus(for tool: ToolDefinition) -> String {
        guard LocalMCPServer.widgetEligible(tool: tool) else { return "Plain text for this tool" }
        guard resultCardPreferences.showsCards else { return "Off in Settings" }
        let family = ToolFamily(tool)
        return isResultCardFamilyOn(family) ? "On" : "Off for \(family.name)"
    }
}
