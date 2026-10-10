# GUIA — Link Desktop real (iPhone ↔ OpenCode)

> Guía humana para operar el flujo real de emparejamiento. Todo comando aquí
> fue ejecutado y su salida es la real capturada en esta máquina (2026-09-18,
> opencode 1.18.31, Windows). Si un comando no se pudo probar, se marca.

---

## El comando que viniste a buscar

En la carpeta del proyecto que quieres que OpenCode controle:

```bash
npx --yes github:DannyBaanks/IysCodeMovil#main link
```

Eso es todo en el escritorio. El resto es pegar el link en el iPhone.

---

## La regla de oro

**La terminal que lanzó `link` debe permanecer abierta.** El password es
efímero: al cerrar esa terminal muere el servidor y el password queda
inválido. Y jamás hagas port-forward del puerto 4096 a internet — este
flujo es para una LAN de confianza (o túnel TLS/VPN).

---

## Paso 1 — Lanzar el link (escritorio)

Salida real capturada (el password mostrado era de una sesión ya cerrada;
cada corrida genera uno nuevo):

```

iyscode native / desktop link
────────────────────────────────────────
project   C:\Development\ISyCo Git\IysCodeMovil
server    http://192.168.1.102:4096

paste this into the iPhone app:

iyscodemovil://pair?host=192.168.1.102&port=4096&username=iyscode&password=%3CREDACTED%3E&directory=C%3A%5CDevelopment%5CISyCo+Git%5CIysCodeMovil

Keep this terminal open. Ctrl+C stops the link.
────────────────────────────────────────

opencode server listening on http://0.0.0.0:4096
```

El password del pairing está oculto en este ejemplo. El Bridge genera uno
nuevo en cada ejecución y avisa que HTTP no cifra credenciales ni tráfico.

Si el Bridge no encuentra una IPv4 privada enrutable (RFC1918) imprime un
`WARNING` — significa que la IP impresa probablemente no la alcanza el
iPhone (p.ej. adaptadores Bluetooth/Hyper-V en `169.254.*`). Conecta ambos
equipos al mismo Wi-Fi y reintenta.

## Paso 2 — Conectar el iPhone

1. Instala la app (artefacto `IysCodeMovil-unsigned` del CI, firmado con
   iloader o vía sideload).
2. Pega el link `iyscodemovil://pair?...` en la primera pantalla y toca
   **connect**.
3. Si todo va bien verás `OpenCode connected` y la sesión del servidor.

## Paso 3 — Verificar (opcional, escritorio)

```powershell
# Salud del servidor con Basic auth (usa el password impreso en tu terminal):
Invoke-RestMethod "http://192.168.1.102:4096/global/health" `
  -Headers @{ Authorization = "Basic " + [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes("opencode:<PASSWORD>")) }
# Salida real: {"healthy":true,"version":"1.18.31"}

# Sin credencial el servidor responde 401 (protegido, como debe ser):
Invoke-RestMethod "http://192.168.1.102:4096/global/health"   # -> 401
```

---

## Cómo leer los estados

| Lo que ves | Significado | Qué hacer |
|---|---|---|
| `OpenCode connected` en la app | SSE + HTTP OK | A usar |
| `connection refused` / timeout en connect | Firewall bloquea inbound o el servidor no corre | Ver trampa #1 |
| `error: HTTP 401` en la app | Password/host mal pegados | Re-copia el link completo |
| `WARNING: no private-routable IPv4` en la terminal | La IP del pairing no es alcanzable por LAN | Mismo Wi-Fi, reintenta |
| `failed to start opencode` | `opencode` no está en PATH | Instala OpenCode (`npm i -g opencode-ai`) |
| Banner `Connection lost` en la app | Se cayó el SSE | Toca **Reconnect** (o cierra y relanza el link) |

---

## Las trampas (cada una costó tiempo real)

### 1. Firewall en red **Public** — el iPhone no conecta aunque todo lo demás esté bien

En esta máquina el Wi-Fi está con perfil **Public** (`Get-NetConnectionProfile`
→ `NetworkCategory: Public`); Windows bloquea inbound por defecto. Dos salidas:

- **GUI:** Configuración → Red e Internet → Wi-Fi → propiedades de la red →
  "Perfil de red" → **Privada** (acción del usuario, sin admin extra).
- O crea una regla inbound para el puerto 4096 en redes Privadas (requiere
  PowerShell como admin):

```powershell
# NO PROBADO (requiere admin): se deja documentado, no ejecutado
New-NetFirewallRule -DisplayName "OpencodeNative link" -Direction Inbound `
  -LocalPort 4096 -Protocol TCP -Action Allow -Profile Private
```

