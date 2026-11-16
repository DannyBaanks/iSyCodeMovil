# UX-02 — Alineación nativa Android/iOS

Rama: `feat/mobile-ux-02-native-alignment`.

## Implementado

Android Compose y SwiftUI ahora presentan `Resumen` en lugar de `Inicio`, manteniendo la misma nomenclatura que la web mergeada. La portada nativa expone una lectura semántica común de las capacidades: preguntar, leer Google y actuar con confirmación.

En Android Compose, `HomeSection` conserva los contratos existentes del `AssistantViewModel` y añade estados explícitos para Google, asistente local, memoria local y equipo local. Cuando el monitor no reporta una conexión activa, el texto mostrado es `estado no verificado` en lugar de inventar una señal live. También se muestra la regla `Proponer → confirmar → ejecutar`.

En SwiftUI se aplicó el mismo contrato semántico al hero de `HomeSection`, se añadieron las tres tarjetas de capacidades y se mantuvieron las convenciones nativas de `NavigationStack`, `ScrollView`, `Button` y sheet de confirmación. No se sustituyó ninguna implementación por WebView.

## Contratos compartidos

- Secciones: `Resumen`, `Memoria`, `Google`, `Registro` y `Opciones`.
- Seguridad: `PROPOSED → AUTHORIZED → EXECUTED`, con confirmación humana antes de escrituras.
- Estados honestos: conectado, sin conectar, local y estado no verificado según la señal disponible.
- Capacidades: preguntar/resumir, leer sin cambiar datos y actuar con confirmación.
- Dark/light mode y tokens nativos existentes se conservaron.

## Verificación

- `git diff --check`: PASS.
- Android Gradle wrapper inició correctamente, pero `:app:compileDebugKotlin` no pudo configurar el proyecto porque el entorno no tiene Android SDK localizado (`ANDROID_HOME`/`local.properties` ausentes).
- No hay emulador Android ni dispositivo conectado por `adb`.
- No hay Xcode/macOS disponible; SwiftUI fue revisado estáticamente y no se declara compilación o ejecución iOS.
- Las pruebas web y bridge de la base ya pasaron antes de abrir esta rama; este cambio nativo no altera esos contratos.

## Evidencia

- `DEMONSTRATED`: cambios de código Android/SwiftUI inspeccionados, diff limpio y contratos de navegación/capacidad alineados.
- `INFERRED`: compilabilidad de los cambios nativos, sustentada por APIs y patrones ya usados en los archivos.
- `NOT_DEMONSTRATED`: build Android por SDK ausente, build/ejecución iOS por falta de Xcode, click-through nativo, teclado físico/virtual y lector de pantalla real.
