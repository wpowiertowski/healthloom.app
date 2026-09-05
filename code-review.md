# Code review guidelines

A review exists to find three things: what will break, what will rot, and
what the tests don't actually prove. Everything else — formatting, naming
taste, "I'd have done it differently" — is secondary and mostly a tooling
problem. Read this before reviewing *or writing* code in this repo. §1–§6
are general; §7 is the repo-specific distillate from the WP-27/WP-28 rounds.

## 1. What counts as a finding

A finding is a **claim you have verified**, with four parts:

1. **Location** — `file:line`, not "the orchestrator".
2. **Failure scenario** — concrete input or state → wrong output, crash,
   leak, or silent degradation. "This could be a problem" is not a finding.
3. **Severity + when it bites** — now, or latent until a named gate goes
   live (see §6).
4. **Fix** — the smallest change that closes it, with an effort estimate.

Not findings: restating the diff; preferences a linter doesn't enforce;
alternatives with no failure scenario; anything you haven't grepped, built,
or run to confirm. A review with twenty nits and one buried blocker is worse
than a review with one blocker. Rank by severity, cut the rest, and mark
anything you could not confirm as **plausible**, not **confirmed**.

Always say what ships. A review that lists problems without a verdict and
a gated checklist for the next step is unactionable.

## 2. Verify, don't read

- **Build and run.** `swift build`, then the scoped `swift test --filter`
  for every touched suite. Record pass counts and which toolchain.
- **Grep every claim** — yours and the author's. "Never constructed" → grep
  constructors. "No callers" → grep call sites. "Identical" → diff bodies.
  "Fixed" → re-grep the *reviewed HEAD*, not your memory of it (a stale
  tree has produced both false "still open" and false "fixed" verdicts).
- **Read the collaborators, not just the diff.** The bug is usually in the
  interaction: the factory that builds the thing, the gate in front of it,
  the call site that forgets a parameter, the prior test double it should
  have reused. A diff is where the change is; the failure is where the
  change is *consumed*.
- **Treat summaries as intent, not fact.** Commit messages, PR bodies, and
  agent write-ups describe what the author meant to do. Review the code.
- **Mutation check the tests.** For each new test, mentally (or actually)
  break the line it guards. If the test stays green, it isn't coverage.

## 3. Where real bugs live

Check each shape explicitly. These are the ones that survive a green build
and a passing suite.

### 3.1 Data flow

- A parameter accepted but not forwarded (`tier` taken, never used for the
  cache key / budget / error map). Until proven otherwise, this is the bug.
- Defaults that lie: a default tuned for one caller silently degrades the
  others. Defaults belong to the domain object; callers override only in
  tests.
- Cache keys missing a dimension. Same input + different tier / tools /
  instructions / locale sharing an entry.
- N−1 of N call sites updated. A tightening that isn't single-sourced is a
  hole at the one site the diff didn't touch.

### 3.2 Boundaries

- Empty, one, many. Zero, negative, max. First and last element. `nil`.
- Off-by-one between doc and impl (`prefix(300) + "…"` is 301).
- Locale-sensitive string ops (`lowercased().contains` mis-folds Turkic İ;
  use `range(of:options:)` with `.caseInsensitive`).
- Unbounded input reaching a bounded sink (log line, error payload, prompt).

### 3.3 State and time

- Check-then-act (TOCTOU). A gate needs a re-check at dispatch, tested with
  a true-once seam, not a static `false`.
- Retries that aren't idempotent; re-entrancy on a MainActor path; ordering
  assumptions on concurrent completions.
- Cancellation: does a cancelled `Task` leave partial state? Is the
  cancellation propagated or swallowed?
- Real clocks and `Date()` in logic that should take an injected clock.
  DST, timezone, and "day" boundaries are where health data goes wrong.

### 3.4 Concurrency (Swift)

- `@unchecked Sendable` on anything with mutable state — who guarantees it?
- Actor isolation crossings that copy stale snapshots; `nonisolated`
  closures that assume MainActor context.
