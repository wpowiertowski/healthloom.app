# AGENTS.md — HealthLoom agent rules

Binding on every agent working in this repo (coder, reviewer, coordinator).
Violations hold the merge. `code-review.md` is the normative review spec;
this file is its enforceable distillate plus build policy.

## 1. Build strictness — warnings are errors, everywhere, with zero warnings

1. **All warnings are promoted to errors on every lane, no carve-outs:**
   `SWIFT_TREAT_WARNINGS_AS_ERRORS=YES` + `GCC_TREAT_WARNINGS_AS_ERRORS=YES`
   per first-party target in `project.yml` (covers Xcode-GUI builds),
   on the `make test` xcodebuild command line, in the CI app job, and
   `-Xswiftc -warnings-as-errors` on every per-package `swift test` run
   (local `Makefile`, CI package jobs).
2. **Builds and tests must be error- AND warning-free.** A green suite with
   a warning in the log is red. Prove it: `grep 'warning:'` on the build
   log returns zero compiler warnings before reporting done.
3. **Third-party warnings are fixed at the source, never suppressed around.**
   If a remote SPM dependency emits warnings under our toolchain, the fix
   is upgrading to a warning-free release, patching, or removing the
   dependency (e.g. WP-33: `swift-snapshot-testing` 1.19.4 — newest upstream
   — carried iOS-15 deprecations, so it was replaced with a local snapshot
   helper). No warning-suppression flag rides anywhere: with zero remote
   SPM dependencies there is nothing to suppress, and the planted-warning
   probe (unused `let` in a local package → build exit 65 naming the file)
   proves local-package iOS warnings surface and promote. If a remote
   dependency ever returns, its warnings stay visible — never silently
   suppressed — and a warning there holds the merge until fixed at the
   source per this rule. Never narrow strictness to make a dependency pass.
4. **Keep the scopes in sync.** `Makefile`, `project.yml` (base note +
   per-target flags), and `.github/workflows/ci.yml` must describe the same
   policy. A change to one is a change to all three, with comments rewritten
   — never a stale rationale paragraph left behind.

## 2. Design rules (from `code-review.md` §4 + §7)

- **One source of truth.** Constants, UI copy, predicates, framing
  sentences: one definition, referenced everywhere. Tests assert *which*
  constant, never re-type the string.
- **Structural over conventional.** If correctness needs every caller to
  remember something, move it into the type/constructor. Sanitize in the
  error's `init`; carry dimensions (tier, tools, locale) in signatures.
- **Make invalid states unrepresentable.** Enum over boolean pairs;
  `let` / `private(set)` over `public var` on shared collaborators;
  exhaustive `switch` with deliberate `@unknown default`.
- **Narrow the surface.** `internal` by default; `public` only with an
  out-of-module caller. Every `public` is a promise to keep.
- **Seams at I/O boundaries only** (network, health store, keychain, clock,
  sleeper, model provider). Never protocol a pure value type to mock it.
- **Pure core, thin adapters.** Decision logic is pure and exhaustively
  tested; framework adapters stay thin and documented where untestable.
- **Repo bug shapes — check each explicitly:** tier-blind code (unforwarded
  `tier` is the bug until proven otherwise); gate-then-dispatch TOCTOU
  (re-check at dispatch, true-once seam); literal drift; prompt-injection
  framing single-sourced; redaction at construction incl. `@unknown
  default`; cache keys with a dimension per axis + busting tests; tier-owned
  defaults; no `public var` on shared collaborators (§7.1). MainActor hot
  paths: one shared encoder, cheap checks first, caches keyed by the real
  key (§7.3).

## 3. Review rules — `code-review.md` is binding

Every review strictly abides by `code-review.md`:

- **Findings are verified claims** — `file:line` + failure scenario
  (input/state → wrong output) + severity + smallest fix with effort.
  Unconfirmed items are marked **plausible**, never confirmed. Rank by
  severity; cut the rest (§1).
- **Verify, don't read** — build + run the touched suites on the reviewed
  HEAD (record counts per toolchain), grep every claim, read collaborators
  not just the diff, treat summaries as intent, mutation-check each new
  test (§2). Never review from memory of a stale tree.
- **Tests get one line each** — *"catches: ‹the production bug›"*; fold
  what you can't justify. Check doubles for semantics (not canned data),
  duplication, and failure paths. Report counts split
  functional / seam-smoke / pins (§5). Smells in §5.1 hold no coverage
  credit (mock-echo, transcription, presence, happy-path-only, `!`/`[0]`
  in tests — Swift Testing uses `#expect`, `guard let` + `Issue.record`).
- **Write-up** — verdict up top, what the round gets right, findings as
  `### Fn. [SEVERITY — effort]`, spec-compliance table (every touched
  plan/architecture decision → ✅/⚠️/⏳ with `file:line`), gated checklist
  for next steps (§6). Severity scale: blocker / high / medium / low / nit.
- **Re-reviews** verify every prior item ✅/⚠️/❌ in a table, then list only
  new/residual findings; decisions recorded inline (`> Decided:`). An item
  surviving two fix rounds untouched is promoted, not repeated (§6).
- **Tone:** specific, unhedged. Wrong is wrong; right is right; guesses are
  labeled.

## 4. Workflow

1. One work package per branch, scoped to its named modules; progress notes
   appended to `progress.md` per the handoff protocol.
2. Coordinator loop per step: dispatch to coder → thorough review →
   findings back to coder for fixes → second review → PR → monitor CI to
   green → merge → next phase. `re` is echoed on every agent reply.
3. Findings live in `reviews/<wp>-review.md` (gitignored working notes);
   review files are committed only when asked. This file (`AGENTS.md`) and
   `code-review.md` stay in the repo.
4. Review state first (`git log` + `status` + diffstat) before reading code
   (§7.4): full-diff → collaborator read → spec check → build → tests.
