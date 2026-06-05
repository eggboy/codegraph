# Upstream sync — runbook

This fork (`eggboy/codegraph`) tracks `colbymchenry/codegraph` upstream and
carries patches that add **GitHub Copilot CLI** and **GitHub Copilot
(VS Code)** as installer targets. The upstream PR was rejected, so the fork
must be maintained indefinitely.

The `.github/workflows/sync-upstream.yml` workflow keeps the fork rebased
on top of upstream automatically. This document covers the setup,
operational mechanics, failure modes, and what to do when the auto-PR
opens.

## TL;DR

- **Cadence:** Monday 09:00 UTC (cron), plus manual dispatch.
- **Resolution:** GitHub Copilot CLI (`claude-sonnet-4.5`) reads
  `scripts/sync/copilot-resolve-prompt.md` and resolves conflicts headless.
- **Safety net:** `scripts/sync/verify.sh` runs after every rebase
  attempt and re-proves the fork's invariants (build, tests, MCP smoke,
  Copilot target presence). The agent never gets the last word.
- **Outcome:**
  - Clean rebase + green verify → pushed straight to `main`.
  - Anything else → opens an `auto-sync` PR labeled `needs-review`.

## One-time setup

### 1. Required repository secrets

| Secret | Purpose | Scope |
|---|---|---|
| `RELEASE_PAT` | Push to `main`, create PRs. Re-used from the release workflow. | Fine-grained PAT (or classic), **contents: write** + **pull-requests: write** on this repo. |
| `COPILOT_CLI_PAT` | Authenticates the headless Copilot CLI to the LLM API. The default `GITHUB_TOKEN` does NOT work. | Classic PAT with the **`copilot`** scope. Issued by an account with a Copilot subscription. |

Create the `COPILOT_CLI_PAT`:

1. Visit <https://github.com/settings/tokens> → **Generate new token (classic)**.
2. Note: "codegraph fork auto-sync — Copilot CLI".
3. Expiration: 90 days (rotate per your policy).
4. Scopes: tick **`copilot`** only.
5. Generate, copy.
6. Repo → **Settings → Secrets and variables → Actions → New repository secret**.
7. Name: `COPILOT_CLI_PAT`. Value: paste.

Confirm `RELEASE_PAT` already exists (release.yml uses it). If not, create
a fine-grained PAT with **contents: write** and **pull-requests: write**
on this repo only.

### 2. Org policy check

If your account belongs to a GitHub organization that restricts PAT
issuance (the "Restrict personal access tokens" setting), you may need
to request approval before the `copilot`-scoped PAT works against this
repo. The symptom is: `copilot auth status` reports 401/403 in the CI
run. Workarounds:

- **Self-hosted runner** with `gh auth login` configured persistently
  (the token sits on the runner machine, not in repo secrets).
- **Service account** owned by you (not the org) that has its own
  Copilot subscription.

### 3. Verify the install

Dispatch the workflow manually:

```
Actions → "Sync upstream" → Run workflow → Use workflow from main → Run
```

If upstream and the fork are already aligned, the run will report
`Already at upstream HEAD` and exit cleanly. If upstream has new commits,
the workflow rebases and reports the outcome on GitHub Step Summary.

## How it works

```
Mondays 09:00 UTC (or manual)
    │
    ├─ Checkout fork (full history) using RELEASE_PAT
    ├─ git fetch upstream main
    ├─ If upstream/main is already an ancestor of HEAD → exit (nothing to do)
    ├─ If an open auto-sync PR already targets this upstream HEAD SHA → exit (loop guard)
    ├─ npm ci
    ├─ npm install -g @github/copilot
    │
    ├─ git rebase upstream/main
    │   ├─ Clean → had_conflicts=false
    │   └─ Conflicts → had_conflicts=true, agent step runs
    │
    ├─ If had_conflicts: copilot -p "$(cat scripts/sync/copilot-resolve-prompt.md)"
    │      --allow-all --no-ask-user --model claude-sonnet-4.5
    │      --add-dir $(pwd) --share /tmp/sync/sync-log.md
    │   The agent:
    │     - reads the prompt
    │     - inspects every conflict
    │     - applies the hard rules (e.g. -ghcp suffix, preserve Copilot targets)
    │     - re-runs git rebase --continue until the rebase completes
    │     - runs verify.sh and iterates until green
    │
    ├─ npm install --package-lock-only --ignore-scripts
    │   (Regenerate lock; amend into top commit so no stray "lock" commit is added.)
    │
    ├─ bash scripts/sync/verify.sh
    │   Independent verification — never trusts the agent's claims.
    │   See "What verify.sh checks" below.
    │
    └─ Outcome:
       ├─ Clean rebase + green verify  → git push --force-with-lease origin HEAD:main
       └─ Anything else                → push to sync/upstream/<sha>; open PR
```

