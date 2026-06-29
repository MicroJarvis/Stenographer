import Foundation

struct LiveSpeakerDiarizationUpdate: Sendable {
    var commandID: UUID
    var result: SpeakerDiarizationResult
}

struct SpeakerDiarizationResult: Codable, Sendable {
    var speakers: [RecognizedSpeaker]
    var segments: [SpeakerDiarizationSegment]
    var transcript: [TranscriptEntry]
}

struct RecognizedSpeaker: Identifiable, Codable, Sendable {
    var id: UUID
    var name: String
    var voiceprint: String
    var role: String
    var confidence: String
    var embedding: [Double]
    var sourceSpk: Int
    var similarity: Double?
}

struct SpeakerDiarizationSegment: Codable, Sendable {
    var startMS: Int
    var endMS: Int
    var sourceSpk: Int
    var speakerID: UUID
    var text: String
}

enum SpeakerDiarizationError: LocalizedError {
    case missingAudioFile
    case helperMissing
    case alreadyRunning
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .missingAudioFile:
            "没有找到录音文件。"
        case .helperMissing:
            "没有找到 FunASR CAM++ 声纹脚本。"
        case .alreadyRunning:
            "FunASR CAM++ 正在分析声纹。"
        case .failed(let message):
            message
        }
    }
}

@MainActor
final class SpeakerDiarizationService: ObservableObject {
    @Published private(set) var isRunning = false
    @Published private(set) var isLiveRunning = false
    @Published private(set) var statusText = "待分析"

    let modelName = "FunASR CAM++"
    private let liveWindowSeconds = 45
    private let liveHopSeconds = 15
    private var liveWorker: Process?
    private var liveInputPipe: Pipe?
    private var liveSegmenter: LiveSpeakerAudioSegmenter?
    private var liveOnUpdate: ((LiveSpeakerDiarizationUpdate) -> Void)?

    func diarize(audioPath: String, outputPath: String, libraryPath: String) async throws -> SpeakerDiarizationResult {
        guard !isRunning else {
            throw SpeakerDiarizationError.alreadyRunning
        }
        guard FileManager.default.fileExists(atPath: audioPath) else {
            throw SpeakerDiarizationError.missingAudioFile
        }

        let helperURL = try resolveHelperURL()
        let invocation = resolvePythonInvocation()
        let environment = processEnvironment()

        isRunning = true
        statusText = "CAM++ 声纹分析中"
        defer { isRunning = false }

        do {
            let result: SpeakerDiarizationResult = try await Task.detached(priority: .utility) {
                let process = Process()
                process.executableURL = invocation.executableURL
                process.arguments = invocation.arguments + [
                    helperURL.path,
                    "--audio", audioPath,
                    "--output", outputPath,
                    "--library", libraryPath
                ]
                process.environment = environment

                let errorPipe = Pipe()
                let errorCollector = PipeCollector(pipe: errorPipe, label: "Stenographer.SpeakerDiarizationErrorCollector")
                process.standardError = errorPipe
                errorCollector.start()

                try process.run()
                process.waitUntilExit()
                let errorOutput = errorCollector.finish()

                if process.terminationStatus != 0 {
                    throw SpeakerDiarizationError.failed(errorOutput.isEmpty ? "FunASR CAM++ 声纹分析失败。" : errorOutput)
                }

                let data = try Data(contentsOf: URL(fileURLWithPath: outputPath))
                return try JSONDecoder().decode(SpeakerDiarizationResult.self, from: data)
            }.value

            statusText = result.speakers.isEmpty ? "未检测到声纹" : "已分析"
            return result
        } catch {
            statusText = "分析失败"
            throw error
        }
    }

