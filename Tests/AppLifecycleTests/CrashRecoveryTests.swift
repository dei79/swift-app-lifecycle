import Foundation
import Testing
@testable import AppLifecycle

@Suite("Recovery startup handshake", .timeLimit(.minutes(1)))
@MainActor
struct CrashRecoveryTests {
    @Test("Startup waits for the helper to confirm readiness")
    func ready() throws {
        let pipe = Pipe()
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.02) {
            try? pipe.fileHandleForWriting.write(contentsOf: Data([1]))
        }
        try CrashRecovery.waitForReady(pipe.fileHandleForReading, timeout: 1)
    }

    @Test("A silent helper has a bounded startup wait")
    func timeout() {
        let pipe = Pipe()
        let start = ProcessInfo.processInfo.systemUptime
        #expect(throws: CrashRecovery.ReadinessFailure.timedOut) {
            try CrashRecovery.waitForReady(pipe.fileHandleForReading, timeout: 0.025)
        }
        #expect(ProcessInfo.processInfo.systemUptime - start < 1)
        withExtendedLifetime(pipe) {}
    }

    @Test("Helper exit or invalid confirmation cannot report readiness", arguments: [false, true])
    func disconnected(invalidByte: Bool) throws {
        let pipe = Pipe()
        if invalidByte { try pipe.fileHandleForWriting.write(contentsOf: Data([2])) }
        try pipe.fileHandleForWriting.close()
        #expect(throws: CrashRecovery.ReadinessFailure.disconnected) {
            try CrashRecovery.waitForReady(pipe.fileHandleForReading, timeout: 1)
        }
    }
}
