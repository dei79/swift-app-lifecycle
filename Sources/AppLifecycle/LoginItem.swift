import ServiceManagement

/// "Open at Login" via SMAppService.
@MainActor
public enum LoginItem {
    public enum State: Equatable, Sendable {
        case enabled
        /// Registered, but the user still has to allow it in System Settings › Login Items.
        case requiresApproval
        case disabled
    }

    public static var state: State {
        switch SMAppService.mainApp.status {
        case .enabled: return .enabled
        case .requiresApproval: return .requiresApproval
        default: return .disabled
        }
    }

    public static var isEnabled: Bool { state != .disabled }

    /// Pass the active recovery instance to update monitoring immediately after a change.
    public static func setEnabled(_ enabled: Bool, recovery: CrashRecovery? = nil) throws {
        defer { recovery?.refresh() }
        if enabled {
            try SMAppService.mainApp.register()
        } else {
            try SMAppService.mainApp.unregister()
        }
    }

    public static func openSystemSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}