    func startLiveDiarization(
        meetingDirectoryPath: String,
        libraryPath: String,
        onUpdate: @escaping (LiveSpeakerDiarizationUpdate) -> Void,
        onError: @escaping @Sendable (String) -> Void
    ) throws -> (Data) -> Void {
        stopLiveDiarization(sendStop: false)

        let workerURL = try resolveWorkerURL()
        let invocation = resolvePythonInvocation()
        let process = Process()
        process.executableURL = invocation.executableURL
        process.arguments = invocation.arguments + [
            workerURL.path,
            "--library", libraryPath
        ]
        process.environment = processEnvironment()

        let inputPipe = Pipe()
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardInput = inputPipe
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        let segmenter = LiveSpeakerAudioSegmenter(
            directoryURL: URL(fileURLWithPath: meetingDirectoryPath, isDirectory: true)
                .appendingPathComponent("speaker_live_segments", isDirectory: true),
            windowSeconds: liveWindowSeconds,
            hopSeconds: liveHopSeconds,
            onSegment: { [weak self] segment in
                Task { @MainActor in
                    self?.submitLiveSegment(segment)
                }
            },
            onFinished: { [weak self] in
                Task { @MainActor in
                    self?.finishLiveWorkerInput()
                }
            }
        )

        liveWorker = process
        liveInputPipe = inputPipe
        liveSegmenter = segmenter
        liveOnUpdate = onUpdate

        DispatchQueue(label: "Stenographer.LiveSpeakerOutputReader").async { [weak self] in
            let handle = outputPipe.fileHandleForReading
            var buffer = Data()
            while true {
                let data = handle.availableData
                if data.isEmpty { break }
                buffer.append(data)
                while let newline = buffer.firstIndex(of: 10) {
                    let line = buffer[..<newline]
                    buffer.removeSubrange(...newline)
                    guard !line.isEmpty else { continue }
                    DispatchQueue.main.async {
                        self?.handleLiveWorkerLine(Data(line), onError: onError)
                    }
                }
            }
        }

        DispatchQueue(label: "Stenographer.LiveSpeakerErrorReader").async {
            let data = errorPipe.fileHandleForReading.readDataToEndOfFile()
            guard !data.isEmpty,
                  let message = String(data: data, encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines),
                  !message.isEmpty else { return }
            DispatchQueue.main.async {
                onError(message)
            }
        }

        try process.run()
        isLiveRunning = true
        statusText = "加载 CAM++"

        return { [weak segmenter] data in
            segmenter?.appendPCMFloat32(data)
        }
    }

    func finishLiveDiarization() {
        statusText = "声纹收尾中"
        liveSegmenter?.finish()
    }

    func stopLiveDiarization(sendStop: Bool = true) {
        if sendStop, liveWorker?.isRunning == true {
            sendLiveCommand(["type": "stop"])
        }
        liveSegmenter = nil
        liveOnUpdate = nil
        if liveWorker?.isRunning == true {
            liveWorker?.terminate()
        }
        liveWorker = nil
        try? liveInputPipe?.fileHandleForWriting.close()
        liveInputPipe = nil
        isLiveRunning = false
        if !isRunning {
            statusText = "待分析"
        }
    }

    private func resolveHelperURL() throws -> URL {
        let bundledURL = Bundle.main.resourceURL?
            .appendingPathComponent("Scripts", isDirectory: true)
            .appendingPathComponent("funasr_speaker_diarize.py")
        if let bundledURL, FileManager.default.fileExists(atPath: bundledURL.path) {
            return bundledURL
        }

        let projectURL = projectRootURL()
            .appendingPathComponent("scripts", isDirectory: true)
            .appendingPathComponent("funasr_speaker_diarize.py")
        if FileManager.default.fileExists(atPath: projectURL.path) {
            return projectURL
        }

        throw SpeakerDiarizationError.helperMissing
    }

    private func resolveWorkerURL() throws -> URL {
        let bundledURL = Bundle.main.resourceURL?
            .appendingPathComponent("Scripts", isDirectory: true)
            .appendingPathComponent("funasr_speaker_worker.py")
        if let bundledURL, FileManager.default.fileExists(atPath: bundledURL.path) {
            return bundledURL
        }

        let projectURL = projectRootURL()
            .appendingPathComponent("scripts", isDirectory: true)
            .appendingPathComponent("funasr_speaker_worker.py")
        if FileManager.default.fileExists(atPath: projectURL.path) {
            return projectURL
        }

        throw SpeakerDiarizationError.helperMissing
    }

    private func submitLiveSegment(_ segment: LiveSpeakerAudioSegment) {
        sendLiveCommand([
            "type": "analyze",
            "id": segment.id.uuidString,
            "audio": segment.audioURL.path,
            "offsetMS": segment.offsetMS
        ])
        statusText = "实时声纹分析中"
    }

