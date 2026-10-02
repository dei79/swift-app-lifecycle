import AppKit
import RecoveryCore
import ServiceManagement
import os

@main
struct RecoveryHelper {
    @MainActor
    static func main() async {
        let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "AppLifecycle", category: "Recovery")
        let arguments = CommandLine.arguments
        guard arguments.count >= 2, let pid = Int32(arguments[1]), pid > 1,
              getppid() == pid,
              Bundle.main.bundleURL.pathExtension == "app",
              let bundleID = Bundle.main.bundleIdentifier else { exit(EXIT_FAILURE) }
        let appURL = Bundle.main.bundleURL
        // Listen independently: the main app may already have crashed during logout.
        let observer = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.willPowerOffNotification, object: nil, queue: .main
        ) { _ in exit(EXIT_SUCCESS) }
        defer { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
        do {
            let monitor = try ExitMonitor(pid: pid, controlFD: STDIN_FILENO)
            try FileHandle.standardOutput.write(contentsOf: Data([1]))
            guard await Task.detached(operation: { monitor.waitForCrash() }).value else { return }
            try await Task.sleep(for: .seconds(2))
            // Recheck the OS setting so revocation in System Settings is respected.
            guard SMAppService.mainApp.status == .enabled,
                  FileManager.default.fileExists(atPath: appURL.path),
                  !NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).contains(where: {
                      $0.processIdentifier != getpid() && !$0.isTerminated
                  }) else { return }
            let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent(bundleID, isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let history = directory.appendingPathComponent("crash-recovery.json")
            let data = FileManager.default.fileExists(atPath: history.path) ? try Data(contentsOf: history) : nil
            guard let budget = RecoveryBudget(data: data).next() else {
                logger.error("Automatic restart limit reached. Open the app manually to try again.")
                return
            }
            // Save before launch; this remains intact even if the next process crashes at startup.
            try budget.data.write(to: history, options: .atomic)
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = false
            _ = try await NSWorkspace.shared.openApplication(at: appURL, configuration: configuration)
            logger.notice("Restarted application after a crash.")
        } catch {
            logger.error("Crash recovery failed: \(error.localizedDescription, privacy: .public)")
            exit(EXIT_FAILURE)
        }
    }
}
