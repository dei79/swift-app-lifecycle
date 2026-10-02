import Foundation

/// Persisted in the app container: sandboxed launches can discard launch arguments.
public struct RecoveryBudget: Sendable {
    public static let limit = 3
    public static let interval: TimeInterval = 60
    public let attempts: [TimeInterval]

    public init(data: Data? = nil) {
        guard let data,
              let values = try? JSONDecoder().decode([TimeInterval].self, from: data),
              values.count <= Self.limit, values.allSatisfy({ $0.isFinite && $0 >= 0 }) else {
            attempts = []
            return
        }
        attempts = values
    }

    private init(attempts: [TimeInterval]) { self.attempts = attempts }

    public func next(at now: TimeInterval = Date().timeIntervalSince1970) -> Self? {
        let recent = attempts.filter { $0 <= now && now - $0 < Self.interval }
        guard recent.count < Self.limit else { return nil }
        return Self(attempts: recent + [now])
    }

    public var data: Data {
        try! JSONEncoder().encode(attempts)
    }
}
