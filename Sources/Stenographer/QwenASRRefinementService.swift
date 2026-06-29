import Foundation

struct QwenLiveRefinementUpdate: Sendable {
    var commandID: UUID
    var entries: [TranscriptEntry]
}

enum QwenASRRefinementError: LocalizedError {
    case missingAudioFile
    case helperMissing
    case alreadyRunning
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .missingAudioFile:
            "没有找到录音文件。"
        case .helperMissing:
            "没有找到 Qwen3-ASR 二遍增强脚本。"
        case .alreadyRunning:
            "Qwen3-ASR 正在处理上一段录音。"
        case .failed(let message):
            message
        }
    }
}

@MainActor
final class QwenASRRefinementService: ObservableObject {
    @Published private(set) var isRunning = false
    @Published private(set) var statusText = "待增强"

    let modelName: String
    private let liveSegmentSeconds = 20
    private var liveWorker: Process?
    private var liveInputPipe: Pipe?
    private var liveOutputQueue: DispatchQueue?
    private var liveErrorQueue: DispatchQueue?
    private var liveSegmenter: QwenLiveAudioSegmenter?
    private var liveEntriesByCommand: [UUID: [TranscriptEntry]] = [:]
    private var liveOnUpdate: ((QwenLiveRefinementUpdate) -> Void)?
    private var isLiveSessionActive = false

    init(modelName: String? = ProcessInfo.processInfo.environment["QWEN_ASR_MODEL"]) {
        self.modelName = modelName ?? Self.defaultModelPath()
    }

    var pythonPath: String {
        resolvePythonInvocation().displayPath
    }

    func reset() {
        guard !isRunning else { return }
        statusText = "待增强"
        liveEntriesByCommand.removeAll()
    }

