#!/usr/bin/env bash
# Post-rebase verifier — the deterministic safety net for the upstream-sync
# workflow.
#
# Runs AFTER the rebase has completed (with or without LLM help) and AFTER
# `npm install --package-lock-only --ignore-scripts` has regenerated the lock
# file. Re-proves the fork's invariants independently of whatever the agent
# claims to have done.
#
# The contract:
#   - Exit 0 → workflow can proceed (auto-merge or open PR with green status).
#   - Exit non-zero → workflow opens a PR labeled `needs-review` with this
#     script's output appended to the body.
#
# Every check is independent. Failures accumulate; the script reports ALL
# failed assertions before exiting non-zero, so the agent's next iteration
# (or the human reviewer) sees the full set at once instead of debugging one
# issue at a time.

set -uo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"
cd "${REPO_ROOT}"

# Color helpers (auto-disabled when not a tty, e.g. in CI logs).
if [ -t 1 ] && command -v tput >/dev/null 2>&1; then
  GREEN="$(tput setaf 2)"; RED="$(tput setaf 1)"; YELLOW="$(tput setaf 3)"; RESET="$(tput sgr0)"
else
  GREEN=""; RED=""; YELLOW=""; RESET=""
fi

FAILURES=0
pass() { echo "${GREEN}✓${RESET} $1"; }
fail() { echo "${RED}✗${RESET} $1" >&2; FAILURES=$((FAILURES + 1)); }
info() { echo "${YELLOW}…${RESET} $1"; }

# Fork-specific knobs. If the fork's surface ever grows, update these.
EXPECTED_VERSION_SUFFIX="-ghcp"
EXPECTED_COPILOT_TOOL_COUNT=9
# Slop guard. Current count is ~35; allow some downward drift from upstream
# adding shared cases that don't mention Copilot, but flag a big drop.
MIN_COPILOT_TEST_MENTIONS=30

echo "==> Repo: $(git config --get remote.origin.url 2>/dev/null || echo '<unknown>')"
echo "==> HEAD: $(git rev-parse --short HEAD) ($(git log -1 --pretty=%s))"
echo

# ---------------------------------------------------------------------------
# 1. No unmerged paths remain
# ---------------------------------------------------------------------------
echo "==> Checking: no unmerged paths"
UNMERGED="$(git ls-files -u || true)"
if [ -n "${UNMERGED}" ]; then
  fail "git still reports unmerged paths:"
  echo "${UNMERGED}" | sed 's/^/    /'
else
  pass "working tree fully merged"
fi

# ---------------------------------------------------------------------------
# 2. Brand-new fork files still exist and are non-trivially populated
# ---------------------------------------------------------------------------
echo
echo "==> Checking: fork-owned Copilot target files present"
for f in \
  src/installer/targets/copilot-cli.ts \
  src/installer/targets/copilot-vscode.ts; do
  if [ ! -f "$f" ]; then
    fail "$f is missing — this file IS the fork's reason to exist"
  elif [ "$(wc -c < "$f")" -lt 1000 ]; then
    fail "$f exists but is suspiciously small ($(wc -c < "$f") bytes) — agent likely deleted content"
  else
    pass "$f present ($(wc -c < "$f") bytes)"
  fi
done

# ---------------------------------------------------------------------------
# 3. TargetId union contains both Copilot ids
# ---------------------------------------------------------------------------
echo
echo "==> Checking: TargetId union in types.ts"
TYPES_FILE=src/installer/targets/types.ts
if [ ! -f "$TYPES_FILE" ]; then
  fail "$TYPES_FILE is missing"
else
  for id in "'copilot-cli'" "'copilot-vscode'"; do
    if grep -q "$id" "$TYPES_FILE"; then
      pass "TargetId contains $id"
    else
      fail "TargetId is missing $id"
    fi
  done
fi

# ---------------------------------------------------------------------------
# 4. ALL_TARGETS registry contains both Copilot entries, and imports them
# ---------------------------------------------------------------------------
echo
echo "==> Checking: ALL_TARGETS registry"
REG_FILE=src/installer/targets/registry.ts
if [ ! -f "$REG_FILE" ]; then
  fail "$REG_FILE is missing"
else
  for sym in copilotCliTarget copilotVscodeTarget; do
    if grep -q "import.*${sym}" "$REG_FILE" && grep -q "^\s*${sym}," "$REG_FILE"; then
      pass "registry imports + lists $sym"
    else
      fail "registry missing $sym (either no import, or not in ALL_TARGETS array)"
    fi
  done
fi

# ---------------------------------------------------------------------------
# 5. package.json version matches -ghcp suffix; lock file matches package.json
# ---------------------------------------------------------------------------
echo
echo "==> Checking: package.json + package-lock.json version sync"
if [ ! -f package.json ]; then
  fail "package.json missing"
