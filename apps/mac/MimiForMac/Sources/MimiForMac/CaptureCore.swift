import Foundation

public enum AudioSourceKind: String, Sendable, Equatable, Codable {
    case application
    case window
    case display
    case system
}

public struct AudioSource: Identifiable, Hashable, Sendable, Codable {
    public let id: String
    public let displayName: String
    public let kind: AudioSourceKind
    public let processID: Int32?
    public let windowID: UInt32?
    public let bundleIdentifier: String?

    public init(
        id: String,
        displayName: String,
        kind: AudioSourceKind,
        processID: Int32? = nil,
        windowID: UInt32? = nil,
        bundleIdentifier: String? = nil
    ) {
        self.id = id
        self.displayName = displayName
        self.kind = kind
        self.processID = processID
        self.windowID = windowID
        self.bundleIdentifier = bundleIdentifier
    }

    public static func process(id: String, name: String, processID: Int32) -> Self {
        AudioSource(id: id, displayName: name, kind: .application, processID: processID)
    }

    public static var system: Self {
        AudioSource(id: "system", displayName: "System audio", kind: .system)
    }

    public var isBrowserWindow: Bool {
        guard kind == .window, let bundleIdentifier else { return false }
        return Self.browserBundleIdentifiers.contains(bundleIdentifier)
    }

    public var isBrowserApplication: Bool {
        guard kind == .application, let bundleIdentifier else { return false }
        return Self.browserBundleIdentifiers.contains(bundleIdentifier)
    }

    /// macOS exposes process-level mute control, but not a safe per-window mute boundary.
    public var supportsOriginalVolumeControl: Bool {
        kind == .application || kind == .system
    }

    private static let browserBundleIdentifiers: Set<String> = [
        "com.apple.Safari",
        "com.apple.SafariTechnologyPreview",
        "com.google.Chrome",
        "com.google.Chrome.beta",
        "com.google.Chrome.dev",
        "com.google.Chrome.canary"
    ]
}

public protocol AudioSourceProviding: Sendable {
    func availableSources() async throws -> [AudioSource]
}

public enum CaptureError: Error, Sendable, Equatable, LocalizedError {
    case alreadyRunning
    case notRunning
    case permissionDenied
    case sourceEnded
    case processNotFound(Int32)
    case system(OSStatus)
    case backendUnavailable(String)
    case unsupportedFormat(String)
    case unknown(String)

    public var errorDescription: String? {
        switch self {
        case .alreadyRunning: return "Capture is already running."
        case .notRunning: return "Capture is not running."
        case .permissionDenied: return "Audio capture permission was denied."
        case .sourceEnded: return "The selected audio source ended."
        case .processNotFound(let pid): return "Audio process was not found (pid \(pid))."
        case .system(let status): return "Core Audio returned OSStatus \(status)."
        case .backendUnavailable(let message): return message
        case .unsupportedFormat(let message): return message
        case .unknown(let message): return message
        }
    }

    /// Opening System Settings is only useful for an actual authorization failure.
    public var requiresSystemSettings: Bool {
        self == .permissionDenied
    }
}

public enum CaptureEvent: Sendable, Equatable {
    case started
    case audio(AudioSampleBuffer)
    case metrics(CaptureMetrics)
    case sourceEnded
    case permissionDenied
    case failed(CaptureError)
    case stopped
}

public protocol CaptureBackend: AnyObject, Sendable {
    var backendName: String { get }
    func start(source: AudioSource, onEvent: @escaping @Sendable (CaptureEvent) -> Void) async throws
    func stop() async
}

/// Owns one backend operation and turns stop/source-ending/error races into one terminal transition.
public final class CaptureSession: @unchecked Sendable {
    public enum State: String, Sendable, Equatable {
        case idle
        case starting
        case running
        case stopping
        case ended
    }

    private let backend: any CaptureBackend
    private let lock = NSLock()
    private var state: State = .idle
    private var callback: (@Sendable (CaptureEvent) -> Void)?
    private var terminalEventSent = false
    private var startTask: Task<Void, Error>?

