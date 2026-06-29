import Foundation

struct StreamingTranscriptUpdate: Sendable {
    var text: String
    var isFinal: Bool
}

private enum StreamingWorkerEvent: Sendable {
    case ready
    case partial(String)
    case final(String)
    case error(String)
}

@MainActor
final class StreamingTranscriptionService: ObservableObject {
    @Published private(set) var isRunning = false
    @Published private(set) var statusText = "待启动"

    private var process: Process?
    private var inputPipe: Pipe?
    private var outputPipe: Pipe?
    private var outputReaderQueue: DispatchQueue?
    private var errorReaderQueue: DispatchQueue?
    private var pcmWriter: StreamingPCMWriter?
    private var onUpdate: ((StreamingTranscriptUpdate) -> Void)?
    private var didFinish = false

    func start(onUpdate: @escaping (StreamingTranscriptUpdate) -> Void, onError: @escaping @Sendable (String) -> Void) throws {
        stop()

        self.onUpdate = onUpdate
        didFinish = false
        let helperURL = try resolveHelperURL()
        let pythonURL = resolvePythonURL()

        let process = Process()
        process.executableURL = pythonURL
        process.arguments = [
            helperURL.path,
            "--model", defaultOnlineModelPath(),
            "--quantization", "auto"
        ]
        process.environment = processEnvironment()

        let inputPipe = Pipe()
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardInput = inputPipe
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        self.process = process
        self.inputPipe = inputPipe
        self.outputPipe = outputPipe
        pcmWriter = StreamingPCMWriter(inputPipe: inputPipe) { [weak self] in
            DispatchQueue.main.async {
                self?.statusText = "写入失败"
            }
        }

        let outputQueue = DispatchQueue(label: "Stenographer.StreamingTranscriptionReader")
        outputReaderQueue = outputQueue
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
                    guard let event = Self.parseEvent(line: Data(line)) else { continue }
                    DispatchQueue.main.async {
                        self?.handle(event: event, onError: onError)
                    }
                }
            }
        }

        let errorQueue = DispatchQueue(label: "Stenographer.StreamingTranscriptionErrorReader")
        errorReaderQueue = errorQueue
        errorQueue.async {
            let data = errorPipe.fileHandleForReading.readDataToEndOfFile()
            guard !data.isEmpty,
                  let message = String(data: data, encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines),
                  !message.isEmpty else { return }
            DispatchQueue.main.async { [weak self] in
                guard self?.isRunning == true else { return }
                self?.statusText = "错误"
                onError(message)
            }
        }

        try process.run()
        isRunning = true
        statusText = "启动中"
    }

    func appendPCMFloat32(_ data: Data) {
        guard isRunning, !data.isEmpty else { return }
        pcmWriter?.write(data)
    }

    func pcmChunkHandler() -> (Data) -> Void {
        guard let pcmWriter else {
            return { _ in }
        }

        return { data in
            pcmWriter.write(data)
        }
    }

    func finish() {
        guard !didFinish else { return }
        didFinish = true
        statusText = "收尾中"
        pcmWriter?.finish()
    }

    func stop() {
        outputReaderQueue = nil
        errorReaderQueue = nil
        pcmWriter?.close()
        if process?.isRunning == true {
            process?.terminate()
        }
        process = nil
        inputPipe = nil
        outputPipe = nil
        pcmWriter = nil
        onUpdate = nil
        isRunning = false
        statusText = "待启动"
        didFinish = false
    }

    private func handle(event: StreamingWorkerEvent, onError: @escaping @Sendable (String) -> Void) {
        switch event {
        case .ready:
            statusText = "流式识别中"
        case .partial(let text):
            onUpdate?(StreamingTranscriptUpdate(text: text, isFinal: false))
        case .final(let text):
            onUpdate?(StreamingTranscriptUpdate(text: text, isFinal: true))
            isRunning = false
            statusText = "已完成"
        case .error(let message):
            statusText = "错误"
            onError(message)
        }
    }

    private nonisolated static func parseEvent(line: Data) -> StreamingWorkerEvent? {
        guard let event = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              let type = event["type"] as? String else { return nil }
        switch type {
        case "ready":
            return .ready
        case "partial":
            return .partial(event["text"] as? String ?? "")
        case "final":
            return .final(event["text"] as? String ?? "")
        case "error":
            return .error(event["message"] as? String ?? "FunASR 流式识别失败。")
        default:
            return nil
        }
    }

    private func resolveHelperURL() throws -> URL {
        let bundledURL = Bundle.main.resourceURL?
            .appendingPathComponent("Scripts", isDirectory: true)
            .appendingPathComponent("funasr_stream.py")
        if let bundledURL, FileManager.default.fileExists(atPath: bundledURL.path) {
            return bundledURL
        }

        let projectURL = projectRootURL()
            .appendingPathComponent("scripts", isDirectory: true)
            .appendingPathComponent("funasr_stream.py")
        if FileManager.default.fileExists(atPath: projectURL.path) {
            return projectURL
        }

        throw TranscriptionError.helperMissing
    }

    private func resolvePythonURL() -> URL {
        let venvPython = projectRootURL()
            .appendingPathComponent(".venv", isDirectory: true)
            .appendingPathComponent("bin", isDirectory: true)
            .appendingPathComponent("python")
        if FileManager.default.fileExists(atPath: venvPython.path) {
            return venvPython
        }
        return URL(fileURLWithPath: "/usr/bin/env")
    }

    private func processEnvironment() -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        let projectRoot = projectRootURL().path
        let venvBin = projectRootURL()
            .appendingPathComponent(".venv", isDirectory: true)
            .appendingPathComponent("bin", isDirectory: true)
            .path
        environment["PATH"] = "\(venvBin):" + (environment["PATH"] ?? "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin")
        environment["STENOGRAPHER_PROJECT_ROOT"] = projectRoot
        environment["VOICETRANSFORM_PROJECT_ROOT"] = projectRoot
        environment["PYTHONNOUSERSITE"] = "1"
        environment["FUNASR_ONNX_QUANTIZATION"] = "auto"
        return environment
    }

    private func defaultOnlineModelPath() -> String {
        let localModelURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".cache/modelscope/hub/models/iic/speech_paraformer-large_asr_nat-zh-cn-16k-common-vocab8404-online", isDirectory: true)
        if FileManager.default.fileExists(atPath: localModelURL.appendingPathComponent("model.onnx").path),
           FileManager.default.fileExists(atPath: localModelURL.appendingPathComponent("decoder.onnx").path) {
            return localModelURL.path
        }
        return "iic/speech_paraformer-large_asr_nat-zh-cn-16k-common-vocab8404-online-onnx"
    }

    private func projectRootURL() -> URL {
        let bundleURL = Bundle.main.bundleURL
        if bundleURL.pathExtension == "app" {
            return bundleURL.deletingLastPathComponent()
        }

        return URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
    }
}

