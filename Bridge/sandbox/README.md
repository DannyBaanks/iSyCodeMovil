# Sandbox orchestrator (from MovilClaw)

`server/` and `web/seal.mjs` are copied from
[DannyBaanks/MovilClaw](https://github.com/DannyBaanks/MovilClaw) at commit `45e5f39`
(MIT, same author). They are vendored so that the published one-liner
`npx --yes github:DannyBaanks/iSyCodeMovil#main link --runtime sandbox` works without a
second install, and the Bridge keeps having zero npm dependencies.

Local changes to the copy, so a future sync knows what to keep:

- `server/api.mjs`: `MAX_BODY_BYTES` raised from 16 KiB to 2 MiB. An agent `write` tool
  call carries a whole source file in its JSON body.

Everything specific to iSyCode Móvil lives outside this folder, in
`Bridge/bin/sandbox_bridge.mjs`: the bearer token, the Tailscale-only listener, pinning
the `folder` routes to the linked project, and GitHub token discovery.

The upstream PWA (`web/index.html`) is not copied: the iPhone app is the client here.
