# Changelog

All notable changes to CodeGraph are documented here. Each entry also ships as
a [GitHub Release](https://github.com/colbymchenry/codegraph/releases) tagged
`vX.Y.Z`, which is where most people will look.

This project follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/)
and adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### New Features

- **GitHub Copilot support** — `codegraph install` now configures two new agent targets out of the box:
  - **`copilot-vscode`** (project-local): writes `./.vscode/mcp.json` with the VS Code MCP shape (top-level `servers` key) and a marker-delimited section in `./.github/copilot-instructions.md`. JSONC-aware via `jsonc-parser`.
  - **`copilot-cli`** (global only): writes `~/.copilot/mcp-config.json` with the CLI's `mcpServers` shape, plus an explicit `tools` allowlist.

## [0.9.7] - 2026-05-28

### New Features

- Go: gRPC interface stubs now connect to their hand-written implementation, so callers, callees, impact, and trace land on the real method instead of an empty generated stub.
- Generated files (protobuf, gRPC stubs, mocks, build output) now rank last in search, trace, and explore, so results land on your real implementation instead of an auto-generated placeholder.
- When `codegraph_trace` can't find a static path (a dynamic-dispatch break), it now inlines both endpoints' source, callers, and callees in one response, so the agent gets the full picture without a flurry of follow-up calls.
- Trace now picks the right endpoints in large multi-module repos by preferring symbols that share a directory, instead of grabbing an arbitrary same-named symbol from an unrelated module.
- Test files are now deprioritized in `codegraph_explore` (Go, Ruby, JS/TS, Java/Kotlin/Scala), so the explore budget goes to your real implementation source.
- Small projects (under ~500 files) now resolve flow questions in fewer MCP calls, with a leaner tool surface and tuned context and explore output sized for the project.
- `codegraph_context` now auto-traces flow questions like "how does X reach Y" or "trace the path from A to B", splicing the trace into the response so you don't need a separate `codegraph_trace` call.
- `codegraph_context` now inlines a URL-to-handler routing table and the source of your main routes file for routing questions on small projects, so you don't have to go read `routes.rb` or `web.php` yourself.
- `codegraph_context` search now boosts results in the directory of a project's core framework file, so a small same-named extension file no longer outranks the actual framework core.
- Interface-to-implementation linking now works for C#, TypeScript, JavaScript, Swift, and Scala (previously Java/Kotlin only), so investigating an interface method surfaces its concrete implementations.
- MCP tool descriptions are now shorter, trimming per-session overhead while keeping the steering guidance.
- Java and Kotlin imports now resolve by fully-qualified name, so same-name classes in different packages are told apart correctly in multi-module Spring and Android codebases, including across the Java/Kotlin interop boundary.
- Java and C# anonymous classes (`new T() { ... }`) and their overridden methods are now indexed as real class nodes, so an agent sees those hidden overrides in its trail without a Read.
- The installer no longer writes a duplicate `## CodeGraph` instructions block into your agent's instructions file (`CLAUDE.md`, `AGENTS.md`, `GEMINI.md`, Cursor's `.cursor/rules/codegraph.mdc`, or Kiro's steering doc) — the MCP server is now the single source of truth, and re-running `codegraph install` or `codegraph uninstall` strips a block a previous version left behind (#529). If you added your own notes inside the `CODEGRAPH_START`/`CODEGRAPH_END` markers, move them outside the markers first, since the whole marked block is removed.

### Fixes

- MCP tools no longer return results for files that were deleted while no server was running — the first query of a session now waits for the catch-up sync, so you get the correct index instead of stale rows.
- Windows: black console windows no longer flash on every file save or MCP reconnect (#485, #510, #530).
- `codegraph index` and `init -i` now report the true edge count in their summary, instead of undercounting by missing resolution and synthesizer edges.

