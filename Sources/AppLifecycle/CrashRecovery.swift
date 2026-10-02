import AppKit
import Combine
import ServiceManagement
import os

/// One helper per running app, armed only while macOS actually permits autostart.
@MainActor
public final class CrashRecovery: ObservableObject {
    private let helperName: String
    private let logger: Logger

    /// Retain this instance for the lifetime of the application. Call shutdown before intentional exits.
    public init(helperName: String = "AppLifecycleRecoveryHelper") {
        precondition(!helperName.isEmpty && !helperName.contains("/"), "Expected a helper filename")
        self.helperName = helperName
        logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "AppLifecycle", category: "Recovery")
    }
    private var helper: Process?
    private var control: FileHandle?
    private var timer: Timer?
    private var powerOffObserver: NSObjectProtocol?
    private var stopping = false
    private var resumeAfter = Date.distantPast
    @Published public private(set) var errorMessage: String?
    @Published public private(set) var isMonitoring = false
    public var helperProcessIdentifier: pid_t? { helper?.processIdentifier }

    deinit {
        if let control {
            try? control.write(contentsOf: Data([1]))
            try? control.close()
        }
    }

    public func start() {
        // Development and command-line test runs must not supervise the installed app.
        #if !DEBUG
        guard Bundle.main.bundleURL.pathExtension == "app", timer == nil, !stopping else { return }
        powerOffObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.willPowerOffNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                // Logout can be cancelled by another app. Recover if we remain alive.
                self.resumeAfter = Date().addingTimeInterval(30)
                self.disarm()
            }
        }
        timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        refresh()
        #endif
    }

    public func refresh() {
        #if !DEBUG
        guard timer != nil, !stopping, Date() >= resumeAfter, Bundle.main.bundleURL.pathExtension == "app" else { return }
        guard SMAppService.mainApp.status == .enabled else {
            disarm()
            errorMessage = nil
            return
        }
        guard helper == nil else { return }
        do {
            let pipe = Pipe()
            let ready = Pipe()
            let writer = pipe.fileHandleForWriting
            // Losing the helper must never crash the app when it sends DISARM.
            guard fcntl(writer.fileDescriptor, F_SETNOSIGPIPE, 1) != -1 else {
                throw POSIXError(.EIO)
            }
            let process = Process()
            process.executableURL = Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/\(helperName)")
            process.arguments = [String(ProcessInfo.processInfo.processIdentifier)]
            process.standardInput = pipe
            process.standardOutput = ready
            process.terminationHandler = { [weak self] process in
                let status = process.terminationStatus
                Task { @MainActor [weak self] in
                    guard let self, self.helper === process else { return }
                    self.disarm()
                    self.resumeAfter = Date().addingTimeInterval(30)
                    if status != 0 {
                        self.recordError("Automatic restart is temporarily unavailable (helper exit \(status)). Retrying shortly.")
                    }
                }
            }
            try process.run()
            // Only the helper owns the read end; EOF then tracks the app's lifetime.
            try? pipe.fileHandleForReading.close()
            try? ready.fileHandleForWriting.close()
            helper = process
            control = writer
            do {
                // Finish arming before AppDelegate initializes the remaining services.
                defer { try? ready.fileHandleForReading.close() }
                try Self.waitForReady(ready.fileHandleForReading)
                isMonitoring = true
                errorMessage = nil
            } catch {
                disarm()
                if process.isRunning { process.terminate() }
                throw error
            }
        } catch {
            resumeAfter = Date().addingTimeInterval(30)
            recordError("Automatic restart could not be enabled: \(error.localizedDescription)")
        }
        #endif
    }

    enum ReadinessFailure: LocalizedError {
        case timedOut, disconnected

        var errorDescription: String? {
            switch self {
            case .timedOut: return "The recovery helper did not become ready in time. Retrying shortly."
            case .disconnected: return "The recovery helper did not confirm readiness. Retrying shortly."
            }
        }
    }

    /// Bounded startup handshake; a broken helper must not hang the application.
    static func waitForReady(_ reader: FileHandle, timeout: TimeInterval = 2) throws {
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        while true {
            let remaining = deadline - ProcessInfo.processInfo.systemUptime
            guard remaining > 0 else { throw ReadinessFailure.timedOut }
            var descriptor = pollfd(fd: reader.fileDescriptor, events: Int16(POLLIN), revents: 0)
            let result = poll(&descriptor, 1, Int32(ceil(remaining * 1_000)))
            if result < 0, errno == EINTR { continue }
            guard result != 0 else { throw ReadinessFailure.timedOut }
            guard result > 0, descriptor.revents & Int16(POLLIN) != 0,
                  try reader.read(upToCount: 1) == Data([1]) else { throw ReadinessFailure.disconnected }
            return
        }
    }

    /// Clean termination, updater shutdown and logout permanently disarm this run.
    public func shutdown() {
        stopping = true
        timer?.invalidate()
        timer = nil
        if let powerOffObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(powerOffObserver)
            self.powerOffObserver = nil
        }
        disarm()
    }

    private func disarm() {
        if let control {
            try? control.write(contentsOf: Data([1]))
            try? control.close()
        }
        control = nil
        helper = nil
        isMonitoring = false
    }

    private func recordError(_ message: String) {
        if errorMessage != message {
            logger.error("\(message, privacy: .public)")
        }
        errorMessage = message
    }
}
