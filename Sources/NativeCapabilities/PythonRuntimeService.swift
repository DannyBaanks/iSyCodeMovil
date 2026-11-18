import Foundation

/// Execution result and receipt from the embedded pocketpy 2.2.0 runtime.
public struct PythonExecutionReceipt: Codable, Sendable, Identifiable, Equatable {
    public let id: String
    public let timestamp: Date
    public let durationMs: Int64
    public let succeeded: Bool
    public let stdout: String
    public let error: String?
    public let scriptPreview: String
    public let runtimeVersion: String

    public init(
        id: String = UUID().uuidString,
        timestamp: Date = Date(),
        durationMs: Int64,
        succeeded: Bool,
        stdout: String,
        error: String?,
        scriptPreview: String,
        runtimeVersion: String
    ) {
        self.id = id
        self.timestamp = timestamp
        self.durationMs = durationMs
        self.succeeded = succeeded
        self.stdout = stdout
        self.error = error
        self.scriptPreview = scriptPreview
        self.runtimeVersion = runtimeVersion
    }
}

/// Safe Swift interface over `gus_python_eval` (pocketpy 2.2.0 C11 amalgamation).
///
/// Security & Capability Model:
/// - Runs in-process with `PK_ENABLE_OS=0` (no `os`, `io`, `open()`, subprocess, or sockets)
///   and `stdc` raw-pointer module stripped at VM initialization.
/// - Enforces bytecode instruction watchdog (`PK_ENABLE_WATCHDOG=1`) to interrupt infinite loops.
/// - Does NOT claim OS-level process isolation; scripts only transform data passed in memory
///   (`INPUT_TEXT` / `INPUT`) and return `stdout`. File reads/writes and network requests
///   must go through explicitly authorized L0 tools (`read_file`, `write_file`, `http_request`).
public actor PythonRuntimeService {
    public static let shared = PythonRuntimeService()

    public static let maxOutputBytes = 64 * 1024
    public static let maxErrorBytes = 8 * 1024
    public static let defaultTimeoutMs: Int32 = 3_000

    private var recentReceipts: [PythonExecutionReceipt] = []

    public init() {}

    public nonisolated var runtimeVersion: String {
        String(cString: gus_python_version_info())
    }

    public func receipts(limit: Int = 20) -> [PythonExecutionReceipt] {
        Array(recentReceipts.suffix(limit).reversed())
    }

    /// Normalizes common CPython generator-in-call idioms (`sum(expr for x in seq)`)
    /// into list comprehensions (`sum([expr for x in seq])`) required by pocketpy 2.2.0.
    public nonisolated static func normalizeForPocketPy(_ script: String) -> String {
        let pattern = #"\b(sum|min|max|any|all|tuple|list)\(\s*([^()\[\]\n]+?\s+for\s+[a-zA-Z_][a-zA-Z0-9_,\s]*\s+in\s+[^()\[\]\n]+?)\s*\)"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else {
            return script
        }
        let range = NSRange(script.startIndex..<script.endIndex, in: script)
        return regex.stringByReplacingMatches(in: script, options: [], range: range, withTemplate: "$1([$2])")
    }

    public func evaluate(
        script: String,
        inputText: String = "",
        timeoutMs: Int32 = PythonRuntimeService.defaultTimeoutMs
    ) async -> PythonExecutionReceipt {
        let normalized = Self.normalizeForPocketPy(script)
        let version = runtimeVersion
        let clampedTimeout = max(50, min(timeoutMs, 15_000))

        let rawResult = await Task.detached(priority: .userInitiated) { () -> (rc: Int32, out: String, err: String, dur: Int64) in
            var outBuf = [CChar](repeating: 0, count: Self.maxOutputBytes)
            var errBuf = [CChar](repeating: 0, count: Self.maxErrorBytes)
            var durationMs: Int64 = 0

            let rc = normalized.withCString { scriptPtr in
                inputText.withCString { inputPtr in
                    gus_python_eval(
                        scriptPtr,
                        inputPtr,
                        clampedTimeout,
                        &outBuf,
                        Self.maxOutputBytes,
                        &errBuf,
                        Self.maxErrorBytes,
                        &durationMs
                    )
                }
            }
            let stdoutStr = String(cString: outBuf)
            let errStr = String(cString: errBuf)
            return (rc, stdoutStr, errStr, durationMs)
        }.value

        let receipt = PythonExecutionReceipt(
            durationMs: rawResult.dur,
            succeeded: rawResult.rc == 0,
            stdout: rawResult.out,
            error: rawResult.rc == 0 ? nil : (rawResult.err.isEmpty ? "Error en ejecución Python." : rawResult.err),
            scriptPreview: String(script.trimmingCharacters(in: .whitespacesAndNewlines).prefix(240)),
            runtimeVersion: version
        )
        recentReceipts.append(receipt)
        if recentReceipts.count > 50 {
            recentReceipts.removeFirst(recentReceipts.count - 50)
        }
        return receipt
    }
}
