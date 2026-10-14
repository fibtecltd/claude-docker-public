# Stop Mirroring Your Private Repo. Export It. (Plus the First Numbers From Running It on Fargate)

*How claude-docker-public is produced now, and what its first runs on ECS looked like.*

---

**[claude-docker-public](https://github.com/fibtecltd/claude-docker-public)** is the open-source half of the container setup we run Claude Code in. Until recently it was a mirror of a private repository. It is now an export, and the difference is bigger than the word.

This post has two parts: why we replaced the mirror and how the export works, then what happened the first time we ran the exported design headless on AWS Fargate, with the numbers.

## A mirror's default is "everything crosses"

A mirror copies the private repo and relies on a list of exclusions. Safety is whatever someone remembered to put on that list, and when the list is wrong nothing tells you. We also had a script in each direction, so the two repos were coupled: a change on one side could not be made without thinking about the other.

The public repo also needs files the private one should never have: a licence, a security policy, issue templates. In a mirror those are always one `--delete` away from vanishing.

So we turned it around. **The private repo stays the source. The public repo is a product built from it.**

## What an export does instead

1. **It starts from what is committed.** `git archive HEAD`, not the working directory. A source with uncommitted changes is refused.
2. **It sanitises.** Some paths never cross: the export tooling itself, private deployment settings, profiles that name private projects. Lines matching deny patterns are dropped from the README, and fenced blocks marked as private are cut out. An unbalanced fence aborts the export.
3. **It scans, and aborts instead of warning.** API-key and token shapes, cloud ARNs that carry an account id, and the names of private projects. One hit and nothing is exported.
4. **It writes one commit on a new branch** from the public `main`, with `rsync --checksum --delete` that protects the files that only exist publicly. Review happens as an ordinary pull request on the public side. Exporting the same source twice changes nothing.
5. **CI runs it as a dry run** on pull requests: `--check` writes nothing and lists what would change.

One time the scan fired in CI it was on our own test data: a made-up twelve-digit account id inside an ARN in a test fixture. A false positive, and the right kind to have. We changed the fixture, not the rule.

## Then we ran it on Fargate

The exported design runs Claude Code headless on ECS Fargate: one task per run, nothing standing between runs (the idle cost is image storage), plugins baked into the image at pinned commits, a profile that picks which ones load. Every run must carry a turn cap and a budget cap. The task role is empty and the security group allows outbound HTTPS only.

We deployed it into an AWS account that also runs production pipelines, so the deploy script reads before it writes. Nine checks come back GO or NO-GO, the CDK diff must be create-only, `cdk bootstrap` is never run, and afterwards the account is compared with a baseline taken before. Result: 40 new items in the diff, none changed or removed, the bootstrap stack untouched, no pipeline execution started.

## The first numbers

We ran it twice: five runs, then eleven with cost capture. The second set, on the core and pyvar profiles, Fargate on arm64, the image's default model (Sonnet 5.5) unless stated:

- **One-word answer, first run:** start-up 32 s, run phase 29 s, 1 turn, $0.0955
- **The same, again:** start-up 31 s, run phase 28 s, 1 turn, $0.0077
- **Question about pyvar, repo cloned:** start-up 32 s, run phase 42 s, 3 turns, $0.1615
- **Capped at $0.05:** start-up 31 s, run phase 35 s, 3 turns, $0.0680
- **Four shell commands:** start-up 31 s, run phase 49 s, 5 turns, $0.0803

(Start-up is task created to running, including provisioning and image pull. Cost is Claude Code's own `total_cost_usd`, so API spend only; Fargate time is billed separately.)

- **About 32 seconds to a running container** (30 to 36 over all sixteen runs), almost half of it image pull. A one-word task is about a minute from command to exit.
- **There is no warm start.** Fargate pulls the image for every task. The second run was not faster than the first.
- **The run phase is not the model.** A one-word answer took 28 to 30 seconds on every model we tried, Opus and Haiku included. One run reported its own session time: 7.7 seconds inside a 35-second run phase. So most of the run phase is outside the model session: Claude Code and its plugins starting, and exiting.

Each row is one sample. Read these as orders of magnitude, not benchmarks.

## What a run costs

Eleven runs cost **$0.99** against caps that added up to $3.55.

The capped run printed its token counts, and the bill reproduces from them. It produced 671 output tokens, read 26,641 tokens from the prompt cache and wrote 22,395 to it. At Sonnet 5.5 list prices ($2 and $10 per million tokens, cache writes at 1.25x, cache reads at 0.1x) that is $0.0067 for the answer, $0.0053 for cache reads and $0.0560 for cache writes. They add up to the reported $0.0680. **Eighty-two percent of the cost was writing the starting context. Ten percent was the answer.**

Two consequences:

- **The first call pays, the next ones do not.** A one-word answer cost $0.0955 the first time and $0.0077 both times after, a few minutes later.
- **Set a cap above the starting context.** A cold one-word run already cost more than the $0.05 cap we used for the cap test, so that cap would have stopped any task. The run ended at $0.068, 36 percent over: a cap ends the run after the turn that crosses it, not to the cent.

## Six models, one word

The same prompt on each model, no errors and no rate limits, every one answered `ok` with exit 0:

- **Haiku 5.5, effort max:** $0.0018, warm (the model had been called minutes earlier)
- **Haiku 5.5:** $0.0049, cold (first call on this model)
- **Sonnet 5.5:** $0.0077, warm
- **Sonnet 5:** $0.1270, cold
- **Opus 5.5:** $0.1893, cold
- **Opus 5:** $0.2450, cold

Do not read this as a price list. The cheap rows are the ones with a warm cache; the others paid to write it, so the warm or cold note matters as much as the price. What it does show: the choice of model moved the cost by more than an order of magnitude, even between two first calls ($0.0049 for Haiku 5.5, $0.2450 for Opus 5), and the run time by about two seconds.

## Did it do the job?

We scored the runs two ways.

**The answer.** The pyvar run asked how the Monte Carlo engine gets its random numbers. We wrote down six facts from the real `engine/montecarlo.py` first: the draw happens in Python outside the Numba kernel, it uses `np.random.randn`, it names `_draw_random_shocks`, it names the kernel `_simulate_paths`, the numbers reach the kernel as an argument, the seed is applied with `np.random.seed`. The answer contained all six, **6 out of 6**, in both of our runs. In the second run every line reference we checked by hand was right. (In the first run one was off by a single line.)

That is one question and a pattern match, so it says the agent found the right file in a fresh clone and described it correctly, not that it is good in general.

**The guardrails.** **All eleven runs of the second set behaved as designed.**

- The $0.05 cap stopped the task: `Reached maximum budget ($0.05)`, exit code 1.
- Inside a task, the AWS identity is the task role, and `aws s3 ls` is denied because the role has no permissions.
- HTTPS to the internet returned 200. Plain HTTP on port 80 timed out after eight seconds.

**What we did not measure:** three tasks at once, Spot, and the answer quality of the models on anything harder than one word.

## Try it

You need Docker and AWS credentials, not the AWS CLI:

```bash
scripts/deploy/ecs-in-docker.sh deploy
scripts/deploy/ecs-in-docker.sh runs
```

The first builds and smoke-tests the image, runs the checks, deploys the stack and pushes the image. The second makes five runs by default and prints the report: timings, cost, the answer scored against the facts above and the guardrail checks. Add `--groups G1,G2,G3,G4` for the eleven runs of this article. The repository and the runbook, with the timing table, are in **[claude-docker-public](https://github.com/fibtecltd/claude-docker-public)**.
