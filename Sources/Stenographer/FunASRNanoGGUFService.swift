import Foundation

enum FunASRNanoGGUFError: LocalizedError {
    case missingAudioFile
    case helperMissing
    case alreadyRunning
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .missingAudioFile:
            "没有找到录音文件。"
        case .helperMissing:
            "没有找到 Fun-ASR-Nano GGUF 转写脚本。"
        case .alreadyRunning:
            "Fun-ASR-Nano GGUF 正在转写当前录音。"
        case .failed(let message):
            message
        }
    }
}

@MainActor
final class FunASRNanoGGUFService: ObservableObject {
    @Published private(set) var isRunning = false
    @Published private(set) var statusText = "待试跑"

    var modelDetail: String {
        if isReady {
            return "Fun-ASR-Nano-2512 GGUF \(URL(fileURLWithPath: decoderPath).deletingPathExtension().lastPathComponent)"
        }
        return "等待 GGUF 权重"
    }

    var isReady: Bool {
        FileManager.default.fileExists(atPath: binaryPath)
            && FileManager.default.fileExists(atPath: encoderPath)
            && FileManager.default.fileExists(atPath: decoderPath)
            && FileManager.default.fileExists(atPath: vadPath)
    }

    var binaryPath: String {
        projectRootURL()
            .appendingPathComponent("Tools", isDirectory: true)
            .appendingPathComponent("funasr-llamacpp", isDirectory: true)
            .appendingPathComponent("llama-funasr-cli")
            .path
    }

    var encoderPath: String {
        projectRootURL()
            .appendingPathComponent("Models", isDirectory: true)
            .appendingPathComponent("Fun-ASR-Nano-2512-GGUF", isDirectory: true)
            .appendingPathComponent("funasr-encoder-f16.gguf")
            .path
    }

    var decoderPath: String {
        let modelURL = projectRootURL()
            .appendingPathComponent("Models", isDirectory: true)
            .appendingPathComponent("Fun-ASR-Nano-2512-GGUF", isDirectory: true)
        for name in ["qwen3-0.6b-q8_0.gguf", "qwen3-0.6b-q5km.gguf", "qwen3-0.6b-q4km.gguf"] {
            let candidate = modelURL.appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: candidate.path) {
                return candidate.path
            }
        }
        return modelURL.appendingPathComponent("qwen3-0.6b-q8_0.gguf").path
    }

    var vadPath: String {
        projectRootURL()
            .appendingPathComponent("Models", isDirectory: true)
            .appendingPathComponent("fsmn-vad-GGUF", isDirectory: true)
            .appendingPathComponent("fsmn-vad.gguf")
            .path
    }

    func transcribe(audioPath: String, outputPath: String) async throws -> [TranscriptEntry] {
        guard !isRunning else {
            throw FunASRNanoGGUFError.alreadyRunning
        }
        guard FileManager.default.fileExists(atPath: audioPath) else {
            throw FunASRNanoGGUFError.missingAudioFile
        }

        let helperURL = try resolveHelperURL()
        isRunning = true
        statusText = "Nano GGUF 转写中"
        defer { isRunning = false }

        let pythonURL = resolvePythonURL()
        let environment = processEnvironment()

        do {
            let entries: [TranscriptEntry] = try await Task.detached(priority: .utility) {
                let process = Process()
                process.executableURL = pythonURL.executableURL
                process.arguments = pythonURL.arguments + [
                    helperURL.path,
                    "--audio", audioPath,
                    "--output", outputPath
                ]
                process.environment = environment

                let errorPipe = Pipe()
                let errorCollector = PipeCollector(pipe: errorPipe, label: "Stenographer.FunASRNanoGGUFErrorCollector")
                process.standardError = errorPipe
                errorCollector.start()

                try process.run()
                process.waitUntilExit()
                let errorOutput = errorCollector.finish()

                if process.terminationStatus != 0 {
                    throw FunASRNanoGGUFError.failed(errorOutput.isEmpty ? "Fun-ASR-Nano GGUF 转写失败。" : errorOutput)
                }

                let data = try Data(contentsOf: URL(fileURLWithPath: outputPath))
                return try JSONDecoder().decode([TranscriptEntry].self, from: data)
            }.value

            statusText = entries.isEmpty ? "无可用语音" : "已试跑"
            return entries
        } catch {
            statusText = "试跑失败"
            throw error
        }
    }

    private func resolveHelperURL() throws -> URL {
        let bundledURL = Bundle.main.resourceURL?
            .appendingPathComponent("Scripts", isDirectory: true)
            .appendingPathComponent("funasr_nano_gguf_transcribe.py")
        if let bundledURL, FileManager.default.fileExists(atPath: bundledURL.path) {
            return bundledURL
        }

        let projectURL = projectRootURL()
            .appendingPathComponent("scripts", isDirectory: true)
            .appendingPathComponent("funasr_nano_gguf_transcribe.py")
        if FileManager.default.fileExists(atPath: projectURL.path) {
            return projectURL
        }

        throw FunASRNanoGGUFError.helperMissing
    }

    private func resolvePythonURL() -> PythonInvocation {
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
