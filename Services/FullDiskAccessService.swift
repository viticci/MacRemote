import Foundation

/// Full Disk Access readiness for shared tools that declare the requirement.
///
/// macOS attributes a command-line tool to the app that launched it, so the
/// tools MacRemote starts can read protected data exactly when MacRemote
/// itself can. The check is therefore one read of a protected folder from
/// inside the app, and MacRemote.app is the only thing the owner is asked to
/// add in System Settings. Asking them to add interpreters such as Python or
/// a shell would hand Full Disk Access to every script on the Mac.
struct FullDiskAccessService: Sendable {
    private let runner = ProcessRunner()

    func check(environment: [String: String], tools: [ToolDefinition]) async -> FullDiskAccessReport {
        let protectedTools = tools.filter { $0.permissionRequirements.contains(.fullDiskAccess) }

        guard !protectedTools.isEmpty else {
            return FullDiskAccessReport(
                state: .ready,
                detail: "No shared tools currently require Full Disk Access.",
                targets: [],
                automaticChecksPassed: true
            )
        }

        let targets = await permissionTargets(tools: protectedTools)
        let signature = Self.confirmationSignature(for: protectedTools, targets: targets)
        switch targets.first?.accessState {
        case .working:
            return FullDiskAccessReport(
                state: .ready,
                detail: "MacRemote has Full Disk Access, and the tools it starts use it.",
                targets: targets,
                confirmationSignature: signature,
                automaticChecksPassed: true
            )
        case .blocked:
            let signingWarning = await hostAppSigningWarning()
            return FullDiskAccessReport(
                state: .required,
                detail: appendSigningWarning(
                    "MacRemote does not have Full Disk Access. Add MacRemote in System Settings, then relaunch.",
                    signingWarning
                ),
                targets: targets,
                confirmationSignature: signature
            )
        default:
            // Nothing to test against on this account, or not running from an
            // app bundle: say so and let the owner confirm, rather than claim
            // a check passed.
            return FullDiskAccessReport(
                state: .confirmationRequired,
                detail: "MacRemote could not test Full Disk Access on this Mac. If MacRemote is listed and turned on in System Settings, confirm the setup below.",
                targets: targets,
                requiresManualConfirmation: true,
                confirmationSignature: signature
            )
        }
    }

    func openHelper(environment: [String: String], tools: [ToolDefinition]) async -> FullDiskAccessReport {
        let protectedTools = tools.filter { $0.permissionRequirements.contains(.fullDiskAccess) }
        let targets = await permissionTargets(tools: protectedTools)
        let signature = Self.confirmationSignature(for: protectedTools, targets: targets)

        // MacRemote's Access Fixer already lists, drags, and copies every
        // target, so open System Settings directly.
        return await openSystemFullDiskAccessSettings(
            targets: targets,
            requiresManualConfirmation: !protectedTools.isEmpty,
            confirmationSignature: signature
        )
    }

    func permissionTargets(environment _: [String: String], tools: [ToolDefinition]) async -> [FullDiskAccessTarget] {
        await permissionTargets(tools: tools)
    }

    private func permissionTargets(tools: [ToolDefinition]) async -> [FullDiskAccessTarget] {
        await probedTargets(Self.layeredTargets(for: tools))
    }

    // MARK: - Per-target access probes

    /// Directories macOS only lets Full Disk Access holders read, most
    /// relevant first. Existence is checked with metadata (allowed without
    /// FDA); probing a missing path would misread "no such directory" as "no
    /// access". macOS 27 no longer creates the per-user TCC directory, which
    /// made the original single-sentinel probe report Blocked forever.
    static let protectedSentinelCandidates = [
        NSHomeDirectory() + "/Library/Group Containers/group.com.apple.reminders/Container_v1/Stores",
        NSHomeDirectory() + "/Library/Safari",
        NSHomeDirectory() + "/Library/Application Support/com.apple.TCC"
    ]

    static func resolvedProtectedSentinelPath() -> String? {
        protectedSentinelCandidates.first { FileManager.default.fileExists(atPath: $0) }
    }

