<div align="center">

<img src="./Assets.xcassets/AppIcon.appiconset/AppIcon-1024x1x.png" alt="Ícono de iSyCode Móvil" width="140">

# iSyCode Móvil

### Tus agentes y tu propia IA, contigo en el iPhone. Incluso sin internet.

[![iOS Build](https://github.com/DannyBaanks/iSyCodeMovil/actions/workflows/ios-build.yml/badge.svg?branch=main)](https://github.com/DannyBaanks/iSyCodeMovil/actions/workflows/ios-build.yml)
[![Release](https://img.shields.io/github/v/release/DannyBaanks/iSyCodeMovil?include_prereleases&label=release)](https://github.com/DannyBaanks/iSyCodeMovil/releases)
[![iOS 16.4+](https://img.shields.io/badge/iOS-16.4%2B-111111?logo=apple)](#-instálala)
[![22 modelos locales](https://img.shields.io/badge/GUS-22%20modelos%20locales-7c5cff)](#-gus-una-ia-que-vive-en-tu-iphone)
[![Licencia MIT](https://img.shields.io/badge/licencia-MIT-blue)](./LICENSE)

[Instalar](#-instálala) · [GUS sin internet](#-gus-una-ia-que-vive-en-tu-iphone) · [Conectar tu compu](#-conecta-tu-computadora) · [Si algo no jala](#-si-algo-no-jala)

</div>

---

## ¿Qué es esto?

Dejaste a un agente trabajando en tu computadora y saliste de casa. Abres **iSyCode Móvil**, ves qué hizo, le das permiso para seguir y listo, sin volver al escritorio.

¿Estás en el metro, sin señal? Abres **GUS**, una IA que vive **dentro de tu iPhone**. Nada sale del teléfono y no necesitas cuenta ni internet.

| | |
|---|---|
| 💬 **Tus conversaciones, claras** | Ves por separado tus mensajes, lo que responde el agente, las herramientas que usa y sus resultados. |
| ✋ **Tú decides** | Cuando el agente quiere cambiar algo, te pregunta. Apruebas o rechazas desde el celular. |
| 🧠 **GUS: IA sin internet** | Elige entre **22 modelos** (Qwen, Llama, Gemma, Phi, SmolLM, NVIDIA Nemotron…) y úsalos offline. |
| 📏 **Sabe qué cabe en tu iPhone** | La app mide la memoria real de tu teléfono y te dice qué modelo va bien, cuál va justo y cuál no. |
| 📊 **Benchmarks de la comunidad** | Mide qué tan rápido corre cada modelo en tu iPhone y publica el resultado para ayudar a otros. |
| 🩺 **Si se cierra, te dice por qué** | Al volver a abrirla sabes en qué estaba, con qué modelo y si fue por falta de memoria. |
| 💾 **No vuelvas a descargar** | Guarda tus modelos en Archivos y recupéralos al reinstalar la app. |
| 🧪 **Sandbox en el bolsillo** | Un agente que trabaja con los archivos privados de la app o con la carpeta que tú elijas. |
| 🎨 **Tu estilo** | Temas Consola y Premium. |

> iSyCode Móvil es el compañero de bolsillo de **iSyCode**, la experiencia de escritorio que estamos por publicar.

---

## 📸 La app por dentro

| Conectar | Proyectos | Conversación |
| :---: | :---: | :---: |
| <img src="docs/screenshots/connect.png" alt="Pantalla de conexión de iSyCode Móvil" width="250"> | <img src="docs/screenshots/projects.png" alt="Lista de proyectos de ejemplo" width="250"> | <img src="docs/screenshots/chat.png" alt="Chat de ejemplo con una acción sobre un archivo" width="250"> |
| **Empareja o prueba sin conexión.** | **Encuentra tu espacio.** | **Sigue cada acción del agente.** |

<p align="center"><sub>Capturas generadas en el iPhone Simulator de GitHub Actions con datos de ejemplo. Ninguna viene de un teléfono personal.</sub></p>

---

## 🚀 Empieza en 3 pasos

**1. Instala la app.** Baja la IPA y fírmala con tu Apple ID ([cómo, aquí abajo](#-instálala)).

**2. Elige cómo empezar:**

| Quiero… | Toco… |
|---|---|
| Probar la app sin nada más | **Entorno de prueba → guion de demo**. Es offline y no pide clave. |
| Una IA que funcione sin internet | **Entorno de prueba → GUS local**, y descargo un modelo. |
| Ver a mis agentes de la compu | **Conectar**, y pego el enlace del Bridge ([ver cómo](#-conecta-tu-computadora)). |

**3. Conversa.** Abre una sesión, mira lo que hace el agente y responde cuando te pida permiso.

### 📲 Instálala

1. Entra a [**Releases**](https://github.com/DannyBaanks/iSyCodeMovil/releases) y baja la última versión. Usa `IysCodeMovil-signed.ipa` si aparece; si no, `IysCodeMovil-unsigned.ipa`.
2. Si quieres comprobar el archivo, usa `SHA256SUMS.txt`.
3. Instálala con [**iloader**](https://iloader.app), [SideStore](https://sidestore.io) o [AltStore](https://altstore.io) usando tu Apple ID.
4. En el iPhone ve a **Ajustes → General → VPN y administración de dispositivos**, confía en tu Apple ID y activa el **Modo de desarrollador** si te lo pide.

> ⏳ Con un Apple ID gratuito la app **dura 7 días**. Después vuelves a firmarla y sigue funcionando.
>
> 💾 Antes de reinstalar, usa **Guardar copia** en la pantalla de modelos para no volver a descargar GUS ([ver abajo](#-no-vuelvas-a-descargar-tus-modelos)).

---

## 🧠 GUS: una IA que vive en tu iPhone

GUS corre **dentro del teléfono** con [llama.cpp](https://github.com/ggml-org/llama.cpp). Tus mensajes no salen del iPhone, no hay cuenta ni clave, y funciona en modo avión.

**Cómo:** **Entorno de prueba → Proveedores → GUS local**. Elige un modelo, descárgalo una vez y listo.

### Los modelos

**Recomendados:** pesan hasta 1.6 GB y funcionan en la mayoría de iPhones recientes.

| Modelo | De | Tamaño | Lo bueno |
|---|---|---:|---|
| SmolLM2 135M | Hugging Face | 0.1 GB | Diminuto y rapidísimo |
| SmolLM2 360M | Hugging Face | 0.3 GB | Ligero para respuestas cortas |
| Qwen3 0.6B | Alibaba | 0.4 GB | Razona antes de contestar |
| Qwen2.5 0.5B | Alibaba | 0.5 GB | El equilibrio clásico |
| TinyLlama 1.1B | TinyLlama | 0.7 GB | Clásico y ligero |
| Llama 3.2 1B | Meta | 0.8 GB | Multilingüe, incluye español |
| Gemma 3 1B | Google | 0.8 GB | Multilingüe, de Google |
| SmolLM2 1.7B | Hugging Face | 1.1 GB | El más capaz de los Smol |
| Qwen3 1.7B | Alibaba | 1.1 GB | Razonamiento en poco espacio |
| Qwen2.5 1.5B | Alibaba | 1.1 GB | Sólido para todo |
| Qwen1.5 1.8B | Alibaba | 1.2 GB | El original de GUS (uso no comercial) |

**Experimentales 🧪:** para iPhones con más RAM, como un Pro reciente. Están ocultos tras un interruptor.

| Modelo | De | Tamaño |
|---|---|---:|
| SmolLM3 3B | Hugging Face | 1.9 GB |
| Llama 3.2 3B | Meta | 2.0 GB |
| Phi-3.5 mini · Phi-4 mini | Microsoft | 2.4–2.5 GB |
| Gemma 3 4B | Google | 2.5 GB |
| Qwen3 4B | Alibaba | 2.5 GB |
| Nemotron Mini 4B · Nemotron Nano 4B | NVIDIA | 2.7–2.8 GB |
| Llama 3.1 8B | Meta | 4.9 GB |
| Qwen3 8B | Alibaba | 5.0 GB |
| **Nemotron Nano 9B v2** | NVIDIA | 6.5 GB |

Cada modelo lleva su licencia, su origen y su huella SHA-256. La app **verifica cada archivo antes de usarlo**; si no coincide, lo borra. Los modelos nunca vienen dentro de la app: los descargas tú, y la descarga sigue aunque bloquees la pantalla.

### 📏 ¿Cabe en mi iPhone?

No adivinamos por el nombre del modelo de iPhone. La app mide **cuánta memoria le deja iOS en ese momento** y la compara con lo que necesita cada modelo:

| Etiqueta | Qué significa |
|---|---|
| 🟢 **Cabe bien** | Usa menos del 70 % de lo disponible. |
| 🟡 **Justo** | Puede funcionar, pero otras apps abiertas o chats largos lo pueden tumbar. Te pide confirmar. |
| 🔴 **Probablemente no cabe** | Pasa a la sección experimental. |

> **¿Y si me arriesgo con uno grande?** Lo peor que pasa es que **iOS cierra la app**, el teléfono se calienta un rato o se llena el almacenamiento. Tus datos y tu iPhone están a salvo. Si la app se cierra, al volver te dice exactamente por qué.

### 💾 No vuelvas a descargar tus modelos

iOS borra los datos de una app cuando la eliminas o cuando la reinstalas con otro identificador, algo común al firmar con iloader o SideStore. Para no perder tus modelos:

1. En la pantalla de GUS toca **Guardar copia** y elige una carpeta **fuera** de iSyCode, por ejemplo *En mi iPhone › Descargas* o iCloud Drive.
2. Después de reinstalar, toca **Importar desde Archivos** y elige esa carpeta.

La app reconoce cada modelo por su huella, **aunque le hayas cambiado el nombre**, y lo deja listo sin descargar nada.

### 🔒 Lo que GUS puede y no puede hacer en iPhone

- **Puede trabajar con archivos del sandbox** usando una superficie de miniagente: leer, buscar, editar texto, reemplazar rangos de líneas, append, copiar, mover/renombrar y borrar dentro del workspace autorizado.
- **Cada cambio pide aprobación visible de nuevo.** Un permiso anterior no autoriza automáticamente la siguiente mutación.
- **No tiene shell ni puede lanzar procesos**, y tampoco obtiene acceso general al iPhone, otras apps o secretos del Keychain.
- **No manda la inferencia de GUS a la nube** ni tiene fallback remoto.

Detalles, licencias y procedencia: [aviso de modelos](docs/MODEL_NOTICE.md) · [cómo funciona el catálogo](docs/GUS_MARKETPLACE.md).

---

## 📊 Benchmarks: ¿qué tan rápido va en tu iPhone?

Todos los modelos ya pasaron una prueba en computadora. Lo que falta son **mediciones en iPhones reales**, y ahí entras tú.

1. Descarga un modelo y toca **Benchmark en este iPhone**.
2. La app corre 4 tareas fijas y mide carga, velocidad (tokens por segundo), memoria máxima y temperatura.
3. Toca **Publicar en GitHub**, pega el JSON en el formulario y envíalo.

El reporte **no incluye tus mensajes**, solo números. Cuando se aprueba, aparece en la tabla de [**Benchmarks**](docs/BENCHMARKS.md), agrupado por modelo y por iPhone.

> Si iOS cierra la app a media prueba, también sirve: se publica como **KILLED** y le dice a todos dónde deja de caber ese modelo.

---

## 🩺 Si la app se cierra, sabrás por qué

Como esas apps que te muestran un informe cuando algo falla. Antes de cada paso delicado (cargar un modelo, generar una respuesta) la app anota en qué va y cuánta memoria usa. Si iOS la cierra, al volver a abrirla te dice algo como:

> ⚠️ **La app terminó durante la carga del modelo · Qwen3 4B.**
> Probablemente iOS la cerró por exceder su límite de memoria. Última medición: 2.9 GB en uso, 40 MB disponibles.

- **Historial completo** en **Informes de fallos**.
- **Confirmación de Apple** cuando llega (MetricKit), con la pila técnica para depurar.
- **Exporta o reporta** con un toque, usando el [formulario de fallos](https://github.com/DannyBaanks/iSyCodeMovil/issues/new?template=crash-report.yml).
- **Nunca guarda** el texto de tus mensajes ni de las respuestas.

---

## 💻 Conecta tu computadora

### OpenCode (disponible hoy)

En tu computadora (Node.js 18+ y OpenCode instalados), entra a la carpeta del proyecto y ejecuta:

```bash
npx --yes github:DannyBaanks/iSyCodeMovil#main link
```

Copia el enlace que aparece, abre **Conectar con Bridge anterior** en la app y pégalo. Deja la terminal abierta mientras lo uses.

### Codex (experimental)

Chat, streaming y aprobaciones por Tailscale. Ver la [guía remota](docs/REMOTE.md#experimental-codex-app-server).

### Host de iSyCode (en camino)

El emparejamiento con PIN de 6 dígitos ya funciona. Las sesiones llegan con la versión de escritorio.

> 🌎 **¿Fuera de casa?** Instala [Tailscale](https://tailscale.com) en la computadora y en el iPhone, y usa su dirección. **No expongas el puerto 4096 a Internet**: el Bridge es para tu red de confianza o una VPN.

---

## 🧪 El sandbox del iPhone

Un agente Swift que trabaja dentro del espacio privado de la app:

- Prueba el **demo sin internet** o conecta un proveedor en la nube: NVIDIA NIM, xAI, OpenAI API, Gemini u OpenRouter.
- **Dale una carpeta** desde Archivos si quieres; puedes quitarle el permiso cuando sea.
- **Aprueba cada cambio** de archivos antes de que ocurra.

Tus claves se guardan en el **Keychain** del iPhone. Si eliges un modelo en la nube, lo que le mandes sale hacia ese proveedor. Si eliges **GUS**, no sale nada.

---

## ✅ Qué puedes hacer hoy

| Experiencia | Estado |
|---|---|
| Sandbox en el iPhone | ✅ Disponible |
| GUS: 22 modelos locales, miniagente de archivos, benchmark e informes de fallos | 🧪 Experimental: runtime y CI en validación; mediciones físicas dependen del modelo/iPhone |
| OpenCode en tu computadora | ✅ Disponible con el Bridge |
| Codex en tu computadora | 🧪 Experimental |
| Host de la TUI de iSyCode | 🚧 En desarrollo: emparejamiento listo, sesiones en camino |

### ¿El agente puede usar todo mi iPhone?

No. Empieza en los archivos privados de la app y solo ve una carpeta externa si tú la eliges. No puede leer datos de otras apps ni controlar tu pantalla. Ver [límites de iOS](docs/IOS_LIMITATIONS.md).

---

## 🆘 Si algo no jala

| Pasa esto | Prueba esto |
|---|---|
| `Could not connect to the server` | No uses `127.0.0.1`: usa la IP de tu red o de Tailscale que muestra el Bridge, y revisa que siga abierto. |
| El enlace no abre la app | Copia el enlace completo `iyscodemovil://…` y pégalo en la pantalla de conexión. |
| La app no instala o dejó de abrir | Fírmala otra vez (pasaron los 7 días) y confía en tu Apple ID en Ajustes. |
| Me pide descargar los modelos otra vez | iOS borró los datos al reinstalar. Usa **Importar desde Archivos** con tu copia. Si no tenías copia, descárgalos y toca **Guardar copia**. |
| La app se cierra al cargar un modelo | Ese modelo no cabe ahora. Cierra otras apps o elige uno marcado 🟢. El detalle está en **Informes de fallos**. |
| GUS tarda mucho en responder | Los modelos grandes van más lentos y el iPhone se calienta. Prueba uno más chico. |
| `Rate limited` | El proveedor en la nube limitó tus llamadas. Espera un poco y revisa tu cuota. |
| El sandbox no ve mi carpeta | Vuelve a elegirla desde Archivos dentro de la app. |

---

<details>
<summary><b>🛠️ Para desarrolladores: compilar y contribuir</b></summary>

<br>

Necesitas macOS, Xcode, [XcodeGen](https://github.com/yonaskolb/XcodeGen) y CMake:

```bash
brew install xcodegen cmake
bash scripts/build-llama-xcframework.sh   # llama.cpp fijado a un commit
xcodegen generate
open IysCodeMovil.xcodeproj
```

- **CI:** cada push a `main` compila la app, corre las pruebas en el iOS Simulator, genera las capturas de este README y publica una pre-release con la IPA y sus SHA-256.
- **Catálogo de GUS:** `Catalog/models.json` es la fuente de verdad. El workflow *GUS model catalog* resuelve cada modelo en Hugging Face, compila el bridge real de la app en Linux y lo prueba con cada GGUF. Para agregar un modelo, sigue [docs/GUS_MARKETPLACE.md](docs/GUS_MARKETPLACE.md).
- **Benchmarks:** los reportes se validan con `scripts/benchmarks/validate.py` y se agregan a [docs/BENCHMARKS.md](docs/BENCHMARKS.md).

Más documentación:
- [Uso detallado](docs/USAGE.md)
- [Conexión y transporte](docs/REMOTE.md)
- [Compatibilidad con OpenCode](docs/OPENCODE_COMPAT.md)
- [Roadmap de runtimes](docs/ROADMAP_CLIS.md)
- [Propuesta MCP](docs/CHATGPT_MCP.md)

</details>

## Licencia

El código es **MIT**; ver [LICENSE](LICENSE). Cada modelo de GUS conserva su propia licencia, que ves en la app antes de descargarlo.

iSyCode Móvil no está afiliado con OpenCode, OpenAI, Anthropic, Google, Meta, Microsoft, Alibaba, NVIDIA, Hugging Face, xAI ni OpenRouter.