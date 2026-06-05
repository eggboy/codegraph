# Changelog

All notable changes to CodeGraph are documented here. Each entry also ships as
a [GitHub Release](https://github.com/colbymchenry/codegraph/releases) tagged
`vX.Y.Z`, which is where most people will look.

This project follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/)
and adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added
- **GitHub Copilot support** — `codegraph install` now configures two new
  agent targets out of the box:
  - **`copilot-vscode`** (project-local): writes `./.vscode/mcp.json` with the
    VS Code MCP shape (top-level `servers` key) and a marker-delimited section
    in `./.github/copilot-instructions.md`. JSONC-aware via `jsonc-parser`.
  - **`copilot-cli`** (global only): writes `~/.copilot/mcp-config.json`
    with the CLI's `mcpServers` shape, plus an explicit `tools` allowlist.


## [0.9.7] - 2026-05-28

### Added
- **Generated-file down-ranking across search, trace, and explore.** A new
  filename-based classifier (`src/extraction/generated-detection.ts`) flags
  protobuf / gRPC / mockgen / build-output files (`.pb.go`, `.pulsar.go`,
  `_grpc.pb.go`, `_mock.go`, `_mocks.go`, `mock_*.go`, `.generated.[jt]sx`,
  `_pb2(_grpc)?.py`, `.pb.{cc,h}`, `.g.dart`, `.freezed.dart`) and pushes them
  LAST in disambiguation. Before this, a `codegraph_search "Send"` on
  cosmos-sdk returned the gRPC interface stub at `tx_grpc.pb.go:124` as the
  first match — the trace landed on that empty stub, reported "no path", and
  the agent fell back to Read. With the down-rank applied to `findSymbol`,
  `findAllSymbols`, `codegraph_search`, the CLI `query` command, AND the
  context Entry Points / Related Symbols / Code blocks, the bank keeper's
  `msgServer.Send` (the real implementation) ranks #3 instead of #9 and
  trace lands on it directly. Pure path-based classifier — no schema change,
  no index migration.
- **gRPC interface→implementation bridge for Go.** New synthesizer
  `goGrpcStubImplEdges` in `src/resolution/callback-synthesizer.ts` finds
  `UnimplementedXxxServer` structs in `.pb.go` / `_grpc.pb.go` files,
  identifies their RPC-method signatures (excluding the `mustEmbed*` /
  `testEmbeddedByValue` gRPC markers), and links each stub method to the
  hand-written impl method on any struct whose method-name set is a
  superset. Closes Go's structural-typing gap that the Java/Kotlin-only
  `interfaceOverrideEdges` couldn't bridge. Excludes other generated files
  from candidate impls so a sibling `msgClient` in the same `.pb.go` doesn't
  get falsely paired. Measured on cosmos-sdk: 467 stub→impl `calls` edges
  synthesized, bank's `UnimplementedMsgServer::Send` now points only to
  `x/bank/keeper/msg_server.go::msgServer::Send` — not to mocks, not to
  client wrappers.
- **Trace-failure response now inlines both endpoints' bodies + neighbors.**
  When `codegraph_trace` can't find a static call path (typically a
  dynamic-dispatch break), it used to return a one-liner telling the agent
  to call `codegraph_node` next — which triggered 3-4 follow-up calls plus a
  Read. The new failure response inlines each endpoint's source (capped at
  120 lines / 3600 chars), callers, and callees in one response. On the
  cosmos-Q3 / etcd-Q2 audits this eliminated the entire fan-out pattern
  (5-11 codegraph calls collapsed into 1-2).
- **Path-proximity pairing in trace endpoint selection.** In a multi-module
  Go repo, a symbol like `EndBlocker` exists in 20+ modules; FTS picks one
  almost arbitrarily. Trace now scores every `from` × `to` candidate pair by
  shared directory prefix length (longest match wins) so
  `x/gov/abci.go::EndBlocker` + `x/gov/keeper/tally.go::Tally` are paired
  before `simapp/app.go`'s wrapper EndBlocker is even considered. A
  less-canonical-path penalty (`enterprise/`, `contrib/`, `examples/`,
  `vendor/`, `third_party/`, `deprecated/`, `legacy/`) ensures a side-module
  with a longer shared prefix doesn't beat the canonical module with a
  shorter one. FindPath probe budget capped at 20 pairs.
