# Panel web de iSyCode Móvil

Un panel que corre **en tu computadora** (solo escucha en `127.0.0.1`) con:

- **Asistente** con Gemini y las herramientas de Google Workspace (Gmail, Calendar, Drive, Docs, Sheets, Tasks, Keep, Contactos, Classroom), más Google Maps y Búsqueda con fuentes.
- **Memoria & Contexto**: el árbol de contexto semántico (dominio › categoría › tema), con buscador tolerante a erratas, grafo y vista previa de qué recuerdos recibiría el modelo.
- **Mis Apps de Google**: cada herramienta como formulario, para probarla a mano.
- **Bitácora** (modo desarrollador): lo que de verdad pasó, con reintento de lecturas.

Nació como un prototipo hecho en Google AI Studio. De aquel prototipo se conservó el diseño y la idea; la lógica se reescribió sobre los módulos del Bridge (`../Bridge/workspace`), que son los que prueba `npm run test:bridge` en la raíz.

## Cómo correrlo

```bash
cd web
npm install
cp .env.example .env     # y llena lo que vayas a usar
npm run dev              # http://127.0.0.1:3000
```

Para usarlo sin el servidor de Vite: `npm run build && npm start`.

### Lo que necesita (todo opcional: el panel abre sin nada y te dice qué falta)

| Variable | Para qué | Cómo obtenerla |
|---|---|---|
| `GEMINI_API_KEY` | que el asistente responda | <https://aistudio.google.com/apikey> |
| `GEMINI_MODEL` | otro modelo (por defecto `gemini-2.5-flash`) | si Google retira uno, cámbialo aquí |
| `ISY_GOOGLE_CLIENT_ID` (+ `ISY_GOOGLE_CLIENT_SECRET`) | iniciar sesión con Google | cliente OAuth tipo **App de escritorio** en <https://console.cloud.google.com/apis/credentials>; habilita las APIs que vayas a usar |

No hay un `client_id` incluido a propósito: tiene que ser tuyo, para que la pantalla de permisos de Google muestre *tu* proyecto.

## Cómo se protege

- **Solo lectura por defecto.** La sesión de Google pide únicamente permisos de lectura, uno por herramienta. Los de escritura se piden solo si activas «Permitir acciones de escritura» en Opciones.
- **El modelo propone, tú confirmas.** Enviar un correo, agendar, escribir en una hoja o guardar un recuerdo desde el asistente nunca se ejecuta solo: aparece una ventana con los datos exactos y solo corre al confirmarla. El servidor rechaza (409) cualquier escritura que no venga confirmada.
- **El contenido que lee es dato, no instrucciones.** Los resultados de correos o documentos se entregan al modelo marcados como no confiables.
- **Tu token no toca el disco.** Vive en la memoria del proceso; al reiniciar vuelves a entrar.
- **Solo tu navegador, solo esta página.** Se rechazan Host y Origin ajenos (CSRF / DNS rebinding).
- **Sin respuestas de relleno.** Si Gemini o Google fallan, ves el error; no hay un «modo local» que finja haber ejecutado algo.
- **Qué sale de tu compu.** Al usar «Usar mi memoria», Gemini recibe **solo los recuerdos relevantes** a tu mensaje (más los marcados como críticos), no todo el árbol. Los recuerdos viven en `~/.iyscodemovil/semantic-context.json` (permisos `0600`).

## Pruebas

```bash
npm test            # API del panel: confirmaciones, host/origin, asistente con Gemini simulado
npm run typecheck
```

El motor de memoria y las herramientas de Google se prueban en la raíz con `npm run test:bridge`.

## Lo que no se portó del prototipo (y por qué)

- **Notificaciones push / «daemon PTY» / monitor `raw.github`**: eran maquetas sin backend; no existe un APNs/FCM ni un daemon que las respalde.
- **Ejecutar comandos en la compu desde el modelo (`tui_exec_daemon_task`)**: no se expone; para eso está el sandbox Docker del Bridge, con sus propias aprobaciones.
- **Firebase/Firestore**: el prototipo usaba un proyecto de AI Studio ajeno a este repo. Aquí los datos viven en tu compu.
- **Simulador de iPhone/Android y visor de código nativo**: ya existen las apps reales (`Sources/`, `android/`).
