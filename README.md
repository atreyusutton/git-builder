# git-builder

Every night at 02:30 this searches for what just shipped in AI, invents a small
project that only makes sense because of it, builds the thing, verifies it
actually runs, pushes it to GitHub, and leaves you a report to read with coffee.

```
bin/morning.sh          # what got built last night
bin/morning.sh --list   # everything built so far
bin/morning.sh -o       # read it, then open the repo
```

## How a night goes

| Phase | What happens | If it goes wrong |
|---|---|---|
| **Scout** | `claude -p` with web search finds a release from the last ~14 days and returns a spec as JSON | Retries once, then aborts and logs |
| **Build** | A fresh `claude -p` run builds the whole thing in an empty git repo, unattended | Timeout at `BUILD_TIMEOUT`, marked failed |
| **Verify** | The smoke test from the spec runs for real | **Failed builds are never pushed** |
| **Publish** | `git commit`, `gh repo create --public --push` | Stays committed locally, report says so |
| **Report** | `reports/YYYY-MM-DD.md` + a macOS notification | — |

The scout is shown the last 60 ideas and told not to repeat them, so the
projects stay distinct as the history grows.

## Setup

```bash
cd ~/Documents/GitHub/git-builder
chmod +x bin/*.sh

# night one, locally, nothing pushed:
NO_PUSH=1 bin/nightly.sh

# happy with it? schedule it:
bin/install.sh
```

`bin/install.sh` writes a launchd agent to
`~/Library/LaunchAgents/com.atreyusutton.git-builder.plist`. Change the time
with `RUN_HOUR=3 RUN_MINUTE=0 bin/install.sh`. Remove it with `bin/uninstall.sh`.

If your Mac is asleep at 02:30, launchd runs the job the next time it wakes —
you get the build a little later, not never.

## Configuration

Everything lives in [`config.env`](config.env):

| Setting | Default | Notes |
|---|---|---|
| `REPO_VISIBILITY` | `public` | `private` if you'd rather not publish nightly |
| `NO_PUSH` | `0` | `1` builds and commits locally only |
| `BUILD_MODEL` | `opus` | `sonnet` is cheaper and usually still fine |
| `BUILD_BUDGET_USD` | `8.00` | Hard ceiling; the run aborts rather than exceed it |
| `BUILD_TIMEOUT` | `3600` | Seconds before the build is killed |
| `REPO_PREFIX` | *(empty)* | e.g. `nightly-` to namespace the repos |

Budget defaults land around **$5–9 a night**, so roughly $150–270/month if you
leave it running. Drop `BUILD_MODEL` to `sonnet` and `BUILD_BUDGET_USD` to `3`
to cut that by most of it.

## What it makes

Constraints given to the scout, so builds don't fail at 3am on a missing
toolchain:

- Runs on python3, node 18, or a static HTML page — nothing else is installed
- No Docker, no database server, no GPU, no paid API key required
- If it calls an AI API it must still demo offline from fixtures
- One night's work, finished — no "phase 2"

## Layout

```
bin/nightly.sh     the whole pipeline
bin/morning.sh     read the report
bin/install.sh     schedule it     bin/uninstall.sh  unschedule it
prompts/scout.md   how it picks an idea
prompts/build.md   how it builds one
config.env         all the knobs
state/history.json every idea so far, for dedupe
reports/           one markdown file per night
builds/            the actual projects
logs/              one log per night
```

## Notes

- `nightly.sh` runs `claude` with `--dangerously-skip-permissions`, which is
  what makes unattended operation possible. It's scoped to a fresh empty
  directory under `builds/` per night, and the build prompt forbids touching
  anything outside it — but that flag is doing real work, so know it's there.
- The build agent is explicitly told not to run `git` or `gh`. Version control
  is the wrapper's job, so a confused agent can't push a broken tree.
- `state/.lock` prevents overlapping runs. If a run is killed mid-flight, delete
  that directory before the next one.

## Deliberately not included

Auto-committing filler changes across your other repos to inflate the
contribution graph. A real project shipped nightly already gives you a genuine
daily commit streak, and it survives someone clicking into it.