else
  PKG_V=$(node -p "require('./package.json').version" 2>/dev/null || echo "<unparseable>")
  echo "    package.json version: ${PKG_V}"
  if [[ "${PKG_V}" =~ ^[0-9]+\.[0-9]+\.[0-9]+${EXPECTED_VERSION_SUFFIX}$ ]]; then
    pass "package.json version matches /^\\d+\\.\\d+\\.\\d+${EXPECTED_VERSION_SUFFIX}\$/"
  else
    fail "package.json version (${PKG_V}) does NOT match /^\\d+\\.\\d+\\.\\d+${EXPECTED_VERSION_SUFFIX}\$/"
  fi
fi

if [ ! -f package-lock.json ]; then
  fail "package-lock.json missing"
else
  LOCK_V=$(node -p "require('./package-lock.json').version" 2>/dev/null || echo "<unparseable>")
  LOCK_PKG_V=$(node -p "require('./package-lock.json').packages[''].version" 2>/dev/null || echo "<unparseable>")
  echo "    package-lock.json top version: ${LOCK_V}"
  echo "    package-lock.json packages[''] version: ${LOCK_PKG_V}"
  if [ "${LOCK_V}" = "${PKG_V}" ] && [ "${LOCK_PKG_V}" = "${PKG_V}" ]; then
    pass "lock file versions match package.json (both fields)"
  else
    fail "lock file version drift — package.json=${PKG_V}, lock.version=${LOCK_V}, lock.packages[''].version=${LOCK_PKG_V}"
  fi
fi

# ---------------------------------------------------------------------------
# 6. Test file slop guard
# ---------------------------------------------------------------------------
echo
echo "==> Checking: installer-targets.test.ts mentions Copilot enough times"
TEST_FILE=__tests__/installer-targets.test.ts
if [ ! -f "$TEST_FILE" ]; then
  fail "$TEST_FILE is missing"
else
  MENTIONS=$(grep -E -c "copilot-cli|copilot-vscode" "$TEST_FILE" || true)
  if [ "${MENTIONS}" -ge "${MIN_COPILOT_TEST_MENTIONS}" ]; then
    pass "installer-targets.test.ts mentions Copilot ${MENTIONS} times (≥ ${MIN_COPILOT_TEST_MENTIONS})"
  else
    fail "installer-targets.test.ts mentions Copilot only ${MENTIONS} times (< ${MIN_COPILOT_TEST_MENTIONS}) — agent likely mis-slotted a parameterized arm"
  fi
fi

# ---------------------------------------------------------------------------
# 7. CHANGELOG.md still has the GitHub Copilot bullet under [Unreleased]
# ---------------------------------------------------------------------------
echo
echo "==> Checking: CHANGELOG.md retains fork Copilot entry"
if [ ! -f CHANGELOG.md ]; then
  fail "CHANGELOG.md missing"
else
  UNRELEASED_BODY=$(awk '/^## \[Unreleased\]/{flag=1;next} /^## \[[0-9]/{flag=0} flag' CHANGELOG.md)
  if echo "${UNRELEASED_BODY}" | grep -qi "github copilot"; then
    pass "[Unreleased] contains a GitHub Copilot bullet"
  else
    fail "[Unreleased] is missing the GitHub Copilot bullet — agent dropped fork's persistent entry"
  fi
fi

# ---------------------------------------------------------------------------
# 7b. README.md still describes the fork's local-build / Copilot story
# ---------------------------------------------------------------------------
echo
echo "==> Checking: README.md retains fork's local-build / Copilot guidance"
if [ ! -f README.md ]; then
  fail "README.md missing"
else
  # The fork rewrote the README's install section to describe local-build
  # workflow (npm link, manual MCP setup) and added Copilot mentions.
  # If both markers vanish, the agent likely took upstream's README
  # verbatim and dropped the fork's user-facing install guidance.
  if grep -qi "copilot" README.md; then
    pass "README.md mentions Copilot"
  else
    fail "README.md no longer mentions Copilot — fork's user-facing guidance was dropped"
  fi
fi

# ---------------------------------------------------------------------------
# 8. Diffstat guard — detect agent edits outside expected fork divergence
# ---------------------------------------------------------------------------
echo
echo "==> Checking: no unexpected fork-vs-upstream file divergence"

