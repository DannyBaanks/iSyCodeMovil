# Asistente: Google, memoria y avisos de tu PC

El Asistente vive dentro de iSyCode Móvil en iPhone (botón **Asistente** arriba a la izquierda de Proyectos) y en Android (pestaña **Asistente**). Las dos apps comparten las mismas reglas y los mismos nombres de herramientas.

| Sección | Qué hace |
|---|---|
| **Inicio** | Saludo, estado (Google, PC, memoria), el campo "¿Qué necesitas?", acciones rápidas y los avisos recientes. |
| **Memoria** | Notas en carpetas de tres niveles (dominio › rama › subtema). Incluye búsqueda tolerante a errores con historial, una vista de carpetas, un grafo para arrastrar los nodos (colores por prioridad: crítica roja, alta naranja, normal azul) y una prueba de qué notas usaría GUS. |
| **Google** | Gmail, Calendar, Tasks, Drive, Contactos, Docs, Sheets y Classroom, con tu propia cuenta. |
| **Registro** | Solo con el modo desarrollador: cada llamada, con **Copiar** (JSON) y **Reintentar** en las fallidas. |
| **Opciones** | Apariencia (Automático / Oscuro / Claro), notificaciones, monitor de tu PC, Google y modo desarrollador (que además muestra el corpus de tools). |

Nada que cambie tus datos se ejecuta sin una confirmación visible: enviar un correo, crear un evento, un pendiente, un documento, una fila, un anuncio o guardar una nota en la memoria.

## 1. Conectar Google (una vez)

Cada usuario usa **su propio** proyecto de Google Cloud. La app no trae claves ni secretos.

1. En [console.cloud.google.com](https://console.cloud.google.com) crea un proyecto y configura la pantalla de consentimiento de OAuth. En modo *Testing*, agrega tu correo como usuario de prueba.
2. Habilita las APIs que vayas a usar: Gmail API, Google Calendar API, Google Tasks API, Google Drive API, People API, Google Docs API, Google Sheets API y Google Classroom API.
3. Crea los ID de cliente OAuth:
   - **iOS**: tipo *iOS*, bundle ID `dev.iyscode.movil`. La app usa el redireccionamiento `com.googleusercontent.apps.<tu-id>:/oauth2redirect` mediante `ASWebAuthenticationSession`, así que no tienes que editar el Info.plist.
   - **Android**: tipo *Android*, paquete `dev.iyscode.movil` y la huella SHA-1 de la firma (el APK de CI usa `app/debug.keystore`; obtén la huella con `keytool -list -v -keystore app/debug.keystore -storepass android`). En *Configuración avanzada*, activa **Esquema de URI personalizado**. El redireccionamiento es `dev.iyscode.movil:/oauth2redirect`.
4. En la app: **Asistente › Opciones › Google**, pega el ID de cliente, elige los servicios y toca **Iniciar sesión con Google** en la sección Google.

El inicio de sesión es OAuth 2.0 con PKCE y sin secreto de cliente. En iOS el token se guarda en el Llavero; en Android, en las preferencias privadas de la app (`allowBackup=false`). **Desconectar** revoca el token en Google.

## 2. Avisos de tu PC (monitor tipo raw.github)

El daemon de iSyCode TUI / IsyMCP en tu PC publica un JSON con sus tareas. Puede estar en GitHub (`raw.githubusercontent.com`), en cualquier `https://`, o en `http://` dentro de tu red local (`192.168.x.x`, `10.x.x.x`, `172.16–31.x.x`, `*.local`, `localhost`). El teléfono lo consulta cada 30 segundos con `If-None-Match` y avisa de cada `id` nuevo.

```json
{
  "tasks": [
    {
      "id": "build-2026-11-12-1",
      "title": "Build de iOS terminado",
      "body": "xcodebuild OK en 4m12s",
      "source": "pc.tui",
      "status": "completed",
      "createdAt": "2026-11-12T21:40:00Z"
    }
  ]
}
```

- `id` y `title` son obligatorios. `body` (o `summary`), `source`, `status` y `createdAt` son opcionales.
- También se acepta un arreglo en la raíz (`[ {...}, {...} ]`). Se leen como máximo 50 tareas.
- La primera lectura solo aprende lo que ya existe, para no llenarte de avisos viejos.
- **Avisarme de correos nuevos** revisa Gmail (no leídos de la bandeja) cada minuto.

**Límite real:** iOS y Android detienen las apps que no están en pantalla, así que el monitor y la vigilancia de Gmail funcionan **mientras la app está abierta**. Para que los avisos lleguen con el teléfono bloqueado, el daemon de tu PC tiene que enviar su propio push (APNs/FCM o un servicio como ntfy). El formato del manifiesto no cambia.

## 3. Herramientas para cualquier modelo

En iPhone, el agente de GUS (con cualquier modelo, local o en la nube) recibe solo las herramientas que vienen al caso para tu mensaje y cuyo permiso de Google diste. Las de escritura piden aprobación en el iPhone **cada vez**.

| Tool | Modo |
|---|---|
| `gmail.read.inbox` / `gmail.write.send` | lectura / escritura con confirmación |
| `googlecalendar.read.events` / `googlecalendar.write.event` | lectura / escritura con confirmación |
| `googletasks.read.list` / `googletasks.write.create` | lectura / escritura con confirmación |
| `googledrive.read.files` | lectura |
| `googledocs.write.create` | escritura con confirmación |
| `googlecontacts.read.lookup` | lectura |
| `googlesheets.read.range` / `googlesheets.write.append_row` | lectura / escritura con confirmación |
| `googleclassroom.read.courses` / `googleclassroom.write.announcement` | lectura / escritura con confirmación |
| `as.read.context_tree` | recorre la memoria por carpetas |
| `as.save.context` | guarda una nota (con confirmación) |

**Memoria en el prompt:** antes de cada respuesta se agregan al prompt las pocas notas que vienen al caso: primero la rama que coincide, luego las que comparten palabras y al final las críticas. Con **Contexto prioritario** activado, el recorrido abarca todo el dominio y lo que envías se guarda como nota crítica. En Android esto aplica al chat de GUS, que además tiene **Guardar en memoria** debajo de cada respuesta.

## 4. Lo que no incluye (y por qué)

- **Google Maps SDK / Places:** necesitan una clave de API y dependencias que no se pueden verificar en CI sin esa clave. "Buscar un lugar" abre tu app de mapas con la búsqueda.
- **Google Keep:** su API solo está disponible para cuentas de Google Workspace administradas, no para cuentas personales. Para notas rápidas, usa la Memoria o Tasks.
- **Grounding con Google Search:** es una función de la API de Gemini y requiere su propia clave. Los modelos que ya conectas a GUS pueden usar las herramientas de arriba.
