# Auditoría UI/UX — ISyCode Móvil

**Fecha:** 2026-11-15  
**Alcance:** superficie web React/TypeScript, experiencia nativa Android Compose e iOS SwiftUI, consistencia visual, flujos de asistente, estados, accesibilidad y claridad de autoridad local.  
**Método:** lectura de componentes y contratos existentes, inspección estática de estados/interacciones, revisión de tokens y ejecución de checks disponibles. No se hizo click-through visual en un emulador/dispositivo porque no hay Preview/browser local disponible en esta sesión.

## Resumen ejecutivo

ISyCode Móvil tiene una base de producto sólida: el flujo de seguridad “el asistente propone, la persona confirma, el host ejecuta” está expresado en la UI y respaldado por contratos/test del bridge. La experiencia nativa Android/iOS es la superficie más coherente para una persona no técnica: saludo, estado de Google/PC/memoria, prompt y acciones rápidas aparecen en el mismo recorrido.

La principal deuda UX está en la **divergencia entre superficies**. La web se siente como un panel técnico de administración: navegación superior con etiquetas largas, una columna de acciones rápidas deshabilitadas, herramientas expuestas como formularios y JSON, y una bitácora escondida detrás de modo desarrollador. La app nativa, en cambio, comunica “asistente personal” y tiene mejor jerarquía de inicio. El siguiente paso no debería ser añadir más funciones, sino llevar la claridad de la experiencia nativa a la web y alinear tokens, estados y vocabulario entre plataformas.

**Evaluación heurística orientativa:**

| Área | Nivel | Lectura |
|---|---:|---|
| Claridad del propósito | 7/10 | Muy buena en nativo; correcta pero técnica en web. |
| Flujo principal | 7/10 | Prompt y quick actions están disponibles; falta una ruta web más guiada. |
| Confianza/autoridad | 8/10 | Confirmación explícita y separación lectura/escritura bien planteadas. |
| Consistencia cross-platform | 4/10 | Verde/violeta/coral nativo vs azul Tailwind en web. |
| Estados y recuperación | 6/10 | Hay errores, vacíos y reintentos; faltan checking/demo/contexto global. |
| Accesibilidad | 6/10 | Buen uso parcial de labels/roles; foco, modal y estados requieren endurecimiento. |
| Densidad y lenguaje para no técnicos | 5/10 | Web expone demasiada implementación demasiado pronto. |

## Hallazgos prioritarios

### P0 — Alinear el modelo mental de web y nativo

**Problema:** la web abre con `Asistente`, pero la navegación visible es “Asistente / Memoria & Contexto / Mis Apps de Google / Opciones”, y al activar developer mode cambia etiquetas a “Árbol de contexto” y “Herramientas de Google”. El nativo ofrece una portada más humana con saludo, estado y avisos. Esto hace que dos usuarios de ISyCode perciban productos distintos.

**Evidencia:** `web/src/App.tsx:16-22,102-140`; `Sources/Assistant/AssistantViews.swift:29-77,233-315`; `android/.../AssistantScreens.kt:301-371`.

**Recomendación:** convertir la web en una portada tipo “Resumen” con tres zonas: “Qué puedo hacer”, “Estado de tus conexiones” y “Actividad reciente”. Mantener “Memoria”, “Google”, “Actividad” y “Opciones” como destinos secundarios. El developer mode debe cambiar el nivel de detalle, no el nombre del producto ni la arquitectura mental.

**Criterio de aceptación:** una persona nueva puede responder “¿qué puedo hacer?”, “¿está conectado?” y “¿qué va a cambiar?” sin entrar a Opciones ni leer documentación.

### P0 — Unificar el sistema visual y semántico

**Problema:** la web usa `slate + blue` (`web/src/components/ui.tsx:3-23`), mientras Android/iOS usan tokens verdes/violeta/coral (`AssistantScreens.kt:308-318`; `DesignSystem.swift:50-123,157-213`). Además, la web no declara un token raíz `data-design-system` y `index.css` solo contiene tipografía base.

**Impacto:** se pierde reconocimiento de marca y se vuelve ambiguo si azul, verde o violeta significa acción segura, conexión o selección.

**Recomendación:** definir tokens compartidos para background, surface, border, accent, info, warning, danger y text. Aplicarlos en web y documentarlos junto a los tokens nativos. Elegir una semántica estable: por ejemplo, accent para acción/selección; verde solo para evidencia de éxito/conexión; ámbar para demo/checking/confirmación; rojo para error/denegación.

**Criterio de aceptación:** la misma acción y estado tienen el mismo color, nombre y iconografía en web, Android e iOS; ningún estado de conexión depende únicamente de un punto de color.

### P1 — Hacer visibles los estados de conexión y autoridad

**Problema:** la portada web comunica “conectado con Google y tu memoria” (`App.tsx:121-125`) antes de mostrar si Google está conectado, si Gemini está configurado o si la sesión es solo lectura. En `AssistantPanel.tsx:87-105`, las acciones rápidas pueden aparecer deshabilitadas con opacidad, pero la explicación queda debajo en un aviso separado.

