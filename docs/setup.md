# Setup guide

Host-side setup that Paddock cannot ship in the image, because the sandbox home
(`~/.local/share/paddock/home` on the host, `/home/ai` in the sandbox) is a bind mount
that masks anything baked into it.

## Versioning the sandbox home

`./paddock.sh init` creates a bare git repository at `~/.local/share/paddock/home.git` whose work
tree is the sandbox home. The repository sits outside the home, so it survives
`rm -rf ~/.local/share/paddock/home`, and it is never mounted into the sandbox. Git always runs on
the host. It needs git 2.54 or newer. The settings live in the repository config, so plain
`git --git-dir=~/.local/share/paddock/home.git --work-tree=~/.local/share/paddock/home` works
the same as `./paddock.sh git`.

```bash
./paddock.sh init                       # new empty repository
./paddock.sh init git@host:me/home.git  # or clone an existing one
./paddock.sh git add .bashrc .config/opencode/agents
./paddock.sh git commit -m "Track shell and agents"
./paddock.sh git remote add origin git@host:me/home.git   # after a plain init
./paddock.sh git push -u origin HEAD
```

- Nothing is tracked until you `git add` it, and `status` hides untracked files. Avoid `git add .`:
  it would stage everything in the home, including `opencode.db` and any credentials.
- To start over, delete the home, run `./paddock.sh init` to recreate it, then
  `./paddock.sh git checkout -f`. That writes the tracked files into the home and overwrites files
  that exist, so use it on an empty home. After `init URL` on a host that already has a home, the
  files stay as they are and `git status` shows the differences.
- `./paddock.sh git` only runs git in the home. It creates nothing and changes no settings: `init`
  does that, and re-running `init` repairs the settings, for example after you move the checkout.
- Only clone a repository you trust. Restoring decrypts its encrypted files on the host, and sops
  contacts the key service named inside each file, with your credentials for it.
- Good candidates: `.bashrc`, `.config/opencode/{opencode.jsonc,agents,commands,skills}`,
  `.gemini/settings.json`, `.agents`. Keep `opencode.db`, history, caches, `.ssh` and `.gnupg` out.
- For per-host differences, track a `.bashrc` that sources an untracked `.bashrc.local`.
- Review `./paddock.sh git diff` before committing: the sandbox can edit every tracked file.
- Reuse someone else's ideas with `./paddock.sh git remote add them URL`, `fetch them`, then
  `checkout them/main -- .config/opencode/skills`.

### Encrypted secrets with sops

Files that hold secrets can be stored `sops`-encrypted: a git filter keeps them plaintext in the
home and encrypted in the repository. Nothing is encrypted by default; you choose the files. It
needs `sops` 3.9 or newer on the host and a key that sops can use, for example a gpg key. The key
stays on the host and is never visible to the sandbox. With gpg, gpg-agent must have the passphrase
cached, since git runs the filter without a terminal.

Two tracked files in the home control it: `.gitattributes` lists the files to encrypt and
`.sops.yaml` holds the encryption rules. `paddock.sh git` reads both from the last commit, not from
the home, so changes the sandbox makes to them take effect only once you commit them; review them
in `git diff` like any other change. Commit them before the secret: a pre-commit check refuses a
secret that is staged unencrypted.

For example, to track opencode's service password (`opencode service set` stores it in
`.config/opencode/service.json`):

```gitattributes
# .gitattributes
.config/opencode/service.json filter=sops diff=sops
```

```yaml
# .sops.yaml (replace the fingerprint)
creation_rules:
  - path_regex: service\.json$
    pgp: 0123456789ABCDEF0123456789ABCDEF01234567
    encrypted_regex: ^(password|env)$
```

```bash
./paddock.sh git add .gitattributes .sops.yaml
./paddock.sh git commit -m "Encrypt service.json"
./paddock.sh git add .config/opencode/service.json
./paddock.sh git commit -m "Track service.json"
```

`encrypted_regex` keeps the other keys readable in diffs, and `git diff` decrypts JSON files for
display. A new host needs only the key: `init URL` and `git checkout -f` bring the rules along.
List several recipients to keep a backup key: without a key the file cannot be restored. If
`git checkout -f` fails, fix the cause and run it again.

Do not track other credentials. Log in inside the sandbox instead: `opencode auth login`,
`NO_BROWSER=true gemini` and `gcloud auth application-default login --no-launch-browser`.

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
