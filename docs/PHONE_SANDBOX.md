# El sandbox del iPhone: clonar y trabajar con cualquier modelo

En el iPhone no hace falta una máquina virtual para aislar al agente: iOS ya impide que
la app salga de su contenedor. Lo que faltaba era otra cosa: que el sandbox pudiera
traer código, y que un modelo pequeño supiera usarlo. Esta guía cubre las dos.

## Clonar sin git

iOS no permite ejecutar `git`. La app descarga el archivo `.tar.gz` que GitHub publica
para cada repositorio y lo descomprime en `repos/<dueño>-<nombre>/` dentro del espacio
de trabajo.

- Desde **Ajustes → Repositorios en este iPhone**, o pidiéndoselo al agente (`clone`).
- Acepta `dueño/nombre`, `dueño/nombre@rama` y enlaces de github.com.
- Solo repositorios **públicos**, y sin historial: es una copia para leer y editar.
- No sobrescribe: si el clon ya existe, se niega. Bórralo o ciérralo antes.
- Se omiten los enlaces simbólicos, los archivos de más de 5 MB y cualquier ruta que
  intente salir de la carpeta. Límites: 40 MB de descarga, 200 MB descomprimido,
  8 000 entradas.
- GitHub limita las descargas sin cuenta (unas 60 por hora por red).

Publicar los cambios desde el iPhone todavía no existe. Para abrir un pull request usa
el [sandbox Docker de la computadora](SANDBOX.md).

## Proyecto activo: sin aprobaciones, con deshacer

El último repositorio clonado es el **proyecto activo**. Mientras lo sea, y con un modelo
local:

- las rutas de las herramientas son relativas a esa carpeta y no pueden salir de ella;
- `edit` y `write` se aplican **sin pedir aprobación**, porque es una copia desechable;
- cada cambio guarda antes el contenido anterior, y `undo` (o **Deshacer el último
  cambio** en Ajustes) lo restaura. Se recuerdan los últimos 50 cambios de la sesión;
  al cerrar la app el historial de deshacer se pierde.

Sin proyecto activo nada cambia respecto a antes: el agente trabaja en el espacio
privado de la app o en la carpeta que elegiste en Archivos, y **cada cambio pide
aprobación**. **Cerrar el proyecto** vuelve a ese modo sin borrar los archivos.

## Siete herramientas en vez de catorce

Un modelo de 0.5B se pierde con catorce herramientas de hasta cuatro argumentos. Los
modelos locales reciben estas siete, con argumentos de texto planos:

| Herramienta | Argumentos | Qué hace |
| --- | --- | --- |
| `clone` | `repo` | Descarga un repositorio y lo deja como proyecto activo |
| `list` | `path?` | Lista una carpeta |
| `read` | `path`, `from_line?` | Lee 80 líneas numeradas y dice cómo seguir |
| `find` | `text` | Busca en todos los archivos: `archivo:línea: texto` |
| `edit` | `path`, `old_text`, `new_text` | Reemplaza un fragmento |
| `write` | `path`, `content` | Crea o reemplaza un archivo |
| `undo` | — | Deshace el último `edit` o `write` |

`edit` es tolerante con lo que más fallan los modelos pequeños. Si el texto no coincide
exactamente, compara línea a línea ignorando espacios al principio y al final, y ajusta
la sangría del reemplazo a la de la línea que sustituye. Exige que la coincidencia sea
única; si no lo es, o no existe, el error dice qué hacer (añadir contexto, o en qué
línea hay algo parecido).

Los modelos en la nube conservan el catálogo completo de catorce herramientas, con
aprobación en cada cambio, y además reciben `clone`.

## Gramática: una llamada mal formada no se puede escribir

El modelo local responde con texto normal o con una etiqueta:

```
<GUS_TOOL_CALL>{"name":"read","arguments":{"path":"README.md"}}</GUS_TOOL_CALL>
```

Antes, que eso saliera bien dependía del modelo. Ahora la app genera en cada turno una
gramática (GBNF de llama.cpp) con las herramientas disponibles, y el muestreador descarta
cualquier token que la rompa. En cuanto el modelo empieza una llamada, solo puede:

- nombrar una herramienta que existe en ese turno;
- escribir sus argumentos obligatorios, en orden, con el tipo correcto;
- añadir solo argumentos opcionales que existen;
- cerrar la etiqueta y terminar.

Lo que la gramática **no** hace: decidir bien. El modelo puede seguir eligiendo la
herramienta equivocada, o una ruta que no existe; para eso están los mensajes de error.
Y si la respuesta se corta por el límite de 512 tokens a mitad de una llamada, no se
ejecuta.

### Cómo se comprueba

- `scripts/gus_catalog/tool_grammar.gbnf` es la gramática de las siete herramientas, y
  una prueba de Swift exige que el generador produzca exactamente ese texto.
- En CI, el arnés del puente real (`bridge_smoke grammar`) carga cada tokenizador de
  llama.cpp y comprueba los casos de `tool_grammar_cases.txt`: las llamadas válidas se
  aceptan completas y las inválidas (herramienta inexistente, argumento de más, tipo
  equivocado, texto después de la etiqueta) son imposibles de emitir.
- `bridge_smoke constrained <modelo> <gramática> <prompt>` genera con un modelo real
  bajo la gramática y dice si la salida es una frase completa de ella.
