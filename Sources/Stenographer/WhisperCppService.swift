import Foundation

struct WhisperLiveTranscriptionUpdate: Sendable {
    var commandID: UUID
    var entries: [TranscriptEntry]
}

enum WhisperCppError: LocalizedError {
    case missingExecutable
    case missingLargeModel
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .missingExecutable:
            "没有找到 whisper.cpp/main。"
        case .missingLargeModel:
            "没有找到 Whisper large 模型。请下载 ggml-large-v1.bin 到 whisper.cpp/models。"
        case .failed(let message):
            message
        }
    }
}

@MainActor
final class WhisperCppService: ObservableObject {
    @Published private(set) var isRunning = false
    @Published private(set) var statusText = "待转写"

    private let liveSegmentSeconds = 12
    private var liveSegmenter: WhisperLiveAudioSegmenter?
    private var liveEntriesByCommand: [UUID: [TranscriptEntry]] = [:]
    private var liveOnUpdate: ((WhisperLiveTranscriptionUpdate) -> Void)?
    private var liveOnError: (@Sendable (String) -> Void)?
    private var pendingSegments: [WhisperLiveAudioSegment] = []
    private var currentTask: Task<Void, Never>?
    private var liveSessionID = UUID()
    private var isLiveSessionActive = false
    private var liveLanguageCode = "auto"
    private var liveDefaultSpeakerID = UUID()

    var executablePath: String? {
        Self.resolveExecutableURL()?.path
    }

    var modelPath: String? {
        Self.resolveLargeModelURL()?.path
    }

    var modelDetail: String {
        Self.resolveLargeModelURL()?.lastPathComponent ?? "未找到 large 模型"
    }

    var isReady: Bool {
        executablePath != nil && modelPath != nil
    }

    func reset() {
        guard !isRunning else { return }
        liveEntriesByCommand.removeAll()
        statusText = isReady ? "待转写" : "缺少 large 模型"
    }

    func startLiveTranscription(
        meetingDirectoryPath: String,
        language: String,
        defaultSpeakerID: Speaker.ID,
        onUpdate: @escaping (WhisperLiveTranscriptionUpdate) -> Void,
        onError: @escaping @Sendable (String) -> Void
    ) throws -> (Data) -> Void {
        stopLiveTranscription(finishPendingAudio: false)

        guard Self.resolveExecutableURL() != nil else {
            statusText = "缺少 whisper.cpp"
            throw WhisperCppError.missingExecutable
        }
        guard Self.resolveLargeModelURL() != nil else {
            statusText = "缺少 large 模型"
            throw WhisperCppError.missingLargeModel
        }

        let sessionID = UUID()
        let segmentDirectoryURL = URL(fileURLWithPath: meetingDirectoryPath, isDirectory: true)
            .appendingPathComponent("whisper_large_segments", isDirectory: true)
        let segmenter = WhisperLiveAudioSegmenter(
            directoryURL: segmentDirectoryURL,
            segmentSeconds: liveSegmentSeconds,
            onSegment: { [weak self] segment in
                Task { @MainActor in
                    self?.submitLiveSegment(segment, sessionID: sessionID)
                }
            },
            onFinished: { [weak self] in
                Task { @MainActor in
                    self?.handleSegmenterFinished(sessionID: sessionID)
                }
            }
        )

        liveSessionID = sessionID
        liveLanguageCode = Self.whisperLanguageCode(from: language)
        liveDefaultSpeakerID = defaultSpeakerID
        liveOnUpdate = onUpdate
        liveOnError = onError
        liveSegmenter = segmenter
        pendingSegments.removeAll()
        liveEntriesByCommand.removeAll()
        isLiveSessionActive = true
        statusText = "等待稳定片段"

        return { [weak segmenter] data in
            segmenter?.appendPCMFloat32(data)
        }
    }

    func finishLiveTranscription() {
        guard isLiveSessionActive else { return }
        statusText = isRunning || !pendingSegments.isEmpty ? "收尾转写中" : "等待收尾片段"
        liveSegmenter?.finish()
    }

