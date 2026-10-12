# Setup guide

Host-side setup that Paddock cannot ship in the image, because the sandbox home
(`~/.local/share/paddock/home` on the host, `/home/ai` in the sandbox) is a bind mount
that masks anything baked into it.

## Serving opencode to the host

opencode 2 runs one shared background service per user, started on demand by the first
`opencode` in the sandbox. It listens on `127.0.0.1` and a channel-specific port (49374 for
release builds) by default, which the published port cannot reach. Set both from inside the
sandbox; the values are stored in `~/.config/opencode/service.json`, which on the host is
`~/.local/share/paddock/home/.config/opencode/service.json`:

```bash
opencode service set hostname ::
opencode service set port 4096
opencode service start
```

Changing a setting stops the service, so run `opencode service start` afterwards. Use `::`, not
`0.0.0.0`: `0.0.0.0` listens on IPv4 only, so a client reaching a `-P` published port over IPv6
(for example through a hostname that resolves to an IPv6 address) gets its connection reset. `::`
accepts both. Add a browser origin with `opencode service set cors <origin>` if a client needs it.

Then launch the sandbox with the port published and connect a client from the host:

```bash
./paddock.sh run -p
opencode --server http://127.0.0.1:4096
```

The service is password-protected. The generated password is the `password` field of
`service.json`; `opencode service set password <secret>` replaces it.

To skip the shared service, run a foreground server instead. It takes its own flags, ignores
`service.json`, defaults to `127.0.0.1`, and prints a password at startup:

```bash
./paddock.sh run -p opencode serve --hostname :: --port 4096
```

The distro `opencode` package is built without the browser UI, so `http://127.0.0.1:4096/`
answers 404. Connect with `opencode --server`, or use the OpenCode desktop app.

## Plugins

The distro package disables runtime npm installs, so plugins listed under `plugins` in
`opencode.jsonc` fail to load (`npm install disabled by distribution policy`). To allow them:

```bash
opencode service set env OPENCODE_ALLOW_NPM_INSTALL 1
opencode service start
```

This lets opencode fetch packages from the network at runtime inside the sandbox.
