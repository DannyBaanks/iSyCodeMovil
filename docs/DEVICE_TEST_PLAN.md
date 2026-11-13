# Prueba en dispositivo

Esta es la checklist para validar el Asistente, GUS y los avisos de la PC en un iPhone o Android real. El CI compila las dos apps y corre las pruebas, pero esto solo se puede comprobar en un teléfono. Toma unos 20 minutos.

Reporta el resultado con el formulario [Prueba en dispositivo](https://github.com/DannyBaanks/iSyCodeMovil/issues/new?template=device-test.yml).

## Antes de empezar

- **App instalada:** la última build ([Instalación](../README.md#instalación)).
- **ID de cliente de Google:** sigue [GOOGLE_ASSISTANT.md](GOOGLE_ASSISTANT.md#1-conectar-google-una-vez). Para una prueba basta con Gmail, Calendar y Tasks.
- **Node.js 18+ en la PC,** en la misma red Wi-Fi que el teléfono.
- **Opcional:** la app de [ntfy](https://ntfy.sh) en el teléfono.

## 1. Apariencia (2 min)

1. **Asistente › Opciones › Apariencia › Automático:** cambia el modo del sistema y vuelve a la app. Debe cambiar sola.
2. Prueba **Claro** y **Oscuro**: ningún texto debe quedar ilegible. Revisa Proyectos, una conversación y el Asistente.

## 2. Google (5 min)

1. **Opciones › Google:** pega el ID de cliente. Luego, en **Google**, toca **Iniciar sesión con Google**.
2. Al volver deben aparecer tu correo y los permisos que diste.
3. **Actualizar todo:** se ven correos, eventos y pendientes reales.
4. Crea un pendiente. Debe pedir confirmación; si cancelas, no se crea. Confirma y revisa que aparezca en Google Tasks.
5. Activa el modo desarrollador y abre **Registro**. Cada paso debe tener su entrada, y **Copiar** debe dar un JSON.

## 3. Memoria (5 min)

1. **Memoria › Guardar una nota:** escribe "Las juntas de equipo son de 45 minutos" y confirma. Debe quedar en *Google y vida diaria › Comunicación y agenda*.
2. Busca "jnta" (con el error a propósito): debe encontrarla. Al cerrar la búsqueda, el término queda en el historial.
3. En **Grafo**, arrastra un nodo y toca otro: debe abrirse su detalle. **Ocultar leyenda** y **Reorganizar** deben funcionar.
4. **Probar qué usaría GUS** con "¿cuánto duran las juntas?" debe elegir esa nota.

## 4. GUS con contexto (4 min)

1. Con un modelo local descargado, pregunta: "¿Cuánto duran mis juntas de equipo?". La respuesta debe usar la nota.
2. **Android:** pregunta "¿Qué pendientes tengo?". Debe aparecer "Consultando tu Google…", y la respuesta debe listar tus pendientes reales, con "usó googletasks.read.list" debajo.
3. **iPhone**, en una sesión con GUS: "Revisa mis correos". El agente debe usar `gmail.read.inbox`. Si le pides enviar uno, debe pedir aprobación.

## 5. Avisos de la PC (4 min)

En la PC:

```bash
npx --yes github:DannyBaanks/iSyCodeMovil#main tasks serve
```

1. Pega la dirección que imprime en **Opciones › Tu PC** y activa **Vigilar el manifiesto**. El estado debe decir "Conectado".
2. En otra terminal, ejecuta `npx --yes github:DannyBaanks/iSyCodeMovil#main notify "Prueba desde la PC"`. En 30 segundos debe llegar una notificación y aparecer en **Inicio › Avisos**.
3. Con ntfy: `notify "Prueba bloqueada" --ntfy <tu-tema>` con el teléfono bloqueado. Debe llegar el push de ntfy.
