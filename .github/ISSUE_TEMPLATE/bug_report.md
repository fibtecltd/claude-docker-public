---
name: Bug report
about: Something in the build, container, or bundled Claude Code config is broken
title: "[BUG] "
labels: bug
assignees: ''
---

**Describe the bug**
A clear, concise description of what's wrong.

**To reproduce**
Steps to reproduce, e.g.:
1. `docker compose build --no-cache claude`
2. `docker compose run --rm claude`
3. See error

**Expected behavior**
What you expected to happen instead.

**Environment**
- Host OS: [e.g. macOS 15, Windows 11 + WSL2, Ubuntu 24.04]
- Docker / Docker Desktop version:
- Output of `docker compose version`:

**Relevant logs**
Paste the relevant `docker compose build`/`run` output. Redact anything
that looks like a real credential before pasting — see SECURITY.md if the
bug itself is credential exposure rather than something to paste here.

**Additional context**
Anything else that might help — did this work before a specific commit,
plugin update, or Docker Desktop upgrade?
