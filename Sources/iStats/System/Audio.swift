import AppKit
import CoreAudio
import Observation

/// Per-app volume. An app turned below 100% gets a private process tap that mutes its output and
/// replays it through the current output device at the chosen gain. Nothing is written anywhere.
@available(macOS 14.2, *)
@Observable
final class VolumeMixer {
    static let shared = VolumeMixer()

    struct Source: Identifiable {
        let id: String
        let name: String
        let iconPath: String?
        var objects: [AudioObjectID]
    }

    private(set) var sources: [Source] = []
    private(set) var volumes: [String: Float] = [:]
    private(set) var failed = false
    @ObservationIgnored private var taps: [String: ProcessTap] = [:]

    private typealias ResponsibleFn = @convention(c) (pid_t) -> pid_t
    @ObservationIgnored private let responsible: ResponsibleFn? = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "responsibility_get_pid_responsible_for_pid")
        .map { unsafeBitCast($0, to: ResponsibleFn.self) }

    func volume(for source: Source) -> Float { volumes[source.id] ?? 1 }

    /// Apps currently playing audio, plus any app whose volume was changed and is still running.
    func refresh() {
        var found: [String: Source] = [:]
        var order: [String] = []
        for object in Self.processObjects() {
            guard let pid: pid_t = Self.property(object, kAudioProcessPropertyPID), pid != getpid() else { continue }
            let playing: UInt32 = Self.property(object, kAudioProcessPropertyIsRunningOutput) ?? 0
            let owner = responsible?(pid) ?? pid
            let app = NSRunningApplication(processIdentifier: owner > 0 ? owner : pid) ?? NSRunningApplication(processIdentifier: pid)
            let key = app?.bundleURL?.path ?? app?.localizedName ?? "pid \(pid)"
            guard playing != 0 || taps[key] != nil else { continue }
            if found[key] == nil {
                let name = app?.localizedName ?? AppActions.processName(pid)
                found[key] = Source(id: key, name: name, iconPath: app?.bundleURL?.path, objects: [])
                order.append(key)
            }
            found[key]!.objects.append(object)
        }
        sources = order.compactMap { found[$0] }.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }

        for (key, tap) in taps {
            guard let source = found[key] else {
                taps[key] = nil
                volumes[key] = nil
                continue
            }
            if Set(source.objects) != tap.objects || tap.outputUID != Self.defaultOutputUID() {
                taps[key] = ProcessTap(objects: source.objects, gain: tap.gain)
            }
        }
    }

    func setVolume(_ value: Float, for source: Source) {
        volumes[source.id] = value
        if value >= 0.995 {
            taps[source.id] = nil
            return
        }
        if let tap = taps[source.id] {
            tap.gain = value
        } else if let tap = ProcessTap(objects: source.objects, gain: value) {
            taps[source.id] = tap
            failed = false
        } else {
            failed = true
            volumes[source.id] = 1
        }
    }

    func reset() {
        taps.removeAll()
        volumes.removeAll()
    }

    // MARK: - Core Audio helpers

    fileprivate static func address(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    }

    private static func processObjects() -> [AudioObjectID] {
        var address = address(kAudioHardwarePropertyProcessObjectList)
        var size: UInt32 = 0
        let system = AudioObjectID(kAudioObjectSystemObject)
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr, size > 0 else { return [] }
        var objects = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(system, &address, 0, nil, &size, &objects) == noErr else { return [] }
        return objects
    }

    fileprivate static func property<T>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> T? {
        var address = address(selector)
        var size = UInt32(MemoryLayout<T>.size)
        let value = UnsafeMutablePointer<T>.allocate(capacity: 1)
        defer { value.deallocate() }
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, value) == noErr else { return nil }
        return value.pointee
    }

    fileprivate static func defaultOutputUID() -> String? {
        guard let device: AudioDeviceID = property(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultOutputDevice),
              let uid: Unmanaged<CFString> = property(device, kAudioDevicePropertyDeviceUID)
        else { return nil }
        return uid.takeRetainedValue() as String
    }
}

