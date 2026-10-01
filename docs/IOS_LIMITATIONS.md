# iOS — Limitaciones reales (no se simulan)

> Capacidades iOS verificadas durante este experimento. **No se finge ninguna
> capacidad inexistente**. Lo que no puede hacerse se marca como tal.

## A. Nodos bloqueantes para el OpenCode TUI REAL

| Capability | Estado iOS | Por qué |
|---|---|---|
| PTY/TTY | **Imposible** | No hay API `openpty`/`posix_openpt` expuesta en iOS SDK. El sandbox prohíbe raw TTY sobre stdin/stdout. Sin PTY, `@lydell/node-pty` y el renderer `@opentui` no operan. |
| spawn/exec de procesos | **Imposible** | `Process`/`NSTask` no existen en el SDK iOS. El sandbox prohíbe `fork`/`execve`/`posix_spawn` de binarios arbitrarios (solo el ejecutable principal firmado del bundle se ejecuta). |
| Runtime Bun | **Imposible** | Bun publica builds para `linux/darwin/win × {x64,arm64}`; no hay target Bun `ios-arm64`. JavaScriptCore/WKWebView ejecutan JS puro pero no implementan `bun:*`/`node:*`/`net:*`/PTY. |
| Binario OpenCode para iOS | **No existe** | El script `install` de OpenCode solo admite `linux/darwin/win × {x64,arm64}`; cualquier otro combo → `unsupported OS/Arch` + exit 1. |
| tree-sitter nativo | **Imposible sin Mac** | tree-sitter es C++; los bindings npm requieren compilación. No hay toolchain en iOS. |
| Entorno POSIX (SHELL/HOME/EDITOR) | **Imposible** | iOS no tiene shell ni `$HOME` POSIX ni `.zshrc`. |
| Compilar/correr código nativo en device | **Imposible** | Sin toolchain ni ejecución de procesos. |

## B. Capacidades iOS efectivamente disponibles (sin simular)

| Capability | Cómo se expone en este runtime |
|---|---|
| Filesystem sandbox | `FileManager` en App Support / Documents / tmp. Ver `Sources/Workspace`. |
| File watching | `DispatchSource.makeFileSystemObjectSource` solo para paths del sandbox. |
| Security-scoped bookmarks | `UIDocumentPickerViewController` + `URL.startAccessingSecurityScopedResource`. No usado aún en el harness. |
| SQLite | SQLite del sistema vía C API / GRDB / SQLite.swift / CoreData. |
| Red TLS | `URLSession` + ATS. |
| WebSocket | `URLSessionWebSocketTask`. |
| localhost server | `Network.NWListener` en `127.0.0.1`. |
| LLM API remoto | `URLSession` a cualquier API OpenAI-compatible. |
| Keychain | `SecItem*` (hardware-backed). No usado para API keys todavía. |

## C. Lo que el runtime nativo alternativo (no OpenCode) hace

- 9 tools de filesystem (`read_file`/`write_file`/`edit_file`/`list_directory`/`search_files`/`file_info`/`create_directory`/`delete_file`/`move_file`). `edit_file` requiere una única coincidencia exacta en texto UTF-8.
- Agente async con loop, multi-turn tool calls, persistencia JSONL.
- Provider LLM remoto **o** provider scripteado offline (sin red ni API key) para demo/tests.
- GUS local puede proponer esas herramientas solo cuando la persona las activa por separado; cada mutación exige aprobación por operación. La ejecución de llamadas generadas por cada modelo sigue pendiente de evaluación en dispositivo.

## D. Qué se DELIBERADAMENTE queda fuera (no es falta de control)

- Imitar la terminal/PTY de OpenCode con escapes ANSI fake — fuera; no simula lo inexistente.
- "Bash tool" sin PTY — proyectado pero no entregado como fake; el `AgentLoop` aquí expone solo tools de fs.
- Compilar libgit2 o tree-sitter para iOS — fuera del alcance de este experimento.
- App móvil convencional con chips/bubbles — reemplazada por consola TUI-first.

## E. Addendum: sandbox del iPhone

- El runtime puede usar una carpeta externa seleccionada por el usuario en el
  picker de Archivos. iSyCode guarda el bookmark entregado por iOS en Keychain y conserva
  el acceso solo mientras el workspace nativo está abierto; el usuario puede
  cambiar o revocar la carpeta.
- El agente queda confinado a esa raíz. El acceso no se extiende a carpetas
  vecinas, datos privados de otras apps ni al sistema. File Provider I/O se
  coordina con `NSFileCoordinator`; escrituras y borrados continúan sujetos a
  la aprobación de herramientas de la sesión.
- Si se usa un modelo remoto, el contenido de archivos que el agente lea puede
  viajar al proveedor configurado. La UI lo informa antes de conceder acceso.
- No hay permiso general para leer la pantalla, automatizar taps o controlar
  otras apps. La vía soportada para acciones entre apps es la superficie que
  cada app exponga mediante App Intents, Atajos o el picker/hoja Compartir.