- Detached tasks losing task-local values, cancellation, or priority.

### 3.5 Error handling

- `try?` and `catch { }` that discard the cause. Errors mapped once, at the
  boundary, keeping the original.
- Catch-all arms (`default`, `@unknown default`) that carry the *least*
  reviewed text and are therefore the most likely to leak raw payloads.
- Redaction/sanitization at construction, not by convention. "The render
  site will redact" is not a guarantee; the next render site won't.

### 3.6 Security and privacy

- Secrets or PII in logs, error strings, or analytics. Keychain reads that
  land in a struct that's later `String(describing:)`'d.
- Model-facing content: user data framed as data, not instructions, from
  one composer. Any second framing is an injection surface.
- Public API wider than its callers (`public var`, `public init` on a type
  that should be built by one factory).

### 3.7 Resources and hot paths

- Per-call allocation of expensive objects (`JSONEncoder`, formatters,
  regexes) inside a loop or a per-turn path.
- Expensive work before cheap rejection (fetch → trim → serialize → *then*
  check the quota).
- Unbounded growth: arrays that only append, caches without eviction,
  observers never removed.

### 3.8 Spec compliance

- Does it do what the plan says, and only that? Deferrals are fine when the
  plan names them — verify the deferral, don't accept it.

## 4. Durable, reusable code — what to push authors toward

Reviews shape the next diff more than they fix this one. Direct authors
toward code that stays correct when the next person touches it.

- **One source of truth.** Constants, UI copy, predicates, framing
  sentences: one definition, referenced everywhere. If a rule is enforced in
  two places it's enforced in neither. Tests assert *which* constant, never
  re-type the string.
- **Structural over conventional.** If correctness depends on every caller
  remembering to do something, move it into the type or the constructor.
  Sanitize in the error's `init`; carry the tier in the error mapping's
  signature; make the flag a field, not a post-adjustment at the catch site.
- **Make invalid states unrepresentable.** Enum over boolean pairs; struct
  over a growing tuple (the third associated value on a `case` is the
  signal); `let` / `private(set)` over `public var` on shared collaborators.
  Exhaustive `switch` with a *deliberate* `@unknown default`.
- **Narrow the surface.** `internal` by default; `public` only with a
  caller outside the module. Every `public` is a promise to keep.
- **Seams at I/O boundaries only.** Protocol the network, the health store,
  the keychain, the clock, the sleeper, the model provider. Do not protocol
  a pure value type or a formatter so it can be mocked — test it directly.
  Seam width = what a test must script, no wider.
- **Pure core, thin adapters.** Decision logic (quota tables, error maps,
  conflict resolution, budget trimming) is pure and exhaustively testable.
  Framework adapters with no public init on the framework side stay thin
  and are documented as untestable-here.
- **Generalize on the second real use, not the first imagined one.** Three
  similar lines beat a premature abstraction. A third copy is the signal to
  extract — and the extraction goes next to the existing helper, found by
  grep before it's written.
- **Comment the why and the constraint.** A header that cites the plan item
  and explains why the mock implements semantics instead of passing
  predicates through is a model. A comment that restates the code is noise.
- **Reuse the existing double.** One shared scripted double per boundary,
  with a `failure` / `handler` field. New providers get a variant, not a
  new type. Cross-file test helpers move to shared support on the next
  touch.
- **Performance is durability.** MainActor hot paths get one shared
  encoder, cheap checks first, and caches keyed by the real key (locale,
  unit system, day) — not by turn.

## 5. Tests: functional coverage vs mock theatre

The only question that matters: **if the production code were wrong in the
way this test claims to guard, would the test fail?** The corollary: **if
the mock were wrong, would anything fail?** A suite where the second answer
is "no" has no floor under it.

### 5.1 Smells — and what to do about each

1. **Testing the double.** Asserting that chunks join, that `"Boom"`
   interpolates, that the stub returns what it was told. This is seam
   smoke: keep *one* to prove the seam compiles; don't count the rest as
   coverage.