# The upstream target ref is set by the workflow. When running locally it may
# not exist — skip gracefully.
if git rev-parse "${UPSTREAM_TARGET_REF:-refs/remotes/upstream-sync/target}" >/dev/null 2>&1; then
  _UP_REF="${UPSTREAM_TARGET_REF:-refs/remotes/upstream-sync/target}"

  # Allowlist: glob patterns for files the fork is EXPECTED to differ from
  # upstream. Anything outside this set is suspicious — the LLM agent likely
  # wandered into unrelated code.
  FORK_ALLOWLIST=(
    '.github/workflows/sync-upstream.yml'
    '.markdownlint-cli2.jsonc'
    'CHANGELOG.md'
    'README.md'
    '__tests__/installer-targets.test.ts'
    'docs/SYNC.md'
    'package.json'
    'package-lock.json'
    'scripts/sync/*'
    'src/installer/index.ts'
    'src/installer/instructions-template.ts'
    'src/installer/targets/copilot-cli.ts'
    'src/installer/targets/copilot-vscode.ts'
    'src/installer/targets/registry.ts'
    'src/installer/targets/types.ts'
    '.cursor/rules/codegraph.mdc'
  )

  # Get files where fork (HEAD) differs from upstream target.
  DIVERGED_FILES=$(git diff --name-only "${_UP_REF}"..HEAD 2>/dev/null || true)
  UNEXPECTED=""

  for f in ${DIVERGED_FILES}; do
    MATCHED=false
    for pattern in "${FORK_ALLOWLIST[@]}"; do
      # Use bash pattern matching (supports * glob).
      # shellcheck disable=SC2053
      if [[ "$f" == $pattern ]]; then
        MATCHED=true
        break
      fi
    done
    if [ "${MATCHED}" = "false" ]; then
      UNEXPECTED="${UNEXPECTED}    ${f}\n"
    fi
  done

  if [ -n "${UNEXPECTED}" ]; then
    fail "fork diverges from upstream in unexpected files — agent may have wandered:"
    printf "%b" "${UNEXPECTED}" >&2
  else
    DIVERGE_COUNT=$(echo "${DIVERGED_FILES}" | grep -c . || true)
    pass "all ${DIVERGE_COUNT} diverging files are in the fork allowlist"
  fi
else
  info "upstream target ref not available — skipping diffstat guard (local run?)"
fi

# ---------------------------------------------------------------------------
# 9. Build
# ---------------------------------------------------------------------------
echo
echo "==> Running: npm run build (TypeScript compile + asset copy)"
if npm run build > /tmp/sync-build.log 2>&1; then
  pass "npm run build succeeded"
else
  fail "npm run build failed (see /tmp/sync-build.log):"
  tail -30 /tmp/sync-build.log | sed 's/^/    /'
fi

# ---------------------------------------------------------------------------
# 10. Targeted Copilot installer-contract tests
# ---------------------------------------------------------------------------
echo
echo "==> Running: targeted Copilot installer-contract tests"
if npx vitest run __tests__/installer-targets.test.ts -t "copilot" > /tmp/sync-copilot-tests.log 2>&1; then
  pass "Copilot installer-contract tests passed"
else
  fail "Copilot installer-contract tests failed (see /tmp/sync-copilot-tests.log):"
  tail -40 /tmp/sync-copilot-tests.log | sed 's/^/    /'
fi

# ---------------------------------------------------------------------------
# 11. MCP initialize smoke (end-to-end-ish — catches semantic drift the unit
#     tests miss)
# ---------------------------------------------------------------------------
echo
echo "==> Running: MCP initialize smoke test"
if npx vitest run __tests__/mcp-initialize.test.ts > /tmp/sync-mcp-init.log 2>&1; then
  pass "MCP initialize test passed"
else
  fail "MCP initialize test failed (see /tmp/sync-mcp-init.log):"
  tail -40 /tmp/sync-mcp-init.log | sed 's/^/    /'
fi