    /// Fills `accessState` by reading a protected folder from inside the app.
    private func probedTargets(_ targets: [FullDiskAccessTarget]) async -> [FullDiskAccessTarget] {
        // No protected folder to test against on this account: stay .unknown
        // rather than invent a Blocked verdict.
        guard let sentinel = Self.resolvedProtectedSentinelPath() else { return targets }
        return targets.map { target in
            var probed = target
            // The in-process read only speaks for the running app.
            if target.path == Bundle.main.bundleURL.path {
                probed.accessState =
                    (try? FileManager.default.contentsOfDirectory(atPath: sentinel)) != nil ? .working : .blocked
            }
            return probed
        }
    }

    private func openSystemFullDiskAccessSettings(
        targets: [FullDiskAccessTarget],
        requiresManualConfirmation: Bool,
        confirmationSignature: String
    ) async -> FullDiskAccessReport {
        do {
            let result = try await runner.run(
                executablePath: "/usr/bin/open",
                arguments: ["x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles"],
                timeoutSeconds: 8,
                outputByteLimit: 128 * 1024
            )

            guard result.succeeded || result.timedOut else {
                return FullDiskAccessReport(
                    state: .failed("Could not open Full Disk Access settings."),
                    detail: result.stderr.isEmpty ? result.stdout : result.stderr,
                    targets: targets,
                    confirmationSignature: confirmationSignature
                )
            }

            return FullDiskAccessReport(
                state: .helperOpened,
                detail: "Opened macOS Full Disk Access settings. Add MacRemote, turn it on, then relaunch MacRemote.",
                targets: targets,
                requiresManualConfirmation: requiresManualConfirmation,
                confirmationSignature: confirmationSignature
            )
        } catch {
            return FullDiskAccessReport(
                state: .failed(error.localizedDescription),
                detail: "Could not open macOS Full Disk Access settings.",
                targets: targets,
                confirmationSignature: confirmationSignature
            )
        }
    }

    // MARK: - Target inference

    /// What the owner adds in System Settings: MacRemote.app, and nothing else.
    static func layeredTargets(for tools: [ToolDefinition]) -> [FullDiskAccessTarget] {
        let bundleURL = Bundle.main.bundleURL
        guard !tools.isEmpty, bundleURL.pathExtension == "app" else { return [] }
        return [
            FullDiskAccessTarget(
                title: bundleURL.lastPathComponent,
                path: bundleURL.path,
                subtitle: "MacRemote starts the command-line tools you share, and macOS gives them MacRemote's access."
            )
        ]
    }

    static func confirmationSignature(for tools: [ToolDefinition], targets: [FullDiskAccessTarget]) -> String {
        let toolPart = tools
            .map { "\($0.id)=\($0.executablePath)" }
            .sorted()
            .joined(separator: "|")
        let targetPart = targets
            .map { "hostApp=\($0.path)" }
            .sorted()
            .joined(separator: "|")
        return "\(toolPart)#\(targetPart)"
    }

    // MARK: - Host app signing

    private func hostAppSigningWarning() async -> String? {
        let bundleURL = Bundle.main.bundleURL
        guard bundleURL.pathExtension == "app" else { return nil }

        do {
            let designated = try await runner.run(
                executablePath: "/usr/bin/codesign",
                arguments: ["-dr", "-", bundleURL.path],
                timeoutSeconds: 5,
                outputByteLimit: 128 * 1024
            )
            let details = try await runner.run(
                executablePath: "/usr/bin/codesign",
                arguments: ["-dv", "--verbose=2", bundleURL.path],
                timeoutSeconds: 5,
                outputByteLimit: 128 * 1024
            )
            let output = [designated.stdout, designated.stderr, details.stdout, details.stderr].joined(separator: "\n")
            guard output.contains("designated => cdhash") else {
                return nil
            }
            return "This local MacRemote build has a cdhash-only code requirement, so a rebuilt app can leave a stale Full Disk Access row behind. If System Settings already shows access enabled, remove the old row, add the current MacRemote.app again, then relaunch."
        } catch {
            return nil
        }
    }

    private func appendSigningWarning(_ detail: String, _ warning: String?) -> String {
        guard let warning, !warning.isEmpty else {
            return detail
        }
        guard !detail.isEmpty else {
            return warning
        }
        return "\(detail) \(warning)"
    }
}
