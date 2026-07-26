import CoreGraphics
import CoreMedia
import Foundation
import ScreenCaptureKit

public struct ScreenCaptureKitSourceProvider: AudioSourceProviding, Sendable {
    public init() {}

    public func availableSources() async throws -> [AudioSource] {
        let content: SCShareableContent
        do {
            content = try await SCShareableContent.current
        } catch {
            if !CGPreflightScreenCaptureAccess() {
                throw CaptureError.permissionDenied
            }
            throw CaptureError.backendUnavailable("Audio source list is temporarily unavailable.")
        }
        let currentProcessID = ProcessInfo.processInfo.processIdentifier
        let applications = content.applications
            .filter { $0.processID != currentProcessID }
            .map {
                AudioSource(
                    id: "pid:\($0.processID)",
                    displayName: $0.applicationName,
                    kind: .application,
                    processID: $0.processID,
                    bundleIdentifier: $0.bundleIdentifier
                )
            }
        let windows = content.windows.compactMap { window -> AudioSource? in
            guard window.windowLayer == 0,
                  window.isOnScreen,
                  let application = window.owningApplication,
                  application.processID != currentProcessID,
                  let title = window.title?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !title.isEmpty else { return nil }
            return AudioSource(
                id: "window:\(window.windowID)",
                displayName: title,
                kind: .window,
                processID: application.processID,
                windowID: window.windowID,
                bundleIdentifier: application.bundleIdentifier
            )
        }
        return applications + windows
    }
}

