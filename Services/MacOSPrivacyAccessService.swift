import Foundation
@preconcurrency import EventKit

enum MacOSPrivacyRequirementStatus: Equatable, Sendable {
    case ready
    case notDetermined
    case denied
    case restricted
    case unsupported
    case failed(String)

    var isReady: Bool {
        self == .ready
    }

    var isBlocking: Bool {
        switch self {
        case .ready, .unsupported:
            false
        case .notDetermined, .denied, .restricted, .failed:
            true
        }
    }
}

struct MacOSPrivacyAccessService: Sendable {
    private let statusProvider: @Sendable (ToolPermissionRequirement) async -> MacOSPrivacyRequirementStatus

    init(
        statusProvider: @escaping @Sendable (ToolPermissionRequirement) async -> MacOSPrivacyRequirementStatus = MacOSPrivacyAccessService.systemStatus(for:)
    ) {
        self.statusProvider = statusProvider
    }

    func check(tools: [ToolDefinition]) async -> MacOSPrivacyAccessReport {
        let requirements = Self.automaticallyCheckedRequirements(in: tools)
        guard !requirements.isEmpty else {
            return MacOSPrivacyAccessReport(
                state: .ready,
                detail: "No exposed tools require an automatically checked macOS privacy service.",
                checkedRequirements: []
            )
        }

        var statuses: [ToolPermissionRequirement: MacOSPrivacyRequirementStatus] = [:]
        for requirement in requirements {
            statuses[requirement] = await statusProvider(requirement)
        }
        return Self.report(requirements: requirements, statuses: statuses)
    }

    static func automaticallyCheckedRequirements(in tools: [ToolDefinition]) -> [ToolPermissionRequirement] {
        let requirements = tools.flatMap(\.permissionRequirements)
        let checked = requirements.filter { requirement in
            switch requirement {
            case .reminders:
                true
            default:
                false
            }
        }
        return ToolPermissionRequirement.normalized(checked)
    }

    static func report(
        requirements: [ToolPermissionRequirement],
        statuses: [ToolPermissionRequirement: MacOSPrivacyRequirementStatus]
    ) -> MacOSPrivacyAccessReport {
        let normalizedRequirements = ToolPermissionRequirement.normalized(requirements)
        let blockingRequirements = normalizedRequirements.filter { requirement in
            (statuses[requirement] ?? .unsupported).isBlocking
        }

        guard !blockingRequirements.isEmpty else {
            let names = normalizedRequirements.map(\.title).joined(separator: ", ")
            return MacOSPrivacyAccessReport(
                state: .ready,
                detail: names.isEmpty
                    ? "No exposed tools require an automatically checked macOS privacy service."
                    : "macOS privacy access is ready for \(names).",
                checkedRequirements: normalizedRequirements
            )
        }

        let names = blockingRequirements.map(\.title).joined(separator: ", ")
        let failedMessages = blockingRequirements.compactMap { requirement -> String? in
            if case .failed(let message) = statuses[requirement] {
                return "\(requirement.title): \(message)"
            }
            return nil
        }
        let detail = failedMessages.isEmpty
            ? "Grant \(names) access to MacRemote in System Settings, then relaunch MacRemote before starting the server."
            : failedMessages.joined(separator: " ")

        return MacOSPrivacyAccessReport(
            state: .required(blockingRequirements),
            detail: detail,
            checkedRequirements: normalizedRequirements
        )
    }

    private static func systemStatus(for requirement: ToolPermissionRequirement) async -> MacOSPrivacyRequirementStatus {
        switch requirement {
        case .reminders:
            await remindersStatus()
        default:
            .unsupported
        }
    }

    private static func remindersStatus() async -> MacOSPrivacyRequirementStatus {
        let status = EKEventStore.authorizationStatus(for: .reminder)
        switch status {
        case .fullAccess:
            return .ready
        case .notDetermined:
            return await requestRemindersAccess()
        case .denied:
            return .denied
        case .restricted:
            return .restricted
        case .writeOnly:
            return .denied
        @unknown default:
            return .failed("Unknown Reminders authorization status.")
        }
    }

    private static func requestRemindersAccess() async -> MacOSPrivacyRequirementStatus {
        let eventStore = EKEventStore()
        return await withCheckedContinuation { continuation in
            eventStore.requestFullAccessToReminders { granted, error in
                if granted {
                    continuation.resume(returning: .ready)
                } else if let error {
                    continuation.resume(returning: .failed(error.localizedDescription))
                } else {
                    continuation.resume(returning: .denied)
                }
            }
        }
    }
}
