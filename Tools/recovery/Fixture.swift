// Test app for smoke.py, compiled with production CrashRecovery and LoginItem.
import AppKit
import ServiceManagement

@MainActor
final class Fixture: NSObject, NSApplicationDelegate {
    let recovery = CrashRecovery()
    var timer: Timer?
    var count = 0
    var directory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(Bundle.main.bundleIdentifier!)
    }

    func applicationDidFinishLaunching(_ note: Notification) {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            if !UserDefaults.standard.bool(forKey: "registered") {
                try SMAppService.mainApp.register()
                UserDefaults.standard.set(true, forKey: "registered")
            }
            count = UserDefaults.standard.integer(forKey: "launchCount") + 1
            UserDefaults.standard.set(count, forKey: "launchCount")
            recovery.start()
            let startupCrash = directory.appendingPathComponent("crash-on-start")
            if FileManager.default.fileExists(atPath: startupCrash.path) {
                try FileManager.default.removeItem(at: startupCrash)
                UserDefaults.standard.synchronize()
                // Crash immediately after start() returns, before any fixture timers run.
                raise(SIGTRAP)
            }
            timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { _ in
                MainActor.assumeIsolated {
                    self.command()
                    self.writeState()
                }
            }
        } catch {
            try? Data(error.localizedDescription.utf8).write(to: directory.appendingPathComponent("error.txt"))
            NSApp.terminate(nil)
        }
    }

    func writeState() {
        let state: [String: Any] = ["pid": getpid(), "helperPID": recovery.helperProcessIdentifier ?? 0,
            "armed": recovery.isMonitoring, "status": SMAppService.mainApp.status.rawValue,
            "launchCount": count, "error": recovery.errorMessage ?? ""]
        try? JSONSerialization.data(withJSONObject: state).write(to: directory.appendingPathComponent("state.json"), options: .atomic)
    }

    func command() {
        let url = directory.appendingPathComponent("command")
        guard let value = try? String(contentsOf: url, encoding: .utf8) else { return }
        try? FileManager.default.removeItem(at: url)
        if value == "disable" || value == "cleanup" { try? LoginItem.setEnabled(false, recovery: recovery) }
        if value == "revoke" { try? SMAppService.mainApp.unregister() }
        if value == "enable" { try? LoginItem.setEnabled(true, recovery: recovery) }
        if value == "disarm" { recovery.shutdown() }
        if value == "logout" {
            NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.willPowerOffNotification, object: nil)
        }
        if value == "quit" || value == "cleanup" { NSApp.terminate(nil) }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        recovery.shutdown()
        return .terminateNow
    }

    func applicationWillTerminate(_ note: Notification) { recovery.shutdown() }
}

@main
struct FixtureMain {
    @MainActor static func main() {
        let app = NSApplication.shared
        let delegate = Fixture()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }
}