2. **Mock-echo.** Mock returns X, code passes X through, test asserts X.
   Proves plumbing, not logic. Replace with a case where the code must
   *transform* or *decide* on X.
3. **Interaction-only assertions.** "Called once with args" where the
   outcome is observable. Assert the outcome. Interaction counts are
   legitimate only when the count *is* the contract — exactly one refresh
   call, one `save` per batch not per sample, delete targets only the
   requested IDs.
4. **Canned mocks with no semantics.** A store that returns the same page
   regardless of query passes with broken pagination, broken date windows,
   broken dedupe. Doubles at a boundary implement the *semantics* the code
   under test relies on (date-window overlap, metadata-key presence,
   N-th-call scripting) — or the test isn't testing the query.
5. **Over-mocking.** Mocking a value type, a formatter, a pure function, or
   the class under test's own sibling. Mock only at I/O: network, disk,
   HealthKit, keychain, clock, randomness, model provider. Everything
   inside that ring runs for real.
6. **Transcription tests.** `#expect(defaultModel == .sonnet5)`; a test
   that echoes a `switch`. Fails only if someone changes the constant to
   another valid value — tests itself. Keep as a *deliberate-change pin*
   with a comment saying so, or drop.
7. **Presence tests.** `!isEmpty`, `!= nil`, `count > 0`. Fail on any edit,
   pass on garbage. Replace with a golden snapshot plus one adversarial
   case ("neutral input names no cause").
8. **Happy path only.** No failure arm, no empty input, no cancellation.
   Every scripted double has a failure field; the failure test asserts the
   *mapped* error, not merely "throws".
9. **Static seams for dynamic bugs.** A gate re-check tested with `false`
   from the start. TOCTOU needs true-then-false.
10. **Force-unwrap / force-index in tests.** `sessions[0]` crashes the
    suite instead of failing the test. `guard let` + `Issue.record`.
11. **Structure-mirroring tests.** One test per private method; a refactor
    with no behaviour change goes red in twenty places. Test through the
    public surface; the suite should survive an internal rewrite.
12. **Duplicated propositions.** A truth-table row that is also a dedicated
    test. Keep one; point at it from the other.
13. **Vendor mocks with no fixture from reality.** A hand-written mock of a
    third-party API drifts from the real shape and nobody notices. At
    least one fixture captured from a real response, pinned.
14. **Real time.** `sleep`, `Date()`, wall-clock timeouts. Inject a clock
    and a sleeper; assert the *requested* delay, not elapsed time.
15. **Coverage-number tests.** Exists to hit a percentage; asserts nothing
    a mutation would catch. Delete.

### 5.2 What a good test looks like

- **Real inside, scripted at the edge.** Real value types, real decision
  logic, real orchestration; the double only stands in for the I/O.
- **Observable outcome.** Return value, persisted state, or the exact
  encoding of a recorded request — not "the method was invoked".
- **Names the proposition.** `cloudNeverEscalates`,
  `exhaustedQuotaFallsBackToOnDevice` — behaviour, not method name.
- **One reason to fail.** Flip the guard in prod and *this* test goes red,
  alone. Whole-value asserts (`info == TurnInfo()`) over per-flag noise.
- **Both toolchains accounted for.** A test that needs the beta SDK says
  so and is counted separately.

### 5.3 Reviewer procedure for tests

For each **new test**, write one line: *"catches: ‹the production bug›"*.
If you can't, mark it for folding. For each **new double**: does it
implement semantics or return canned data? Is it a duplicate of an existing
double? Does it have a failure path? For the **suite count**: report
functional tests, seam-smoke, and pins as three numbers. "179 passing"
means nothing if forty of them test the mock.

## 6. Severity, write-up, verdict

| Level | Meaning |
| --- | --- |
| **blocker** | Wrong now, user-visible or data-corrupting. Holds the merge. |
| **high** | Wrong, but latent until a named gate goes live. Name the WP that must fix it. |
| **medium** | Structural risk: works today, the next caller gets it wrong with no compiler hint. |
| **low** | Missing pin, arity growth, doc/impl drift. Fix on next touch. |
| **nit** | Log only. |