**Riesgo:** una persona puede interpretar que una acción está rota en lugar de entender qué falta.

**Recomendación:** añadir una barra de estado persistente debajo del encabezado: `Google: sin conectar / lectura / escritura`, `Asistente: disponible / falta clave`, `Memoria: local`, `Host: estado no verificado / conectado`. Para cada quick action bloqueada, mostrar una causa contextual y CTA (“Conectar Google”, “Configurar asistente”), no solo `disabled`.

**Importante:** no mostrar “activo”, “verificado” o un punto verde sin evidencia derivada del contrato real.

### P1 — Mejorar la confirmación de acciones de escritura

**Fortaleza actual:** la web centraliza la confirmación en `ConfirmModal.tsx`; Android/iOS también usan diálogo/sheet y distinguen acciones pendientes. Esto preserva bien la autoridad local.

**Problemas:** el modal web no implementa focus trap, no mueve el foco al título o al primer control al abrir, y no devuelve explícitamente el foco al disparador al cerrar (`ConfirmModal.tsx:22-28,45-77`). El botón de confirmación dice “Confirmar y ejecutar”, pero no siempre verbaliza el efecto humano; los detalles se muestran como valores técnicos.

**Recomendación:**

1. Mover foco al título o botón Cancelar al abrir.
2. Capturar Tab dentro del diálogo y devolver foco al disparador al cerrar.
3. Cambiar el encabezado a una acción humana: “Enviar correo a…”, “Crear evento…”, “Guardar recuerdo…”.
4. Mostrar un resumen legible antes del bloque técnico expandible.
5. Conservar `PROPOSED → AUTHORIZED → EXECUTED → VERIFIED/DENIED` como estados textuales cuando existan en el contrato.

### P1 — Reducir la exposición prematura de herramientas técnicas

**Problema:** `WorkspacePanel.tsx:107-121` presenta todos los grupos de tools como formularios, con nombres de servicio, esquemas y ejecución directa. Es útil para desarrollo, pero no es la mejor experiencia por defecto para una persona que solo quiere pedir algo al asistente.

**Recomendación:** esconder el catálogo de tools detrás de “Herramientas avanzadas” o developer mode. En la vista normal, agrupar por intención (“Leer”, “Organizar”, “Crear o enviar”) y dejar que el asistente genere la propuesta. Mostrar scopes, IDs y JSON solo en un disclosure técnico.

### P1 — Mejorar móvil web y navegación larga

**Problema:** el header web usa navegación horizontal y un bloque de login (`App.tsx:104-117`); en pantallas pequeñas puede competir por ancho con el nombre de marca y ocultar destinos. El contenido mantiene grids y formularios con tres campos en línea en memoria (`ContextPanel.tsx:163-167`), lo que puede producir inputs estrechos.

**Recomendación:** usar bottom navigation o segmented control compacto en móvil; mantener siempre visible el resumen, el estado y el prompt. Apilar los tres niveles de carpeta en móvil. Verificar especialmente que el modal fijo no cubra acciones y que el teclado no tape el composer.

### P2 — Accesibilidad y robustez de interacción

**Observaciones:**

- Hay buen uso de `aria-label`, `aria-expanded`, `aria-current`, `role="dialog"` y `role="alert"` en varios componentes.
- `ConfirmModal` necesita `aria-describedby`, gestión de foco y cierre por backdrop opcional con cuidado.
- `ContextPanel` oculta borrar con `opacity-0` hasta hover (`ContextPanel.tsx:33-37`); aunque incluye `focus:opacity-100`, conviene que la acción sea visible siempre en touch y no dependa de hover.
- No se detectó una regla `prefers-reduced-motion` en `web/src/index.css`; la app sí usa transiciones en header/cards y el nativo anima banners.
- Los estados de actividad usan texto (`ok/error/pending`), lo cual es positivo, pero deberían acompañarse con iconos o badges semánticos consistentes y labels traducidos (“Correcto”, “Error”, “Pendiente”) en vez de exponer el enum técnico.
- `AssistantPanel.tsx:155` muestra `JSON.stringify(action.args)` truncado para la persona; debe existir una vista humana y un disclosure “Ver datos técnicos”.
- Los enlaces de respuesta usan emojis de pin/enlace (`AssistantPanel.tsx:163-167`), una señal visual poco consistente con el resto del sistema.

### P2 — Diseñar estados completos, no solo estados felices

Debe haber estados explícitos y probables en la portada:

- **Checking:** comprobando conexión al host/Google/Gemini.
- **Live:** derivado de una respuesta real del contrato.
- **Demo o no conectado:** rotulado de forma persistente; nunca presentarlo como actividad real.
- **Empty:** sin memoria, sin actividad, sin herramientas disponibles.
- **Error:** qué pasó, qué no pasó y cómo recuperar.
- **Recovery:** reintentar, cambiar cuenta, abrir opciones o continuar en modo local.

La web tiene vacíos y errores puntuales, pero el estado global se reduce con frecuencia a ausencia de datos (`status` undefined) o avisos dispersos. Android/iOS tienen una mejor portada para expresar estado, pero también usan chips de color (`StatusChip`) que deben acompañarse con texto y evidencia.

