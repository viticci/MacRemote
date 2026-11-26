import SwiftUI

/// Settings › General ▸ Result Cards (SPEC D77). One switch for every card,
/// then, while cards are on, one switch per tool family. The family switches
/// are hidden while cards are off: a column of "on" switches under an "off"
/// main switch read as cards still showing for those families (D78).
struct ResultCardsSettingsSection: View {
    @Environment(AppModel.self) private var appModel

    var body: some View {
        @Bindable var appModel = appModel
        let showsCards = appModel.resultCardPreferences.showsCards

        Section {
            Toggle(isOn: $appModel.resultCardPreferences.showsCards) {
                Text("Show result cards")
                Text("Apps that can draw them, such as Claude and ChatGPT, show each tool result as a card. When this is off, results come back as plain text.")
            }

            if showsCards {
                let families = appModel.resultCardFamilies
                if families.isEmpty {
                    Text("No shared tools yet.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(families) { family in
                        Toggle(family.name, isOn: Binding(
                            get: { appModel.isResultCardFamilyOn(family) },
                            set: { appModel.setResultCardFamily(family, isOn: $0) }
                        ))
                    }
                }
            }
        } header: {
            Text("Result Cards")
        } footer: {
            Text("Apps pick up a change the next time they reload your tools.")
        }
    }
}
