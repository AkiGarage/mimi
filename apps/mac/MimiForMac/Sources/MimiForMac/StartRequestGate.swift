/// Main-actor-owned gate that coalesces Start requests arriving from the
/// window and menu bar before the asynchronous pipeline updates UI state.
public struct MimiStartRequestGate: Sendable {
    public private(set) var hasPendingRequest = false

    public init() {}

    public mutating func begin(isActive: Bool) -> Bool {
        guard !isActive, !hasPendingRequest else { return false }
        hasPendingRequest = true
        return true
    }

    public mutating func complete() {
        hasPendingRequest = false
    }
}
