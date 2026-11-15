# TODO — UX-01 Implementación UI/UX

## P0 — Portada web orientada a personas

- [ ] Implementar una portada principal tipo Resumen que permita comprender, sin abrir Opciones, qué puede hacer el asistente, qué servicios están conectados realmente, qué funciones requieren configuración, qué operaciones necesitan confirmación humana y qué actividad reciente existe.
- [ ] Conservar el prompt principal, la navegación a funciones existentes y las acciones rápidas útiles.
- [ ] Adoptar la estructura Resumen → Trabajo → Configuración y diagnóstico.
- [ ] Hacer que el modo desarrollador revele información adicional sin alterar arbitrariamente los nombres o el modelo mental del producto.
- [ ] No eliminar capacidades técnicas existentes: reubicarlas en vistas avanzadas.

## P0 — Sistema visual consistente

- [ ] Definir y documentar tokens para fondo, superficies, bordes, texto, acento/selección, información, éxito/conexión verificada, advertencia/comprobación/confirmación pendiente y error/denegación.
- [ ] Agregar `data-design-system` a la raíz web si encaja con la arquitectura.
- [ ] No usar el color como única señal de estado.
- [ ] No inventar estados únicamente para que la UI resulte atractiva.

## P1 — Estados reales de conexiones y capacidades

- [ ] Implementar una barra reutilizable que consulte las fuentes reales del proyecto.
- [ ] Distinguir Google sin conectar / solo lectura / escritura habilitada.
- [ ] Distinguir asistente disponible / requiere configuración.
- [ ] Distinguir memoria local / no disponible.
- [ ] Distinguir host comprobando / conectado / desconectado / desconocido, o mostrar “Estado no verificado” si el contrato no permite comprobarlo.
- [ ] Para acciones rápidas deshabilitadas, explicar por qué y ofrecer una acción contextual existente.

## P1 — Confirmación accesible y autoridad preservada

- [ ] Implementar foco inicial correcto, contención de foco mediante teclado y retorno del foco al elemento disparador.
- [ ] Añadir `aria-describedby` y nombres accesibles apropiados.
- [ ] Mostrar resumen legible del efecto de la operación y detalles técnicos expandibles.
- [ ] Hacer comprensibles los estados de ejecución y error.
- [ ] Proteger contra confirmaciones duplicadas.
- [ ] Presentar exactamente la operación autorizada.
- [ ] Conservar la invariante: el asistente propone → la persona confirma → el host ejecuta.
- [ ] Conservar y ampliar pruebas de seguridad donde corresponda.

## P1/P2 — Usabilidad móvil y accesibilidad

- [ ] Adaptar navegación a pantallas estrechas.
- [ ] Apilar formularios de memoria en móvil.
- [ ] Mantener campos y botones con tamaño táctil adecuado.
- [ ] Hacer visibles las acciones importantes sin depender de hover.
- [ ] Evitar que el teclado esconda el prompt.
- [ ] Añadir focus rings visibles.
- [ ] Respetar `prefers-reduced-motion`.
- [ ] Usar etiquetas humanas para estados.
- [ ] Mantener JSON, scopes e IDs técnicos como divulgación avanzada.

## Validación

- [ ] Ejecutar pruebas del bridge.
- [ ] Ejecutar typecheck web.
- [ ] Ejecutar tests web.
- [ ] Ejecutar build web.
- [ ] Añadir y ejecutar regresiones para componentes modificados cuando sea posible.
- [ ] Verificar estados de conexión y confirmación.
- [ ] Verificar teclado y accesibilidad básica.
- [ ] Si hay Preview/browser, hacer click-through de primer uso, conexión, acción bloqueada, propuesta, confirmación y recuperación.
- [ ] No declarar como ejecutadas pruebas que no se hayan ejecutado.

## Publicación

- [ ] Revisar diff completo y descartar credenciales, tokens, rutas privadas, temporales e información personal.
- [ ] Ejecutar controles Repo-Engine/hooks disponibles.
- [ ] Separar commits coherentes.
- [ ] Hacer push de la rama de trabajo al remoto correcto.
- [ ] Abrir PR hacia la rama principal sin hacer merge automático.
- [ ] Entregar repositorio, rama, SHA, URL del PR, archivos modificados, mejoras, pruebas, comparación antes/después, pendientes y evidencia `DEMONSTRATED`/`INFERRED`/`NOT_DEMONSTRATED`.