/// ScreenCaptureKit audio adapter using an app-level content filter and current-process exclusion.
public final class ScreenCaptureKitBackend: NSObject, CaptureBackend, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    public let backendName = "ScreenCaptureKit audio"
    public let sampleRate: Double
    public let channelCount: Int

    private let lock = NSLock()
    private let callbackQueue = DispatchQueue(label: "com.mimi-for-mac.capture.audio")
    private var stream: SCStream?
    private var callback: (@Sendable (CaptureEvent) -> Void)?

    public init(sampleRate: Double = 48_000, channelCount: Int = 2) {
        self.sampleRate = sampleRate
        self.channelCount = channelCount
        super.init()
    }

    private func withLock<T>(_ body: () -> T) -> T {
        lock.lock(); defer { lock.unlock() }
        return body()
    }

    public func start(source: AudioSource, onEvent: @escaping @Sendable (CaptureEvent) -> Void) async throws {
        guard source.kind == .application || source.kind == .window else {
            throw CaptureError.backendUnavailable("ScreenCaptureKit requires an application or window source.")
        }
        let content: SCShareableContent
        do {
            content = try await SCShareableContent.current
        } catch {
            if !CGPreflightScreenCaptureAccess() {
                throw CaptureError.permissionDenied
            }
            throw CaptureError.backendUnavailable("ScreenCaptureKit is temporarily unavailable.")
        }
        let filter: SCContentFilter
        switch source.kind {
        case .application:
            guard let processID = source.processID else {
                throw CaptureError.backendUnavailable("Application source has no process identifier.")
            }
            guard let app = content.applications.first(where: { $0.processID == processID }) else {
                throw CaptureError.processNotFound(processID)
            }
            guard let display = content.displays.first else {
                throw CaptureError.backendUnavailable("No display is available for the ScreenCaptureKit app filter.")
            }
            filter = SCContentFilter(display: display, including: [app], exceptingWindows: [])
        case .window:
            guard let windowID = source.windowID else {
                throw CaptureError.backendUnavailable("Window source has no window identifier.")
            }
            guard let window = content.windows.first(where: { $0.windowID == windowID }) else {
                throw CaptureError.sourceEnded
            }
            filter = SCContentFilter(desktopIndependentWindow: window)
        case .display, .system:
            throw CaptureError.backendUnavailable("ScreenCaptureKit requires an application or window source.")
        }
        let configuration = SCStreamConfiguration()
        configuration.capturesAudio = true
        configuration.sampleRate = Int(sampleRate)
        configuration.channelCount = channelCount
        configuration.excludesCurrentProcessAudio = true
        configuration.width = 2
        configuration.height = 2
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 1)
        let newStream = SCStream(filter: filter, configuration: configuration, delegate: self)
        do {
            try newStream.addStreamOutput(self, type: .audio, sampleHandlerQueue: callbackQueue)
            try await newStream.startCapture()
        } catch {
            throw CaptureError.unknown("ScreenCaptureKit could not start audio capture: \(error.localizedDescription)")
        }

        withLock {
            stream = newStream
            callback = onEvent
        }
        onEvent(.started)
    }

    public func stop() async {
        let currentStream = withLock {
            let current = stream
            stream = nil
            callback = nil
            return current
        }
        guard let currentStream else { return }
        try? await currentStream.stopCapture()
    }

    public func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of outputType: SCStreamOutputType) {
        guard outputType == .audio, let audio = Self.audioBuffer(from: sampleBuffer) else { return }
        lock.lock(); let callback = self.callback; lock.unlock()
        callback?(.audio(audio))
    }

    public func stream(_ stream: SCStream, didStopWithError error: Error) {
        lock.lock(); let callback = self.callback; self.stream = nil; self.callback = nil; lock.unlock()
        callback?(.failed(.unknown("ScreenCaptureKit stream stopped: \(error.localizedDescription)")))
    }

    private static func audioBuffer(from sampleBuffer: CMSampleBuffer) -> AudioSampleBuffer? {
        guard let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer),
              let asbdPointer = CMAudioFormatDescriptionGetStreamBasicDescription(formatDescription)
        else { return nil }
        let asbd = asbdPointer.pointee
        let channels = Int(asbd.mChannelsPerFrame)
        let frames = CMSampleBufferGetNumSamples(sampleBuffer)
        guard channels > 0, frames > 0 else { return nil }

        var bufferListSize = MemoryLayout<AudioBufferList>.size + max(0, channels - 1) * MemoryLayout<AudioBuffer>.size
        let bufferList = AudioBufferList.allocate(maximumBuffers: max(1, channels))
        defer { bufferList.unsafeMutablePointer.deallocate() }
        var retainedBlockBuffer: CMBlockBuffer?
        let status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer,
            bufferListSizeNeededOut: &bufferListSize,
            bufferListOut: bufferList.unsafeMutablePointer,
            bufferListSize: bufferListSize,
            blockBufferAllocator: nil,
            blockBufferMemoryAllocator: nil,
            flags: 0,
            blockBufferOut: &retainedBlockBuffer
        )
        guard status == noErr else { return nil }

        let isFloat = asbd.mFormatFlags & kAudioFormatFlagIsFloat != 0
        let isSignedInteger = asbd.mFormatFlags & kAudioFormatFlagIsSignedInteger != 0
        let bitDepth = Int(asbd.mBitsPerChannel)
        guard (isFloat && bitDepth == 32) || (isSignedInteger && bitDepth == 16) else { return nil }

        var samples = Array(repeating: Float.zero, count: frames * channels)
        let buffers = UnsafeMutableAudioBufferListPointer(bufferList.unsafeMutablePointer)
        if buffers.count == 1, let data = buffers[0].mData {
            if isFloat {
                let values = data.assumingMemoryBound(to: Float.self)
                samples = Array(UnsafeBufferPointer(start: values, count: frames * channels))
            } else {
                let values = data.assumingMemoryBound(to: Int16.self)
                for index in samples.indices { samples[index] = Float(values[index]) / 32_768 }
            }
        } else {
            for channel in 0..<min(channels, buffers.count) {
                guard let data = buffers[channel].mData else { continue }
                if isFloat {
                    let values = data.assumingMemoryBound(to: Float.self)
                    for frame in 0..<frames { samples[frame * channels + channel] = values[frame] }
                } else {
                    let values = data.assumingMemoryBound(to: Int16.self)
                    for frame in 0..<frames { samples[frame * channels + channel] = Float(values[frame]) / 32_768 }
                }
            }
        }
        return AudioSampleBuffer(sampleRate: asbd.mSampleRate, channels: channels, samples: samples)
    }
}