**Finding format:** `### Fn. [SEVERITY — effort] title`, then location,
failure scenario, fix. Effort in lines or minutes, honestly.

**Every review has:**

1. Range, method (build ✅, tests N/N per toolchain, grep-verified), and a
   one-line verdict up top.
2. **What this round gets right** — tells the author what to keep doing;
   as important as the findings.
3. Findings, most severe first.
4. **Spec compliance table** — every architecture/plan decision the WP
   touches → ✅ / ⚠️ / ⏳ with `file:line`.
5. Verdict + **gated checklist** for the next WP.

**Re-reviews:** verify every prior item ✅ / ⚠️ / ❌ in a table, then list
only new or residual findings. Record decisions inline (`> Decided:`,
`> Fixed (round 2):`) so the file is the audit trail. An item that survives
two fix rounds untouched gets promoted, not repeated.

**Tone:** specific, unhedged, no softening. If it's wrong say wrong; if it's
right say right. Say when you're guessing.

## 7. This repo — distilled from WP-27/WP-28

### 7.1 Recurring bug shapes (check each one)

1. **Tier-blind code.** Any function taking `tier` must use it for: session
   cache key, token budget, escalation flag, error mapping. Unforwarded
   `tier` is the bug until proven otherwise.
2. **Gate-then-dispatch TOCTOU.** Every gate (`isEnabled`) needs a
   defense-in-depth re-check before dispatch (`missingCredential`). Test
   with a flaky seam (`FlakyKey`: true once, then false).
3. **Literal drift.** UI copy in ≥2 places is one constant
   (`TierAvailability.notLive`). `makeModel` throw reasons and
   `availability` reasons are the classic pair.
4. **Prompt-injection framing.** The "data, not instructions" sentence and
   composer are single-sourced in `HealthContext.promptBlock`.
5. **Redaction at construction.** Error payloads sanitized where built —
   `sanitizedSummary` on every arm including `@unknown default`.
6. **Cache keys.** Same prompt + different tier / tools / instructions must
   not share a session. Every cache dimension has a busting test.
7. **API defaults that lie.** Budget/model/gate values are tier-owned;
   caller override only for tests.
8. **`public var` on shared collaborators.** `let` / `private(set)`; tests
   build fresh instances instead of mutating.

### 7.2 Test conventions

- Swift Testing: `#expect`, `guard let` + `Issue.record`, never `!`/`[0]`.
- One shared scripted double per boundary: `RecordingHTTPSession`
  (handler closure + recorded requests), `MockHealthStore` (in-memory with
  real query semantics + per-method error fields), `RecordingSleeper`,
  `FakeTokenStore`. Variants, not new types.
- `liveTiers` flips provider rows in tests without real providers.
- Two tests need the 27 SDK; count them separately (stable vs beta).
- Test helpers used across files (`StubTool`) live beside their call sites
  or in shared support — not in an unrelated test file.

### 7.3 Optimization lens (MainActor hot path first)

- Count per-turn `JSONEncoder` constructions; share one; cache by
  (locale, unitSystem, day).
- Cheap checks (phrase match, quota read) before expensive ones (fetch,
  trim, serialize, insert). Don't persist snapshots for turns that never
  ran — unless trace linkage requires it (say so).
- Phrase sets: one case-insensitive `range(of:options:)` pass; word
  boundaries once the set passes ~10 entries.

### 7.4 Workflow

1. `git log` + `git status` + diffstat first — know what "current changes"
   means (branch vs base) before reading.
2. Full-diff read → collaborator read → spec check → build → tests. In that
   order.
3. Findings go to `reviews/<wp>-review.md`; Part 1 correctness/spec, Part 2
   redundancy/mock-only/optimization on request, Part 3+ re-review tables.
   Commit review files only when asked. This rules file stays in the repo.
