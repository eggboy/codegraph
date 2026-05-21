# Changelog

All notable changes to CodeGraph are documented here. Each entry also ships as
a [GitHub Release](https://github.com/colbymchenry/codegraph/releases) tagged
`vX.Y.Z`, which is where most people will look.

This project follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/)
and adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### New Features

- `codegraph status --json` now also reports the running CLI `version`, the index directory (`indexPath`), and a `lastIndexed` timestamp (ISO-8601, or null when nothing's indexed yet), so CI and scripts can pin the CLI version and check index freshness from a single command. A matching `CodeGraph.getLastIndexedAt()` library method exposes the same freshness check without shelling out. Thanks @12122J and @eddieran. (#329)

### Fixes

- The background file watcher no longer exhausts your machine's file-descriptor budget. On macOS it previously kept **one open file handle per watched file**, so on a large project the running MCP server could pile up tens of thousands of handles and blow past the system-wide limit — at which point *unrelated* apps (your shell, editor, Docker, browser) started failing with "too many open files" until the codegraph process was killed. The watcher now uses a single recursive watch on macOS and Windows, and bounded per-directory watches on Linux, so its cost stays flat no matter how large the project is. (#644, #496, #555, #628, #579)
- Indexing a project with very symbol-dense files (tens of thousands of functions or methods in a single file) no longer runs out of memory. The step that links dynamic call relationships used to load every function and method into memory at once, which could exhaust the heap and abort indexing with "JavaScript heap out of memory" on large or generated codebases; it now streams them, so memory stays flat no matter how many symbols the project has. (#610)
- Indexing a very large repository no longer aborts during its first sync with a "too many SQL variables" error. (#540)
- Files under directories with non-ASCII names (for example CJK characters) are no longer silently skipped during indexing. (#541)
- The `.codegraph/` index folder no longer clutters `git status`: its generated ignore file now excludes everything in the folder except itself, so the database, `daemon.pid`, sockets, and logs stop showing up as untracked changes. (#492, #484)
- SAP HANA `.xsjs` / `.xsjslib` files are now indexed as JavaScript. (#556)
- TypeScript `.mts` and `.cts` module files are now indexed instead of being skipped. (#366)
- JavaScript modules that wrap their code in an anonymous function — AMD/RequireJS, NetSuite SuiteScript, IIFE bundles — now have their inner functions and calls indexed, instead of the file coming up nearly empty. (#528)
- Go methods declared on generic types (e.g. `func (s *Stack[T]) Push(...)`) are now correctly attached to their type, so callers, callees, and impact include them. (#583)
- Asking what a symbol impacts no longer drags in every unrelated sibling method of its class — impact now follows real dependencies instead of the structural "contains" relationship, keeping the result focused on what actually depends on the symbol. (#536)
- CodeGraph's MCP server now answers an agent's `resources/list` and `prompts/list` probes with an empty list instead of an error, clearing the `-32601` messages some clients (opencode, Codex) logged on connect. (#621)
- Svelte and Vue components used through a barrel file — `export { default as Button } from './Button.svelte'` re-exported from an `index.ts` and imported elsewhere — are no longer falsely reported as having **0 callers**. CodeGraph now follows the default re-export all the way to the component and resolves the imports that `.svelte` / `.vue` files themselves use, so `codegraph_callers` and `codegraph_impact` see every place a component is used. This also covers components imported from another package in a workspace/monorepo (`@scope/ui/widgets`) and bare directory imports (`import { x } from './'`). Previously a live component consumed only through a barrel looked like dead code. Thanks @nakisen. (#629)
- Components used in a Vue Single-File Component's `<template>` — `<MyButton />`, or the kebab-case `<my-button />` — are now indexed as usages, so `codegraph_callers` and `codegraph_impact` include components that appear only in another component's markup (including through a barrel re-export). Previously only a Vue component's `<script>` block was analyzed, so template-only usages were invisible. (#629)

## [0.9.9] - 2026-06-02

### New Features

- `codegraph_explore` is now the primary tool, and one call is usually all an agent needs: it returns the verbatim source of the symbols relevant to your question (a plain question works as the query — you no longer need exact symbol names), grouped by file and Read-equivalent, so the agent answers without falling back to read/grep. The narrower `codegraph_context` and `codegraph_trace` tools were removed in favor of it — explore already surfaces the call flow among the symbols you name (the job trace did), so there's one obvious tool to reach for instead of three.
- `codegraph_explore` now includes a compact "Blast radius" for the symbols you're looking at — who depends on each (just the locations, not their source) and which test files cover it — so before editing, the agent can see what else to update and which tests to run, without a separate impact lookup. Symbols nothing depends on are skipped, so it stays short.
- Functions defined inside a store or handler object — the actions in a Zustand `create((set, get) => ({ … }))` store, and the same shape in Redux, Pinia, MobX, or any exported handler/route map — are now indexed as real symbols. Previously they existed only as object properties, so looking one up by name or asking who calls it returned "not found" and the agent had to read the whole store file to follow the flow; now `codegraph_node`, `codegraph_callers`, and `codegraph_explore` resolve them directly — including calls made through `useStore.getState().fetchUser()` or a destructured `const { fetchUser } = useStore.getState()`.
- `codegraph_explore` now surfaces the *right* definition when a method name is overloaded across types. Asking about, say, `DataRequest`'s `task` and `validate` used to return a same-named method from an unrelated file (or an abstract base stub) and bury the one you meant; explore now recognizes the type you named in the query and leads with that type's own overloads, in full.

### Fixes

- Search ranking no longer lets a common word in your request hijack the results: asking about, say, a "flat object" screen used to surface an unrelated constant that merely happened to be named the same, because the exact-name match outweighed everything else. Ranking now weighs how well each result is corroborated by the rest of your request, so the symbols you actually meant come first (this improves `codegraph_explore`'s results).
- `codegraph_node` now returns *every* definition when a name is ambiguous — an overloaded method, or the same method name on different types — instead of returning one (sometimes the wrong one) with a note listing the rest. Asking for such a symbol now hands back all of the matching definitions with their source in a single call, so the agent stops having to read the file by hand to find the specific overload it wanted (common in Swift, Go, Java, and C#). For a heavily-overloaded name (a `poll`/`validate` with dozens of definitions), pass `file` (and/or `line`) — e.g. the `file:line` shown in a trail — to get that exact definition's body. Large overload sets show the most relevant ones in full and list the remainder by location.
- `codegraph_explore` never returns half a method anymore: when output runs up against its size budget it drops whole methods or whole files (and lists what it dropped, so you can ask for them in another call) instead of cutting off a method body partway. A truncated method was the one case that still sent the agent to read the file for the rest — so the source explore returns is now always complete and usable as-is.

## [0.9.8] - 2026-06-01

### New Features

- `codegraph init` now builds the initial index by default — you no longer need the `-i`/`--index` flag (it's still accepted, so existing commands and scripts keep working). (#483)
- Go: Gin middleware chains now connect end-to-end in `codegraph_trace` and `codegraph_explore` — following a request reaches the middleware and route handlers registered via `.Use()` / `.GET()` instead of dead-ending where the framework dispatches the chain dynamically.
- `codegraph_explore` now sizes its response to the *answer* instead of the file count: it shows the mechanism and the exact methods you asked about in full — even when they're buried deep in a large file — while collapsing the redundant interchangeable implementations of an interface (an HTTP interceptor chain, a query-compiler family) down to signatures. Fewer tokens for a more complete answer, so on the flows that used to occasionally cost more than plain grep/read it's now clearly cheaper — and the win holds across small, medium, and large codebases. Distinct, non-interchangeable code is shown in full as before. Disable with `CODEGRAPH_ADAPTIVE_EXPLORE=0`.
- Swift deferred-validation flows (and similar "handler array" patterns) now connect end-to-end in `codegraph_trace` and `codegraph_explore` — following a request's lifecycle reaches the validators registered with `.validate { … }` instead of dead-ending where the framework runs them by iterating a stored list of closures. Any pattern where closures are appended to a collection and later invoked by looping over it is now traced.
- `codegraph_explore` now spells out the dynamic-dispatch relationships of the symbols you ask about — e.g. "the closures registered here are run by `didCompleteTask`" — so the indirect hops you'd otherwise grep to reconstruct are listed alongside the call flow.
- `codegraph_explore` answers multi-phase questions that span a large "god file" far more completely. For a flow like "build, send, and validate a request" — where one big file holds the build chain and the validate logic lives in others — it now keeps every method *on the flow path* in full, collapses the file's off-path methods to one-line signatures, and guarantees each phase's defining file is shown (instead of truncating at a fixed size and dropping whichever phase came last, which sent you to read it by hand). Incidental files that merely name-drop the flow are still trimmed, so the response stays focused on the code that answers the question.
- CodeGraph is usable as an embedded library again: `require("@colbymchenry/codegraph")` and `import` now resolve the programmatic API — the `CodeGraph` class plus building blocks like `DatabaseConnection`, `QueryBuilder`, `initGrammars`, and `FileLock` — so you can drive the graph directly from your own app (for example an Electron process) instead of only through the CLI or MCP server. Embedding runs on your own runtime, so it needs Node 22.5+ for the built-in SQLite. (#354)

### Fixes

- `codegraph_trace` now resolves an overloaded symbol name to its real implementation instead of an empty protocol/delegate stub. Tracing a flow through a heavily-overloaded API (common in Swift, Java, C#, and Go) could land on an unrelated no-op method that happened to share the name and report "no path"; it now picks the substantive definition the flow actually runs through.
- CodeGraph's MCP server now answers an agent's opening handshake the instant it launches instead of blocking while the index loads, so a fresh session's very first tool call no longer occasionally races a server that's still warming up and falls back to grep/read. The first question in a new session now reliably goes through CodeGraph.
- Indexing a project that contains only config-style files (YAML, Twig, or `.properties`) no longer misleadingly reports "No files found to index" — these files are tracked at the file level and are now counted as indexed. Thanks @luojiyin1987 (#357).

## [0.9.7] - 2026-05-28

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
- **GitHub Copilot support** — `codegraph install` now configures two new agent targets out of the box:
  - **`copilot-vscode`** (project-local): writes `./.vscode/mcp.json` with the VS Code MCP shape (top-level `servers` key) and a marker-delimited section in `./.github/copilot-instructions.md`. JSONC-aware via `jsonc-parser`.
  - **`copilot-cli`** (global only): writes `~/.copilot/mcp-config.json` with the CLI's `mcpServers` shape, plus an explicit `tools` allowlist.
- The installer no longer writes a duplicate `## CodeGraph` instructions block into your agent's instructions file (`CLAUDE.md`, `AGENTS.md`, `GEMINI.md`, Cursor's `.cursor/rules/codegraph.mdc`, or Kiro's steering doc) — the MCP server is now the single source of truth, and re-running `codegraph install` or `codegraph uninstall` strips a block a previous version left behind (#529). If you added your own notes inside the `CODEGRAPH_START`/`CODEGRAPH_END` markers, move them outside the markers first, since the whole marked block is removed.

### Fixes

- MCP tools no longer return results for files that were deleted while no server was running — the first query of a session now waits for the catch-up sync, so you get the correct index instead of stale rows.
- Windows: black console windows no longer flash on every file save or MCP reconnect (#485, #510, #530).
- `codegraph index` and `init -i` now report the true edge count in their summary, instead of undercounting by missing resolution and synthesizer edges.

