# Upstream-sync conflict resolution — Copilot CLI prompt

You are resolving a `git rebase upstream/main` conflict in the
`eggboy/codegraph` fork of `colbymchenry/codegraph`. The fork carries
a small set of changes that add **GitHub Copilot CLI** and
**GitHub Copilot (VS Code)** as installer targets. Upstream rejected
the PR, so the fork must keep these changes forever while tracking
upstream.

You are running headless inside a GitHub Actions runner. There is no
human watching. **Resolve every conflict, run the verifier, and stop.**
Do not ask questions; make defensible decisions and proceed.

## Goal

1. Resolve every unmerged path (`git ls-files -u`) so the rebase can
   continue and complete.
2. After every conflict is resolved, run `git rebase --continue`
   (with `GIT_EDITOR=true` to bypass the commit-message editor) until
   the rebase completes or you hit a new conflict.
3. When the rebase completes, run `bash scripts/sync/verify.sh`.
   If it fails, **fix the cause and re-run until it passes**.

## Hard rules (do not violate)

| Rule | Why |
|---|---|
| `package.json` `.version` MUST end in `-ghcp`. Take upstream's version and append `-ghcp`. E.g. upstream `0.9.7` → fork `0.9.7-ghcp`. | Local fork marker. Verifier asserts `/^\d+\.\d+\.\d+-ghcp$/`. |
| Do NOT edit `package-lock.json` by hand. The workflow runs `npm install --package-lock-only --ignore-scripts` after you finish. | The lock file regenerates from `package.json` and `node_modules` resolution. Hand edits will conflict with the regeneration step. |
| Files `src/installer/targets/copilot-cli.ts` and `src/installer/targets/copilot-vscode.ts` MUST remain present and substantially intact. | These ARE the reason the fork exists. They almost never conflict (upstream doesn't touch them). |
| Before "deferring to upstream" on any file, GREP for what the fork's `copilot-cli.ts` and `copilot-vscode.ts` import from it. Any imported symbol MUST remain exported. If upstream's version removes an export the fork imports, KEEP the fork's version (`git checkout --theirs <path>` during rebase) instead of taking upstream's. | Validated by a real dry-run: upstream removed `INSTRUCTIONS_TEMPLATE` from `src/installer/instructions-template.ts` in a refactor (the MCP server now emits the same guidance). The fork's Copilot targets still `import { INSTRUCTIONS_TEMPLATE }`. Naively taking upstream's version breaks `npm run build` with `TS2305: Module has no exported member 'INSTRUCTIONS_TEMPLATE'`. The fork's whole reason for `.github/copilot-instructions.md` is that it's read by surfaces (Copilot Chat, GH.com, cloud agent) that DON'T have MCP, so the export must stay. |
| `TargetId` union in `src/installer/targets/types.ts` MUST contain both `'copilot-cli'` and `'copilot-vscode'`. | Without these, the installer can't register the targets. Verifier asserts. |
| `ALL_TARGETS` array in `src/installer/targets/registry.ts` MUST contain both `copilotCliTarget` and `copilotVscodeTarget`. | Same. Verifier asserts. |
| `__tests__/installer-targets.test.ts` MUST mention the string `copilot-cli` AND `copilot-vscode` at least 30 times combined (current count is ~35; allow a slack of 5 for inconsequential test reshuffles). | Slop-guard against the parameterized contract suite. Mis-slotting a `case` arm here can ship green tests that silently skip the Copilot targets. |
| `CHANGELOG.md` `[Unreleased]` MUST preserve any fork-only bullets (the **GitHub Copilot support** entry under `### Added` is the main one). Merge upstream's new `[Unreleased]` entries in alongside it. Do NOT touch `[X.Y.Z]` released blocks — upstream owns them. NOTE: upstream periodically renames the subsection (e.g. `### Added` → `### New Features`); when they do, put the fork's bullet under the renamed section, not under a separate `### Added` you re-introduce. | Without this, the fork's release notes lose attribution. |
| `README.md` MUST continue to mention Copilot somewhere. The verifier checks for this — if it can't grep `copilot` (case-insensitive) in README, verify fails. | The fork rewrote the install section to mention Copilot CLI + VS Code targets. Losing that guidance is a user-visible regression. |
| `.github/copilot-instructions.md` (if present in conflicts) is the **agent instructions file the fork writes via `copilot-vscode` installer**. Preserve its CODEGRAPH-marked section verbatim. | This file is read by VS Code Copilot + GH.com Copilot Chat. |
| **Commit all post-rebase fixes.** When `verify.sh` flags an issue and you fix it, you MUST `git add` the fix and amend the top commit (`git commit --amend --no-edit`). Leaving a fix uncommitted is unsafe: CI re-runs `verify.sh` and would push the un-fixed commits. | The workflow asserts `git diff --quiet && git diff --cached --quiet` after you exit; an uncommitted fix fails the workflow even though your local verify passed. |
| **No remote mutations.** Do NOT run `git push`, `git tag`, `gh pr create`, `gh release create`, `npm publish`, or any other command that mutates `origin`, the GitHub API, or any external service. Your scope is the local working tree and local git refs only. The workflow pushes and creates the PR after you exit and after CI re-runs verify. | Defense in depth. The CI step runs you with `--allow-all` so you CAN technically push; you MUST NOT. |

## Conflict hot-spots (what to expect)

Based on observed history, the following files conflict on most syncs.
None of these need deterministic resolution — your judgment is fine.

### `src/installer/targets/registry.ts`

Upstream periodically appends new entries to `ALL_TARGETS` (Kiro,
Gemini, Antigravity in recent history). The fork's two entries
(`copilotVscodeTarget`, `copilotCliTarget`) sit near the top, right
after `claudeTarget`. Keep them in that position. When upstream adds
new entries, slot them in **after** the Copilot entries (or wherever
upstream's diff suggests — preserve upstream's intended ordering).

The corresponding `import` statements at the top must also include both
`copilotCliTarget` and `copilotVscodeTarget`.

### `src/installer/targets/types.ts`

`TargetId` is a string-union type. Upstream periodically adds new
literals. Keep `'copilot-vscode'` and `'copilot-cli'` in the union no
matter what upstream does. Order doesn't matter for correctness, but
mirror upstream's surrounding ordering to minimize future diff churn.

### `__tests__/installer-targets.test.ts`

This is a parameterized contract test suite. Upstream extends both the
shared describe blocks and the per-target conditionals. Fork has added
~240 lines of Copilot-specific cases under headings like
"Copilot VS Code — shape & quirks" and "Copilot CLI — shape & quirks".

When merging:
- Keep ALL the Copilot-specific test cases the fork added.
- Add upstream's new test cases in the appropriate locations.
- In switch-style blocks (`if (target.id === 'opencode') { ... } else
  if (target.id === 'copilot-vscode') { ... } else { ... }`), preserve
  every arm. Upstream may add new arms; do not delete fork's arms.
- After resolution, double-check the file has the expected number of
  Copilot mentions (verifier will too).

### `src/installer/instructions-template.ts`

A shared template string. Fork makes minimal edits here (a wording
tweak in one place). Upstream periodically rewrites sections.

**Caution — the export-preservation rule (above) usually wins here.**
A real dry-run showed upstream removing the `INSTRUCTIONS_TEMPLATE`
export entirely (refactor: MCP server now emits the guidance). The
fork's `copilot-cli.ts` and `copilot-vscode.ts` both
`import { INSTRUCTIONS_TEMPLATE } from '../instructions-template'`,
so taking upstream's version breaks `npm run build`. In that case,
`git checkout --theirs src/installer/instructions-template.ts` (fork's
side) and add. If upstream's edits are just wording within an export
the fork still uses, take upstream's wording while keeping the export.

Reminder: during `git rebase`, `--ours` = upstream (the branch being
rebased ONTO) and `--theirs` = fork (the commits being replayed).
This is the OPPOSITE of `git merge`. Read carefully before using.

### `src/installer/index.ts`

Fork tweaked a few installer log strings. Upstream evolves this file
regularly. When in doubt: take upstream's version. If the fork's log
strings were about Copilot-specific output (e.g. "Open VS Code and
reload to apply"), preserve those; otherwise defer to upstream.

### `README.md`

Fork rewrote the install section to describe local-build workflow
(`npm link`, manual MCP setup) instead of upstream's
`npx @colbymchenry/codegraph` flow. Upstream evolves the README
regularly. **Preserve the fork's install section** (it reflects how
the fork is actually built and used). For all other sections, take
upstream's content. If upstream added a new section that mentions
"GitHub Copilot," merge that with the fork's existing Copilot mentions.

### `CHANGELOG.md`

Fork has a persistent bullet under `## [Unreleased]` → `### Added`
about GitHub Copilot support. Upstream's `[Unreleased]` evolves with
new entries each cycle, and periodically gets promoted to `[X.Y.Z]`
blocks by their release workflow.

Resolution recipe:
- Take upstream's full file as the structural base.
- Find the fork-only bullet(s) in ours's `[Unreleased]` — the
  **GitHub Copilot support** entry is the canonical one. There may be
  more if the fork has added other features in the future.
- Splice those fork-only bullets into upstream's `[Unreleased]`
  section, under the appropriate `### Added` / `### Changed` / etc.
  subheading.
- A bullet is "fork-only" if its first-bold-token (e.g.
  `**GitHub Copilot support**`) does NOT appear anywhere in upstream's
  `[Unreleased]` AND does NOT appear in any of upstream's released
  `[X.Y.Z]` blocks (which would mean upstream had promoted it).
- Never edit `[X.Y.Z]` released blocks. Those are upstream's history.

### `package.json`

Conflict is almost always on the `.version` field. Take upstream's
version and append `-ghcp`. For every other field (dependencies,
scripts, description, engines), take upstream verbatim.

## Resolution workflow (do this in order)

1. Inspect: `git status` and `git ls-files -u` to enumerate conflicts.
2. For each conflict, open the file, read both sides of the markers,
   apply the rules above, and remove the markers. Use `git checkout
   --ours <path>` or `--theirs <path>` for files where one side is
   clearly correct, but verify the result manually after.
3. `git add <resolved-files>`
4. When all are added: `GIT_EDITOR=true git rebase --continue`
5. If rebase reports a new conflict on a later commit, repeat from 1.
6. When rebase is complete (no rebase in progress, working tree clean
   except for tracked files):
   - `npm install --package-lock-only --ignore-scripts` to regenerate
     the lock file against the merged `package.json`.
   - `bash scripts/sync/verify.sh`
7. If `verify.sh` exits non-zero:
   - Read its output carefully. Find the failing assertion.
   - Fix the underlying cause (most likely a missed conflict arm, a
     wrong import, a typo in registry/types, or — see the
     instructions-template.ts caution above — an export the fork
     needs that upstream removed).
   - Re-run `npm install --package-lock-only --ignore-scripts` if you
     touched `package.json` again.
   - **`git add` the fix and `git commit --amend --no-edit` it into
     the top rebased commit.** Do NOT leave uncommitted changes.
   - Re-run `bash scripts/sync/verify.sh`.
   - Repeat until it passes. Do NOT exit with verify failing.
8. When verify passes, stop. Report what you did in your final message
   so the auto-PR body can quote it.

## Reporting back

After you're done, output a brief summary including:
- Files you modified (one bullet per file, with a one-line "why")
- Any non-obvious judgment calls
- Final `verify.sh` exit status (should be 0)

This summary goes into the auto-PR body. Keep it under 30 lines.

## Things you might be tempted to do but shouldn't

- **Do not refactor.** Resolve conflicts, nothing else. The diff
  should be the minimum needed to merge.
- **Do not bump the version yourself.** The version comes from
  upstream `+ -ghcp`. If `package.json.version` ends up as something
  other than `<upstream>-ghcp`, you got it wrong.
- **Do not add new files** unless an upstream commit was supposed to
  add one and `git add` would have included it. The fork's only new
  files are `copilot-cli.ts` and `copilot-vscode.ts`, which should
  already exist on the fork's commits being rebased.
- **Do not run `git rebase --skip`** unless the conflicted commit is
  obviously a duplicate of an upstream commit (rare; usually means
  upstream adopted the fork's change). If you skip a commit, mention
  it explicitly in your summary.
- **Do not run `git rebase --abort`.** If you're stuck, exit
  non-zero and the workflow will open a PR with the partial state
  for human review.