## What `verify.sh` checks

1. **Working tree merged.** `git ls-files -u` is empty.
2. **Fork-owned files present.** `copilot-cli.ts` + `copilot-vscode.ts`
   both exist and are non-trivially sized.
3. **`TargetId` union contains both Copilot IDs.**
4. **`ALL_TARGETS` registry imports and lists both Copilot targets.**
5. **`package.json` version matches `/^\d+\.\d+\.\d+-ghcp$/`.**
6. **`package-lock.json` version matches `package.json`** (top-level and `packages[''].version`).
7. **Test-file slop guard.** `__tests__/installer-targets.test.ts`
   mentions `copilot-cli` or `copilot-vscode` at least 30 times. Catches
   parameterized-test mis-slotting where the LLM might collapse Copilot
   cases into a single arm.
8. **`CHANGELOG.md` `[Unreleased]` contains a GitHub Copilot bullet.**
9. **`npm run build` succeeds.**
10. **Targeted Copilot tests pass** (`vitest run installer-targets -t copilot`).
11. **MCP initialize smoke test passes** (`vitest run mcp-initialize`).
12. **Full vitest suite assertions pass.** Worker-pool crashes (V8 wasm
    compile bugs, OOM) are noted but don't count as failures.
13. **`codegraph install --print-config copilot-cli`** emits 9 tools in
    the allowlist.
14. **`codegraph install --print-config copilot-vscode`** emits the VS
    Code `servers` shape.

If any of these fail, the workflow opens a PR labeled `auto-sync,
needs-review, verify-failed` with the verify log in the PR body. The
workflow never pushes to `main` under a failed verify.

## When the auto-PR opens

The PR body includes:
- Upstream SHA the rebase targeted.
- Whether conflicts were encountered.
- Model used.
- Diffstat against `upstream/main`.
- Tail of `verify.sh` output.
- Tail of the Copilot CLI session log.

Review checklist:

1. **Read the diffstat first.** Anything outside the expected hot-spots
   (the 7 files listed in `scripts/sync/copilot-resolve-prompt.md`) is
   a red flag — the agent may have edited something it shouldn't have.
2. **Check `verify.sh` status.** If it's red, fix the cause locally,
   push to the PR branch (`sync/upstream/<sha>`), and re-run verify
   manually with `bash scripts/sync/verify.sh`.
3. **Skim the session log.** Confirm the agent's resolution reasoning
   for any semantic conflicts.
4. **Squash-merge or rebase-merge.** Don't preserve the agent's
   intermediate commits.

## Running it locally (debugging)

The same flow works on your laptop. Useful for testing changes to the
prompt or verify script.

```bash
# From the fork's main, current state
git remote get-url upstream || git remote add upstream https://github.com/colbymchenry/codegraph.git
git fetch upstream main

# Dry-run the rebase
GIT_EDITOR=true git rebase upstream/main

# If conflicts, run the prompt against the local Copilot CLI
# (requires `gh auth login` or GITHUB_TOKEN env)
copilot \
  -p "$(cat scripts/sync/copilot-resolve-prompt.md)" \
  --allow-all --no-ask-user \
  --model claude-sonnet-4.5 \
  --add-dir "$(pwd)" \
  --share /tmp/sync-log.md

# Regenerate lock
npm install --package-lock-only --ignore-scripts

# Verify
bash scripts/sync/verify.sh
```

## Failure modes seen so far

| Failure | Cause | Fix |
|---|---|---|
| `copilot auth status` 401 in CI | `COPILOT_CLI_PAT` missing or expired | Rotate the PAT; re-add to secrets |
| `gh pr create` 403 | `RELEASE_PAT` missing `pull-requests: write` | Re-issue with correct scope |
| Workflow opens 4 PRs in a row for the same upstream SHA | Loop-guard bug (head branch naming drift) | Inspect the head branch name; confirm `sync/upstream/<short>` matches what the guard searches |
| `verify.sh` flakes on V8 wasm crash | Known Node 24 issue with the `node-sqlite3-wasm` fallback | Already handled — script distinguishes worker crashes from test failures |
| Agent removes Copilot test cases | Mis-resolution of the parameterized matrix | Slop guard (`≥ 30` mentions) catches it; verify fails, PR opens for review |
| Agent edits files outside the expected hot-spots | Over-eager refactor | Reviewer rejects PR; re-run with explicit instruction to be minimal |

