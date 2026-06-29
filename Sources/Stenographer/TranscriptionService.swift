import Foundation

enum TranscriptionError: LocalizedError {
    case missingAudioFile
    case helperMissing
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .missingAudioFile:
            "没有找到录音文件。"
        case .helperMissing:
            "没有找到 FunASR 转写脚本。"
        case .failed(let message):
            message
        }
    }
}

@MainActor
final class TranscriptionService: ObservableObject {
    @Published private(set) var isRunning = false

    func transcribe(audioPath: String, outputPath: String) async throws -> [TranscriptEntry] {
        guard FileManager.default.fileExists(atPath: audioPath) else {
            throw TranscriptionError.missingAudioFile
        }

        let helperURL = try resolveHelperURL()
        guard FileManager.default.fileExists(atPath: helperURL.path) else {
            throw TranscriptionError.helperMissing
        }

        isRunning = true
        defer { isRunning = false }

        let pythonURL = resolvePythonURL()
        let environment = processEnvironment()
        let modelPath = defaultOfflineModelPath()

        let entries: [TranscriptEntry] = try await Task.detached(priority: .utility) {
            let process = Process()
            process.executableURL = pythonURL
            process.arguments = [
                helperURL.path,
                "--audio", audioPath,
                "--output", outputPath,
                "--model", modelPath,
                "--quantization", "auto"
            ]
            process.environment = environment

            let errorPipe = Pipe()
            process.standardError = errorPipe

            try process.run()
            process.waitUntilExit()

            if process.terminationStatus != 0 {
                let data = errorPipe.fileHandleForReading.readDataToEndOfFile()
                let message = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
                throw TranscriptionError.failed(message?.isEmpty == false ? message! : "FunASR 转写失败。")
            }

            let data = try Data(contentsOf: URL(fileURLWithPath: outputPath))
            return try JSONDecoder().decode([TranscriptEntry].self, from: data)
        }.value

        return entries
    }

    private func resolveHelperURL() throws -> URL {
        let bundledURL = Bundle.main.resourceURL?
            .appendingPathComponent("Scripts", isDirectory: true)
            .appendingPathComponent("funasr_transcribe.py")
        if let bundledURL, FileManager.default.fileExists(atPath: bundledURL.path) {
            return bundledURL
        }

        let projectURL = projectRootURL()
            .appendingPathComponent("scripts", isDirectory: true)
            .appendingPathComponent("funasr_transcribe.py")
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

    private func defaultOfflineModelPath() -> String {
        let localModelURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".cache/modelscope/hub/models/iic/speech_paraformer-large-vad-punc_asr_nat-zh-cn-16k-common-vocab8404-pytorch", isDirectory: true)
        if FileManager.default.fileExists(atPath: localModelURL.appendingPathComponent("model.onnx").path) {
            return localModelURL.path
        }
        return "iic/speech_paraformer-large-vad-punc_asr_nat-zh-cn-16k-common-vocab8404-onnx"
    }

    private func projectRootURL() -> URL {
        let bundleURL = Bundle.main.bundleURL
        if bundleURL.pathExtension == "app" {
            return bundleURL.deletingLastPathComponent()
        }

        return URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
    }
}
