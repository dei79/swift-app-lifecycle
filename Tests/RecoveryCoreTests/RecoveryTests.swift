import Darwin
import Foundation
import Testing
@testable import RecoveryCore

@Suite("Crash recovery", .timeLimit(.minutes(1)))
struct RecoveryTests {
    @Test("Three automatic starts per minute, with persisted history")
    func budget() throws {
        var budget = RecoveryBudget()
        for time in [100.0, 110, 120] {
            budget = try #require(budget.next(at: time))
            budget = RecoveryBudget(data: budget.data)
        }
        #expect(budget.next(at: 130) == nil)
        #expect(budget.next(at: 160)?.attempts == [110, 120, 160])
        #expect(budget.next(at: 181)?.attempts == [181])
        #expect(RecoveryBudget().next(at: 130)?.attempts == [130])
    }

    @Test("Clock rollback discards future attempts without blocking recovery")
    func clockRollback() {
        let budget = RecoveryBudget(data: Data("[100,110,120]".utf8))
        #expect(budget.next(at: 90)?.attempts == [90])
        #expect(budget.next(at: 115)?.attempts == [100, 110, 115])
        #expect(budget.next(at: 120) == nil)
    }

    @Test("Malformed history cannot crash the parser", arguments: ["bad", "[null]", "[-1]", "[1,2,3,4]"])
    func malformed(value: String) {
        #expect(RecoveryBudget(data: Data(value.utf8)).attempts.isEmpty)
    }

    @Test("Crash signals are distinct from deliberate termination", arguments: [SIGABRT, SIGBUS, SIGFPE, SIGILL, SIGSEGV, SIGTRAP, SIGSYS])
    func signals(signal: Int32) {
        #expect(ExitMonitor.isCrash(status: signal))
        #expect(ExitMonitor.isCrash(status: signal | 0x80)) // Core-dump bit.
        #expect(!ExitMonitor.isCrash(status: 0))
        #expect(!ExitMonitor.isCrash(status: 1 << 8))
        #expect(!ExitMonitor.isCrash(status: SIGKILL))
        #expect(!ExitMonitor.isCrash(status: SIGTERM))
        #expect(!ExitMonitor.isCrash(status: SIGINT))
    }

    @Test("Kernel monitor distinguishes real process exits", arguments: [SIGTRAP, SIGTERM, SIGKILL])
    func processExit(signal: Int32) async throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sleep")
        process.arguments = ["30"]
        try process.run()
        defer { if process.isRunning { process.terminate() } }
        let pipe = Pipe()
        let monitor = try ExitMonitor(pid: process.processIdentifier, controlFD: pipe.fileHandleForReading.fileDescriptor)
        let result = Task.detached { monitor.waitForCrash() }
        #expect(kill(process.processIdentifier, signal) == 0)
        #expect(await result.value == (signal == SIGTRAP))
        process.waitUntilExit()
        withExtendedLifetime(pipe) {}
    }

    @Test("Disarming before a crash prevents restart")
    func disarm() async throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sleep")
        process.arguments = ["30"]
        try process.run()
        defer { if process.isRunning { process.terminate() } }
        let pipe = Pipe()
        let monitor = try ExitMonitor(pid: process.processIdentifier, controlFD: pipe.fileHandleForReading.fileDescriptor)
        try pipe.fileHandleForWriting.write(contentsOf: Data([1]))
        #expect(kill(process.processIdentifier, SIGTRAP) == 0)
        #expect(await Task.detached { monitor.waitForCrash() }.value == false)
        process.waitUntilExit()
    }

    @Test("Pipe EOF alone never means crash, including nonzero normal exit", arguments: [0, 7])
    func normalExit(status: Int) async throws {
        let process = Process()
        let gate = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "read line; exit \(status)"]
        process.standardInput = gate
        try process.run()
        defer { if process.isRunning { process.terminate() } }
        let pipe = Pipe()
        let monitor = try ExitMonitor(pid: process.processIdentifier, controlFD: pipe.fileHandleForReading.fileDescriptor)
        try pipe.fileHandleForWriting.close()
        let result = Task.detached { monitor.waitForCrash() }
        try gate.fileHandleForWriting.write(contentsOf: Data("go\n".utf8))
        #expect(await result.value == false)
        process.waitUntilExit()
    }
}
