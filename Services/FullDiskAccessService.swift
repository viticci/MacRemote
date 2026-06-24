import Foundation

struct FullDiskAccessService: Sendable {
    private let runner = ProcessRunner()

    func check(environment: [String: String], tools: [ToolDefinition]) async -> FullDiskAccessReport {
        let protectedTools = tools.filter { $0.permissionRequirements.contains(.fullDiskAccess) }
        let targets = await permissionTargets(environment: environment, tools: protectedTools)
        let signature = Self.confirmationSignature(for: protectedTools, targets: targets)
        let signingWarning = await hostAppSigningWarning()

        guard !protectedTools.isEmpty else {
            return FullDiskAccessReport(
                state: .ready,
                detail: "No exposed tools currently require Full Disk Access.",
                targets: targets,
                automaticChecksPassed: true
            )
        }

        let remCTLTools = protectedTools.filter(Self.isRemCTLTool)
        let manuallyVerifiedTools = protectedTools.filter { !Self.isRemCTLTool($0) }
        var automaticChecksPassed = remCTLTools.isEmpty

        if !remCTLTools.isEmpty {
            do {
                let result = try await runner.run(
                    executablePath: RemCTLToolCatalog.executablePath,
                    arguments: ["doctor", "--for-agent", "--json"],
                    timeoutSeconds: 10,
                    outputByteLimit: 512 * 1024,
                    environment: environment
                )

                guard let json = parseJSONObject(result.stdout) else {
                    return FullDiskAccessReport(
                        state: .failed("Could not parse access diagnostic output."),
                        detail: appendSigningWarning(result.stderr.isEmpty ? result.stdout : result.stderr, signingWarning),
                        targets: targets,
                        confirmationSignature: signature
                    )
                }

                guard (json["ok"] as? Bool) == true else {
                    let detail = appendSigningWarning(doctorFailureDetail(from: json, fallback: result.stderr), signingWarning)
                    let failedChecks = Self.failedCheckNames(from: json)
                    let state: FullDiskAccessState = Self.failedChecksRequireFullDiskAccess(failedChecks)
                        ? .required
                        : .failed("RemCTL diagnostic failed")
                    return FullDiskAccessReport(
                        state: state,
                        detail: detail,
                        targets: targets,
                        confirmationSignature: signature
                    )
                }

                automaticChecksPassed = true
            } catch {
                return FullDiskAccessReport(
                    state: .failed(error.localizedDescription),
                    detail: appendSigningWarning("Could not run the RemCTL access diagnostic from MacRemote.", signingWarning),
                    targets: targets,
                    confirmationSignature: signature
                )
            }
        }

        if !manuallyVerifiedTools.isEmpty {
            let toolNames = manuallyVerifiedTools.map(\.name).sorted().joined(separator: ", ")
            return FullDiskAccessReport(
                state: .confirmationRequired,
                detail: appendSigningWarning("Automatic protected-data checks passed where available. MacRemote cannot safely prove \(toolNames) without running tool-specific commands, so confirm this setup after granting the targets below.", signingWarning),
                targets: targets,
                requiresManualConfirmation: true,
                confirmationSignature: signature,
                automaticChecksPassed: automaticChecksPassed
            )
        }

        return FullDiskAccessReport(
            state: .ready,
            detail: appendSigningWarning("Protected-data diagnostic passed from the MacRemote process context.", signingWarning),
            targets: targets,
            confirmationSignature: signature,
            automaticChecksPassed: automaticChecksPassed
        )
    }