    public init(backend: any CaptureBackend) { self.backend = backend }

    private func withLock<T>(_ body: () -> T) -> T {
        lock.lock(); defer { lock.unlock() }
        return body()
    }

    public var currentState: State {
        lock.lock(); defer { lock.unlock() }
        return state
    }

    public func start(
        source: AudioSource,
        onEvent: @escaping @Sendable (CaptureEvent) -> Void
    ) async throws {
        var operation: Task<Void, Error>?
        let canStart = withLock {
            guard state == .idle || state == .ended else { return false }
            state = .starting
            callback = onEvent
            terminalEventSent = false
            let newOperation = Task { [weak self, backend] in
                try await backend.start(source: source) { [weak self] event in
                    self?.receive(event)
                }
            }
            startTask = newOperation
            operation = newOperation
            return true
        }
        guard canStart, let operation else {
            throw CaptureError.alreadyRunning
        }

        do {
            try await operation.value
            withLock {
                startTask = nil
                if state == .starting { state = .running }
            }
        } catch {
            withLock {
                startTask = nil
                if state != .stopping { state = .ended }
            }
            throw error
        }
    }

    public func stop() async {
        let decision: (shouldStop: Bool, operation: Task<Void, Error>?) = withLock {
            guard state == .starting || state == .running else { return (false, nil) }
            state = .stopping
            return (true, startTask)
        }
        guard decision.shouldStop else { return }
        if let operation = decision.operation { _ = await operation.result }
        await backend.stop()
        finish(.stopped)
    }

    private func receive(_ event: CaptureEvent) {
        switch event {
        case .audio, .metrics, .started:
            lock.lock()
            let shouldForward = state == .starting || state == .running
            if event == .started, state == .starting { state = .running }
            let callback = shouldForward ? self.callback : nil
            lock.unlock()
            callback?(event)
        case .sourceEnded:
            if finish(.sourceEnded) { Task { await backend.stop() } }
        case .permissionDenied:
            if finish(.permissionDenied) { Task { await backend.stop() } }
        case .failed(let error):
            if finish(.failed(error)) { Task { await backend.stop() } }
        case .stopped:
            finish(.stopped)
        }
    }

    @discardableResult
    private func finish(_ event: CaptureEvent) -> Bool {
        lock.lock()
        guard !terminalEventSent else {
            lock.unlock()
            return false
        }
        terminalEventSent = true
        state = .ended
        let callback = self.callback
        lock.unlock()
        callback?(event)
        return true
    }
}

public protocol ProcessObjectResolving: Sendable {
    func processObjectID(for processID: Int32) throws -> UInt32
    func processObjectIDs(forApplicationProcessID processID: Int32) throws -> [UInt32]
}

public extension ProcessObjectResolving {
    func processObjectIDs(forApplicationProcessID processID: Int32) throws -> [UInt32] {
        [try processObjectID(for: processID)]
    }
}

public struct ProcessExclusionConfiguration: Sendable, Equatable {
    public let processIDs: [Int32]

    public init(selfProcessID: Int32, helperProcessIDs: [Int32] = []) {
        self.processIDs = Set([selfProcessID] + helperProcessIDs).sorted()
    }

    public func resolve(using resolver: any ProcessObjectResolving) throws -> ResolvedProcessExclusion {
        let objectIDs = try processIDs.map { try resolver.processObjectID(for: $0) }
        return ResolvedProcessExclusion(processIDs: processIDs, processObjectIDs: objectIDs)
    }

    public static func currentProcess(helperProcessIDs: [Int32] = []) -> Self {
        Self(selfProcessID: ProcessInfo.processInfo.processIdentifier, helperProcessIDs: helperProcessIDs)
    }
}

public struct ResolvedProcessExclusion: Sendable, Equatable {
    public let processIDs: [Int32]
    public let processObjectIDs: [UInt32]
}
