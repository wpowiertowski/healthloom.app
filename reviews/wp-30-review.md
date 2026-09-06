# WP-30 review — Knowledge transparency UI ("You" tab), round 1

**Range:** uncommitted work on `wp-30-you-tab` vs `HEAD` (`c06d088`,
WP-29 merge): 9 tracked files + 3 new (`HealthLoomApp/You/`,
`YouViewModelTests`, `YouTabUITests`).
**Method:** full-diff read → collaborator read (`KnowledgeStore`,
`CoachSessionFactory`, `ProfileField`, `ChatTurn`, `ThemedChrome`,
scripted session) → spec check (plan WP-30) → build ✅ → tests (below) →
grep-verified claims.
**Toolchain:** `/Applications/Xcode-beta.app`, iPhone 17 Pro sim
(E0F48175…); CoachKit also on stable (`swift`, 6.3.1).

**Verdict: DO NOT MERGE — 1 high (F1: chat wipe deletes rows but the live
session keeps the transcript).** Small fix with an in-repo precedent;
everything else is mergeable. Gated checklist at the bottom.

## Method / counts

- `xcodegen generate` + `xcodebuild build` (warnings-as-errors): ✅.
- CoachKit `swift test`: ✅ **189/189 beta, 188/188 stable** (delta = 1
  beta-only test; +3 new durability tests).
- `xcodebuild test -only-testing:HealthLoomTests`: ✅ **92/92 in 15 suites**
  (86 + 6 new `YouViewModelTests`).
- `xcodebuild test -only-testing:HealthLoomUITests/YouTabUITests`: ✅
  **4/4**. `-only-testing:HealthLoomUITests/CoachUITests`: ✅ **3/3**
  (incl. new `testTraceExpanderNamesServingTier`).
- Mutation walk (§5.3): all 6 VM tests + 3 store tests fail if their guard
  breaks (checked by reading — e.g. dropping carry-over flips
  `exclusionSurvivesRefresh`; storing pre-validation breaks nothing here,
  but `pinCorrection` writing untrimmed/unstamped text breaks
  `correctionPins`; deleting the `resetConversation`… — n/a, it doesn't
  exist yet, which is F1). 9 functional unit tests, 0 seam-smoke; UI tests
  assert outcomes (toggle value, rendered text, notice count, tier label),
  not interactions.

## What this round gets right

- **The F1 lesson from WP-29 was learned and applied structurally:** every
  `YouViewModel` mutation path assigns a tracked property (`fields` via
  `load()`, `errorMessage`, `notice`) — the round-1 blocker class is absent
  here by construction, and `testToggleOffSticks` passing on an immediate
  read is the empirical receipt.
- **Flag carry-over is the right durable-exclusion design**, with the one
  accepted gap (absent-for-a-cycle resets) documented at *both* the
  mechanism (`performRefresh`) and the contract (`setExcludedFromAI`) —
  plus a test pinning both directions (off survives, on survives).
- **Tests run the real stack:** `toggleOffExcludesFromContext` goes through
  the real `ContextAssembler` (toggle → next context lacks the field is the
  plan's key proposition, proven, not mocked); store tests use the existing
  `MockHealthReadStore` (variant, not a new double) with an injected clock.
- **UI-test craft kept its standard:** stream-end signal is the stop
  button's *disappearance* (the reply text also matches the mid-stream
  draft — the comment says so); `scrubChat` exists because unbounded
  history across runs degrades scroll-to-Nth tests, with the failure mode
  documented; `tapTrailing`/`scrollUntilExists` reused from shared support.
- **Single sources held:** D8 default lives in `ProfileField.init`
  (`excludedFromAI ?? isClinical`) — derivations, seeds, and tests all
  inherit it; correction posture preservation is in `pinCorrection`, not at
  call sites; `resetConversation()` is reused, not reimplemented (which is
  exactly what makes F1 a 10-line fix).
- The `you.screen`-without-`.contain` worry I carried in: **empirically
  moot** — all four UI tests resolve row/toggle/button identifiers fine
  (the ScrollView/VStack composition evidently breaks the collapse the
  row-level `.contain`s guard against). Verified by running, not by reasoning.

## Findings

### F1. [HIGH — ~15 lines + 1 test] `wipeChatHistory` deletes rows but never resets the conversation session — the coach remembers what the UI forgot

Locations: `YouViewModel.wipeChatHistory` (no factory in `Dependencies`);
`CoachSessionFactory.makeSession` (reuses cached conversation while
instructions + toolSetKey match) + `resetConversation()` (explicit close
path, called only from `PromptEditorViewModel.swift:227`).

