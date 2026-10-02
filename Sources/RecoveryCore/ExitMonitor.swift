import Darwin
import Foundation

/// Kernel exit status distinguishes crashes from Quit, SIGTERM and Force Quit.
/// The private pipe lets the app disarm before updating or disabling autostart.
public final class ExitMonitor: @unchecked Sendable {
    private let queue: Int32
    private let controlFD: Int32

    public init(pid: pid_t, controlFD: Int32) throws {
        self.controlFD = controlFD
        queue = kqueue()
        guard queue >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        var changes = [
            kevent(ident: UInt(pid), filter: Int16(EVFILT_PROC), flags: UInt16(EV_ADD | EV_ONESHOT),
                   fflags: NOTE_EXIT | UInt32(NOTE_EXITSTATUS), data: 0, udata: nil),
            kevent(ident: UInt(controlFD), filter: Int16(EVFILT_READ), flags: UInt16(EV_ADD),
                   fflags: 0, data: 0, udata: nil),
        ]
        guard kevent(queue, &changes, Int32(changes.count), nil, 0, nil) == 0 else {
            let code = errno
            // All stored properties are initialized: Swift calls deinit when we throw.
            throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
        }
    }

    deinit { if queue >= 0 { close(queue) } }

    /// Call once, from a worker thread. Any disarm byte takes precedence over a crash.
    public func waitForCrash() -> Bool {
        var events = [kevent(), kevent()]
        while true {
            let count = kevent(queue, nil, 0, &events, Int32(events.count), nil)
            if count < 0 {
                if errno == EINTR { continue }
                return false
            }
            let ready = events.prefix(Int(count))
            if ready.contains(where: { $0.filter == Int16(EVFILT_READ) && $0.data > 0 }) { return false }
            if let exit = ready.first(where: { $0.filter == Int16(EVFILT_PROC) }) {
                // A stop byte might arrive in the same instant as the exit event.
                var pollFD = pollfd(fd: controlFD, events: Int16(POLLIN), revents: 0)
                if poll(&pollFD, 1, 0) > 0, pollFD.revents & Int16(POLLIN) != 0 {
                    var byte: UInt8 = 0
                    if read(controlFD, &byte, 1) > 0 { return false }
                }
                return Self.isCrash(status: Int32(truncatingIfNeeded: exit.data))
            }
            // EOF is not proof of a crash. Wait for the kernel's process event.
            if ready.contains(where: { $0.filter == Int16(EVFILT_READ) && $0.flags & UInt16(EV_EOF) != 0 }) {
                var change = kevent(ident: UInt(controlFD), filter: Int16(EVFILT_READ),
                                    flags: UInt16(EV_DELETE), fflags: 0, data: 0, udata: nil)
                _ = kevent(queue, &change, 1, nil, 0, nil)
            }
        }
    }

    public static func isCrash(status: Int32) -> Bool {
        let signal = status & 0x7f
        return [SIGABRT, SIGBUS, SIGFPE, SIGILL, SIGSEGV, SIGTRAP, SIGSYS].contains(signal)
    }
}