## Tuning

- **Cadence.** Edit the `cron:` line. Current: Monday 09:00 UTC.
- **Model.** Default `claude-sonnet-4.5`. Override per-run via the
  `workflow_dispatch` input. If sonnet starts producing low-quality
  resolutions, try `opus`-class via the input.
- **Slop guard threshold.** Edit `MIN_COPILOT_TEST_MENTIONS` near the
  top of `scripts/sync/verify.sh`. Current: 30 (actual: ~35).
- **Forced re-run on the same upstream SHA.** Use `workflow_dispatch`
  with the `force` input set true.

## What this does NOT cover

- **Pre-existing fork test failures.** `verify.sh` runs the full suite,
  but if upstream introduces a bug that breaks tests, it's the same as
  a real conflict — PR opens, human reviews.
- **Major upstream restructuring** (e.g. renaming `src/installer/` or
  changing the `AgentTarget` interface). The agent will try, but a
  human should review carefully. Consider pausing the workflow until
  the fork is realigned.
- **Releases.** This workflow only syncs upstream into `main`. Cutting
  a `-ghcp` release still uses `.github/workflows/release.yml`
  (manual dispatch). After a sync, you may want to bump the version
  and publish.

## Operational gotchas

### Labels are created on first PR

The workflow uses three labels: `auto-sync`, `needs-review`, and
`verify-failed`. GitHub creates labels on first use via
`gh pr create --label`, but if the labels don't already exist on the
repo, the very first auto-sync run will fail at PR creation time.
One-time setup before letting the cron run:

```bash
gh label create auto-sync     --color "0E8A16" --description "Created by sync-upstream workflow"
gh label create needs-review  --color "FBCA04" --description "Awaiting human review"
gh label create verify-failed --color "B60205" --description "scripts/sync/verify.sh failed"
```

### Token safety — the LLM never gets push credentials

`actions/checkout` is invoked with `persist-credentials: false` and
the `RELEASE_PAT` is re-injected only for the explicit `git push` /
`gh pr` steps that run AFTER the Copilot CLI exits. The Copilot CLI
runs with `--allow-all` (so it can `git rebase`, `git add`,
`npm install`, etc.), but the local git remote has no auth during
its execution. This guarantees the agent cannot push to `origin` or
mutate the GitHub API behind the workflow's back.

If you ever copy this workflow to another repo, preserve this
ordering. Persisting credentials into the LLM step is a
prompt-injection / accident risk.

### Recovering from a dirty sync branch

If the workflow opened a PR but you want to redo the resolution
manually (e.g. the agent made a bad call):

```bash
git fetch origin "sync/upstream/<short>"
git checkout -b sync/upstream/<short>-manual FETCH_HEAD
git reset --hard upstream/main
# re-apply fork commits manually
git cherry-pick <fork commits>
# fix conflicts
bash scripts/sync/verify.sh
git push --force-with-lease origin HEAD:sync/upstream/<short>
```

The PR updates automatically; the workflow's loop guard will keep
itself out of your way.

### Superseded sync PRs (upstream advances while a PR is open)

The loop guard is conservative: **the workflow skips entirely if any
auto-sync PR is open**, even for an older upstream SHA. This is
intentional — two competing sync PRs is operational noise. Close or
merge the older PR before letting the cron tick produce a new one
(or dispatch manually with `force=true` to override).

### `COPILOT_CLI_PAT` expired mid-run

Symptom: the `Install GitHub Copilot CLI` step prints
`copilot --version` OK but the resolution step exits with
`Authentication failed` or `401`. The PR will NOT open because the
workflow aborts before the PR step. Rotate the PAT, re-add to
secrets, and re-dispatch with `force=true`.

### Artifacts and logs

Each run uploads `/tmp/sync/sync-log.md` (Copilot session transcript)
and `/tmp/sync/verify.log` (verifier output) as a workflow artifact
named `sync-artifacts-<upstream_short>`, retained 30 days. For
deeper diagnostics, the raw build log lives in the
`Verify post-rebase invariants` step's stdout — open the run page in
the Actions tab and expand the step.

### Local dry-run cleanup

If you ran the local dry-run section above and it left a half-done
rebase, recover with:

```bash
git rebase --abort
git checkout main
git reset --hard origin/main
```

Worktrees created for testing can be removed with
`git worktree remove --force <path>`.
