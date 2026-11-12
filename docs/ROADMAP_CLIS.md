# Roadmap: más CLIs en IysCode Movil

## Objetivo

Usar desde el iPhone los CLIs que corren en una computadora enlazada. Los CLIs
siguen ejecutándose en la computadora: iOS actúa como cliente remoto y no intenta
ejecutar Bun, shells, PTYs ni binarios de terceros dentro de la app.

## Estado de partida

- OpenCode y OpenISy comparten el transporte remoto OpenCode; el Bridge inicia
  ambos.
- Hay stubs de Crush, Claude Code y Gemini, pero todavía no son backends
  funcionales; Codex está descrito en la actualización siguiente.
- En el host revisado están disponibles Claude Code (`claude`), Codex
  (`codex`), OpenCode (`opencode`), Gemini (`gemini`), Bun y Node. `crush` no
  aparece en el `PATH` de este host.

**Actualización 2026-09-27:** Codex dejó de ser un stub y tiene un adapter
experimental de alcance limitado (Codex CLI 0.155.1 inspeccionado). Incluye
pairing token por Tailscale, JSON-RPC App Server, threads, texto/streaming,
interrupción e approvals representables. No cuenta como compatibilidad de
producción ni como implementación de los otros CLIs. El build iOS de esta
revisión sigue pendiente porque el host de trabajo es Linux y no tiene Xcode.

**Actualización 2026-10-10:** Grok CLI 1.0.50 tiene un adapter experimental en
el working tree, sin commit. `grok agent serve` se queda en `127.0.0.1` y el
Bridge publica un proxy WebSocket solo en Tailscale. iOS habla ACP. El
2026-10-09 un turno de texto pasó por el proxy en loopback y Grok contestó
`pong`. No se compiló iOS ni se dejó el listener de Tailscale abierto. Los
otros CLIs del probe no se cablearon.

## Hitos

### M0 — Base del Bridge y seguridad inmediata

**Estado: cambios preparados en esta revisión; pendientes de ejecución de pruebas.**
Se corrigieron los nombres de paquete, bin y comando de pruebas; se añadió
`--openisy-root`; se rechazan parámetros duplicados en enlaces de pairing; se
bloquean symlinks del workspace; se retiró la excepción global de ATS y el
Bridge advierte que HTTP no cifra el tráfico.

**Listo cuando:** los nombres de instalación/documentación coinciden con los
archivos del repositorio, el OpenISy root se resuelve por argumento o variable
de entorno, y las rutas de herramientas no siguen symlinks.

La advertencia reduce el riesgo de uso accidental, pero el tráfico OpenCode
sigue en HTTP dentro de una LAN. TLS verificable o VPN es el objetivo de M2.

### M1 — Contrato común de adaptadores

Definir una interfaz del Bridge para descubrir, iniciar, enumerar capacidades,
crear/seleccionar sesiones, enviar prompts, transmitir eventos, cancelar y
contestar permisos. Cada adapter declara soporte por capacidad; la UI no debe
presentar como disponible una operación que el CLI no puede ejecutar.

**Listo cuando:** OpenCode/OpenISy siguen funcionando detrás del contrato común
y un adapter simulado permite probar el ciclo de sesión sin ejecutar un LLM.

### M2 — Transporte y emparejamiento seguros

Separar el pairing del formato específico de OpenCode. Acordar el transporte
entre Bridge y app, renovación de credenciales, alcance por proyecto/sesión y
reconexión. Priorizar TLS verificable o un túnel VPN; mantener HTTP solo como
modo LAN claramente advertido hasta que los runtimes puedan ofrecer TLS directo.

**Listo cuando:** credenciales y mensajes no viajan en claro por redes públicas,
el usuario puede revocar un pairing y los errores de conexión son visibles en
la app.

### M3 — Codex CLI y Claude Code

**Estado Codex: parcial, experimental.** El Bridge deriva un perfil del schema
instalado y enlaza a una IP Tailscale; iOS guarda el token en Keychain y adapta
threads, turnos de texto, streaming, interrupción e approvals que puede
representar sin cambiar su significado. El transporte App Server es `ws://`
dentro de Tailscale. Pendientes: validación de build en Xcode, cobertura de
versiones/dispositivos y Claude Code.

Implementar adapters separados para los CLIs disponibles. Antes de programar
cualquiera de los dos, comprobar en la versión instalada los modos no
interactivos, eventos estructurados, persistencia/resume de sesiones,
cancelación y aprobaciones. Traducir solo las capacidades que realmente existan
a eventos y permisos de la app.

**Listo cuando:** cada CLI inicia una tarea, transmite salida incremental,
permite cancelar y retoma sesiones si la versión soporta esa función; los
permisos se muestran antes de acciones que el adapter clasifique como riesgosas.

### M4 — Gemini CLI y Crush

Aplicar el mismo contrato a Gemini. Para Crush, primero localizar su instalación
en el host objetivo y confirmar si ofrece un modo headless o un protocolo
estable. Si solo ofrece TUI/PTY, dejar esa limitación explícita hasta tener una
API soportada; no simular un servidor compatible.

**Listo cuando:** cada adapter implementado pasa su propia matriz de capacidades
y los runtimes sin transporte estable se identifican como no disponibles.

### M5 — CLI propio y extensibilidad

Publicar un contrato documentado para que el CLI propio pueda integrarse como
adapter: identidad/versionado, sesión, streaming, cancelación, permisos, errores
y compatibilidad. Mantener los detalles propios del CLI detrás de su adapter.

**Listo cuando:** una versión de desarrollo del CLI propio se puede enlazar sin
modificar el núcleo de la app y declara su versión de protocolo.

### M6 — Compatibilidad y distribución

Validar instalación/detección del Bridge en macOS, Windows y Linux; compatibilidad
con versiones de CLI y Node/Bun; firewall, redes domésticas y VPN; actualización
y desinstalación. Publicar una tabla por runtime con versiones verificadas y
capacidades reales.

**Listo cuando:** una matriz CI/release cubre los adapters soportados y la guía
permite instalar, enlazar, actualizar y revocar cada runtime.

## Orden sugerido

M0 → M1 → M2 → M3 (Codex y Claude en paralelo por adapter) → M4 → M5 → M6.
OpenCode/OpenISy sirven como referencia durante toda la transición.

## Decisiones para aprobar antes de M1

1. Orden entre Codex y Claude Code para el primer adapter.
2. Política de pairing: VPN/TLS obligatorio para remoto, con HTTP limitado a
   LAN explícita.
3. Alcance de Crush: buscarlo en otro host o aplazarlo si no hay API headless.
4. Cuándo integrar el CLI propio: como primer adapter del contrato o después de
   estabilizar Codex/Claude.
