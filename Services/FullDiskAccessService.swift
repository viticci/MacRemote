import Foundation

struct FullDiskAccessService: Sendable {
    private let runner = ProcessRunner()

    func check(environment: [String: String]) async -> FullDiskAccessReport {
        let targets = await permissionTargets(environment: environment)

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
                    state: .failed("Could not parse remctl doctor output."),
                    detail: result.stderr.isEmpty ? result.stdout : result.stderr,
                    targets: targets
                )
            }

            if (json["ok"] as? Bool) == true {
                return FullDiskAccessReport(
                    state: .ready,
                    detail: "remctl doctor passes from the MacRemote process context.",
                    targets: targets
                )
            }

            let detail = doctorFailureDetail(from: json, fallback: result.stderr)
            return FullDiskAccessReport(
                state: .required,
                detail: detail,
                targets: targets
            )
        } catch {
            return FullDiskAccessReport(
                state: .failed(error.localizedDescription),
                detail: "Could not run remctl doctor from MacRemote.",
                targets: targets
            )
        }
    }

    func openHelper(environment: [String: String]) async -> FullDiskAccessReport {
        let targets = await permissionTargets(environment: environment)

        do {
            let result = try await runner.run(
                executablePath: RemCTLToolCatalog.executablePath,
                arguments: ["permissions", "full-disk-access"],
                timeoutSeconds: 8,
                outputByteLimit: 128 * 1024,
                environment: environment
            )

            if result.succeeded {
                return FullDiskAccessReport(
                    state: .helperOpened,
                    detail: "Opened RemCTL's guided Full Disk Access helper. Add the listed targets, relaunch MacRemote, then check again.",
                    targets: targets
                )
            }

            return FullDiskAccessReport(
                state: .failed("Could not open the RemCTL permission helper."),
                detail: result.stderr.isEmpty ? result.stdout : result.stderr,
                targets: targets
            )
        } catch {
            return FullDiskAccessReport(
                state: .failed(error.localizedDescription),
                detail: "Could not launch the RemCTL permission helper.",
                targets: targets
            )
        }
    }

    private func permissionTargets(environment: [String: String]) async -> [FullDiskAccessTarget] {
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
                    subtitle: rawTarget["subtitle"] as? String ?? ""
                )
            }
        } catch {
            return []
        }
    }

    private func doctorFailureDetail(from json: [String: Any], fallback: String) -> String {
        if let checks = json["checks"] as? [[String: Any]] {
            let failed = checks
                .filter { ($0["status"] as? String) == "fail" }
                .compactMap { $0["name"] as? String }
            if !failed.isEmpty {
                if failed.contains("database") || failed.contains("store_dir") {
                    return "MacRemote cannot read the local Reminders database from its app-launched RemCTL process. Grant Full Disk Access to the targets below, relaunch MacRemote, then check again."
                }

                let checkList = failed.joined(separator: ", ")
                return "remctl doctor failed from MacRemote for: \(checkList). Resolve those checks, relaunch MacRemote, then check again."
            }
        }

        if let context = json["context"] as? [String: Any],
           let effectiveContext = context["effective_context"] as? String {
            return "Full Disk Access is required for \(effectiveContext). Grant access to the listed targets, relaunch MacRemote, then check again."
        }

        return fallback.isEmpty ? "Full Disk Access is required before exposing full RemCTL tools." : fallback
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