    private func finishLiveWorkerInput() {
        sendLiveCommand(["type": "stop"])
        try? liveInputPipe?.fileHandleForWriting.close()
    }

    private func sendLiveCommand(_ command: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: command),
              let line = String(data: data, encoding: .utf8)?.data(using: .utf8) else { return }
        do {
            try liveInputPipe?.fileHandleForWriting.write(contentsOf: line)
            try liveInputPipe?.fileHandleForWriting.write(contentsOf: Data([10]))
        } catch {
            statusText = "声纹分析失败"
        }
    }

    private func handleLiveWorkerLine(_ line: Data, onError: @escaping @Sendable (String) -> Void) {
        guard let event = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              let type = event["type"] as? String else { return }

        switch type {
        case "ready":
            statusText = "等待声纹窗口"
        case "result":
            guard let idString = event["id"] as? String,
                  let commandID = UUID(uuidString: idString),
                  let payload = try? JSONSerialization.data(withJSONObject: [
                    "speakers": event["speakers"] ?? [],
                    "segments": event["segments"] ?? [],
                    "transcript": event["transcript"] ?? []
                  ]),
                  let result = try? JSONDecoder().decode(SpeakerDiarizationResult.self, from: payload) else { return }
            statusText = result.speakers.isEmpty ? "窗口无声纹" : "已实时分析"
            liveOnUpdate?(LiveSpeakerDiarizationUpdate(commandID: commandID, result: result))
        case "error", "fatal":
            statusText = "声纹分析失败"
            onError(event["message"] as? String ?? "FunASR CAM++ 实时声纹分析失败。")
        case "stopped":
            isLiveRunning = false
            liveWorker = nil
            liveInputPipe = nil
            liveSegmenter = nil
            liveOnUpdate = nil
            if !isRunning {
                statusText = "已实时分析"
            }
        default:
            break
        }
    }

    private func resolvePythonInvocation() -> PythonInvocation {
        let funASRPython = projectRootURL()
            .appendingPathComponent(".venv", isDirectory: true)
            .appendingPathComponent("bin", isDirectory: true)
            .appendingPathComponent("python")
        if FileManager.default.fileExists(atPath: funASRPython.path) {
            return PythonInvocation(executableURL: funASRPython, arguments: [], displayPath: funASRPython.path)
        }

        return PythonInvocation(
            executableURL: URL(fileURLWithPath: "/usr/bin/env"),
            arguments: ["python3"],
            displayPath: "/usr/bin/env python3"
        )
    }

    private func processEnvironment() -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        let projectRoot = projectRootURL().path
        let funASRBin = projectRootURL()
            .appendingPathComponent(".venv", isDirectory: true)
            .appendingPathComponent("bin", isDirectory: true)
            .path
        environment["PATH"] = "\(funASRBin):" + (environment["PATH"] ?? "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin")
        environment["STENOGRAPHER_PROJECT_ROOT"] = projectRoot
        environment["VOICETRANSFORM_PROJECT_ROOT"] = projectRoot
        environment["PYTHONNOUSERSITE"] = "1"
        environment["FUNASR_DEVICE"] = "cpu"
        return environment
    }

    private func projectRootURL() -> URL {
        let bundleURL = Bundle.main.bundleURL
        if bundleURL.pathExtension == "app" {
            return bundleURL.deletingLastPathComponent()
        }

        return URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
    }
}

private struct LiveSpeakerAudioSegment: Sendable {
    var id: UUID
    var audioURL: URL
    var offsetMS: Int
}

private final class LiveSpeakerAudioSegmenter: @unchecked Sendable {
    private let directoryURL: URL
    private let windowFrameCount: Int
    private let hopFrameCount: Int
    private let onSegment: @Sendable (LiveSpeakerAudioSegment) -> Void
    private let onFinished: @Sendable () -> Void
    private let queue = DispatchQueue(label: "Stenographer.LiveSpeakerAudioSegmenter")
    private var samples: [Float] = []
    private var nextEmitSampleCount: Int
    private var totalSampleCount = 0
    private var emittedWindowCount = 0
    private var isFinished = false

