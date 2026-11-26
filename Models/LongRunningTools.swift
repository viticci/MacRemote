import Foundation

/// The tools the owner marked Long-Running (SPEC D81). In an app that
/// supports MCP Tasks, a call to one of them starts in the background at
/// once instead of after the usual 20 seconds. Other apps wait for the
/// result as before.
///
/// This changes only how the answer is delivered. It never touches
/// `tools.json`, a security fingerprint, a permission epoch, or an approval.
enum LongRunningTools {
    static let defaultsKey = "MacRemote.longRunningToolIDs"

    /// The saved tool IDs. A missing value means none.
    static func toolIDs(in userDefaults: UserDefaults) -> Set<String> {
        Set(userDefaults.stringArray(forKey: defaultsKey) ?? [])
    }

    static func save(_ toolIDs: Set<String>, to userDefaults: UserDefaults) {
        userDefaults.set(toolIDs.sorted(), forKey: defaultsKey)
    }
}
