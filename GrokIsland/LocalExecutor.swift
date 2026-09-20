import Foundation

#if canImport(AppKit)
import AppKit
#endif

/// Runs work on this Mac. Never executes a shell command unless `local.confirmedShellCommand`
/// is a non-empty string that the user explicitly confirmed in the UI.
struct LocalExecutor: ModuleExecuting {
    var kind: ExecutorKind { .local }

    func run(
        _ request: ExecutionRequest,
        progress: @escaping @Sendable (ExecutionProgress) async -> Void
    ) async throws -> ExecutionResult {
        guard let options = request.local else {
            throw IslandError.localConfirmationRequired
        }

        try Task.checkCancellation()
        await progress(ExecutionProgress(fraction: 0.1, message: "Local run confirmed"))

        var notes: [String] = []

        if options.openAttachedFiles {
            try Task.checkCancellation()
            await progress(ExecutionProgress(fraction: 0.35, message: "Opening attached files"))
            notes.append(await openFiles(in: request.resources))
        }

        if let command = sanitizedCommand(options.confirmedShellCommand) {
            try Task.checkCancellation()
            await progress(ExecutionProgress(fraction: 0.7, message: "Running confirmed command"))
            notes.append(try await runConfirmedCommand(command))
        }

        if !options.hasWork {
            try await Task.sleep(for: .milliseconds(50))
            notes.append("No-op: confirmation accepted, nothing to open or run.")
        }

        try Task.checkCancellation()
        await progress(ExecutionProgress(fraction: 1.0, message: "Local run finished"))
        return ExecutionResult(
            summary: "Local module “\(request.module.displayName)” finished.",
            detail: notes.joined(separator: "\n")
        )
    }

    private func sanitizedCommand(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func openFiles(in resources: [ResourceItem]) async -> String {
        let fileURLs = resources.compactMap { item -> URL? in
            guard item.kind != .url, let url = item.url else { return nil }
            return url
        }
        guard !fileURLs.isEmpty else {
            return "No local files to open."
        }

        #if canImport(AppKit)
        await MainActor.run {
            for url in fileURLs {
                NSWorkspace.shared.open(url)
            }
        }
        return "Opened \(fileURLs.count) item(s) with the default application."
        #else
        return "Would open \(fileURLs.count) item(s) (AppKit unavailable)."
        #endif
    }

    /// Only invoked with a command string the user typed and confirmed.
    private func runConfirmedCommand(_ command: String) async throws -> String {
        let process = Process()
        let shell = FileManager.default.isExecutableFile(atPath: "/bin/zsh") ? "/bin/zsh" : "/bin/sh"
        process.executableURL = URL(fileURLWithPath: shell)
        process.arguments = ["-lc", command]
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                DispatchQueue.global(qos: .userInitiated).async {
                    do {
                        try process.run()
                        process.waitUntilExit()
                        let outData = stdout.fileHandleForReading.readDataToEndOfFile()
                        let errData = stderr.fileHandleForReading.readDataToEndOfFile()
                        let out = String(data: outData, encoding: .utf8) ?? ""
                        let err = String(data: errData, encoding: .utf8) ?? ""
                        if process.terminationStatus == 0 {
                            let body = out.trimmingCharacters(in: .whitespacesAndNewlines)
                            continuation.resume(returning: body.isEmpty ? "Command exited 0." : body)
                        } else if process.terminationReason == .uncaughtSignal {
                            continuation.resume(throwing: CancellationError())
                        } else {
                            let message = err.trimmingCharacters(in: .whitespacesAndNewlines)
                            continuation.resume(
                                throwing: IslandError.executorFailed(
                                    message.isEmpty ? "Command exited \(process.terminationStatus)." : message
                                )
                            )
                        }
                    } catch {
                        continuation.resume(throwing: IslandError.executorFailed(error.localizedDescription))
                    }
                }
            }
        } onCancel: {
            if process.isRunning {
                process.terminate()
            }
        }
    }
}
