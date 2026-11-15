# Plan UX-01 — Alineación premium y accesible de ISyCode Móvil

## Objetivo

Convertir la superficie web en un resumen claro para personas no técnicas, alinear su sistema visual con Android/iOS, hacer visibles los estados reales de conexión y endurecer el flujo de confirmación accesible, sin alterar los contratos del bridge ni conceder permisos nuevos.

## Alcance y estructura

- `web/src/App.tsx`: shell, navegación y resumen principal.
- `web/src/components/`: barra de estado, resumen, quick actions, actividad, contexto, Google, opciones y confirmación.
- `web/src/components/ui.tsx` y `web/src/index.css`: tokens, estados semánticos, foco y reduced motion.
- `web/src/lib/api.ts`: reutilizar `PanelStatus`; no inventar estados backend.
- `web/public/manus-routes.json`: declarar la ruta real `/` antes de levantar Preview.
- Tests web: cubrir helpers puros y contratos accesibles que sean verificables sin añadir un runner visual.

## Diseño

**Dirección elegida:** control room humano y local-first. Tres características: calma visual, evidencia explícita y progresión de resumen a detalle. La portada usa superficies elevadas oscuras/claras, un accent consistente y colores semánticos solo como acompañamiento de texto/iconos. El copy evita afirmar conexión o actividad sin evidencia. La web conserva el prompt como acción primaria y reubica raw tools/JSON en capas avanzadas existentes.

**Tokens:** background, surface, surface-elevated, border, text-primary, text-secondary, text-muted, accent, accent-contrast, information, success, warning y danger. La raíz tendrá `data-design-system="isycode-local-first"`.

**Interacción:** el asistente propone; la persona revisa y confirma; el host ejecuta. El modal gestionará foco inicial, Tab, Escape, devolución de foco y errores sin cerrar prematuramente. Los detalles técnicos serán expandibles.

## Implementación

1. Añadir tokens y utilidades semánticas en web.
2. Añadir `ConnectionStatusBar` con estados derivados exclusivamente de `PanelStatus` y estado de carga/error de la API.
3. Añadir `SummaryPanel` en la portada con propósito, capacidades, confirmación y actividad reciente.
4. Mantener navegación existente, renombrar la primera sección a `Resumen` y evitar que developer mode cambie el modelo mental; conservar labels técnicos dentro de vistas avanzadas.
5. Mejorar quick actions bloqueadas con causa y CTA real (`Opciones` o login Google).
6. Apilar el formulario de memoria en viewport estrecho y eliminar dependencia de hover para acciones importantes.
7. Mejorar ConfirmModal con foco, resumen humano, disclosure de detalles, estados y protección de doble submit.
8. Añadir `prefers-reduced-motion`, focus rings y labels humanos para estados.
9. Instalar dependencias desde `web/package-lock.json`, ejecutar typecheck/tests/build y levantar servidor local para verificar HTTP y `manus-routes.json`.
10. Ejecutar bridge tests, revisar diff/secretos y publicar una rama con PR hacia la rama principal, sin merge automático.

## Restricciones

No crear endpoints nuevos, no simular live/demo/verified, no eliminar tools, no automatizar escrituras, no modificar contratos de autoridad ni tocar cambios ajenos no relacionados.