    func stopLiveTranscription(finishPendingAudio: Bool = true) {
        if finishPendingAudio {
            liveSegmenter?.finish()
        }
        liveSegmenter = nil
        liveOnUpdate = nil
        liveOnError = nil
        pendingSegments.removeAll()
        isLiveSessionActive = false
        currentTask?.cancel()
        currentTask = nil
        isRunning = false
        statusText = liveEntriesByCommand.isEmpty ? (isReady ? "待转写" : "缺少 large 模型") : "已滚动转写"
    }

    private func submitLiveSegment(_ segment: WhisperLiveAudioSegment, sessionID: UUID) {
        guard isLiveSessionActive, sessionID == liveSessionID else { return }
        pendingSegments.append(segment)
        if !isRunning {
            processNextSegment(sessionID: sessionID)
        } else {
            statusText = "Whisper large 排队 \(pendingSegments.count) 段"
        }
    }

    private func handleSegmenterFinished(sessionID: UUID) {
        guard sessionID == liveSessionID else { return }
        liveSegmenter = nil
        if !isRunning && pendingSegments.isEmpty {
            isLiveSessionActive = false
            statusText = liveEntriesByCommand.isEmpty ? "无可用语音" : "已滚动转写"
        }
    }

    private func processNextSegment(sessionID: UUID) {
        guard isLiveSessionActive, sessionID == liveSessionID else { return }
        guard currentTask == nil, !pendingSegments.isEmpty else {
            if pendingSegments.isEmpty && !isRunning {
                statusText = liveEntriesByCommand.isEmpty ? "等待稳定片段" : "已滚动转写"
            }
            return
        }
        guard let executableURL = Self.resolveExecutableURL(),
              let modelURL = Self.resolveLargeModelURL() else {
            statusText = "Whisper large 未就绪"
            liveOnError?(WhisperCppError.missingLargeModel.localizedDescription)
            return
        }

        let segment = pendingSegments.removeFirst()
        let languageCode = liveLanguageCode
        let defaultSpeakerID = liveDefaultSpeakerID
        let threadCount = Self.threadCount()
        isRunning = true
        statusText = "Whisper large 转写中"

        currentTask = Task { [weak self] in
            do {
                let entries = try await Task.detached(priority: .utility) {
                    try Self.transcribeSegment(
                        segment,
                        executableURL: executableURL,
                        modelURL: modelURL,
                        languageCode: languageCode,
                        defaultSpeakerID: defaultSpeakerID,
                        threadCount: threadCount
                    )
                }.value
                await MainActor.run {
                    self?.handleSegmentResult(entries, commandID: segment.id, sessionID: sessionID)
                }
            } catch {
                await MainActor.run {
                    self?.handleSegmentError(error, sessionID: sessionID)
                }
            }
        }
    }

    private func handleSegmentResult(_ entries: [TranscriptEntry], commandID: UUID, sessionID: UUID) {
        guard sessionID == liveSessionID else { return }
        currentTask = nil
        isRunning = false

        if entries.isEmpty {
            statusText = pendingSegments.isEmpty ? "片段无语音" : "Whisper large 排队 \(pendingSegments.count) 段"
        } else {
            liveEntriesByCommand[commandID] = entries
            statusText = pendingSegments.isEmpty ? "已滚动转写" : "Whisper large 排队 \(pendingSegments.count) 段"
            liveOnUpdate?(WhisperLiveTranscriptionUpdate(commandID: commandID, entries: entries))
        }

        processNextSegment(sessionID: sessionID)
    }

    private func handleSegmentError(_ error: Error, sessionID: UUID) {
        guard sessionID == liveSessionID else { return }
        currentTask = nil
        isRunning = false
        statusText = "转写失败"
        liveOnError?(error.localizedDescription)
        processNextSegment(sessionID: sessionID)
    }

