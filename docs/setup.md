# Setup guide

Host-side setup that Paddock cannot ship in the image, because the sandbox home
(`~/.local/share/paddock/home` on the host, `/home/ai` in the sandbox) is a bind mount
that masks anything baked into it.

## Serving opencode to the host

`opencode serve` listens on `127.0.0.1` inside the sandbox by default, which the published
port cannot reach. Either pass `--hostname 0.0.0.0` on every launch:

```bash
./paddock.sh run -p opencode serve --hostname 0.0.0.0
```

or set it once in opencode's global config, the only place `serve`/`web` read network
defaults from (not `OPENCODE_CONFIG`, project configs or `/etc/opencode`).
Create `~/.local/share/paddock/home/.config/opencode/opencode.json` on the host:

```json
{
  "$schema": "https://opencode.ai/config.json",
  "server": {
    "hostname": "0.0.0.0",
    "port": 4096
  }
}
```

Then:

```bash
./paddock.sh run -p opencode serve
```

Open `http://127.0.0.1:4096` on the host. `-p` binds the host side to loopback only, and the
opencode server has no authentication unless `OPENCODE_SERVER_PASSWORD` is exported from a
login file in the sandbox home.

An explicit `--hostname`/`--port` on the command line overrides the config. The config
applies to `opencode serve` and `opencode web` only; the TUI is unaffected.
