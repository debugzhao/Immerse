import Foundation

/// 调用系统 `/usr/bin/shortcuts` 命令行
enum ShortcutsRunner {
    static let executable = URL(fileURLWithPath: "/usr/bin/shortcuts")

    enum RunError: LocalizedError {
        case notInstalled
        case timedOut
        /// 进程被系统信号终止（比如 SIGKILL），通常是安全策略拦截了快捷指令
        case killed(signal: Int32)
        case failed(code: Int32, message: String)

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

    /// 列出所有快捷指令的名称
    static func list(timeout: Duration = .seconds(5)) async throws -> [String] {
        let output = try await execute(["list"], timeout: timeout)
        return output
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    /// 运行一个快捷指令。input 会写进临时文本文件，作为快捷指令的输入
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

    /// 在后台执行，超时或任务被取消时终止进程
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
        // 边运行边读输出：等进程退出再读的话，输出超过管道缓冲区（64KB）时子进程会卡在写入上永远不退出
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
                    // 进程没起来，关掉写端让读取线程结束
                    try? stdout.fileHandleForWriting.close()
                    try? stderr.fileHandleForWriting.close()
                    continuation.resume(throwing: error)
                    return
                }
                // 超时看门狗
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

/// 让 Process 能安全地在取消回调和看门狗之间共享
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