    private nonisolated static func transcribeSegment(
        _ segment: WhisperLiveAudioSegment,
        executableURL: URL,
        modelURL: URL,
        languageCode: String,
        defaultSpeakerID: Speaker.ID,
        threadCount: Int
    ) throws -> [TranscriptEntry] {
        let process = Process()
        process.executableURL = executableURL
        process.arguments = [
            "-m", modelURL.path,
            "-f", segment.audioURL.path,
            "-l", languageCode,
            "-t", String(threadCount),
            "-nt",
            "--prompt", "Use accurate punctuation. Preserve English words exactly."
        ]

        let outputPipe = Pipe()
        let errorPipe = Pipe()
        let outputCollector = PipeCollector(pipe: outputPipe, label: "Stenographer.WhisperOutputCollector")
        let errorCollector = PipeCollector(pipe: errorPipe, label: "Stenographer.WhisperErrorCollector")
        process.standardOutput = outputPipe
        process.standardError = errorPipe
        outputCollector.start()
        errorCollector.start()

        try process.run()
        process.waitUntilExit()
        let output = outputCollector.finish()
        let diagnostics = errorCollector.finish()

        guard process.terminationStatus == 0 else {
            throw WhisperCppError.failed(diagnostics.isEmpty ? output : diagnostics)
        }

        let text = Self.parseTranscriptText(output: output, diagnostics: diagnostics)
        guard Self.isUsableTranscript(text) else { return [] }

        let sourceLanguage = Self.inferSourceLanguage(from: text, requestedLanguageCode: languageCode)
        return [
            TranscriptEntry(
                id: segment.id,
                time: segment.startTime,
                startMS: segment.startMS,
                endMS: segment.endMS,
                speakerID: defaultSpeakerID,
                sourceLanguage: sourceLanguage,
                original: text,
                translation: text,
                confidence: "whisper-large"
            )
        ]
    }

    private nonisolated static func parseTranscriptText(output: String, diagnostics: String) -> String {
        let primary = output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? diagnostics : output
        let ignoredPrefixes = [
            "whisper_", "ggml_", "main:", "system_info:", "sampling:", "compute buffer",
            "load time", "fallbacks", "mel time", "sample time", "encode time", "decode time", "total time"
        ]
        let lines = primary
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { line in
                guard !line.isEmpty else { return false }
                let lower = line.lowercased()
                return !ignoredPrefixes.contains { lower.hasPrefix($0) }
            }
        return cleanTranscript(lines.joined(separator: " "))
    }