# ---------------------------------------------------------------------------
# 12. Full test suite (only if all the targeted checks above passed — saves
#     time on broken trees by surfacing focused failures first)
# ---------------------------------------------------------------------------
echo
if [ "${FAILURES}" -eq 0 ]; then
  echo "==> Running: full vitest suite"
  # Vitest can exit non-zero from worker-pool crashes (V8 wasm compile bugs,
  # OOM in CI runners) even when every test assertion passes. We only fail
  # verify.sh when at least one test ASSERTION fails — worker crashes get
  # reported but do not block the sync.
  set +o pipefail
  npm test > /tmp/sync-full-tests.log 2>&1
  TEST_EXIT=$?
  set -o pipefail
  # Vitest summary line looks like: "Tests  4 failed | 1021 passed | 2 skipped (1096)"
  # or:                              "Tests  1025 passed | 2 skipped (1096)"
  SUMMARY_LINE=$(grep -E "^[[:space:]]*Tests[[:space:]]+" /tmp/sync-full-tests.log | tail -1)
  FAILED_COUNT=$(echo "${SUMMARY_LINE}" | grep -oE "[0-9]+ failed" | head -1 | grep -oE "[0-9]+" || echo "0")
  FAILED_COUNT=${FAILED_COUNT:-0}
  # Distinguish "test assertion failed" from "worker crashed / runner
  # broke". A worker crash is a known V8/Node issue we tolerate; a
  # broken runner that prints no summary at all could let a real
  # regression slip through, so only treat exit-with-no-summary as
  # benign when we can ALSO see the worker-exit signature.
  WORKER_CRASH_MARKER='Worker exited unexpectedly'
  if [ "${TEST_EXIT}" -eq 0 ]; then
    pass "full test suite passed (${SUMMARY_LINE# *})"
  elif [ "${FAILED_COUNT}" -gt 0 ]; then
    fail "full test suite has ${FAILED_COUNT} failing test(s):"
    grep -E "^ FAIL|AssertionError|installer-targets|expected " /tmp/sync-full-tests.log | head -40 | sed 's/^/    /'
  elif [ -z "${SUMMARY_LINE}" ]; then
    # No vitest summary at all — runner failed to even produce output.
    # Treat as a real failure; don't let a broken runner pass verify.
    fail "test suite exited ${TEST_EXIT} and produced no vitest summary line — runner broken"
    tail -30 /tmp/sync-full-tests.log | sed 's/^/    /'
  elif grep -q "${WORKER_CRASH_MARKER}" /tmp/sync-full-tests.log; then
    # Known V8/Node worker crash (e.g. wasm compile bug). Summary line
    # present, no assertion failures, worker-exit signature found.
    info "test suite exited ${TEST_EXIT} with worker-exit marker — known env noise, not regression"
    echo "    summary: ${SUMMARY_LINE}"
    pass "full test suite assertions passed (worker crash noted, not counted as failure)"
  else
    # Summary line shows 0 failures but exit is non-zero with no known
    # crash marker. Surface as a real failure to be safe.
    fail "test suite exited ${TEST_EXIT} with 0 reported failures but no known worker-crash marker — investigate"
    echo "    summary: ${SUMMARY_LINE}"
    tail -30 /tmp/sync-full-tests.log | sed 's/^/    /'
  fi
else
  info "skipping full test suite — earlier checks failed; fix those first"
fi

# ---------------------------------------------------------------------------
# 13. install --print-config smoke for both Copilot targets
# ---------------------------------------------------------------------------
echo
echo "==> Running: codegraph install --print-config smoke (Copilot targets)"
if [ "${FAILURES}" -eq 0 ]; then
  # Requires the build above to have completed.
  CLI_CFG=$(node dist/bin/codegraph.js install --print-config copilot-cli 2>&1 || true)
  if echo "${CLI_CFG}" | grep -q '"mcpServers"' && echo "${CLI_CFG}" | grep -q '"codegraph"'; then
    # Extract the JSON portion (strip the leading `# Add to ...` comment line).
    CLI_JSON=$(echo "${CLI_CFG}" | sed -n '/^{/,$p')
    TOOL_COUNT=$(echo "${CLI_JSON}" | node -e "
      let data = '';
      process.stdin.on('data', c => data += c);
      process.stdin.on('end', () => {
        try {
          const cfg = JSON.parse(data);
          const tools = cfg.mcpServers && cfg.mcpServers.codegraph && cfg.mcpServers.codegraph.tools;
          console.log(Array.isArray(tools) ? tools.length : -1);
        } catch (e) { console.log(-2); }
      });
    " 2>/dev/null || echo "-3")
    if [ "${TOOL_COUNT}" = "${EXPECTED_COPILOT_TOOL_COUNT}" ]; then
      pass "copilot-cli --print-config emits ${EXPECTED_COPILOT_TOOL_COUNT} tools in allowlist"
    else
      fail "copilot-cli --print-config tool count = ${TOOL_COUNT} (expected ${EXPECTED_COPILOT_TOOL_COUNT})"
    fi
  else
    fail "copilot-cli --print-config did not produce expected JSON shape"
    echo "${CLI_CFG}" | head -20 | sed 's/^/    /'
  fi

  VSC_CFG=$(node dist/bin/codegraph.js install --print-config copilot-vscode 2>&1 || true)
  if echo "${VSC_CFG}" | grep -q '"servers"' && echo "${VSC_CFG}" | grep -q '"codegraph"'; then
    pass "copilot-vscode --print-config emits VS Code 'servers' shape"
  else
    fail "copilot-vscode --print-config did not produce expected JSON shape"
    echo "${VSC_CFG}" | head -20 | sed 's/^/    /'
  fi
else
  info "skipping --print-config smoke — earlier checks failed"
fi

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo
echo "============================================================"
if [ "${FAILURES}" -eq 0 ]; then
  echo "${GREEN}✓ verify.sh: all checks passed${RESET}"
  exit 0
else
  echo "${RED}✗ verify.sh: ${FAILURES} check(s) failed${RESET}"
  echo "The sync workflow will open a PR with this output appended."
  exit 1
fi
