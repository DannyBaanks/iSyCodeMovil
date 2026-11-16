# UX-01 — Validación responsive post-merge

Fecha de validación: 2026-11-15. Base: `main` en `0c8c699`, incluyendo el merge de PR #26.

## Hallazgo corregido

La primera captura móvil mostró que el encabezado conservaba logo y botón de Google, pero la navegación principal quedaba comprimida fuera de la vista en 390–412 px. La portada y los estados sí se adaptaban correctamente, pero las secciones Memoria, Google y Opciones no tenían una ruta de navegación visible.

La corrección se implementó en `web/src/App.tsx`: en pantallas menores que `sm` la navegación se presenta como un `<select>` accesible con la sección actual; tablet y desktop conservan el menú horizontal existente. No se sustituyó ningún contrato de backend ni se alteró la autoridad de confirmación.

## Matriz de evidencia

| Viewport | Resultado | Evidencia |
|---|---|---|
| 390 × 844 | PASS después del fix | [phone-390x844.png](screenshots/ux01-responsive/phone-390x844.png) |
| 412 × 915 | PASS después del fix | [phone-412x915.png](screenshots/ux01-responsive/phone-412x915.png) |
| 768 × 1024 | PASS visual | [tablet-768x1024.png](screenshots/ux01-responsive/tablet-768x1024.png) |
| 1440 × 900 | PASS visual | [desktop-1440x900.png](screenshots/ux01-responsive/desktop-1440x900.png) |

Las capturas fueron generadas con Google Chrome headless contra `http://127.0.0.1:3917/`. Esto demuestra layout y visibilidad del control; no equivale a probar un teclado virtual físico ni un dispositivo real.

## Estados observados sin credenciales

La portada mostró correctamente:

- Google: `No configurado`, con explicación del cliente OAuth faltante.
- Asistente: `Requiere configuración`, con `GEMINI_API_KEY` explícito.
- Memoria: `Local`, con cero recuerdos.
- Equipo local: `Estado no verificado`, sin inventar una señal de host.
- Actividad vacía: mensaje de ausencia de actividad.
- Regla de seguridad visible: `proponer → confirmar → ejecutar`.

Las conexiones reales de Google/Gemini y las escrituras no se declararon verificadas porque no se utilizaron credenciales reales.

## Verificación técnica

- `npm run typecheck`: PASS.
- `npm test`: 12/12 PASS.
- `npm run build`: PASS.
- `npm run test:bridge`: 78/78 PASS en la ejecución posterior al merge.
- `node --test Bridge/test/notify.test.mjs`: 5/5 ejecuciones PASS.
- `git diff --check`: PASS antes de publicar el follow-up.

El `ECONNRESET` observado en una corrida anterior de `notify.test.mjs` no se reprodujo en cinco ejecuciones directas ni en la suite completa. Se conserva como riesgo de flakiness no reproducible, no como fallo corregido.

## Limitaciones restantes

No hay emulador Android ni dispositivo conectado por `adb`; tampoco hay Xcode/macOS. La interacción con teclado, focus trap, Escape y retorno de foco queda sustentada por inspección estática del modal y typecheck, pero no por una sesión interactiva de lector de pantalla o dispositivo físico. La navegación móvil visual sí quedó demostrada en Chrome headless.

Clasificación: responsive visual `DEMONSTRATED`; estados sin credenciales `DEMONSTRATED`; integraciones reales Google/Gemini `NOT_DEMONSTRATED`; teclado virtual, lector de pantalla y Android/iOS nativos `NOT_DEMONSTRATED`.