    private nonisolated static func cleanTranscript(_ text: String) -> String {
        var cleaned = text
            .replacingOccurrences(of: "<|endoftext|>", with: "")
            .replacingOccurrences(of: "<|startoftranscript|>", with: "")
            .replacingOccurrences(of: "<|notimestamps|>", with: "")
            .replacingOccurrences(
                of: #"([!！?？.,，。；;:：])\1{2,}"#,
                with: "$1",
                options: .regularExpression
            )
        while let range = cleaned.range(of: "[00:") {
            guard let close = cleaned[range.lowerBound...].firstIndex(of: "]") else { break }
            cleaned.removeSubrange(range.lowerBound...close)
        }
        return cleaned
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private nonisolated static func isUsableTranscript(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 6 else { return false }

        let meaningfulCount = meaningfulCharacterCount(in: trimmed)
        guard meaningfulCount > 0 else { return false }

        let punctuationCount = punctuationCharacterCount(in: trimmed)
        if punctuationCount >= max(6, meaningfulCount * 6) {
            return false
        }

        let lower = trimmed.lowercased()
            .trimmingCharacters(in: CharacterSet(charactersIn: ".。!！?？,， "))
        let hallucinations: Set<String> = [
            "thank you",
            "thanks for watching",
            "you",
            "music",
            "字幕由amaram.org社区提供"
        ]
        return !hallucinations.contains(lower)
    }

    private nonisolated static func inferSourceLanguage(from text: String, requestedLanguageCode: String) -> String {
        if requestedLanguageCode == "en" {
            return "English"
        }
        if requestedLanguageCode == "zh" {
            return "中文"
        }
        if requestedLanguageCode == "ja" {
            return "日本語"
        }

        var latinCount = 0
        var cjkCount = 0
        var kanaCount = 0
        for scalar in text.unicodeScalars {
            switch scalar.value {
            case 0x0041...0x005A, 0x0061...0x007A:
                latinCount += 1
            case 0x3040...0x30FF:
                kanaCount += 1
            case 0x4E00...0x9FFF:
                cjkCount += 1
            default:
                break
            }
        }

        if kanaCount > 0 && kanaCount >= latinCount {
            return "日本語"
        }
        if latinCount > cjkCount {
            return "English"
        }
        if cjkCount > 0 {
            return "中文"
        }
        return "自动检测"
    }

    private static func whisperLanguageCode(from language: String) -> String {
        switch language {
        case "English":
            return "en"
        case "中文":
            return "zh"
        case "日本語":
            return "ja"
        default:
            return "auto"
        }
    }

    private static func resolveExecutableURL() -> URL? {
        if let path = ProcessInfo.processInfo.environment["WHISPER_CPP_MAIN"],
           FileManager.default.isExecutableFile(atPath: path) {
            return URL(fileURLWithPath: path)
        }

        let projectRoot = projectRootURL()
        let candidates = [
            projectRoot.appendingPathComponent("whisper.cpp/main"),
            projectRoot.deletingLastPathComponent().appendingPathComponent("whisper.cpp/main"),
            URL(fileURLWithPath: "/Users/tfjiang/Projects/whisper.cpp/main")
        ]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    private static func resolveLargeModelURL() -> URL? {
        if let path = ProcessInfo.processInfo.environment["WHISPER_CPP_MODEL"],
           isUsableModel(atPath: path) {
            return URL(fileURLWithPath: path)
        }

        let projectRoot = projectRootURL()
        let modelNames = [
            "ggml-large-v1.bin",
            "ggml-large.bin",
            "ggml-large-v2.bin",
            "ggml-large-v3.bin"
        ]
        let modelDirectories = [
            projectRoot.appendingPathComponent("Models/Whisper", isDirectory: true),
            projectRoot.appendingPathComponent("Models", isDirectory: true),
            projectRoot.deletingLastPathComponent()
                .appendingPathComponent("whisper.cpp/models", isDirectory: true),
            URL(fileURLWithPath: "/Users/tfjiang/Projects/whisper.cpp/models", isDirectory: true)
        ]

        for directory in modelDirectories {
            for modelName in modelNames {
                let url = directory.appendingPathComponent(modelName)
                if isUsableModel(atPath: url.path) {
                    return url
                }
            }
        }
        return nil
    }

    private static func isUsableModel(atPath path: String) -> Bool {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: path),
              let size = attributes[.size] as? NSNumber else { return false }
        return size.uint64Value > 100_000_000
    }

    private static func projectRootURL() -> URL {
        let bundleURL = Bundle.main.bundleURL
        if bundleURL.pathExtension == "app" {
            return bundleURL.deletingLastPathComponent()
        }
        return URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
    }

    private static func threadCount() -> Int {
        max(4, min(8, ProcessInfo.processInfo.activeProcessorCount - 2))
    }

    private nonisolated static func meaningfulCharacterCount(in text: String) -> Int {
        text.unicodeScalars.reduce(into: 0) { count, scalar in
            if isMeaningfulScalar(scalar) {
                count += 1
            }
        }
    }

    private nonisolated static func punctuationCharacterCount(in text: String) -> Int {
        text.unicodeScalars.reduce(into: 0) { count, scalar in
            if isPunctuationScalar(scalar) {
                count += 1
            }
        }
    }

    private nonisolated static func isMeaningfulScalar(_ scalar: UnicodeScalar) -> Bool {
        switch scalar.value {
        case 0x0030...0x0039, 0x0041...0x005A, 0x0061...0x007A:
            return true
        case 0x4E00...0x9FFF, 0x3040...0x30FF, 0xAC00...0xD7AF:
            return true
        default:
            return false
        }
    }

    private nonisolated static func isPunctuationScalar(_ scalar: UnicodeScalar) -> Bool {
        switch scalar.value {
        case 0x0021, 0x002C, 0x002E, 0x003A, 0x003B, 0x003F, 0x3001, 0x3002, 0xFF01, 0xFF0C, 0xFF0E, 0xFF1A, 0xFF1B, 0xFF1F:
            return true
        default:
            return false
        }
    }
}

private struct WhisperLiveAudioSegment: Sendable {
    var id: UUID
    var audioURL: URL
    var startTime: String
    var startMS: Int
    var endMS: Int
}

private final class WhisperLiveAudioSegmenter: @unchecked Sendable {
    private let directoryURL: URL
    private let segmentFrameCount: Int
    private let minimumFrameCount: Int
    private let onSegment: @Sendable (WhisperLiveAudioSegment) -> Void
    private let onFinished: @Sendable () -> Void
    private let queue = DispatchQueue(label: "Stenographer.WhisperLiveAudioSegmenter")
    private var pendingSamples: [Float] = []
    private var emittedSegmentCount = 0
    private var emittedSampleCount = 0
    private var isFinished = false