    init(
        directoryURL: URL,
        windowSeconds: Int,
        hopSeconds: Int,
        onSegment: @escaping @Sendable (LiveSpeakerAudioSegment) -> Void,
        onFinished: @escaping @Sendable () -> Void
    ) {
        self.directoryURL = directoryURL
        self.windowFrameCount = max(1, windowSeconds) * 16_000
        self.hopFrameCount = max(1, hopSeconds) * 16_000
        self.nextEmitSampleCount = self.windowFrameCount
        self.onSegment = onSegment
        self.onFinished = onFinished
        samples.reserveCapacity(self.windowFrameCount + self.hopFrameCount)
    }

    func appendPCMFloat32(_ data: Data) {
        guard !data.isEmpty else { return }
        let copied = Data(data)
        queue.async { [weak self] in
            self?.appendOnQueue(copied)
        }
    }

    func finish() {
        queue.async { [weak self] in
            guard let self, !self.isFinished else { return }
            self.isFinished = true
            if self.totalSampleCount >= 16_000 * 8 {
                self.emitWindow(endingAtSample: self.totalSampleCount)
            }
            self.onFinished()
        }
    }

    private func appendOnQueue(_ data: Data) {
        guard !isFinished else { return }
        data.withUnsafeBytes { rawBuffer in
            let floatBuffer = rawBuffer.bindMemory(to: Float.self)
            samples.append(contentsOf: floatBuffer)
            totalSampleCount += floatBuffer.count
        }

        trimOldSamples()
        while totalSampleCount >= nextEmitSampleCount {
            emitWindow(endingAtSample: nextEmitSampleCount)
            nextEmitSampleCount += hopFrameCount
        }
    }

    private func emitWindow(endingAtSample endSample: Int) {
        let availableStartSample = totalSampleCount - samples.count
        let startSample = max(availableStartSample, max(0, endSample - windowFrameCount))
        let startIndex = max(0, startSample - availableStartSample)
        let endIndex = min(samples.count, max(0, endSample - availableStartSample))
        guard endIndex > startIndex else { return }

        let windowSamples = Array(samples[startIndex..<endIndex])
        do {
            try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
            let segmentID = UUID()
            let audioURL = directoryURL.appendingPathComponent("\(emittedWindowCount)-\(segmentID.uuidString).wav")
            try Self.writeWAV(samples: windowSamples, to: audioURL)
            emittedWindowCount += 1
            onSegment(
                LiveSpeakerAudioSegment(
                    id: segmentID,
                    audioURL: audioURL,
                    offsetMS: startSample * 1000 / 16_000
                )
            )
        } catch {
            samples.removeAll(keepingCapacity: true)
        }
    }

    private func trimOldSamples() {
        let maximumSampleCount = windowFrameCount + hopFrameCount
        guard samples.count > maximumSampleCount else { return }
        samples.removeFirst(samples.count - maximumSampleCount)
    }

    private static func writeWAV(samples: [Float], to url: URL) throws {
        var data = Data()
        let sampleRate: UInt32 = 16_000
        let channelCount: UInt16 = 1
        let bitsPerSample: UInt16 = 16
        let byteRate = sampleRate * UInt32(channelCount) * UInt32(bitsPerSample / 8)
        let blockAlign = channelCount * (bitsPerSample / 8)
        let pcmByteCount = UInt32(samples.count * MemoryLayout<Int16>.size)

        data.appendASCII("RIFF")
        data.appendLittleEndian(UInt32(36) + pcmByteCount)
        data.appendASCII("WAVE")
        data.appendASCII("fmt ")
        data.appendLittleEndian(UInt32(16))
        data.appendLittleEndian(UInt16(1))
        data.appendLittleEndian(channelCount)
        data.appendLittleEndian(sampleRate)
        data.appendLittleEndian(byteRate)
        data.appendLittleEndian(blockAlign)
        data.appendLittleEndian(bitsPerSample)
        data.appendASCII("data")
        data.appendLittleEndian(pcmByteCount)

        for sample in samples {
            let clipped = max(-1, min(1, sample))
            let intSample = Int16(clipped * Float(Int16.max))
            data.appendLittleEndian(intSample)
        }

        try data.write(to: url, options: .atomic)
    }
}
