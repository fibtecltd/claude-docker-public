# Sonnet 5.5 by Default, Opus 5.5 on Call: What's New in claude-docker-public

*Fibtec's containerized Claude Code setup now defaults to Claude Sonnet 5.5, with Claude Opus 5.5 one flag away.*

---

A few weeks ago we open-sourced **[claude-docker-public](https://github.com/fibtecltd/claude-docker-public)**, the container we run Claude Code in across our own projects. The pitch was simple: [the sandbox is the feature](https://github.com/fibtecltd/claude-docker-public/blob/main/articles/the-sandbox-is-the-feature.md). The agent gets a disposable box, and the box is the security boundary.

This update is about what runs *inside* the box. The image now knows about **Claude Sonnet 5.5** and **Claude Opus 5.5**, and it starts every session on Sonnet 5.5 by default.

## What changed

A small addition to `claude-backup/settings.json`, and one idea behind it.

```json
{
  "model": "claude-sonnet-5-5",
  "modelSettings": {
    "claude-sonnet-5-5": { "effortLevel": "xhigh" },
    "claude-opus-5-5":   { "effortLevel": "high" },
    "claude-sonnet-5":   { "effortLevel": "xhigh" },
    "claude-fable-5":    { "effortLevel": "medium" },
    "claude-fable-5-1":  { "effortLevel": "medium" }
  }
}
```

- **A default model, stated explicitly.** Before this, the image didn't pin one at all: whatever Claude Code picked on the day was what you got. Now `"model": "claude-sonnet-5-5"` makes the starting point a decision rather than a side effect. A container that's rebuilt in six months should behave the way the repo says it does, not the way a moving default says it does.
- **Per-model effort levels.** Effort controls how much thinking a model spends on a task. The right level isn't the same for every model, so each one gets its own entry instead of one global setting.
- **Nothing removed.** The Sonnet 5 and Fable entries are still there. If you pin an older model, you keep the settings you had.

## Why Sonnet 5.5 as the default

Most of what an agent does in a dev loop is not the hardest problem in your codebase. It's reading files, running tests, making a focused edit, fixing the lint error the last edit introduced. For that kind of work you want a model that's fast and cheap enough that you stop thinking about the meter.

At the published API rates, Sonnet 5.5 is $2 input / $10 output per million tokens, and Opus 5.5 is $4 / $20. Both have a 1M-token context window and up to 128K output tokens. That matters here because the container authenticates with an `ANTHROPIC_API_KEY`, so the choice of default model is a line item, not an abstraction. Half the price for the model that handles the bulk of a session is a good default. When you hit the genuinely hard problem, you switch up for that task and switch back.

## Opus 5.5, on call

Opus 5.5 is configured and ready, just not the starting point. Two ways to reach for it:

```bash
# for this whole session
docker compose run --rm claude --model claude-opus-5-5

# or, mid-session, inside Claude Code
/model
```

The first works because the entrypoint hands its arguments straight to `claude`. No rebuild, no config edit: it's a flag on a throwaway container.

## The effort levels, and why they're a starting point

We set Sonnet 5.5 to `xhigh`, matching how we already ran Sonnet 5, and Opus 5.5 to `high`. The Opus choice is the one with a reason behind it: Opus 5.5's own built-in default is `medium`, a step below the `high` its predecessor shipped with, so leaving it unset would have quietly made Opus 5.5 think *less* than the model it replaces.

The honest caveat is that effort levels were recalibrated with Sonnet 5.5, so a level doesn't mean exactly what it did on Sonnet 5. `xhigh` is a reasonable place to begin for agentic coding, not a measured optimum. If your sessions feel slow or expensive, `medium` is the first thing to try. The values live in one file, and changing them is a one-line edit followed by a rebuild.

## What didn't change

The parts that made the original setup worth publishing are untouched:

- **The container is still the boundary.** Same bind-mounted project directories, same one-way credential pass-through.
- **Plugins are still baked in at build time.** A container start still makes zero marketplace calls.
- **`bypassPermissions` is still on, and still documented.** It's safe because the box is disposable. Read the permission-mode section of `SETUP.md` before you build; that part is not optional.

## Try it

```bash
git clone https://github.com/fibtecltd/claude-docker-public
cd claude-docker-public
cp .env.example .env   # add your ANTHROPIC_API_KEY
docker compose build --no-cache claude
docker compose run --rm claude
```

If you already have the image, rebuild it. The settings are copied into the image at build time, so a running container won't pick up the change on its own.

Don't like our defaults? That's the point of publishing a config rather than a product. Edit `claude-backup/settings.json`, rebuild, and tell us what you changed and why. We'd like to hear what effort level survives contact with your codebase.

## License

Apache-2.0. It bundles a few plugin marketplaces as forks under our GitHub org; each keeps its own upstream license, credited in `NOTICE`.

---

*Fibtec Limited builds regulatory-grade financial risk infrastructure. Find us at [fibtec.co.uk](https://fibtec.co.uk) and [pyvar.com](https://www.pyvar.com).*