    init(
        directoryURL: URL,
        segmentSeconds: Int,
        onSegment: @escaping @Sendable (WhisperLiveAudioSegment) -> Void,
        onFinished: @escaping @Sendable () -> Void
    ) {
        self.directoryURL = directoryURL
        self.segmentFrameCount = max(4, segmentSeconds) * 16_000
        self.minimumFrameCount = 4 * 16_000
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
            if self.pendingSamples.count >= self.minimumFrameCount {
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

        guard let trimmed = Self.trimSpeech(samples) else {
            emittedSampleCount += sampleCount
            return
        }

        do {
            try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
            let segmentID = UUID()
            let audioURL = directoryURL.appendingPathComponent("\(emittedSegmentCount)-\(segmentID.uuidString).wav")
            try Self.writeWAV(samples: trimmed.samples, to: audioURL)
            let segment = WhisperLiveAudioSegment(
                id: segmentID,
                audioURL: audioURL,
                startTime: Self.timeString(seconds: (emittedSampleCount + trimmed.leadingTrimSamples) / 16_000),
                startMS: (emittedSampleCount + trimmed.leadingTrimSamples) * 1000 / 16_000,
                endMS: (emittedSampleCount + sampleCount - trimmed.trailingTrimSamples) * 1000 / 16_000
            )
            emittedSegmentCount += 1
            emittedSampleCount += sampleCount
            onSegment(segment)
        } catch {
            pendingSamples.removeAll(keepingCapacity: true)
        }
    }

    private static func rms(_ samples: [Float]) -> Float {
        guard !samples.isEmpty else { return 0 }
        var sum: Float = 0
        for sample in samples {
            sum += sample * sample
        }
        return sqrt(sum / Float(samples.count))
    }

    private static func trimSpeech(_ samples: [Float]) -> (samples: [Float], leadingTrimSamples: Int, trailingTrimSamples: Int)? {
        guard !samples.isEmpty else { return nil }

        let frameSize = 320
        let frameThreshold: Float = 0.006
        let paddingFrames = 8
        let frameCount = Int(ceil(Double(samples.count) / Double(frameSize)))
        var firstActiveFrame: Int?
        var lastActiveFrame: Int?

        for frameIndex in 0..<frameCount {
            let start = frameIndex * frameSize
            let end = min(samples.count, start + frameSize)
            guard start < end else { continue }
            let frame = Array(samples[start..<end])
            if rms(frame) >= frameThreshold {
                if firstActiveFrame == nil {
                    firstActiveFrame = frameIndex
                }
                lastActiveFrame = frameIndex
            }
        }

        guard let firstActiveFrame, let lastActiveFrame else { return nil }

        let startFrame = max(0, firstActiveFrame - paddingFrames)
        let endFrame = min(frameCount - 1, lastActiveFrame + paddingFrames)
        let startSample = startFrame * frameSize
        let endSample = min(samples.count, (endFrame + 1) * frameSize)
        guard endSample > startSample else { return nil }

        let trimmed = Array(samples[startSample..<endSample])
        guard rms(trimmed) >= 0.003 else { return nil }

        return (
            samples: trimmed,
            leadingTrimSamples: startSample,
            trailingTrimSamples: samples.count - endSample
        )
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
