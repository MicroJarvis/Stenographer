@preconcurrency import AVFoundation
import Foundation

enum RecordingError: LocalizedError {
    case microphoneDenied
    case recorderUnavailable

    var errorDescription: String? {
        switch self {
        case .microphoneDenied:
            "没有麦克风权限。请在系统设置的隐私与安全性里允许 Stenographer 使用麦克风。"
        case .recorderUnavailable:
            "录音器暂时不可用。"
        }
    }
}

struct RecordingSession {
    let meetingID: UUID
    let directoryURL: URL
    let audioURL: URL
}

@MainActor
final class AudioRecorderService: NSObject, ObservableObject {
    @Published private(set) var currentSession: RecordingSession?
    @Published private(set) var level: Double = 0

    private var pipeline: AudioCapturePipeline?

    var currentMeetingID: UUID? {
        currentSession?.meetingID
    }

    func startRecording(meetingID: UUID, title: String, onPCMChunk: ((Data) -> Void)? = nil) async throws -> RecordingSession {
        guard await requestMicrophoneAccess() else {
            throw RecordingError.microphoneDenied
        }

        stopRecording()

        let session = try MeetingFileStore.shared.createRecordingSession(meetingID: meetingID, title: title)
        let pipeline = try AudioCapturePipeline(
            audioURL: session.audioURL,
            onPCMChunk: onPCMChunk,
            onLevel: { [weak self] level in
                Task { @MainActor in
                    self?.level = level
                }
            }
        )

        try pipeline.start()
        self.pipeline = pipeline
        currentSession = session
        refreshMeters()
        return session
    }

    func pauseRecording() {
        pipeline?.pause()
        refreshMeters()
    }

    func resumeRecording() throws {
        guard let pipeline else {
            throw RecordingError.recorderUnavailable
        }
        try pipeline.resume()
        refreshMeters()
    }

    func stopRecording() {
        pipeline?.stop()
        pipeline = nil
        currentSession = nil
        level = 0
    }

    func refreshMeters() {
        level = pipeline?.latestLevel ?? 0
    }

    private func requestMicrophoneAccess() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            return true
        case .denied, .restricted:
            return false
        case .notDetermined:
            return await withCheckedContinuation { continuation in
                AVCaptureDevice.requestAccess(for: .audio) { granted in
                    continuation.resume(returning: granted)
                }
            }
        @unknown default:
            return false
        }
    }
}

private final class AudioCapturePipeline: @unchecked Sendable {
    private let engine = AVAudioEngine()
    private let audioURL: URL
    private let processingQueue = DispatchQueue(label: "Stenographer.AudioCapturePipeline")
    private let onPCMChunk: ((Data) -> Void)?
    private let onLevel: (Double) -> Void
    private let targetFormat: AVAudioFormat
    private let chunkSampleCount = 9_600
    private let stateLock = NSLock()

    private var audioFile: AVAudioFile?
    private var converter: AVAudioConverter?
    private var pendingSamples: [Float] = []
    private var stopped = true
    private var paused = false
    private var latestLevelStorage: Double = 0

    var latestLevel: Double {
        stateLock.lock()
        defer { stateLock.unlock() }
        return latestLevelStorage
    }

    init(
        audioURL: URL,
        onPCMChunk: ((Data) -> Void)?,
        onLevel: @escaping (Double) -> Void
    ) throws {
        guard let targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 16_000,
            channels: 1,
            interleaved: false
        ) else {
            throw RecordingError.recorderUnavailable
        }

