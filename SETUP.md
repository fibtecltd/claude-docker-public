# Claude Code B+D Plugin Setup
## fibtecltd marketplace forks + build-time plugin installation

> **About this repo.** This is the public mirror of Fibtec's internal
> `claude-docker` setup for running Claude Code in a containerized dev
> environment, originally built for [pyvar](https://github.com/fibtecltd/pyvar).
> It is kept in sync with the private original via `scripts/sync-to-public.sh`
> (run from the private repo) — see that script for what is and isn't
> mirrored here.
>
> **Permission mode.** `claude-backup/settings.json` ships with
> `"defaultMode": "bypassPermissions"` — Claude Code will run every tool
> (Bash, Write, Edit, etc.) inside the container **without** asking for
> per-action confirmation. That's a deliberate choice for our own
> disposable, containerized dev environment, not Claude Code's own default.
> If you adopt this repo, decide deliberately whether you want that too —
> change `permissions.defaultMode` (and `skipDangerousModePermissionPrompt`)
> in `claude-backup/settings.json` before building if you don't.

---

## Architecture

```
GitHub (fibtecltd org)
  └── fibtecltd/claude-workflows        ← fork of wshobson/agents
  └── fibtecltd/python-backend-plugins  ← fork of ruslan-korneev/python-backend-claude-plugins

Dockerfile (build time)
  └── RUN install-plugins.sh           ← registers fibtecltd marketplaces
                                           installs all 41 plugins as claude user
                                           plugins baked into image layer

docker-compose.yml (runtime)
  └── claude_sessions → .claude/projects/   ← session history persists
  └── claude_persist  → .claude-persist/    ← auth token persists
  └── plugins/                             ← image layer, never masked

entrypoint.sh (runtime)
  └── restore .claude.json from persist volume
  └── start Claude Code  (no plugin logic)
```

**Key properties:**
- Zero marketplace network calls at container start
- Plugin updates require only `docker compose build --no-cache`
- Upstream schema changes never reach you until you merge the fork
- Any fresh `git clone` + `docker compose build` produces identical plugins

---

## Step 1 — Create GitHub forks (one-time, manual)

Go to https://github.com and create forks under the `fibtecltd` organisation.

### Fork 1: claude-code-workflows

1. Open https://github.com/wshobson/agents
2. Click **Fork** → owner = `fibtecltd` → name = `claude-workflows`
3. Uncheck "Copy the main branch only" — keep all branches

### Fork 2: python-backend-plugins

1. Open https://github.com/ruslan-korneev/python-backend-claude-plugins
2. Click **Fork** → owner = `fibtecltd` → name = `python-backend-plugins`

### Result

```
github.com/fibtecltd/claude-workflows        (wshobson/agents fork)
github.com/fibtecltd/python-backend-plugins  (ruslan-korneev fork)
```

---

## Step 2 — Copy files to claude-docker repo

Copy the four files from this package into `~/claude-docker/`:

```
Dockerfile           → ~/claude-docker/Dockerfile
entrypoint.sh        → ~/claude-docker/entrypoint.sh
install-plugins.sh   → ~/claude-docker/install-plugins.sh
docker-compose.yml   → ~/claude-docker/docker-compose.yml
```

Commit and push:

```bash
cd ~/claude-docker
git add Dockerfile entrypoint.sh install-plugins.sh docker-compose.yml
git commit -m "feat: B+D — fibtecltd forks + build-time plugin installation"
git push
```

---

## Step 3 — Build the image

```bash
cd ~/claude-docker

# Clear stale volume state (only needed on machines that had the old setup)
docker compose run --rm --entrypoint sh claude \
  -c "rm -rf /home/claude/.claude/plugins && \
      rm -f /home/claude/.claude/.plugins-installed && \
      rm -f /home/claude/.claude/settings.local.json" 2>/dev/null || true

# Full rebuild — plugins installed at build time
docker compose build --no-cache claude
```

Build time: approximately 5 minutes (plugin cloning via network).
Subsequent builds without `--no-cache`: seconds (cached layer).

---

## Step 4 — Run

```bash
docker compose run --rm claude
# Run /doctor inside Claude Code to verify zero plugin errors
```

---

## Step 5 — On every other machine

```bash
git clone https://github.com/fibtecltd/claude-docker-public
cd claude-docker-public
cp .env.example .env   # add ANTHROPIC_API_KEY
docker compose build --no-cache claude
docker compose run --rm claude
```

---

## Updating plugins (ongoing workflow)

### Update a plugin in a fibtecltd fork

```bash
# On your local machine
cd ~/forks/claude-workflows   # clone of fibtecltd/claude-workflows

# Merge upstream changes selectively
git remote add upstream https://github.com/wshobson/agents
git fetch upstream
git merge upstream/main --no-ff -m "chore: merge upstream wshobson/agents"

# Review and test the changes before pushing
# Only push when you have verified the plugin works
git push origin main
```

### Rebuild the image after a fork update

```bash
cd ~/claude-docker
docker compose build --no-cache claude
docker compose run --rm claude
# Verify /doctor is clean before distributing to team
```

### Add a new plugin

1. Add the install line to `install-plugins.sh`
2. Commit `install-plugins.sh` to `claude-docker`
3. Rebuild with `--no-cache`

---

## Volume structure

| Volume | Mounts at | Contents | Survives `--rm` |
|---|---|---|---|
| `claude_sessions` | `.claude/projects/` | Session history | Yes |
| `claude_persist` | `.claude-persist/` | Auth token copy | Yes |
| Image layer | `.claude/plugins/` | All 41 plugins | N/A — in image |
| Image layer | `.claude/settings.local.json` | Plugin enable list | N/A — in image |

Volume names are prefixed with your clone directory's name (the Docker
Compose project name) — `claude-docker-public_...` if you cloned this repo
as-is.

To reset auth (re-login):
```bash
docker volume rm claude-docker-public_claude_persist
docker compose run --rm claude
```

To reset session history:
```bash
docker volume rm claude-docker-public_claude_sessions
```

To update plugins: rebuild image (no volume manipulation needed).