    func openHelper(environment: [String: String], tools: [ToolDefinition]) async -> FullDiskAccessReport {
        let protectedTools = tools.filter { $0.permissionRequirements.contains(.fullDiskAccess) }
        let targets = await permissionTargets(environment: environment, tools: protectedTools)
        let signature = Self.confirmationSignature(for: protectedTools, targets: targets)
        let includesRemCTL = protectedTools.contains(where: Self.isRemCTLTool)
        let requiresManualConfirmation = protectedTools.contains { !Self.isRemCTLTool($0) }

        guard includesRemCTL else {
            return await openSystemFullDiskAccessSettings(
                targets: targets,
                requiresManualConfirmation: requiresManualConfirmation,
                confirmationSignature: signature
            )
        }

        do {
            let result = try await runner.run(
                executablePath: RemCTLToolCatalog.executablePath,
                arguments: ["permissions", "full-disk-access"],
                timeoutSeconds: 8,
                outputByteLimit: 128 * 1024,
                environment: environment
            )

            if result.succeeded || result.timedOut {
                return FullDiskAccessReport(
                    state: .helperOpened,
                    detail: "Opened the guided Full Disk Access setup. Add every listed target. If System Settings already shows access enabled, relaunch MacRemote so macOS refreshes this process's permission state, then check again.",
                    targets: targets,
                    requiresManualConfirmation: requiresManualConfirmation,
                    confirmationSignature: signature
                )
            }

            return FullDiskAccessReport(
                state: .failed("Could not open guided Full Disk Access setup."),
                detail: result.stderr.isEmpty ? result.stdout : result.stderr,
                targets: targets,
                confirmationSignature: signature
            )
        } catch {
            return FullDiskAccessReport(
                state: .failed(error.localizedDescription),
                detail: "Could not launch guided Full Disk Access setup.",
                targets: targets,
                confirmationSignature: signature
            )
        }
    }

