import CoreAudio
import Darwin
import Foundation

public enum ActiveAudioTargetDecision: Equatable, Sendable {
    case selected(AudioSource)
    case none
    case ambiguous([AudioSource])
}

public enum ActiveAudioTargetResolver {
    public static func activeApplications(
        applications: [AudioSource],
        activeProcessIDs: Set<Int32>,
        parentOf: (Int32) -> Int32?
    ) -> [AudioSource] {
        applications
            .filter { $0.kind == .application && $0.processID != nil }
            .filter { application in
                guard let rootProcessID = application.processID else { return false }
                return activeProcessIDs.contains {
                    CoreAudioProcessFamily.contains(
                        $0,
                        root: rootProcessID,
                        parentOf: parentOf
                    )
                }
            }
            .sorted {
                $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
            }
    }

    public static func resolve(
        applications: [AudioSource],
        activeProcessIDs: Set<Int32>,
        frontmostProcessID: Int32?,
        parentOf: (Int32) -> Int32?
    ) -> ActiveAudioTargetDecision {
        let activeApplications = activeApplications(
            applications: applications,
            activeProcessIDs: activeProcessIDs,
            parentOf: parentOf
        )

        guard !activeApplications.isEmpty else { return .none }
        if activeApplications.count == 1 { return .selected(activeApplications[0]) }
        if let frontmostProcessID,
           let frontmost = activeApplications.first(where: { application in
               guard let rootProcessID = application.processID else { return false }
               return CoreAudioProcessFamily.contains(
                   frontmostProcessID,
                   root: rootProcessID,
                   parentOf: parentOf
               )
           }) {
            return .selected(frontmost)
        }
        return .ambiguous(activeApplications)
    }
}

@available(macOS 14.2, *)
public struct CoreAudioActiveAudioTargetDetector: Sendable {
    public init() {}

    public func detect(
        applications: [AudioSource],
        frontmostProcessID: Int32?
    ) throws -> ActiveAudioTargetDecision {
        try ActiveAudioTargetResolver.resolve(
            applications: applications,
            activeProcessIDs: activeOutputProcessIDs(),
            frontmostProcessID: frontmostProcessID,
            parentOf: Self.parentProcessID
        )
    }

    public func activeApplications(applications: [AudioSource]) throws -> [AudioSource] {
        try ActiveAudioTargetResolver.activeApplications(
            applications: applications,
            activeProcessIDs: activeOutputProcessIDs(),
            parentOf: Self.parentProcessID
        )
    }

    private func activeOutputProcessIDs() throws -> Set<Int32> {
        var listAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyProcessObjectList,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var byteCount: UInt32 = 0
        var status = AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject),
            &listAddress,
            0,
            nil,
            &byteCount
        )
        guard status == noErr else { throw CaptureError.system(status) }
        guard byteCount > 0 else { return [] }

        var objectIDs = Array(
            repeating: AudioObjectID(kAudioObjectUnknown),
            count: Int(byteCount) / MemoryLayout<AudioObjectID>.size
        )
        status = objectIDs.withUnsafeMutableBytes { bytes in
            AudioObjectGetPropertyData(
                AudioObjectID(kAudioObjectSystemObject),
                &listAddress,
                0,
                nil,
                &byteCount,
                bytes.baseAddress!
            )
        }
        guard status == noErr else { throw CaptureError.system(status) }

        return Set(objectIDs.compactMap(Self.activeOutputProcessID))
    }

    private static func activeOutputProcessID(for objectID: AudioObjectID) -> Int32? {
        var isRunningOutput: UInt32 = 0
        var runningSize = UInt32(MemoryLayout<UInt32>.size)
        var runningAddress = AudioObjectPropertyAddress(
            mSelector: kAudioProcessPropertyIsRunningOutput,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let runningStatus = AudioObjectGetPropertyData(
            objectID,
            &runningAddress,
            0,
            nil,
            &runningSize,
            &isRunningOutput
        )
        guard runningStatus == noErr, isRunningOutput == 1 else { return nil }

        var pid: pid_t = 0
        var pidSize = UInt32(MemoryLayout<pid_t>.size)
        var pidAddress = AudioObjectPropertyAddress(
            mSelector: kAudioProcessPropertyPID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let pidStatus = AudioObjectGetPropertyData(
            objectID,
            &pidAddress,
            0,
            nil,
            &pidSize,
            &pid
        )
        guard pidStatus == noErr, pid > 0 else { return nil }
        return Int32(pid)
    }

    private static func parentProcessID(for processID: Int32) -> Int32? {
        var info = proc_bsdinfo()
        let expectedSize = Int32(MemoryLayout<proc_bsdinfo>.size)
        let bytesRead = proc_pidinfo(processID, PROC_PIDTBSDINFO, 0, &info, expectedSize)
        guard bytesRead == expectedSize else { return nil }
        return Int32(info.pbi_ppid)
    }
}