### 2. La IP del pairing puede no ser la del Wi-Fi

`os.networkInterfaces()` devuelve las interfaces en orden arbitrario; esta
máquina tiene 4 adaptadores en `169.254.*` (Bluetooth, Wi-Fi extra, Ethernet)
**antes** del Wi-Fi real `192.168.1.102`. El Bridge ahora elige una IPv4
privada (RFC1918) y avisa si no la encuentra. Si ves el `WARNING`, revisa qué
red tiene el iPhone.

### 3. `--directory` con espacios por línea de comandos

`node Bridge/bin/iyscodemovil.mjs link --directory "C:\ruta con espacios"`
funciona en una shell normal, pero lanzarlo vía `Start-Process -ArgumentList`
partió el argumento (`unknown option: Git\OpencodeNative` — capturado real).
Si usas wrappers que parten argumentos, **no pases `--directory`**: el Bridge
usa el directorio actual por defecto.

### 4. El servidor corre en el cwd, no donde lances npx

`npx ... link` expone **el directorio donde lo ejecutas**. Ejecútalo desde el
proyecto que quieres controlar (la `x-opencode-directory` del cliente viaja
desde el link, y el worktree del servidor queda fijado ahí).

### 5. El aviso de Node 20 deprecado en el arranque

El runner de acciones imprime "Node.js 20 is deprecated..." — es ruido de
`actions/checkout@v4`, no del flujo; ignóralo.

---

## Grok en tu computadora (experimental)

NO PROBADO de punta a punta en el iPhone: esta máquina no tiene Xcode, y el
enlace de Tailscale no se dejó abierto. El IPA que ya está en Descargas se
compiló antes de este adaptador, así que ese build no sabe abrir `grok://`.

El comando de GitHub (`npx ... #main`) todavía no trae este adaptador. En este
checkout, desde la carpeta del proyecto:

```bash
node Bridge/bin/iyscodemovil.mjs link --runtime grok --host tailscale --directory "$PWD"
```

Pega en el iPhone la línea `grok://pair?...`. El iPhone no habla con el
`localhost` del teléfono: entra por la IP de Tailscale. Grok escucha solo en
`127.0.0.1` de la computadora. El enlace lleva un token de la app. La clave
interna de Grok no sale de la computadora. No reenvíes el enlace.

Ctrl+C cierra el puente y Grok. Para volver a entrar hace falta un enlace
nuevo. No uses `--always-approve`.

Lo que sí se probó aquí, el 2026-10-09: `grok agent serve` en loopback responde
ACP (`initialize`, `session/new`, `session/list`). El proxy del Bridge en
`127.0.0.1` rechaza un WebSocket sin token. Con el token, el mismo proxy
reenvió un turno de texto y Grok contestó `pong` (`stopReason` end_turn, sin
herramientas). `session/list` devuelve una ventana global; la app se queda
solo con la carpeta emparejada. El historial no se carga. Archivos, terminal,
renombrar y borrar no están en este adaptador.

---

## Qué es real y qué no

- El servidor es **el OpenCode real** (1.18.31 probado): modelos, tools,
  permisos, diff, persistencia de sesiones ocurren en tu computadora.
- El iPhone renderiza el workbench nativo y habla HTTP/SSE con el servidor:
  `/session`, `/prompt_async` (204), `/abort`, `/file?path=` (el query es
  **obligatorio**), `/session/:id/shell` (el campo **agent** es
  **obligatorio**), `/provider`, `/config`, `/event` (SSE) — todos
  verificados contra el servidor real el 2026-09-18.
- La terminal/PTY del OpenCode TUI **no** corre en iOS (límite de la
  plataforma, documentado en `docs/IOS_LIMITATIONS.md`); no hay imitación.
