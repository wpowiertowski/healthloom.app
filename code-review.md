# Code review rules & hints

Durable rules distilled from the WP-27/WP-28 review rounds. Read this before
reviewing — or writing — coach/sync/store code in this repo.

## 1. Severity & verdict

- Mark every finding **blocker / high / medium / low / nit**, and say *when*
  it bites (now vs "latent until X goes live"). A latent bug with a named
  gate is high, not a blocker — don't hold the WP for it, but name the WP
  that must fix it.
- End with a verdict + a **gated checklist** for the next WP. Reviews that
  only list problems without saying what ships are unactionable.

## 2. Verify, don't just read

- `swift build` + the scoped `swift test --filter` for touched suites.
  Record pass counts (stable vs beta toolchain — 2 tests need the 27 SDK).
- Grep the claim: "never constructed" → grep for constructors; "no callers"
  → grep for call sites; "character-identical" → diff the bodies.
- Read the collaborators, not just the diff: factory, assembler, prompt
  manager, gate, secret keys, view-model call sites, prior test doubles.

## 3. Spec compliance table

Every review gets one: each architecture/plan decision (D9/D10/D11/D14/D15,
the WP's "Tests" line) → ✅ / ⚠️ / ⏳ with the file:line. Deferred scope is
fine if the plan says so — verify the deferral, don't just accept it.

## 4. Recurring bug shapes (check each one explicitly)

1. **Tier-blind code.** Any function taking `tier` must use it for: session
   cache key, token budget, escalation flag, error mapping. A `tier` param
   that isn't forwarded is the bug until proven otherwise.
2. **Gate-then-dispatch TOCTOU.** Every gate (`isEnabled`) needs a
   defense-in-depth re-check before dispatch (`missingCredential`). Test
   with a flaky seam (true once, then false), not just static false.
3. **Literal drift.** UI copy in ≥2 places must be one constant; tests assert
   *which* blocker (the constant), never re-type the string. `makeModel`
   throw reasons and `availability` reasons are the classic pair.
4. **Prompt-injection framing.** The "data, not instructions" sentence and
   composer must be single-sourced (`HealthContext.promptBlock`). A tightening
   that edits N−1 of N call sites ships a hole.
5. **Redaction at construction, not convention.** Error payloads are
   sanitized (single-line, bounded) where built — including `@unknown
   default` arms, which carry the *most* unreviewed text. "The render site
   will redact" is not a guarantee.
6. **Cache keys.** Same prompt + different tier / tools / instructions must
   not share a session. Every cache dimension needs a busting test.
7. **API defaults that lie.** A default budget/model/gate tuned for one tier
   silently degrades the others — tier-owned values, caller override only
   for tests.
8. **`public var` on shared collaborators.** Use `let`/`private(set)`; tests
   build fresh instances instead of mutating.

## 5. Test-value rules (fold, don't just delete)

- A test that transcribes a `switch` body (getter echoes, constant pins)
  has no behavioral signal — keep only rows with behavioral weight
  (namespaces, counts, key/consent contracts).
- A test of the **double** (chunks join, `"Boom"` interpolates) is seam
  smoke, not functional coverage. Don't count it; don't delete the one
  that proves the seam compiles.
- Duplicated propositions across two tests (truth-table row ≡ dedicated
  test) → keep one, point at it from the other.
- Copy-presence tests (`!isEmpty`) fail on any edit and pass on garbage —
  replace with golden snapshots or drop; keep the adversarial one
  (e.g. "neutral case names no cause").
- One shared scripted double per target (`failure` field beats bespoke
  fakes). New providers get variants of it, not new types.
- Force-indexes (`sessions[0]`) crash instead of failing — `guard let` +
  `Issue.record` like the sibling tests.

## 6. Optimization lens (MainActor hot path first)

- Count per-turn `JSONEncoder` constructions; share one encoder; cache
  values keyed by (locale, unitSystem, day), not by turn.
- Cheap checks (phrase match, quota read) before expensive ones (fetch,
  trim, serialize, insert). Don't persist snapshots for turns that never
  ran — unless trace linkage requires it (then say so).
- Substring phrase sets: one case-insensitive pass (`range(of:options:)` —
  never `lowercased().contains`, it mis-folds Turkic İ); word boundaries
  when the set grows past ~10.

## 7. residuals & nits worth filing

- Off-by-one between doc ("300 chars") and impl (`prefix(300) + "…"` =
  301). Align doc or clamp.
- Arity growth on enum payloads (`.reply` 2→3→4): third associated value
  is the signal to switch to a struct.
- Cross-file test helpers (`StubTool` defined in file A, used in file B)
  belong in shared test support next time tests are touched.
- Build-discipline moves (warnings-as-errors scope) must document what
  lost coverage in exchange.

## 8. Review workflow

1. `git log` + `git status` + diffstat first — know what "current changes"
   means (branch vs base) before reading.
2. Full-diff read, then collaborator read, then spec check, then build,
   then tests. In that order.
3. File findings in markdown: Part 1 (correctness/spec), Part 2
   (redundancy/mock-only/optimization) on request, Part 3+ (re-reviews
   verify each prior item ✅/⚠️ and list only new/residual findings).
4. Findings files live outside the repo (`/tmp/`) unless asked to track
   them. This rules file is the exception — it stays in the repo.