    func permissionTargets(environment: [String: String], tools: [ToolDefinition]) async -> [FullDiskAccessTarget] {
        let inferredTargets = Self.layeredTargets(for: tools)
        let helperTargets = tools.contains(where: Self.isRemCTLTool)
            ? await remCTLPermissionTargets(environment: environment)
            : []
        return Self.mergedTargets(inferredTargets + helperTargets)
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
                detail: "Opened macOS Full Disk Access settings. Add every listed target, relaunch MacRemote, then confirm the setup for tools MacRemote cannot automatically verify.",
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

    private func remCTLPermissionTargets(environment: [String: String]) async -> [FullDiskAccessTarget] {
        do {
            let result = try await runner.run(
                executablePath: RemCTLToolCatalog.executablePath,
                arguments: ["permissions", "full-disk-access", "--json"],
                timeoutSeconds: 5,
                outputByteLimit: 128 * 1024,
                environment: environment
            )
            guard let json = parseJSONObject(result.stdout),
                  let rawTargets = json["targets"] as? [[String: Any]] else {
                return []
            }
            return rawTargets.compactMap { rawTarget in
                guard let title = rawTarget["title"] as? String,
                      let path = rawTarget["path"] as? String else {
                    return nil
                }
                return FullDiskAccessTarget(
                    title: title,
                    path: path,
                    subtitle: displaySubtitle(rawTarget["subtitle"] as? String ?? ""),
                    role: helperTargetRole(
                        title: title,
                        path: path,
                        subtitle: rawTarget["subtitle"] as? String ?? ""
                    )
                )
            }
        } catch {
            return []
        }
    }

    static func layeredTargets(for tools: [ToolDefinition]) -> [FullDiskAccessTarget] {
        guard !tools.isEmpty else { return [] }

        var targets: [FullDiskAccessTarget] = []
        let bundleURL = Bundle.main.bundleURL
        if bundleURL.pathExtension == "app" {
            targets.append(FullDiskAccessTarget(
                title: bundleURL.lastPathComponent,
                path: bundleURL.path,
                subtitle: "Host app. Required because MacRemote launches FDA-required command-line tools.",
                role: .hostApp
            ))
        }

        let toolsByExecutable = Dictionary(grouping: tools, by: \.executablePath)
        for executablePath in toolsByExecutable.keys.sorted() {
            let executableTools = toolsByExecutable[executablePath] ?? []
            let targetName = targetDisplayName(for: executablePath, tools: executableTools)
            let executablePaths = executableTargetPaths(for: executablePath)
            for (index, executablePath) in executablePaths.enumerated() where FileManager.default.isExecutableFile(atPath: executablePath) {
                let isPrimaryPath = index == 0
                targets.append(FullDiskAccessTarget(
                    title: isPrimaryPath ? "\(targetName) executable" : "\(targetName) resolved executable",
                    path: executablePath,
                    subtitle: isPrimaryPath
                        ? "Tool process for \(targetName). Grant this when macOS attributes protected-data access to the CLI itself."
                        : "Resolved target behind a symlink or wrapper for \(targetName). Some package managers launch this path.",
                    role: .toolExecutable
                ))
            }

            for executablePath in executablePaths {
                if let interpreterPath = scriptInterpreterPath(forExecutableAt: executablePath),
                   !executablePaths.contains(interpreterPath),
                   FileManager.default.isExecutableFile(atPath: interpreterPath) {
                    targets.append(FullDiskAccessTarget(
                        title: "\(targetName) interpreter",
                        path: interpreterPath,
                        subtitle: "Interpreter used by \(targetName). Script-based CLIs often need FDA on the interpreter, not just the script.",
                        role: .toolInterpreter
                    ))
                }
            }
        }

        return mergedTargets(targets)
    }

    static func executableTargetPaths(for path: String) -> [String] {
        var paths = [path]
        let resolvedPath = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
        if resolvedPath != path, FileManager.default.fileExists(atPath: resolvedPath) {
            paths.append(resolvedPath)
        }
        return paths
    }

    private static func targetDisplayName(for executablePath: String, tools: [ToolDefinition]) -> String {
        if tools.count == 1, let name = tools.first?.name {
            return name
        }

        let basename = URL(fileURLWithPath: executablePath).lastPathComponent
        return basename.isEmpty ? "Tool" : basename
    }

    static func scriptInterpreterPath(forExecutableAt path: String) -> String? {
        guard let handle = FileHandle(forReadingAtPath: path) else {
            return nil
        }
        defer { try? handle.close() }

        guard let data = (try? handle.read(upToCount: 512)) ?? nil,
              let firstLine = String(data: data.prefix(512), encoding: .utf8)?
                .split(whereSeparator: \.isNewline)
                .first,
              firstLine.hasPrefix("#!") else {
            return nil
        }

        let shebang = firstLine.dropFirst(2).trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = shebang.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
        guard let interpreter = parts.first else { return nil }

        if URL(fileURLWithPath: interpreter).lastPathComponent == "env" {
            if let command = envCommand(from: Array(parts.dropFirst())) {
                return ExecutableLocator.executablePath(named: command)
            }
            return nil
        }

        return interpreter.hasPrefix("/") ? interpreter : ExecutableLocator.executablePath(named: interpreter)
    }

    private static func envCommand(from arguments: [String]) -> String? {
        var index = 0
        while index < arguments.count {
            let argument = arguments[index]
            if argument == "-u" || argument == "--unset" || argument == "-C" || argument == "--chdir" {
                index += 2
                continue
            }

            if argument == "-S" || argument == "--split-string" {
                index += 1
                continue
            }

            if argument.hasPrefix("-") {
                index += 1
                continue
            }

            if isEnvironmentAssignment(argument) {
                index += 1
                continue
            }

            return argument
        }
        return nil
    }

    private static func isEnvironmentAssignment(_ value: String) -> Bool {
        guard let equalsIndex = value.firstIndex(of: "="), equalsIndex != value.startIndex else {
            return false
        }
        return !value[..<equalsIndex].contains("/")
    }

    static func mergedTargets(_ targets: [FullDiskAccessTarget]) -> [FullDiskAccessTarget] {
        var byPath: [String: FullDiskAccessTarget] = [:]
        for target in targets where !target.path.isEmpty {
            if let existing = byPath[target.path] {
                byPath[target.path] = preferredTarget(existing, target)
            } else {
                byPath[target.path] = target
            }
        }
        return byPath.values.sorted {
            if $0.role.sortOrder != $1.role.sortOrder {
                return $0.role.sortOrder < $1.role.sortOrder
            }
            return $0.title < $1.title
        }
    }

    static func confirmationSignature(for tools: [ToolDefinition], targets: [FullDiskAccessTarget]) -> String {
        let toolPart = tools
            .map { "\($0.id)=\($0.executablePath)" }
            .sorted()
            .joined(separator: "|")
        let targetPart = targets
            .map { "\($0.role.rawValue)=\($0.path)" }
            .sorted()
            .joined(separator: "|")
        return "\(toolPart)#\(targetPart)"
    }

    private static func preferredTarget(_ lhs: FullDiskAccessTarget, _ rhs: FullDiskAccessTarget) -> FullDiskAccessTarget {
        if lhs.role == .helperReported, rhs.role != .helperReported { return rhs }
        if rhs.role == .helperReported, lhs.role != .helperReported { return lhs }
        return lhs.role.sortOrder <= rhs.role.sortOrder ? lhs : rhs
    }

    private static func isRemCTLTool(_ tool: ToolDefinition) -> Bool {
        tool.id.hasPrefix("remctl.") || tool.executablePath == RemCTLToolCatalog.executablePath
    }

    private func displaySubtitle(_ rawSubtitle: String) -> String {
        let subtitle = rawSubtitle.trimmingCharacters(in: .whitespacesAndNewlines)
        let lowercasedSubtitle = subtitle.lowercased()

        if lowercasedSubtitle.contains("direct cli reads"),
           lowercasedSubtitle.contains("reminders database") {
            return "Required when protected local data cannot be read from direct CLI processes."
        }

        if lowercasedSubtitle.contains("host app launches"),
           lowercasedSubtitle.contains("remctl") {
            return "Required when this host app launches tools or agent runners."
        }

        return subtitle
    }

    private func helperTargetRole(title: String, path: String, subtitle: String) -> FullDiskAccessTargetRole {
        let combined = "\(title) \(path) \(subtitle)".lowercased()

        if path.hasSuffix(".app") || combined.contains("host app") {
            return .hostApp
        }

        if combined.contains("interpreter") || combined.contains("python") {
            return .toolInterpreter
        }

        return .helperReported
    }

    private func doctorFailureDetail(from json: [String: Any], fallback: String) -> String {
        if let checks = json["checks"] as? [[String: Any]] {
            let failed = checks
                .filter { ($0["status"] as? String) == "fail" }

            if !failed.isEmpty {
                let failedNames = failed.compactMap { $0["name"] as? String }
                if Self.failedChecksRequireFullDiskAccess(failedNames) {
                    return "MacRemote cannot read protected local data from its app-launched tool process. Grant Full Disk Access to every target below. If System Settings already shows MacRemote enabled, remove that stale row, add the current MacRemote.app again, then use Relaunch MacRemote and check again."
                }

                if failedNames.contains("python"),
                   let context = json["context"] as? [String: Any],
                   let pythonPath = context["python"] as? String {
                    return "MacRemote resolved RemCTL's python3 runtime to \(pythonPath), and that runtime cannot pass RemCTL's diagnostic. MacRemote now prefers user and Homebrew bin directories before macOS system paths; if this persists, install Python 3.10 or newer and make sure python3 is available there."
                }

                let checkList = failedNames.joined(separator: ", ")
                return "RemCTL's diagnostic failed from MacRemote for: \(checkList). Resolve those checks, relaunch MacRemote, then check again."
            }
        }

        if let context = json["context"] as? [String: Any],
           let effectiveContext = context["effective_context"] as? String {
            return "Full Disk Access is required for \(effectiveContext). Grant access to every listed target, relaunch MacRemote, then check again."
        }

        return fallback.isEmpty ? "Full Disk Access is required before exposing protected-data tools." : fallback
    }

    static func failedCheckNames(from json: [String: Any]) -> [String] {
        guard let checks = json["checks"] as? [[String: Any]] else {
            return []
        }

        return checks
            .filter { ($0["status"] as? String) == "fail" }
            .compactMap { $0["name"] as? String }
    }

    static func failedChecksRequireFullDiskAccess(_ failedChecks: [String]) -> Bool {
        if failedChecks.isEmpty {
            return true
        }

        let protectedDataChecks: Set<String> = ["database", "store_dir"]
        return failedChecks.contains { protectedDataChecks.contains($0) }
    }

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

    private func parseJSONObject(_ string: String) -> [String: Any]? {
        guard let data = string.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data),
              let json = object as? [String: Any] else {
            return nil
        }
        return json
    }
}
