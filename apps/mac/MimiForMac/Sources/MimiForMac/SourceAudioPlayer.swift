import AVFoundation
import Foundation

/// Plays the tapped source after Core Audio has fail-safely muted its hardware output.
public protocol SourceAudioMonitoring: AnyObject, Sendable {
    func start() throws
    @discardableResult
    func enqueue(_ buffer: AudioSampleBuffer) -> Bool
    func stop()
}

public final class SourceAudioPlayer: SourceAudioMonitoring, @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.mimi-for-mac.source-monitor")
    private let engine = AVAudioEngine()
    private let playerNode = AVAudioPlayerNode()
    private var active = false
    private var currentFormat: AVAudioFormat?
    private var currentVolume: Float = 1

    public init() {
        engine.attach(playerNode)
    }

    public var volume: Float {
        get { queue.sync { currentVolume } }
        set {
            let clamped = min(1, max(0, newValue))
            queue.async { [weak self] in
                self?.currentVolume = clamped
                self?.playerNode.volume = clamped
            }
        }
    }

    public func start() throws {
        queue.sync {
            active = true
            playerNode.volume = currentVolume
        }
    }

    @discardableResult
    public func enqueue(_ buffer: AudioSampleBuffer) -> Bool {
        guard buffer.sampleRate.isFinite,
              buffer.sampleRate > 0,
              buffer.channels > 0,
              !buffer.samples.isEmpty,
              buffer.samples.count.isMultiple(of: buffer.channels) else { return false }
        queue.async { [weak self] in self?.schedule(buffer) }
        return true
    }

    public func stop() {
        queue.sync {
            active = false
            playerNode.stop()
            engine.stop()
            engine.disconnectNodeOutput(playerNode)
            currentFormat = nil
        }
    }

    private func schedule(_ source: AudioSampleBuffer) {
        guard active else { return }
        let channelCount = AVAudioChannelCount(source.channels)
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: source.sampleRate,
            channels: channelCount,
            interleaved: false
        ) else { return }
        if currentFormat?.sampleRate != format.sampleRate || currentFormat?.channelCount != format.channelCount {
            playerNode.stop()
            engine.stop()
            engine.disconnectNodeOutput(playerNode)
            engine.connect(playerNode, to: engine.mainMixerNode, format: format)
            engine.prepare()
            do {
                try engine.start()
                currentFormat = format
            } catch {
                currentFormat = nil
                return
            }
        }

        let frameCount = source.samples.count / source.channels
        guard let pcm = AVAudioPCMBuffer(
            pcmFormat: format,
            frameCapacity: AVAudioFrameCount(frameCount)
        ), let channels = pcm.floatChannelData else { return }
        pcm.frameLength = AVAudioFrameCount(frameCount)
        for channel in 0..<source.channels {
            for frame in 0..<frameCount {
                channels[channel][frame] = source.samples[frame * source.channels + channel]
            }
        }
        playerNode.scheduleBuffer(pcm)
        if !playerNode.isPlaying { playerNode.play() }
    }
}
