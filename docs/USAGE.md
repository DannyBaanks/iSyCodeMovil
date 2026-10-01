# Usage

> The app runs the **OpenCode boot attempt** (compatibility check) plus a
> **native Swift agent runtime** (not OpenCode) that operates
> `user → agent → tools → workspace → result` on iOS.

---

## A. Run on Simulator or Device

1. Generate the project and open in Xcode:

   ```bash
   brew install xcodegen
   xcodegen generate
   open OpencodeNative.xcodeproj
   ```

2. Run on iOS Simulator (⌘R). On launch you'll see the boot attempt transcript:

   ```
   opencode-native — compatibility harness v0.2.0
   opencode-boot> probing host: iOS
   opencode-boot> target: OpenCode TUI v1.18.19 (license MIT)
   opencode-boot> generating capability matrix ...
   opencode-boot> [UNSUPPORTED]   PTY + TTY raw mode (render TUI ANSI)
   ...
   opencode-boot> BLOCKED at first hard blocker: PTY + TTY raw mode
   opencode-boot> OpenCode TUI cannot initialize on this host. NOT simulated.
   ```

3. Type `/demo` to run the scripted agent demo (no API key needed):

   ```
   $ /demo
   ```

   Output: list → write `notes.txt` → read → write 2 lines → read → final.

4. Other commands: `/matrix` (capability sheet), `/boot` (re-run boot attempt),
   `/provider scripted|remote` (switch provider), `/clear`, `/help`.

---

## B. Connect to a Remote LLM (Optional)

1. Create `~/Application Support/OpencodeNative/config.json`:

   ```json
   {
     "apiKeys": { "remote": "sk-..." },
     "defaultModelName": "gpt-4o-mini",
     "defaultModelProvider": "remote"
   }
   ```

2. In the app: `/provider remote`, then type your prompt.

Default base URL: `https://api.openai.com/v1`.

---

## C. Run Tests

```bash
# macOS with Xcode
xcodebuild test \
  -scheme OpencodeNative \
  -destination 'platform=iOS Simulator,name=iPhone 16'
```

CI runs this automatically on every push.

## D. GUS local (experimental)

Choose **GUS local** in the sandbox provider picker. The model screen lists
three fixed GGUF artifacts: Qwen1.5-1.8B Q4_K_M, Qwen2.5-0.5B Q4_K_M, and
SmolLM2-360M Q4_K_M. Each card shows its pinned source revision, exact size,
license, attribution, and SHA-256. Tap **Descargar** to fetch a model directly
to the iPhone; it is not part of the IPA. The app verifies exact byte count and
digest before making it selectable. Multiple approved models can remain
installed, but GUS loads the explicitly selected model only. Delete each model
individually to reclaim storage.

All three models receive the same GUS role and safety boundary. File tools are
off until individually enabled under **Settings → iPhone Sandbox → Native
Capabilities → Herramientas de GUS local**. Every file mutation asks for a
separate approval. Tool calling is experimental and still needs physical-device
evaluation; it does not add iOS permissions or fall back to a cloud model.
Background transfers can continue while iOS suspends the app or the screen is
locked. A user force-quit cancels the transfer; reopen the app to retry, and the
download may restart from zero. See
[MODEL_NOTICE.md](MODEL_NOTICE.md) for provenance, licenses, and safeguards.

### Test Suites

| Suite | Coverage |
|---|---|
| `GlobMatcherTests` | Glob patterns (`*`, `?`, `**/`) |
| `CapabilityMatrixTests` | Capability probe on non-iOS host |
| `CompatibilityReportTests` | Entries match OpenCode requirements |
| `OpenCodeBootAttemptTests` | Boot transcript content |
| `WorkspaceTests` | Create, read, list, move, delete, path traversal |
| `PersistenceTests` | Conversation save/load, JSONL events, config |
| `ToolsDefinitionTests` | 9 filesystem tools present, write marked destructive |
| `AgentEndToEndTests` | Scripted agent writes `notes.txt` end-to-end |

---

## E. Verify Without Xcode (Windows / Linux)

Syntax and typecheck only (no test execution). Verified with Swift 6.3.3
on Windows: **0 errors, 0 warnings**.

```powershell
# Foundation-only sources (todo el core; no SwiftUI) — typecheck completo
swiftc -swift-version 5 -typecheck `
  Sources/Agent/AgentLoop.swift `
  Sources/Workspace/Workspace.swift `
  Sources/Persistence/Persistence.swift `
  Sources/Persistence/KeychainHelper.swift `
  Sources/Model/ModelProvider.swift `
  Sources/Model/ScriptedModelProvider.swift `
  Sources/Tools/GlobMatcher.swift `
  Sources/Tools/FileSystemTools.swift `
  Sources/Host/OpenCodeRuntimeContract.swift `
  Sources/Host/IOSCapabilityMatrix.swift `
  Sources/Host/CompatibilityReport.swift `
  Sources/Host/OpenCodeBootAttempt.swift `
  Sources/Remote/OpenCodeRemoteClient.swift `
  Sources/Remote/PairingStore.swift

# UI + Backend (SwiftUI no existe fuera de Apple — solo parse)
swiftc -parse Sources/UI/*.swift Sources/Backend/*.swift App/OpencodeNativeApp.swift

# Test files (XCTest no existe fuera de Apple — solo parse)
swiftc -parse Tests/*.swift
```

No output = OK. XCTest no está disponible fuera de macOS; ejecuta la suite con
Xcode / iOS Simulator (ver §C).

### Notas de plataforma (honestas, nada simulado)

- **Windows:** `FoundationNetworking.URLSession.bytes(for:)` (SSE) no existe en
  Swift 6.3.3 para Windows → `OpenCodeRemoteClient.events()` termina con
  `OpenCodeRemoteError.unsupportedOnThisHost` en este host. En iOS/macOS/Linux
  compila la rama real con streaming SSE.
- **Windows/Linux:** el framework `Security` (Keychain) no existe →
  `KeychainHelper` lanza `KeychainError.unavailable`; ningún host no-Apple
  persiste secretos fingiendo ser Keychain.
- **Windows/Linux:** `UIKit`/`Network` no existen → `IOSCapabilityMatrix`
  compila con guards `#if canImport` y reporta lo probado como no aplicable
  (fatalError solo si se fuerza la sonda fuera de iOS).

---

## F. What Is NOT Simulated

- Fake terminal / PTY — does not exist on iOS, not faked
- Fake shell / Process — does not exist on iOS, not faked
- "OpenCode runs on iOS" — it does not; the boot attempt documents why
- Code signing on Windows — requires macOS (GitHub Actions or local Xcode)
