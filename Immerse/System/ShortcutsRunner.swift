import Foundation

/// Invokes the system `/usr/bin/shortcuts` command-line tool
enum ShortcutsRunner {
    static let executable = URL(fileURLWithPath: "/usr/bin/shortcuts")

    enum RunError: LocalizedError {
        case notInstalled
        case timedOut
        /// Process terminated by a system signal (e.g. SIGKILL), usually because a security policy blocked the shortcut
        case killed(signal: Int32)
        case failed(code: Int32, message: String)

        /// The system can't run shortcuts at all (missing CLI, or killed by policy), as opposed to a one-off failure
        var isBlocked: Bool {
            switch self {
            case .notInstalled, .killed: true
            case .timedOut, .failed: false
            }
        }

        var errorDescription: String? {
            switch self {
            case .notInstalled: "系统里找不到 shortcuts 命令"
            case .timedOut: "快捷指令执行超时"
            case let .killed(signal):
                "系统阻止了快捷指令运行（信号 \(signal)）。如果是公司电脑，快捷指令可能被设备管理策略禁用了"
            case let .failed(code, message):
                message.isEmpty ? "快捷指令执行失败（退出码 \(code)）" : message
            }
        }
    }

    /// Lists the names of all shortcuts
    static func list(timeout: Duration = .seconds(5)) async throws -> [String] {
        let output = try await execute(["list"], timeout: timeout)
        return output
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    /// Runs a shortcut. `input` is written to a temp text file and passed as the shortcut's input
    static func run(_ name: String, input: String? = nil, timeout: Duration = .seconds(5)) async throws {
        guard let input else {
            _ = try await execute(["run", name], timeout: timeout)
            return
        }
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("immerse-input-\(UUID().uuidString).txt")
        try input.write(to: file, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: file) }
        _ = try await execute(["run", name, "--input-path", file.path], timeout: timeout)
    }

    /// Runs in the background; terminates the process on timeout or task cancellation
    private static func execute(_ arguments: [String], timeout: Duration) async throws -> String {
        guard FileManager.default.isExecutableFile(atPath: executable.path) else { throw RunError.notInstalled }

        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr

        let box = ProcessBox(process)
        // Read output while the process runs: if we waited for exit first, output over the pipe buffer (64KB) would block the child on write and it would never exit
        let reading = DispatchGroup()
        let collected = OutputBox()
        for (pipe, isError) in [(stdout, false), (stderr, true)] {
            reading.enter()
            DispatchQueue.global().async {
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                collected.set(String(decoding: data, as: UTF8.self), isError: isError)
                reading.leave()
            }
        }

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<String, Error>) in
                process.terminationHandler = { finished in
                    reading.wait()
                    let (out, err) = collected.values
                    if box.didTimeOut {
                        continuation.resume(throwing: RunError.timedOut)
                    } else if finished.terminationReason == .uncaughtSignal {
                        continuation.resume(throwing: RunError.killed(signal: finished.terminationStatus))
                    } else if finished.terminationStatus == 0 {
                        continuation.resume(returning: out)
                    } else {
                        continuation.resume(throwing: RunError.failed(
                            code: finished.terminationStatus,
                            message: err.trimmingCharacters(in: .whitespacesAndNewlines)))
                    }
                }
                do {
                    try process.run()
                } catch {
                    process.terminationHandler = nil
                    // Process failed to start: close the write end so the reader thread finishes
                    try? stdout.fileHandleForWriting.close()
                    try? stderr.fileHandleForWriting.close()
                    continuation.resume(throwing: error)
                    return
                }
                // Timeout watchdog
                DispatchQueue.global().asyncAfter(deadline: .now() + timeout.timeInterval) {
                    box.timeOut()
                }
            }
        } onCancel: {
            box.terminate()
        }
    }
}

private final class OutputBox: @unchecked Sendable {
    private let lock = NSLock()
    private var out = ""
    private var err = ""

    func set(_ value: String, isError: Bool) {
        lock.withLock { if isError { err = value } else { out = value } }
    }

    var values: (String, String) { lock.withLock { (out, err) } }
}

/// Lets Process be shared safely between the cancellation handler and the watchdog
private final class ProcessBox: @unchecked Sendable {
    private let process: Process
    private let lock = NSLock()
    private var timedOut = false

    init(_ process: Process) { self.process = process }

    var didTimeOut: Bool { lock.withLock { timedOut } }

    func timeOut() {
        lock.withLock {
            guard process.isRunning else { return }
            timedOut = true
            process.terminate()
        }
    }

    func terminate() {
        lock.withLock {
            if process.isRunning { process.terminate() }
        }
    }
}

private extension Duration {
    var timeInterval: TimeInterval {
        let (seconds, attoseconds) = components
        return TimeInterval(seconds) + TimeInterval(attoseconds) / 1e18
    }
}