    func startLiveEnhancement(
        meetingDirectoryPath: String,
        language: String,
        onUpdate: @escaping (QwenLiveRefinementUpdate) -> Void,
        onError: @escaping @Sendable (String) -> Void
    ) throws -> (Data) -> Void {
        stopLiveEnhancement(sendStop: false)

        let workerURL = try resolveWorkerURL()
        let invocation = resolvePythonInvocation()
        let process = Process()
        process.executableURL = invocation.executableURL
        process.arguments = invocation.arguments + [
            workerURL.path,
            "--model", modelName,
            "--language", language
        ]
        process.environment = processEnvironment()

        let inputPipe = Pipe()
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardInput = inputPipe
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        let segmentDirectoryURL = URL(fileURLWithPath: meetingDirectoryPath, isDirectory: true)
            .appendingPathComponent("qwen_live_segments", isDirectory: true)
        let segmenter = QwenLiveAudioSegmenter(
            directoryURL: segmentDirectoryURL,
            segmentSeconds: liveSegmentSeconds,
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
        isLiveSessionActive = true
        liveEntriesByCommand.removeAll()

        let outputQueue = DispatchQueue(label: "Stenographer.QwenLiveOutputReader")
        liveOutputQueue = outputQueue
        outputQueue.async { [weak self] in
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

        let errorQueue = DispatchQueue(label: "Stenographer.QwenLiveErrorReader")
        liveErrorQueue = errorQueue
        errorQueue.async {
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
        statusText = "加载 Qwen3-ASR"

        return { [weak segmenter] data in
            segmenter?.appendPCMFloat32(data)
        }
    }

    func finishLiveEnhancement() {
        statusText = "收尾增强中"
        liveSegmenter?.finish()
    }

    func stopLiveEnhancement(sendStop: Bool = true) {
        if sendStop, liveWorker?.isRunning == true {
            sendLiveCommand(["type": "stop"])
        }
        liveSegmenter?.finish()
        liveSegmenter = nil
        liveOnUpdate = nil
        isLiveSessionActive = false
        if liveWorker?.isRunning == true {
            liveWorker?.terminate()
        }
        liveWorker = nil
        try? liveInputPipe?.fileHandleForWriting.close()
        liveInputPipe = nil
        liveOutputQueue = nil
        liveErrorQueue = nil
        if !isRunning {
            statusText = liveEntriesByCommand.isEmpty ? "待增强" : "已滚动增强"
        }
    }

    func refine(audioPath: String, outputPath: String, language: String) async throws -> [TranscriptEntry] {
        guard !isRunning else {
            throw QwenASRRefinementError.alreadyRunning
        }
        guard FileManager.default.fileExists(atPath: audioPath) else {
            throw QwenASRRefinementError.missingAudioFile
        }

        let helperURL = try resolveHelperURL()
        guard FileManager.default.fileExists(atPath: helperURL.path) else {
            throw QwenASRRefinementError.helperMissing
        }

        isRunning = true
        statusText = "二遍增强中"
        defer {
            isRunning = false
        }

        let invocation = resolvePythonInvocation()
        let environment = processEnvironment()
        let modelName = modelName

        do {
            let entries: [TranscriptEntry] = try await Task.detached(priority: .utility) {
                let process = Process()
                process.executableURL = invocation.executableURL
                process.arguments = invocation.arguments + [
                    helperURL.path,
                    "--audio", audioPath,
                    "--output", outputPath,
                    "--model", modelName,
                    "--language", language
                ]
                process.environment = environment

                let errorPipe = Pipe()
                let errorCollector = PipeCollector(pipe: errorPipe)
                process.standardError = errorPipe
                errorCollector.start()

                try process.run()
                process.waitUntilExit()
                let errorOutput = errorCollector.finish()

                if process.terminationStatus != 0 {
                    throw QwenASRRefinementError.failed(errorOutput.isEmpty ? "Qwen3-ASR 二遍增强失败。" : errorOutput)
                }

                let data = try Data(contentsOf: URL(fileURLWithPath: outputPath))
                return try JSONDecoder().decode([TranscriptEntry].self, from: data)
            }.value

            statusText = entries.isEmpty ? "无可用语音" : "已增强"
            return entries
        } catch {
            statusText = "增强失败"
            throw error
        }
    }

    private func submitLiveSegment(_ segment: QwenLiveAudioSegment) {
        guard isLiveSessionActive else { return }
        sendLiveCommand([
            "type": "transcribe",
            "id": segment.id.uuidString,
            "audio": segment.audioURL.path,
            "time": segment.startTime,
            "startMS": segment.startMS,
            "endMS": segment.endMS
        ])
        statusText = "滚动增强中"
    }

    private func finishLiveWorkerInput() {
        guard isLiveSessionActive else { return }
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
            statusText = "增强失败"
        }
    }

    private func handleLiveWorkerLine(_ line: Data, onError: @escaping @Sendable (String) -> Void) {
        guard let event = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              let type = event["type"] as? String else { return }

        switch type {
        case "ready":
            statusText = "等待稳定片段"
        case "result":
            guard let idString = event["id"] as? String,
                  let commandID = UUID(uuidString: idString),
                  let payload = try? JSONSerialization.data(withJSONObject: event["entries"] ?? []),
                  let entries = try? JSONDecoder().decode([TranscriptEntry].self, from: payload) else { return }
            liveEntriesByCommand[commandID] = entries
            statusText = entries.isEmpty ? "片段无语音" : "已滚动增强"
            liveOnUpdate?(QwenLiveRefinementUpdate(commandID: commandID, entries: entries))
        case "error", "fatal":
            statusText = "增强失败"
            onError(event["message"] as? String ?? "Qwen3-ASR 滚动增强失败。")
        case "stopped":
            isLiveSessionActive = false
            liveWorker = nil
            liveInputPipe = nil
            liveSegmenter = nil
            liveOnUpdate = nil
            if !isRunning {
                statusText = liveEntriesByCommand.isEmpty ? "待增强" : "已滚动增强"
            }
        default:
            break
        }
    }

    private func resolveHelperURL() throws -> URL {
        let bundledURL = Bundle.main.resourceURL?
            .appendingPathComponent("Scripts", isDirectory: true)
            .appendingPathComponent("qwen_asr_refine.py")
        if let bundledURL, FileManager.default.fileExists(atPath: bundledURL.path) {
            return bundledURL
        }

        let projectURL = projectRootURL()
            .appendingPathComponent("scripts", isDirectory: true)
            .appendingPathComponent("qwen_asr_refine.py")
        if FileManager.default.fileExists(atPath: projectURL.path) {
            return projectURL
        }

        throw QwenASRRefinementError.helperMissing
    }

    private func resolveWorkerURL() throws -> URL {
        let bundledURL = Bundle.main.resourceURL?
            .appendingPathComponent("Scripts", isDirectory: true)
            .appendingPathComponent("qwen_asr_worker.py")
        if let bundledURL, FileManager.default.fileExists(atPath: bundledURL.path) {
            return bundledURL
        }

        let projectURL = projectRootURL()
            .appendingPathComponent("scripts", isDirectory: true)
            .appendingPathComponent("qwen_asr_worker.py")
        if FileManager.default.fileExists(atPath: projectURL.path) {
            return projectURL
        }

        throw QwenASRRefinementError.helperMissing
    }

    private func resolvePythonInvocation() -> PythonInvocation {
        let qwenPython = projectRootURL()
            .appendingPathComponent(".venv-qwen", isDirectory: true)
            .appendingPathComponent("bin", isDirectory: true)
            .appendingPathComponent("python")
        if FileManager.default.fileExists(atPath: qwenPython.path) {
            return PythonInvocation(executableURL: qwenPython, arguments: [], displayPath: qwenPython.path)
        }

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
        let qwenBin = projectRootURL()
            .appendingPathComponent(".venv-qwen", isDirectory: true)
            .appendingPathComponent("bin", isDirectory: true)
            .path
        let funASRBin = projectRootURL()
            .appendingPathComponent(".venv", isDirectory: true)
            .appendingPathComponent("bin", isDirectory: true)
            .path

        environment["PATH"] = "\(qwenBin):\(funASRBin):" + (environment["PATH"] ?? "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin")
        environment["STENOGRAPHER_PROJECT_ROOT"] = projectRoot
        environment["VOICETRANSFORM_PROJECT_ROOT"] = projectRoot
        environment["PYTHONNOUSERSITE"] = "1"
        environment["PYTORCH_ENABLE_MPS_FALLBACK"] = "1"
        environment["TOKENIZERS_PARALLELISM"] = "false"
        return environment
    }

    private func projectRootURL() -> URL {
        let bundleURL = Bundle.main.bundleURL
        if bundleURL.pathExtension == "app" {
            return bundleURL.deletingLastPathComponent()
        }

        return URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
    }

    private static func defaultModelPath() -> String {
        let bundleURL = Bundle.main.bundleURL
        let projectRoot: URL
        if bundleURL.pathExtension == "app" {
            projectRoot = bundleURL.deletingLastPathComponent()
        } else {
            projectRoot = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
        }

        let localModelURL = projectRoot
            .appendingPathComponent("Models", isDirectory: true)
            .appendingPathComponent("Qwen3-ASR-1.7B", isDirectory: true)
        if FileManager.default.fileExists(atPath: localModelURL.appendingPathComponent("config.json").path) {
            return localModelURL.path
        }

        return "Qwen/Qwen3-ASR-1.7B"
    }
}

struct PythonInvocation: Sendable {
    var executableURL: URL
    var arguments: [String]
    var displayPath: String
}

final class PipeCollector: @unchecked Sendable {
    private let pipe: Pipe
    private let queue: DispatchQueue
    private let lock = NSLock()
    private var data = Data()

    init(pipe: Pipe, label: String = "Stenographer.QwenASRRefinementPipeCollector") {
        self.pipe = pipe
        self.queue = DispatchQueue(label: label)
    }

    func start() {
        queue.async { [weak self] in
            guard let self else { return }
            let captured = self.pipe.fileHandleForReading.readDataToEndOfFile()
            self.lock.lock()
            self.data.append(captured)
            self.lock.unlock()
        }
    }

    func finish() -> String {
        queue.sync {}
        lock.lock()
        let captured = data
        lock.unlock()
        return String(data: captured, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }
}

private struct QwenLiveAudioSegment: Sendable {
    var id: UUID
    var audioURL: URL
    var startTime: String
    var startMS: Int
    var endMS: Int
}

private final class QwenLiveAudioSegmenter: @unchecked Sendable {
    private let directoryURL: URL
    private let segmentFrameCount: Int
    private let onSegment: @Sendable (QwenLiveAudioSegment) -> Void
    private let onFinished: @Sendable () -> Void
    private let queue = DispatchQueue(label: "Stenographer.QwenLiveAudioSegmenter")
    private var pendingSamples: [Float] = []
    private var emittedSegmentCount = 0
    private var emittedSampleCount = 0
    private var isFinished = false

    init(
        directoryURL: URL,
        segmentSeconds: Int,
        onSegment: @escaping @Sendable (QwenLiveAudioSegment) -> Void,
        onFinished: @escaping @Sendable () -> Void
    ) {
        self.directoryURL = directoryURL
        self.segmentFrameCount = max(1, segmentSeconds) * 16_000
        self.onSegment = onSegment
        self.onFinished = onFinished
        pendingSamples.reserveCapacity(self.segmentFrameCount * 2)
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
            if self.pendingSamples.count >= 16_000 {
                self.emitSegment(sampleCount: self.pendingSamples.count)
            } else {
                self.pendingSamples.removeAll(keepingCapacity: false)
            }
            self.onFinished()
        }
    }

    private func appendOnQueue(_ data: Data) {
        guard !isFinished else { return }
        data.withUnsafeBytes { rawBuffer in
            let floatBuffer = rawBuffer.bindMemory(to: Float.self)
            pendingSamples.append(contentsOf: floatBuffer)
        }

        while pendingSamples.count >= segmentFrameCount {
            emitSegment(sampleCount: segmentFrameCount)
        }
    }

    private func emitSegment(sampleCount: Int) {
        let samples = Array(pendingSamples.prefix(sampleCount))
        pendingSamples.removeFirst(sampleCount)

        do {
            try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
            let segmentID = UUID()
            let audioURL = directoryURL.appendingPathComponent("\(emittedSegmentCount)-\(segmentID.uuidString).wav")
            try Self.writeWAV(samples: samples, to: audioURL)
            let segment = QwenLiveAudioSegment(
                id: segmentID,
                audioURL: audioURL,
                startTime: Self.timeString(seconds: emittedSampleCount / 16_000),
                startMS: emittedSampleCount * 1000 / 16_000,
                endMS: (emittedSampleCount + sampleCount) * 1000 / 16_000
            )
            emittedSegmentCount += 1
            emittedSampleCount += sampleCount
            onSegment(segment)
        } catch {
            pendingSamples.removeAll(keepingCapacity: true)
        }
    }

    private static func timeString(seconds: Int) -> String {
        let hours = seconds / 3600
        let minutes = (seconds % 3600) / 60
        let seconds = seconds % 60
        return String(format: "%02d:%02d:%02d", hours, minutes, seconds)
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

extension Data {
    mutating func appendASCII(_ string: String) {
        append(contentsOf: string.utf8)
    }

    mutating func appendLittleEndian<T: FixedWidthInteger>(_ value: T) {
        var littleEndian = value.littleEndian
        Swift.withUnsafeBytes(of: &littleEndian) { buffer in
            append(buffer.bindMemory(to: UInt8.self))
        }
    }
}