        self.audioURL = audioURL
        self.onPCMChunk = onPCMChunk
        self.onLevel = onLevel
        self.targetFormat = targetFormat
        pendingSamples.reserveCapacity(chunkSampleCount * 2)
    }

    func start() throws {
        let input = engine.inputNode
        let inputFormat = input.outputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else {
            throw RecordingError.recorderUnavailable
        }

        audioFile = try AVAudioFile(
            forWriting: audioURL,
            settings: inputFormat.settings,
            commonFormat: inputFormat.commonFormat,
            interleaved: inputFormat.isInterleaved
        )
        converter = AVAudioConverter(from: inputFormat, to: targetFormat)
        stopped = false
        paused = false
        setLatestLevel(0)

        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 4_096, format: inputFormat) { [weak self] buffer, _ in
            guard let self, let copiedBuffer = Self.copy(buffer) else { return }
            self.processingQueue.async { [weak self] in
                self?.process(copiedBuffer)
            }
        }

        engine.prepare()
        try engine.start()
    }

    func pause() {
        stateLock.lock()
        paused = true
        stateLock.unlock()

        engine.pause()
        setLatestLevel(0)
    }

    func resume() throws {
        stateLock.lock()
        paused = false
        let shouldStart = !stopped && !engine.isRunning
        stateLock.unlock()

        if shouldStart {
            try engine.start()
        }
    }

    func stop() {
        stateLock.lock()
        stopped = true
        paused = false
        stateLock.unlock()

        engine.inputNode.removeTap(onBus: 0)
        engine.stop()

        processingQueue.sync {
            flushPendingSamples()
            audioFile = nil
            converter = nil
            pendingSamples.removeAll(keepingCapacity: false)
        }
        setLatestLevel(0)
    }

    private func process(_ buffer: AVAudioPCMBuffer) {
        guard shouldProcess else { return }

        try? audioFile?.write(from: buffer)
        setLatestLevel(Self.level(from: buffer))
        emitConvertedPCM(from: buffer)
    }

    private var shouldProcess: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return !stopped && !paused
    }

    private func emitConvertedPCM(from buffer: AVAudioPCMBuffer) {
        guard let converter,
              let outputBuffer = AVAudioPCMBuffer(
                pcmFormat: targetFormat,
                frameCapacity: AVAudioFrameCount(Double(buffer.frameLength) * targetFormat.sampleRate / buffer.format.sampleRate) + 128
              ) else { return }

        let state = ConverterInputState()
        let inputBlock: AVAudioConverterInputBlock = { _, outStatus in
            if state.didProvideInput {
                outStatus.pointee = .noDataNow
                return nil
            }
            state.didProvideInput = true
            outStatus.pointee = .haveData
            return buffer
        }

        var error: NSError?
        converter.convert(to: outputBuffer, error: &error, withInputFrom: inputBlock)
        guard error == nil,
              let channel = outputBuffer.floatChannelData?[0],
              outputBuffer.frameLength > 0 else { return }

        let frameCount = Int(outputBuffer.frameLength)
        pendingSamples.append(contentsOf: UnsafeBufferPointer(start: channel, count: frameCount))

        while pendingSamples.count >= chunkSampleCount {
            let chunk = Array(pendingSamples.prefix(chunkSampleCount))
            pendingSamples.removeFirst(chunkSampleCount)
            chunk.withUnsafeBufferPointer { pointer in
                guard let baseAddress = pointer.baseAddress else { return }
                onPCMChunk?(Data(bytes: baseAddress, count: chunk.count * MemoryLayout<Float>.size))
            }
        }
    }

    private func flushPendingSamples() {
        guard !pendingSamples.isEmpty else { return }

        pendingSamples.withUnsafeBufferPointer { pointer in
            guard let baseAddress = pointer.baseAddress else { return }
            onPCMChunk?(Data(bytes: baseAddress, count: pendingSamples.count * MemoryLayout<Float>.size))
        }
        pendingSamples.removeAll(keepingCapacity: true)
    }

    private func setLatestLevel(_ level: Double) {
        stateLock.lock()
        latestLevelStorage = level
        stateLock.unlock()
        onLevel(level)
    }

    private static func copy(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard let copiedBuffer = AVAudioPCMBuffer(
            pcmFormat: buffer.format,
            frameCapacity: buffer.frameLength
        ) else { return nil }

        copiedBuffer.frameLength = buffer.frameLength
        let sourceBuffers = UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList)
        let destinationBuffers = UnsafeMutableAudioBufferListPointer(copiedBuffer.mutableAudioBufferList)

        for index in 0..<min(sourceBuffers.count, destinationBuffers.count) {
            guard let source = sourceBuffers[index].mData,
                  let destination = destinationBuffers[index].mData else { continue }
            let byteCount = Int(sourceBuffers[index].mDataByteSize)
            memcpy(destination, source, byteCount)
            destinationBuffers[index].mDataByteSize = sourceBuffers[index].mDataByteSize
        }

        return copiedBuffer
    }

    private static func level(from buffer: AVAudioPCMBuffer) -> Double {
        guard let channelData = buffer.floatChannelData, buffer.frameLength > 0 else {
            return 0
        }

        let channelCount = Int(buffer.format.channelCount)
        let frameCount = Int(buffer.frameLength)
        guard channelCount > 0, frameCount > 0 else { return 0 }

        var sum: Float = 0
        for channelIndex in 0..<channelCount {
            let channel = channelData[channelIndex]
            for frameIndex in 0..<frameCount {
                let sample = channel[frameIndex]
                sum += sample * sample
            }
        }

        let rms = sqrt(Double(sum) / Double(channelCount * frameCount))
        return min(max(rms * 8, 0), 1)
    }
}

private final class ConverterInputState: @unchecked Sendable {
    var didProvideInput = false
}