- **Test-file deprioritization in `codegraph_explore`.** Existing
  `isLowValue` only caught directory-style patterns (`/tests/`, `/spec/`);
  now also catches Go's `_test.go`, Ruby's `_spec.rb`, JS/TS `.test.ts` /
  `.spec.tsx`, and Java/Kotlin/Scala `*Test.java` / `*Spec.kt`. Without
  this, etcd's `watchable_store_test.go` consumed 5K chars of explore
  budget that should have gone to the hand-written flow source.
- **Small-repo retrieval tuning (`<500` indexed files).** Three coordinated
  changes so small projects resolve flow questions in 1-2 MCP calls instead
  of 3-5. (i) MCP tool surface drops to the 5 core tools
  (`codegraph_search` / `codegraph_context` / `codegraph_node` /
  `codegraph_explore` / `codegraph_trace`); the other 5 (`codegraph_callers`
  /`codegraph_callees`/`codegraph_impact`/`codegraph_status`/`codegraph_files`)
  cost more in tool-list overhead than they recoup at this scale.
  Empirically validated as the floor — n=2 audits showed cutting below
  5 regresses cobra/ky/sinatra (3-tool gate) and catastrophically regresses
  express (1-tool gate, +107% LOSS). (ii) `codegraph_context` responses end
  with a strong directive telling the agent the response IS the
  comprehensive pass for a project this size and follow-ups should be
  narrow (`trace from→to`, single-symbol `node`) — not another broad
  `codegraph_explore` that re-bundles the same content. (iii) Explore
  output budget gets a sub-150 tier (13K total / 4 files / 3.8K each,
  Relationships section dropped, test/spec/icon/i18n files hard-excluded
  from the relevant-file set unless the query is about tests), and
  `codegraph_context` `maxNodes` defaults to 8 instead of 20.
- **`codegraph_context` auto-traces flow queries.** When the task reads
  like "how does X reach Y", "trace the path from A to B", or "how does
  X propagate through Z", `codegraph_context` now runs the trace
  internally and splices its body into the response. Detection is
  conservative — needs a flow keyword AND ≥2 distinct PascalCase /
  camelCase identifiers, with the first two ordered by appearance taken
  as `from`/`to`. On dynamic-dispatch breaks it falls back to the
  trace-failure response (which already inlines both endpoint bodies +
  neighbors). Saves the follow-up `codegraph_trace` that was the #2
  cost driver on multi-module flow questions in the audit.
- **Routing-manifest inline in `codegraph_context` for small-repo
  routing queries.** When the task mentions
  routes/handlers/endpoints/middleware/etc. on a sub-500-file project,
  `codegraph_context` now appends a compact URL → handler table built
  from `route` nodes + their `references`/`calls` edges, then inlines
  the full source (≤16KB) of the file holding the most handler
  endpoints. Targets the Glob+Read pattern that was beating codegraph
  on realworld template repos (rails-realworld, laravel-realworld,
  drupal-admintoolbar, …) where the agent would just read `routes.rb` /
  `web.php` instead of asking the graph. Manifest is silently skipped
  when fewer than 3 non-test routes exist or no file holds ≥30% of
  them (no single answer file).
- **Core-directory ranking boost in `codegraph_context` search.**
  Projects with one file holding the dense majority of internal call
  edges (e.g. sinatra's `lib/sinatra/base.rb` at ~85% of all in-file
  edges) now get search results in that file's directory boosted by
  +25 score. Fixes the case where a small extension file with a
  verbatim name match outranks the actual framework core
  (sinatra-contrib's `multi_route.rb` `route` was outranking
  base.rb's `route!`). Test and generated files are excluded from
  "dominant file" candidacy so etcd's `rpc.pb.go` (1916 in-file
  edges, generated protobuf) can't beat the hand-written
  `server/etcdserver/server.go` (470 edges).
- **Interface → implementation synthesis extended beyond JVM.**
  `interfaceOverrideEdges` previously bridged interface methods to
  concrete impls in Java/Kotlin only. Now also runs for C#, TypeScript,
  JavaScript, Swift, and Scala — Swift conformance also iterates
  `struct` nodes (value-type protocol conformance) alongside `class`.
  Closes the same structural-typing gap the new Go gRPC bridge closes,
  for any language where the resolver emits explicit
  `implements`/`extends` edges.
