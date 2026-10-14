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

Five runs on the core and pyvar profiles, Fargate on arm64, the image's default model (Sonnet 5.5):

| run | what it did | provisioning | image pull | start-up | run |
|---|---|---|---|---|---|
| 1 | one-word answer | 11 s | 16 s | 30 s | 30 s |
| 2 | same, again | 17 s | 14 s | 36 s | 30 s |
| 3 | question about pyvar, repo cloned | 12 s | 16 s | 32 s | 41 s |
| 4 | same repo, USD 0.05 cap | 14 s | 15 s | 33 s | 37 s |
| 5 | four shell commands | 12 s | 15 s | 32 s | 53 s |

(Start-up is task created to running; it includes provisioning and image pull.)

- **About 32 seconds to a running container**, almost half of it image pull. A one-word task is about a minute from command to exit.
- **There is no warm start.** Fargate pulls the image for every task. The second run was not faster than the first.
- **The 30 seconds for a one-word answer** is Claude Code starting with its plugins plus one model call at the default effort. We have not split it further.

Each row is one sample. Read these as orders of magnitude, not benchmarks.

## Did it do the job?

We scored the runs two ways.

**The answer.** Run 3 asked how pyvar's Monte Carlo engine gets its random numbers. We wrote down six facts from the real `engine/montecarlo.py` first: the draw happens in Python outside the Numba kernel, it uses `np.random.randn`, it names `_draw_random_shocks`, it names the kernel `_simulate_paths`, the numbers reach the kernel as an argument, the seed is applied with `np.random.seed`. The answer contained all six, **6 out of 6**. We also checked its line references against the file by hand: all correct but one, off by a single line.

That is one question and a pattern match, so it says the agent found the right file in a fresh clone and described it correctly, not that it is good in general.

**The guardrails.** **5 of 5 runs behaved as designed.**

- The USD 0.05 cap stopped the task: `Error: Exceeded USD budget (0.05)`, exit code 1.
- Inside a task, the AWS identity is the task role, and `aws s3 ls` is denied because the role has no permissions.
- HTTPS to the internet returned 200. Plain HTTP on port 80 timed out after eight seconds.

One caveat: for the HTTPS check the agent told us it had not captured curl's exit code reliably, so we rely on the 200.

**What we did not measure:** what each run actually cost (our report prints the caps, USD 2.05 for the five, not the spend), a model comparison, concurrent tasks, Spot.

## Try it

You need Docker and AWS credentials, not the AWS CLI:

```bash
scripts/deploy/ecs-in-docker.sh deploy
scripts/deploy/ecs-in-docker.sh runs
```

The first builds and smoke-tests the image, runs the checks, deploys the stack and pushes the image. The second makes the five runs above and prints the report. The repository and the runbook, with the timing table, are in **[claude-docker-public](https://github.com/fibtecltd/claude-docker-public)**.
