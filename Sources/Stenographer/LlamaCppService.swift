import Foundation

enum LlamaCppError: LocalizedError {
    case missingExecutable
    case missingModel
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .missingExecutable:
            "没有找到 llama-cli。请确认 llama.cpp 已通过 Homebrew 或源码安装。"
        case .missingModel:
            "没有配置 llama.cpp 的 GGUF 模型。请设置 LLAMA_MODEL 或在 Models/llm 放置 .gguf 文件。"
        case .failed(let message):
            message
        }
    }
}

@MainActor
final class LlamaCppService: ObservableObject {
    @Published private(set) var isRunning = false

    var executablePath: String? {
        let candidates = [
            "/opt/homebrew/bin/llama-cli",
            "/usr/local/bin/llama-cli",
            "/opt/homebrew/bin/llama-server",
            "/usr/local/bin/llama-server"
        ]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    var modelPath: String? {
        if let configured = ProcessInfo.processInfo.environment["LLAMA_MODEL"], FileManager.default.fileExists(atPath: configured) {
            return configured
        }

        let modelDirectory = projectRootURL()
            .appendingPathComponent("Models", isDirectory: true)
            .appendingPathComponent("llm", isDirectory: true)
        let files = (try? FileManager.default.contentsOfDirectory(at: modelDirectory, includingPropertiesForKeys: nil)) ?? []
        return files.first { $0.pathExtension.lowercased() == "gguf" }?.path
    }

    var statusText: String {
        guard executablePath != nil else { return "未安装" }
        guard modelPath != nil else { return "待配置模型" }
        return isRunning ? "运行中" : "就绪"
    }

    func run(prompt: String) async throws -> String {
        guard let executablePath else { throw LlamaCppError.missingExecutable }
        guard let modelPath else { throw LlamaCppError.missingModel }

        isRunning = true
        defer { isRunning = false }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = ["-m", modelPath, "-p", prompt, "-n", "512", "--temp", "0.2"]

        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        try process.run()
        process.waitUntilExit()

        let output = String(data: outputPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        if process.terminationStatus != 0 {
            let error = String(data: errorPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            throw LlamaCppError.failed(error.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return output.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func projectRootURL() -> URL {
        let bundleURL = Bundle.main.bundleURL
        if bundleURL.pathExtension == "app" {
            return bundleURL.deletingLastPathComponent()
        }

        return URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
    }
}