- **Shorter MCP tool descriptions.** All 10 `codegraph_*` tool
  descriptions condensed (typically ~50% shorter), keeping the
  "use this for X / prefer over Y" steering but dropping the longer
  rationale (which lives in `server-instructions.ts`, the
  load-bearing channel). Tool-list bytes on the agent side drop
  proportionally; cumulative across multi-tool sessions.
- **GitHub Copilot support** — `codegraph install` now configures two new
  agent targets out of the box:
  - **`copilot-vscode`** (project-local): writes `./.vscode/mcp.json` with the
    VS Code MCP shape (top-level `servers` key) and a marker-delimited section
    in `./.github/copilot-instructions.md`. JSONC-aware via `jsonc-parser`.
  - **`copilot-cli`** (global only): writes `~/.copilot/mcp-config.json`
    with the CLI's `mcpServers` shape, plus an explicit `tools` allowlist.
- **Java / Kotlin imports now resolve by fully-qualified name.** Extraction
  wraps every top-level declaration of a `.kt` / `.java` file in a `namespace`
  node carrying the file's `package` (so a class `Bar` in
  `package com.example.foo` is indexed with qualifiedName
  `com.example.foo::Bar`), and `import com.example.foo.Bar` looks the target
  up through that index — regardless of whether the class lives in `Bar.kt`,
  `Models.kt`, or a top-level function. Disambiguates same-name classes
  across packages (the central failure mode of the previous name-matcher
  fallback in multi-module Spring / Android codebases), works across the
  Java↔Kotlin interop boundary, and lays groundwork for binding-precise
  Dagger2 / Hilt resolution. Wildcard imports (`com.example.*`) still go
  through name-matcher.
- **Java / C# anonymous classes (`new T() { ... }`) are now extracted as
  first-class class nodes with their overrides.** Previously, an anonymous
  subclass returned from a factory or lambda — `return new BaseIter() {
  @Override int separatorStart(int s) { ... } };` — produced only an
  `instantiates` edge: the override methods were invisible to the graph and
  Phase 5.5 interface-impl synthesis had no class to bridge. The anon class
  now lands as `<TypeName$anon@line>` with an `extends` reference to the
  named base/interface, scoped under the enclosing method, and its
  `method_declaration` members become normal method nodes. The interface→impl
  synthesizer then bridges the base's abstract methods to the anonymous
  overrides automatically. Concrete effect on `google/guava` (3,227 .java
  files): 3,608 anonymous classes extracted, +2,534 interface-impl edges
  reach overrides hidden in `new T() { ... }` blocks (including lambda
  bodies). An agent investigating `Splitter.SplittingIterator.separatorStart`
  now sees the four anonymous overrides in its trail without a Read.

### Changed
- **The installer no longer writes a `## CodeGraph` instructions block into
  your agent's instructions file** (`CLAUDE.md`, `AGENTS.md`, `GEMINI.md`,
  Cursor's `.cursor/rules/codegraph.mdc`, or Kiro's steering doc). That block
  duplicated, almost verbatim, the usage guidance the MCP server already
  emits in its `initialize` response — so every agent that surfaces MCP
  instructions (Claude Code does) read the same playbook twice each turn
  (#529). The MCP server instructions are now the single source of truth.
  `codegraph install` stops writing the block, and **the next time you run
  `codegraph install` (or `codegraph uninstall`) it strips a block a previous
  version wrote**, preserving everything else in the file (and deleting Cursor
  `.mdc` / Kiro steering files that were ours outright). Note: simply upgrading
  the npm package does not remove an existing block — re-run the installer to
  clean it up. The leftover block is harmless meanwhile (just redundant with
  the MCP instructions). If you'd added your own notes inside the
  `<!-- CODEGRAPH_START -->`/`<!-- CODEGRAPH_END -->` markers, move them outside
  the markers first — only the marked block is removed.

### Fixed
- **MCP tools no longer return rows for files deleted while no server was
  running.** The post-open catch-up sync that reconciles the index against
  the working tree (catching `git pull`/`checkout`/`rebase` and any edits
  or deletes made between sessions) was fire-and-forget — so a tool call
  that landed in the first ~50–300ms could race past it and serve rows