Failure scenario (production, code-verified mechanism): chat about anything
→ You tab → "Erase chat history" → confirm ("Every message and its
shared-context snapshot is deleted") → return to Coach, keep talking.
`wipeChatHistory` deletes `ChatTurn` + `ContextSnapshot` rows, but the
factory's `cachedConversations[.onDevice]` still holds the full transcript
(wipe changes neither instructions nor toolSetID, the only two bust
conditions), and nothing calls `resetConversation()`. Ask "what did I just
tell you" and the reply comes from the retained session. The confirmation
copy is literally true of rows and misleading about memory — for a
transparency feature, that is the trust-damaging direction. (In-memory
`turns`/`contextCache` in the chat VM self-heal on remount via
`onAppear`; the factory cache does not — it outlives the view model.)

Fix (mirror the established precedent exactly): add `factory:
CoachSessionFactory` to `YouViewModel.Dependencies` (as
`PromptEditorViewModel` already holds it), call
`deps.factory.resetConversation()` after the successful wipe save;
unit test with a scripted-build factory asserting the post-wipe session is
fresh. Note the test seam question while there: factory is concrete —
`PromptEditorViewModel` tests presumably already solved observing resets;
copy that pattern rather than inventing one.

### F2. [LOW — 2 lines, defensive] Trace badge renders "Served by " for an unmapped/empty provider

Location: `CoachChatView.swift` (`ModelTier(rawValue:
turn.provider)?.displayName ?? turn.provider`).

Reachability check (done, downgrades this): `provider` has existed with a
`""` default since P0 but every assistant-turn writer sets it (`send()` →
`"onDevice"` since WP-25; seeds explicit; badge renders for assistant turns
only, and user turns are the `""` ones). So no reachable trigger today —
but the field is a free `String`, and any future missed writer (or legacy
row) renders a trailing "Served by " with no tier. Fix: hide the badge
unless the provider is non-empty (keep the raw-string fallback for
non-empty unknowns — WP-32's stamps stay readable).

### F3. [LOW — 3 lines] `-UITestScrubChat` can wipe the real on-disk transcript

Location: `LaunchConfiguration.scrubChat` (standalone flag) +
`AppEnvironment` (`if scrubChat { scrubChatHistory }`, no container check).

Failure scenario: a developer passes `-UITestScrubChat` without
`-UITestScriptedCoach` on a build with the on-disk store — every `ChatTurn`
+ `ContextSnapshot` is deleted at launch, silently (`try?`). All current
uses pair it with scripted (trace test) or don't need it (in-memory You
seeds), so nothing breaks today; the footgun is the flag working
standalone on a real store. Fix: gate the call on `scriptedCoach`
(`if scrubChat && scriptedCoach`), or fold scrub into the scripted branch —
either keeps every current test green while the flag can never touch a
real transcript.

### F4. [LOW, plausible] Two UI assertions read immediately instead of polling — the WP-29 flake lesson, one green run

Locations: `testToggleOffSticks` (toggle value `"0"`), `testForgetChatWipe`
(notice text) — no `waitForLabel` polling, unlike the WP-29 suite's settle
race handling.

Not observed failing (4/4 green); marked plausible per §1. State→render
crosses an async boundary and these read on arrival. If CI ever flakes
here, the fix is already written in `AIModelsUITests.waitForLabel` — copy
it, don't debug it. No action required to merge.

### Nits (log only)

- N1: `notice` is never cleared (`load()` leaves it) — a wipe confirmation
  still reads under later toggles within one mount. Clear on `load()` or
  accept inline.
- N2: `pinCorrection` trims in both VM and store (harmless duplicate), and
  stamps `asOf: .now` while `refresh(now:)` takes an injected clock —
  testing the stamp is needlessly hard. Accept, or thread `now` through.
- N3: `EmptyReadStore` widened `private → internal` for cross-file reuse —
  the repo convention (WP-29 reviews) is shared support on the next touch;
  this was the next touch and it went the other way. Move, don't widen,
  next time the file is open.

## Spec compliance (plan WP-30)

| Plan item | Verdict | Evidence |
|---|---|---|
| Profile: every field (text, source, as-of, toggle; clinical distinct + default-off) | ✅ | `YouView.profileSection`, D8 via `ProfileField.init`, `testProfileRendersSeededFields` |
| Correct: edit ⇒ pinned override beats re-derivation, persists | ✅ | `pinCorrection` + carry-over-exempt corrections, `correctionPins` + `pinCorrectionBeatsReDerivation` |
| Trace: snapshot + serving tier per message | ✅ | Expander + `chat.context.tier` badge, `testTraceExpanderNamesServingTier` |
| Forget: per-field exclusion (durable) | ✅ | Toggle + `setExcludedFromAI` + carry-over, `toggleOffExcludesFromContext` (real assembler) |
| Forget: global insight reset | ✅ | `resetInsights`, `forgetKeepsProfile` |
| Forget: chat-history wipe | ⚠️ | Rows + snapshots deleted ✅ (`forgetKeepsProfile`, `testForgetChatWipe`); live session retains transcript ❌ → F1 |
| Tests: toggle⇒next-context / correction persists / forget clears / tier badge | ✅ in substance | Key proposition at unit level through the real stack; UI asserts stick/persist/clear/badge |

## Round 2 re-review (2026-09-06 — fix round landed, verified)

**Range delta vs round 1:** factory in `YouViewModel` deps +
`resetConversation()` after successful wipe (F1), badge empty-guard (F2),
scrub gated on `scriptedCoach` (F3), `notice` cleared in `load()` (N1),
new `TestDoubles.swift` shared support incl. moved `TestCoachSession` +
`StreamBoom` (N3), F1 session-identity test.
**Method:** fix-point grep → ordering audit (reset *after* `save` —
session drops only when rows actually deleted ✓) → closed-set re-check on
`.keyEntry` (unchanged) → build ✅ → app unit **93/93** ✅ (92 + F1 test)
→ UI **7/7** ✅ (`YouTabUITests` 4/4 + `CoachUITests` 3/3). CoachKit
untouched since round-1 green runs (189/188) — not re-run, stated reason.

| Prior item | Status | Verification |
|---|---|---|
| F1 high (wipe leaves live session) | ✅ fixed | Precedent mirrored; identity test proves cache-hit then post-wipe freshness; mutation check (drop the reset → red) holds by reading |
| F2 low (empty-provider badge) | ✅ fixed | Guard + fallback policy documented at the site |
| F3 low (scrub footgun) | ✅ fixed | `scrubChat && scriptedCoach`; all current uses pair both or need no scrub |
| F4 low, plausible (unpolled UI reads) | ❌ open | Second green run; still no action to merge — port `waitForLabel` only if CI flakes |
| N1/N2/N3 | ✅/✅(N2 open) | Notice cleared; doubles moved to shared support (more than asked); N2 `.now` seam still open, log-only |

No new findings. The fix round is notable for what it didn't break:
ordering (reset-after-save), closed-set preservation, and moving — not
widening — test doubles per the repo convention the review itself cited.

**Verdict: SHIP IT.** F1–F3 closed with test evidence, suites green
throughout (93 unit, 7 UI this round; 189/188 CoachKit round 1). Spec
table now fully ✅/accepted-deferral. Nothing carried.

---

## Gated checklist for the next step

1. [ ] F1: factory in `YouViewModel` deps + `resetConversation()` on
   successful wipe + unit test (copy the prompt-editor test pattern).
2. [ ] F2/F3 two-liners landed (or explicitly accepted inline).
3. [ ] F4: no action to merge; if CI flakes, port `waitForLabel`.
4. [ ] Re-run: app unit bundle + `YouTabUITests` + `CoachUITests` with
   counts recorded (this round: 92, 4/4, 3/3; CoachKit 189/188).

---

## Round 2 re-review (2026-09-06 — fix round landed, verified)

**Fixes landed:**
- F1: `factory: CoachSessionFactory` in `YouViewModel.Dependencies`
  (mirroring `PromptEditorViewModel`), `resetConversation()` called after
  the successful wipe save; `wipeResetsConversationSession` pins it
  (cached session identical pre-wipe, fresh instance post-wipe, via a
  fresh-per-build scripted factory — the prompt-editor seam pattern).
- F2: badge hidden for empty providers, raw-string fallback kept for
  non-empty unknowns.
- F3: scrub gated on `scrubChat && scriptedCoach` — the flag can never
  touch a real transcript standalone.
- N1: `notice` cleared on `load()`. N3 (from log-only): shared doubles
  moved to `HealthLoomTests/TestDoubles.swift` instead of widened —
  the file was open anyway for the F1 test's factory seam. N2 accepted
  (duplicate trim + wall-clock stamp stay as documented).

**Method:** build ✅ (warnings-as-errors) → app unit bundle ✅ **93/93**
(92 + F1 test) → `YouTabUITests` ✅ **4/4** + `CoachUITests` ✅ **3/3**
(all three suites in one `xcodebuild test` invocation). CoachKit
untouched this round (still 189/188 per round 1).

**Verdict: MERGEABLE.** Checklist items 1–2 closed; item 3 carries (F4
polling only if CI flakes).
