# Sandbox en tu computadora

El agente de iSyCode Móvil piensa en el iPhone y trabaja en un contenedor Docker de tu
computadora. El contenedor no tiene red, no ve tu disco y no guarda credenciales. Cuando
el trabajo está listo, tu computadora lo empuja a una rama `movilclaw/<tarea>` y abre el
pull request con su propia cuenta de GitHub.

El orquestador viene de [MovilClaw](https://github.com/DannyBaanks/MovilClaw) y vive en
`Bridge/sandbox/`.

```
iPhone                                Tu computadora
──────                                ──────────────
modelo + conversación  ── Tailscale ─►  Bridge (token) ─► sandbox Docker
(GUS o tu proveedor)                    │                 sin red · sin disco · sin credenciales
                                        └─ git push + PR con tu cuenta de GitHub
```

## Arrancar

Necesitas Docker, Node 18 o posterior y Tailscale en la computadora y en el iPhone.

En la carpeta del proyecto:

```bash
npx --yes github:DannyBaanks/iSyCodeMovil#main link --runtime sandbox --host tailscale
```

La primera vez construye la imagen `movilclaw/sandbox`. Después imprime una línea
`isysandbox://pair?...`: pégala en el iPhone, en **Más opciones de conexión**. No la
reenvíes: lleva el token que da acceso a los sandboxes de esa terminal.

En el iPhone hace falta un modelo configurado (**Probar en este iPhone** → proveedor y
clave, o GUS local). Los modelos locales pequeños rara vez manejan bien herramientas de
código; para trabajar en un repositorio conviene un proveedor en la nube.

## Qué hace la app al vincular

1. Comprueba el enlace con la computadora.
2. Si hay un sandbox vivo de esa terminal, lo retoma. Si no, crea uno (caduca tras 2 h
   sin uso) y copia dentro la carpeta desde la que ejecutaste el comando.
3. Arranca el agente del iPhone con las herramientas del sandbox.

La barra **Sandbox** sobre el chat abre el panel con el estado, el pull request, las
opciones para compartir y las de reiniciar o desvincular.

## Herramientas del agente

| Herramienta | Qué hace | Pide aprobación |
| --- | --- | --- |
| `read_file`, `list_directory`, `search_text` | Leer y buscar | No |
| `write_file`, `edit_file` | Crear y editar archivos | No |
| `run_command` | Ejecutar un comando en la raíz del proyecto | No |
| `git`, `commit` | Estado, diferencias, historial y commit dentro del sandbox | No |
| `open_pull_request` | La computadora empuja la rama y abre el PR | Sí, cada vez |

Editar y ejecutar no piden aprobación porque nada sale del contenedor. Publicar sí.
`open_pull_request` solo aparece si la computadora tiene una cuenta de GitHub y la
carpeta tiene un remoto de github.com.

## GitHub

Al arrancar, el Bridge busca un token en `GITHUB_TOKEN`, `GH_TOKEN` o `gh auth token`.
Se queda en la memoria de ese proceso: no entra al sandbox y no viaja al iPhone. Para no
usar ninguno:

```bash
ISYCODE_SANDBOX_NO_GITHUB=1 npx --yes github:DannyBaanks/iSyCodeMovil#main link --runtime sandbox --host tailscale
```

El pull request sale siempre de una rama `movilclaw/<tarea>-<fecha>`. No se empuja a
`main`, `master`, `trunk` ni `develop`, no se fuerza un push y no se fusiona.

## Compartir

- **La conversación**: se comparte como texto Markdown desde el panel.
- **El trabajo**: el panel descarga la carpeta del sandbox como `.tar.gz` y la pasa a la
  hoja de compartir.

Sellar el trabajo con una frase y reinyectarlo en otro sandbox (lo que MovilClaw hace
desde su PWA) todavía no está en la app.

## Qué se garantiza y qué no

- El API es HTTP con un token en cada petición. Solo escucha en la IP de Tailscale o en
  loopback; el comando se niega a arrancar en otra red.
- Las rutas que copian una carpeta están fijadas a la carpeta del comando. El iPhone no
  puede pedir otra.
- Los archivos que parecen secretos (`.env`, claves, `*.keystore`…) no se copian. Dentro
  del sandbox quedan marcados para que los commits del agente no los borren.
- Si el remoto de la carpeta lleva un token en la URL, se elimina dentro del sandbox.
- `Ctrl+C` detiene el enlace y destruye sus sandboxes.
- El contenido que el agente lee del sandbox se envía al proveedor del modelo que hayas
  elegido en el iPhone, igual que en cualquier otra sesión.
- Con el sandbox encendido, quien administra la computadora puede ver su contenido. El
  aislamiento protege a la computadora del agente, no al revés.

## Limitaciones conocidas

- El sandbox no tiene red: no se pueden instalar dependencias desde dentro.
- La vista **Cambios** no muestra el diff del sandbox; pídele al agente `git diff` o
  usa la terminal.
- Las conversaciones se guardan en el iPhone y son las mismas con o sin sandbox.
- Al reabrir la app hay que volver a pegar el enlace.
