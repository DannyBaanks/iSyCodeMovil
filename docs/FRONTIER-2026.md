# ISyCode Móvil · Informe de la iteración Frontier

Rama local `design/frontier-2026`. La comparación parte de `4d1636e`, que ya incluía el primer ajuste de Inicio. La raíz activa es `App/IysCodeMovilApp.swift` y el inicio del chat vive en `ChatLandingView`.

## A · Llegar a la tarea

Al abrir por primera vez, la acción principal permite entrar y explorar. Los caminos para usar GUS, vincular la computadora o conectar un modelo siguen disponibles. El menú lateral agrupa conversaciones y herramientas y abre destinos del router existente. La zona táctil del borde distingue un arrastre horizontal del scroll vertical. El fondo se oculta del árbol de accesibilidad mientras el menú está abierto. Reducir movimiento desactiva la transición lateral.

Se conservó la familia de superficies de DesignSystem y se corrigieron los tokens de acento, tinta y modos para apariencia clara y oscura. La comparación numérica del botón coral, usando luminancia relativa sRGB de los colores sólidos declarados, es 3.49 → 7.07 en oscuro y 4.53 → 6.84 en claro. El degradado, los materiales y los demás componentes requieren una medición sobre imágenes de iOS.

## B · Conversar

El borrador de texto y los adjuntos tienen un dueño. Cambiar de conversación durante la preparación de una foto conserva el destino original. Abrir una conversación desde Inicio o desde un agente es una acción de navegación. El botón de envío selecciona explícitamente el destino. La selección del modelo pasa por WorkbenchStore.setModel, la ruta que actualiza la configuración persistida.

La actividad usa los eventos del turno actual. La vista muestra el tiempo cuando dispone de una fecha y los pasos cuando hay eventos de herramienta. Copiar y compartir operan sobre el mensaje. El reintento textual se oculta o deshabilita cuando perdería el contexto de los adjuntos. En las opciones del compositor, los modos admiten varias líneas y las opciones de adjuntar pasan a filas con tamaños accesibles.

El dictado continúa usando AVFoundation y Speech. El nivel de entrada se toma del medidor del grabador, la transcripción se incorpora al borrador y la cancelación distingue capturas sucesivas. La cámara, la fototeca y los archivos conservan sus selectores del sistema.

## C · Construir y autorizar

El constructor comienza con una intención editable y ofrece plantillas. GUS conserva su consulta al minimizarse y añade capacidades al borrador al aceptar una propuesta. La secuencia L1 y el alcance se derivan del contrato. Cambiar capacidades invalida la revisión anterior. La prueba presenta la salida y el recibo del intérprete. El guardado informa si la escritura o el registro de herramientas fallan.

Los resultados del control Linux de contratos cubren adición idempotente, invalidación de aprobación, lectura después de escribir y errores de persistencia. Se usaron dobles de llavero y registro. La autorización del dispositivo, el registro completo y la integración con proveedores requieren prueba adicional. El recibo del intérprete acredita la ejecución de la prueba definida en el contrato. Una prueba de ejemplo no certifica todas las capacidades del agente.

## D · Recuperarse y verificar

Los errores de cuota, límite de solicitudes, credenciales, permiso, compatibilidad y conexión ofrecen mensajes diferenciados, con el detalle original bajo demanda. El inspector `scripts/ui-doctor.py` inventaría identificadores y señala posibles botones con acciones vacías. Puede verificar nombres, destinos visibles, geometría y oclusión completa por teclado en XML de WDA. Opera sin tocar controles. Los hallazgos requieren revisión humana.

### Matriz de aceptación

| Escenario | Evidencia disponible | Pendiente |
|---|---|---|
| Abrir menú y volver al borrador | XCUITest de simulador escrito, Swift parseado, esquema verificado | Ejecutar con Xcode y revisar sus capturas |
| Nuevo chat y teclado | Separación de navegación y envío en las rutas reales | Teclado, rotación y gestos en iPhone |
| Cambiar modelo | Selector enlazado a setModel | Relanzar la app y comprobar el identificador remitido al proveedor |
| Enviar y recibir | Pruebas de lógica de turno, cursor y destino | Streaming real, cancelación remota y scroll |
| Abrir, minimizar y recuperar GUS | Estado conservado por la vista del constructor | Recorrido táctil y foco VoiceOver |
| Crear agente | Contrato y persistencia ejercitados con dependencias aisladas | Completar el recorrido en iOS |
| Ejecutar herramienta | Alcance, invalidación de aprobación y recibo conectados | Autorización física y ejecución extremo a extremo |
| Adjuntar fotografía | Regresión ejecutada para resultado tardío, Inicio, sesión y cambio de cuenta | Selector real, transporte y consumo por el proveedor |
| Dictar texto | Integración de captura, nivel real y entrega al borrador | Micrófono, interrupciones y transcripción real |
| Recuperar error | Clasificador ejecutado con errores de ejemplo | Recuperación interactiva con proveedor real |
| Reducir movimiento | Ramas de accesibilidad en menú, opciones y actividad | Verificación visual y de gestos |
| Chat extenso | Microbenchmark de construcción de filas con 500 eventos en Linux | Fluidez de scroll, memoria y FPS en iPhone |

Los bocetos de OpenSwift superponen ramas condicionales y en algunos casos dibujan una vista auxiliar del archivo. No sirven para aprobar las pantallas, el teclado ni el contraste renderizado. Las capturas históricas del repositorio corresponden a versiones anteriores. El entorno Linux no dispone de Xcode y el puente de iPhone no tiene un dispositivo operativo para esta revisión. La aceptación visual en dispositivo queda **NOT_DEMONSTRATED**.

### Decisión de plataforma

SwiftUI conserva la navegación, el compositor y el constructor sobre sus almacenes actuales. Las guías de Expo y React Native sirvieron para evaluar una pantalla embebida y la arquitectura de movimiento. La integración añadiría un runtime, un artefacto nativo para iOS y una frontera de estado sin resolver un fallo observado de estas pantallas. El panel web conserva React. No se evaluó el tamaño de una compilación hipotética con React Native.

### Reproducción

Desde el worktree de Frontier:

```bash
python3 scripts/test_ui_doctor.py
python3 scripts/ui-doctor.py
swiftc -parse UITests/ChatDrawerTests.swift
git diff --check 4d1636e..HEAD
```

Los controles de lógica en Linux usan fixtures. El benchmark mide solo la construcción de la representación de una conversación, con compilación optimizada, una ejecución de calentamiento y 200 muestras. El informe de paquete registra por separado los insumos compilados previamente, el ejecutable de esta rama y su suma de verificación.