private final class StreamingPCMWriter: @unchecked Sendable {
    private let inputPipe: Pipe
    private let queue = DispatchQueue(label: "Stenographer.StreamingTranscriptionWriter")
    private let onWriteError: @Sendable () -> Void
    private let stateLock = NSLock()
    private var isFinished = false

    init(inputPipe: Pipe, onWriteError: @escaping @Sendable () -> Void) {
        self.inputPipe = inputPipe
        self.onWriteError = onWriteError
    }

    func write(_ data: Data) {
        guard !data.isEmpty, markWritable() else { return }

        queue.async { [inputPipe, onWriteError] in
            var count = UInt32(data.count).littleEndian
            let header = Data(bytes: &count, count: MemoryLayout<UInt32>.size)
            do {
                try inputPipe.fileHandleForWriting.write(contentsOf: header)
                try inputPipe.fileHandleForWriting.write(contentsOf: data)
            } catch {
                onWriteError()
            }
        }
    }

    func finish() {
        guard markFinished() else { return }

        queue.async { [inputPipe] in
            var count = UInt32(0).littleEndian
            let header = Data(bytes: &count, count: MemoryLayout<UInt32>.size)
            try? inputPipe.fileHandleForWriting.write(contentsOf: header)
            try? inputPipe.fileHandleForWriting.close()
        }
    }

    func close() {
        _ = markFinished()
        queue.async { [inputPipe] in
            try? inputPipe.fileHandleForWriting.close()
        }
    }

    private func markWritable() -> Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return !isFinished
    }

    private func markFinished() -> Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard !isFinished else { return false }
        isFinished = true
        return true
    }
}
