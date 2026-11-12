import Foundation

/// The stronger consent line shown before an Always Allow grant lands on a tool
/// whose catalog default is to ask every time.
///
/// An explicit grant is honored for every tool — the owner's decision wins. What
/// `approvalPolicy` still buys is this sentence: the twelve marked tools are the
/// ones where "without asking" means something broader than usual, so the app
/// says so once, at the verb, before the grant is written (GUIDELINES §4.1.13).
enum AlwaysAllowConsequence {
    /// `nil` for ordinary tools — they keep the canonical Always Allow caption.
    static func text(for tool: ToolDefinition, clientName: String) -> String? {
        guard tool.approvalPolicy == .everyCall else { return nil }

        var sentences: [String] = []
        if tool.isGenericCLIAdapter {
            sentences.append(
                "\(clientName) can run any \(commandName(for: tool)) command without asking, and MacRemote normally asks you every time."
            )
        } else {
            sentences.append(
                "\(clientName) can run \(tool.name) without asking, and MacRemote normally asks you every time."
            )
        }
        // Only claimed for the CLIs whose argument list is actually policed.
        if FirstPartyFlexibleCommandPolicy.blocksCredentialCommands(in: tool) {
            sentences.append("Sign-in and credential commands stay blocked.")
        }
        sentences.append("You can undo this in Apps.")
        return sentences.joined(separator: " ")
    }

    /// The command as the user knows it — "pocketctl", not its full path.
    static func commandName(for tool: ToolDefinition) -> String {
        let name = URL(fileURLWithPath: tool.executablePath).lastPathComponent
        return name.isEmpty ? tool.name : name
    }
}
