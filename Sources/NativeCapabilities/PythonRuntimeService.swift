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
    /// into list comprehensions (`sum([expr for x in seq])`) required by pocketpy 2.2.0,
    /// supporting arbitrarily nested calls (`sum(float(r['precio']) for r in rows)`).
    public nonisolated static func normalizeForPocketPy(_ script: String) -> String {
        let targetFunctions: Set<String> = [
            "sum", "min", "max", "any", "all", "tuple", "list", "set", "sorted", "join"
        ]
        let chars = Array(script)
        var out = ""
        out.reserveCapacity(chars.count + 16)
        var i = 0

        while i < chars.count {
            let ch = chars[i]
            if ch == "#" {
                let end = scanLineComment(in: chars, from: i)
                out.append(contentsOf: chars[i..<end])
                i = end
                continue
            }
            if ch == "\"" || ch == "'" {
                let end = scanPythonString(in: chars, from: i)
                out.append(contentsOf: chars[i..<end])
                i = end
                continue
            }
            if isPythonIdentStart(ch) {
                let prevIsIdent = i > 0 && isPythonIdentBody(chars[i - 1])
                var j = i + 1
                while j < chars.count && isPythonIdentBody(chars[j]) {
                    j += 1
                }
                let ident = String(chars[i..<j])
                if !prevIsIdent,
                   targetFunctions.contains(ident),
                   j < chars.count,
                   chars[j] == "(",
                   let closeIdx = findMatchingParen(in: chars, openParenIndex: j) {
                    let rawInner = String(chars[(j + 1)..<closeIdx])
                    let normalizedInner = normalizeForPocketPy(rawInner)
                    if isBareGeneratorExpression(normalizedInner) {
                        let trimmed = normalizedInner.trimmingCharacters(in: .whitespacesAndNewlines)
                        out.append(ident)
                        out.append("([")
                        out.append(trimmed)
                        out.append("])")
                    } else {
                        out.append(ident)
                        out.append("(")
                        out.append(normalizedInner)
                        out.append(")")
                    }
                    i = closeIdx + 1
                    continue
                }
                out.append(ident)
                i = j
                continue
            }
            out.append(ch)
            i += 1
        }
        return out
    }

    private nonisolated static func isPythonIdentStart(_ c: Character) -> Bool {
        c == "_" || c.unicodeScalars.allSatisfy { CharacterSet.letters.contains($0) }
    }

    private nonisolated static func isPythonIdentBody(_ c: Character) -> Bool {
        c == "_" || c.unicodeScalars.allSatisfy { CharacterSet.alphanumerics.contains($0) }
    }

    private nonisolated static func scanLineComment(in chars: [Character], from start: Int) -> Int {
        var i = start
        while i < chars.count && chars[i] != "\n" {
            i += 1
        }
        return i
    }

    private nonisolated static func scanPythonString(in chars: [Character], from start: Int) -> Int {
        let quote = chars[start]
        let isTriple = start + 2 < chars.count && chars[start + 1] == quote && chars[start + 2] == quote
        var i = start + (isTriple ? 3 : 1)
        while i < chars.count {
            let c = chars[i]
            if c == "\\" {
                i = min(chars.count, i + 2)
                continue
            }
            if isTriple {
                if i + 2 < chars.count && chars[i] == quote && chars[i + 1] == quote && chars[i + 2] == quote {
                    return i + 3
                }
            } else if c == quote || c == "\n" {
                return c == quote ? i + 1 : i
            }
            i += 1
        }
        return chars.count
    }

    private nonisolated static func findMatchingParen(in chars: [Character], openParenIndex: Int) -> Int? {
        var depth = 0
        var i = openParenIndex
        while i < chars.count {
            let c = chars[i]
            if c == "#" {
                i = scanLineComment(in: chars, from: i)
                continue
            }
            if c == "\"" || c == "'" {
                i = scanPythonString(in: chars, from: i)
                continue
            }
            if c == "(" || c == "[" || c == "{" {
                depth += 1
            } else if c == ")" || c == "]" || c == "}" {
                depth -= 1
                if depth == 0 {
                    return c == ")" ? i : nil
                }
                if depth < 0 {
                    return nil
                }
            }
            i += 1
        }
        return nil
    }

    private nonisolated static func isBareGeneratorExpression(_ inner: String) -> Bool {
        let trimmed = inner.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.hasPrefix("["), !trimmed.hasPrefix("{") else {
            return false
        }
        let chars = Array(trimmed)
        var depth = 0
        var sawFor = false
        var sawInAfterFor = false
        var i = 0

        while i < chars.count {
            let c = chars[i]
            if c == "#" {
                i = scanLineComment(in: chars, from: i)
                continue
            }
            if c == "\"" || c == "'" {
                i = scanPythonString(in: chars, from: i)
                continue
            }
            if c == "(" || c == "[" || c == "{" {
                depth += 1
                i += 1
                continue
            }
            if c == ")" || c == "]" || c == "}" {
                depth -= 1
                if depth < 0 { return false }
                i += 1
                continue
            }
            if depth == 0 {
                if c == "," {
                    // Multi-argument call without surrounding list literal is not a single bare generator.
                    return false
                }
                if isPythonIdentStart(c) {
                    let prevOk = i == 0 || !isPythonIdentBody(chars[i - 1])
                    var j = i + 1
                    while j < chars.count && isPythonIdentBody(chars[j]) {
                        j += 1
                    }
                    if prevOk {
                        let word = String(chars[i..<j])
                        if word == "for" && !sawFor {
                            sawFor = true
                        } else if word == "in" && sawFor {
                            sawInAfterFor = true
                        }
                    }
                    i = j
                    continue
                }
            }
            i += 1
        }
        return sawFor && sawInAfterFor
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