/// A muted process tap wired into a private aggregate device whose IO proc copies the tapped audio
/// to the real output at `gain`.
@available(macOS 14.2, *)
private final class ProcessTap {
    private final class Gain: @unchecked Sendable { var value: Float = 1 }

    let objects: Set<AudioObjectID>
    let outputUID: String?
    private let level = Gain()
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var deviceID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?

    var gain: Float {
        get { level.value }
        set { level.value = newValue }
    }

    init?(objects: [AudioObjectID], gain: Float) {
        self.objects = Set(objects)
        level.value = gain
        guard let output = VolumeMixer.defaultOutputUID() else { return nil }
        outputUID = output

        let description = CATapDescription(stereoMixdownOfProcesses: objects)
        description.uuid = UUID()
        description.muteBehavior = .mutedWhenTapped
        description.isPrivate = true
        description.name = "iStats volume"
        guard AudioHardwareCreateProcessTap(description, &tapID) == noErr else { return nil }

        let aggregate: [String: Any] = [
            kAudioAggregateDeviceNameKey: "iStats volume",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceMainSubDeviceKey: output,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: output]],
            kAudioAggregateDeviceTapListKey: [[kAudioSubTapDriftCompensationKey: true, kAudioSubTapUIDKey: description.uuid.uuidString]],
        ]
        guard AudioHardwareCreateAggregateDevice(aggregate as CFDictionary, &deviceID) == noErr else {
            teardown()
            return nil
        }
        let level = level
        let status = AudioDeviceCreateIOProcIDWithBlock(&procID, deviceID, nil) { _, input, _, output, _ in
            Self.render(UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input)),
                        into: UnsafeMutableAudioBufferListPointer(output), gain: level.value)
        }
        guard status == noErr, AudioDeviceStart(deviceID, procID) == noErr else {
            teardown()
            return nil
        }
    }

    deinit { teardown() }

    private func teardown() {
        if let procID {
            AudioDeviceStop(deviceID, procID)
            AudioDeviceDestroyIOProcID(deviceID, procID)
        }
        if deviceID != kAudioObjectUnknown { AudioHardwareDestroyAggregateDevice(deviceID) }
        if tapID != kAudioObjectUnknown { AudioHardwareDestroyProcessTap(tapID) }
        procID = nil
        deviceID = AudioObjectID(kAudioObjectUnknown)
        tapID = AudioObjectID(kAudioObjectUnknown)
    }

    /// Float32 in and out; handles interleaved and non-interleaved layouts on either side.
    private static func render(_ input: UnsafeMutableAudioBufferListPointer, into output: UnsafeMutableAudioBufferListPointer, gain: Float) {
        for buffer in output where buffer.mData != nil { memset(buffer.mData, 0, Int(buffer.mDataByteSize)) }
        guard let first = input.first, first.mNumberChannels > 0, first.mData != nil else { return }
        let frames = Int(first.mDataByteSize) / (MemoryLayout<Float>.size * Int(first.mNumberChannels))
        let inputChannels = input.reduce(0) { $0 + Int($1.mNumberChannels) }
        guard frames > 0, inputChannels > 0 else { return }

        func locate(_ list: UnsafeMutableAudioBufferListPointer, _ channel: Int) -> (UnsafeMutablePointer<Float>, Int)? {
            var remaining = channel
            for buffer in list {
                let count = Int(buffer.mNumberChannels)
                if remaining < count, let data = buffer.mData {
                    return (data.assumingMemoryBound(to: Float.self) + remaining, count)
                }
                remaining -= count
            }
            return nil
        }

        var channel = 0
        for buffer in output {
            for _ in 0..<Int(buffer.mNumberChannels) {
                defer { channel += 1 }
                guard let (destination, destinationStride) = locate(output, channel),
                      let (source, sourceStride) = locate(input, channel % inputChannels)
                else { continue }
                let capacity = Int(buffer.mDataByteSize) / (MemoryLayout<Float>.size * destinationStride)
                for frame in 0..<min(frames, capacity) {
                    destination[frame * destinationStride] = source[frame * sourceStride] * gain
                }
            }
        }
    }
}