### P2 — Evitar promesas ambiguas en copy

La frase web “Tu asistente conectado con Google y tu memoria” es demasiado afirmativa para el primer render (`App.tsx:122`). La frase nativa “lo que pasa en tu PC” también puede sugerir vigilancia continua aunque el estado del monitor no esté conectado (`AssistantViews.swift:299-304`).

Propuesta de copy inicial:

> “Tu asistente local para Google, memoria y tareas de tu equipo.”  
> “Nada se envía ni cambia sin tu confirmación. Revisa el estado de cada conexión abajo.”

## Lo que está bien y conviene preservar

1. **Autoridad local clara:** todas las acciones de escritura pasan por confirmación; los tests del bridge verifican que no se ejecuten sin `confirmed: true`.
2. **Separación lectura/escritura:** `WorkspacePanel` distingue sesión de solo lectura y scopes de escritura.
3. **Memoria local explícita:** la web explica que se guarda en la computadora y la bitácora indica que no guarda contenido de correos/documentos.
4. **Acciones rápidas orientadas a tareas:** correo, agenda, pendientes, documentos, mapas y búsqueda son mejores que una lista de capacidades abstractas.
5. **Paridad conceptual nativo:** Android e iOS comparten estructura de Home, Memory, Google, Log y Options; esa base debe convertirse en el contrato UX cross-platform.
6. **Manejo de vacíos y errores:** existen `Notice`, estados vacíos, retry de actividad y confirmación de borrado/importación.

## Recomendación de arquitectura UX

### Nivel 1: Resumen

- Saludo y propósito.
- Estado real de Google, asistente, memoria y host.
- Prompt principal.
- 4–6 acciones rápidas habilitadas o explicadas.
- Últimos avisos.

### Nivel 2: Trabajo

- Memoria/contexto.
- Google y tareas conectadas.
- Actividad/recibos.

### Nivel 3: Configuración y diagnóstico

- Opciones.
- Herramientas/raw payloads/scopes.
- Modo desarrollador.

Esto conserva el poder actual sin exponer implementación antes de que sea necesaria.

## Roadmap recomendado

### Sprint 1 — Claridad y confianza

- Alinear copy de portada.
- Crear `ConnectionStatusBar` compartida en web.
- Convertir quick actions bloqueadas en estados explicativos con CTA.
- Mejorar `ConfirmModal` con foco, resumen humano y estado de ejecución.
- Traducir estados técnicos visibles en actividad.

### Sprint 2 — Sistema visual cross-platform

- Definir tokens web equivalentes a `OCColor`/`IysTheme`.
- Aplicar accent/semantic colors consistentemente.
- Añadir `data-design-system` a la raíz.
- Incorporar `prefers-reduced-motion`, focus ring y tamaños mínimos táctiles.

### Sprint 3 — Mobile-first y simplificación

- Rediseñar header web para viewport pequeño.
- Apilar formulario de memoria en móvil.
- Ocultar catálogo de tools detrás de “Avanzado”.
- Añadir disclosure técnico para JSON, scopes e IDs.

### Sprint 4 — Validación real

- Instalar dependencias web y ejecutar typecheck, tests y build.
- Levantar la web local y probar click-through de: primer uso, conectar Google, quick action bloqueada, respuesta con propuesta, confirmar, error y retry.
- Validar teclado/foco, VoiceOver/TalkBack, contraste, reduced motion y viewport móvil.
- Capturar screenshots de Android, iOS y web para comparación de tokens y estados.

## Línea base técnica verificada

- **Bridge:** 78/78 pruebas pasan (`npm run test:bridge`).
- **Web:** no verificable en esta sesión porque faltan dependencias instaladas en `web/node_modules`; `npm run typecheck` falla con `tsc: not found`, `npm test` con `Cannot find package 'tsx'`, y `npm run build` con `vite: not found`.
- **Git:** último commit inspeccionado `382de02 docs: refresh README screenshots from CI`.
- **Cambios realizados por esta auditoría:** ninguno en código o configuración. Se añadió únicamente este informe.
- **NO VERIFIED:** no se hizo validación visual mediante Preview/emulador ni click-through en dispositivo; los hallazgos de responsive y accesibilidad visual deben confirmarse en ejecución.

## Checklist para la siguiente iteración

- [ ] Portada web responde qué hace, qué está conectado y qué requiere confirmación.
- [ ] Todos los estados de conexión tienen texto + icono + evidencia.
- [ ] La confirmación tiene resumen humano, foco gestionado y retorno de foco.
- [ ] Web, Android e iOS comparten tokens y vocabulario.
- [ ] Tools/raw JSON/scopes quedan fuera del camino principal.
- [ ] Móvil no depende de hover y no estrecha campos críticos.
- [ ] `prefers-reduced-motion`, contraste y teclado verificados.
- [ ] Estados checking/live/demo/empty/error/recovery probados.
- [ ] Typecheck, tests, build y click-through documentados.
