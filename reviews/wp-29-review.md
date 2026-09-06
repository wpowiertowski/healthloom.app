# WP-29 review — Key management + consent UI (round 1)

**Range:** uncommitted work on `wp-29-key-consent` vs `HEAD` (`e153179`):
6 tracked files + 9 new files (6 app: `AIModelsView{,Model}.swift`,
`CloudGateCache.swift`, `CloudKeyStoring.swift`, `CloudKeyValidator.swift`,
`TierSettingsStore.swift`; 2 unit suites; 1 UI suite).
**Method:** full-diff read → collaborator read (`ModelCatalog`,
`ModelTier`, `AppEnvironment`, `ThemedChrome`) → spec check (plan WP-29,
WP-28 F5/L3) → build ✅ → tests (below) → grep-verified claims.
**Toolchain:** `/Applications/Xcode-beta.app` (beta SDK, iOS 27 sim
iPhone 17 Pro). Package-matrix suites untouched (no CoachKit changes).

**Verdict: DO NOT MERGE — 1 blocker (F1, code-verified; the UI test
purporting to prove it is itself broken — TMP abort + missing tap, see
correction in Method/F1).** Four mutation paths (key delete,
toggle-off, consent withdraw, model pick) change zero `@Observable`-tracked
properties, so the screen never re-renders and the row lies until
leave-and-return. The fix is small and named in F1; the gated checklist
below is the re-review bar.

## Method / counts

- `xcodebuild build` (warnings-as-errors): ✅ **BUILD SUCCEEDED**.
- `xcodebuild test -only-testing:HealthLoomTests`: ✅ **84/84 in 14 suites**,
  incl. new `AIModelsViewModelTests` (12/12) and `CloudKeyValidatorTests`
  (4/4); touched `CoachChatViewModelTests`/`CoachRoundTwoTests` green with
  the new `tierSettings`/`tierCatalog` deps.
- `xcodebuild test -only-testing:HealthLoomUITests/AIModelsUITests`:
  ❌ **4/5 pass**. `testKeyDeleteDisablesTier` fails — but NOT where round 1
  reported. The cited `AIModelsUITests.swift:46` is the `XCTAssertEqual`
  inside the `waitForLabel` helper, not the failure site, and the test never
  reaches its status poll: it aborts first at line 204 on a leftover debug
  assert (`XCTAssertTrue(false, "TMP deleteFrame=…")`), and even with that
  line removed it never taps Delete (no `tap`/`tapTrailing(delete)` between
  the `isHittable` assert at line 202 and the
  `waitForLabel(…, "Requires an API key.", …)` poll at line 209), so the
  10 s poll would exhaust regardless of app behavior. F1 stands on
  tracked-prop enumeration, not on this test.
- Mutation walk (§5.3): every new unit test fails if its guard is broken
  (details in "Tests" below) — 16 functional, 0 seam-smoke, 1 deliberate pin
  (`consentCopyCoverage`). The one UI failure is a test bug on top of an app
  bug: the test aborts on its TMP assert and never taps Delete (so it
  cannot pass even against fixed code), while the unit twin
  (`keyDeleteDisablesTier`) passes, proving VM state is right and the render
  gap of F1 is real — F1 stands on tracked-prop enumeration, not on the UI
  test.

## What this round gets right

- `CloudGateCache` is the right shape for the problem: lock-guarded bools,
  `nonisolated` readers for `@Sendable` catalog closures, writers only at
  launch-fill and per-mutation. No polling, no observation — correct call.
- `fillGateCache` is `static` taking only what it reads so the launch `Task`
  can't capture half-initialized `self`. Someone thought about init-time
  capture; say more of that.
- Consent→key sheet chaining via direct item swap (`.consent` → `.keyEntry`,
  no intermediate `nil`) with the churn rationale in the comment. The
  single-`AIModelsSheet`-enum decision (sibling `.sheet(item:)`s conflict) is
  the kind of framework-corner note that saves the next author an hour.
- Validator mapping is exactly right where it matters: 2xx valid,
  provider-rejection invalid, **429/5xx/throw → transport-error, never
  "invalid key"**, and cancellation can't rewrite the field to "invalid".
  `saveKey` trims, validates *before* touching the Keychain, stores only on
  `.valid`. No key material in any error string (checked all four).
- Toggle-off keeps consent + key (cheap re-enable) with a unit test pinning
  it; delete/withdraw drop effective state while the preference survives —
  the row/toggle/gate separation is clean and consistently held.
- UI-test scenario design is disciplined: `resetAll()` at launch (order
  independence), in-memory keys, stub validator, three named seeds. The
  `tapTrailing`/`waitForLabel`/`scrollUntilHittable` helpers document *why*
  with measured behavior, not lore.
- `TierConsentCopy` single-sources the consent sheet; the coverage test
  asserts the mapping (which tier → which destination), not just
  non-emptiness.

## Findings

### F1. [BLOCKER — ~30 lines] Mutations that change no `@Observable` state never re-render: key delete, toggle-off, consent withdraw, model pick

Location: `HealthLoomApp/Coach/AIModels/AIModelsViewModel.swift`
(`deleteKey`, `setTurnedOn(false)`, `withdrawConsent`, `setModel`);
`TierSettingsStore.swift` (`@Observable` with no observable state).

Failure scenario (code-verified; the UI test as-written cannot confirm it —
see Re-verify correction below): enable Claude fully in
the AI Models screen, tap Delete key. `deleteKey` writes the Keychain and
`gates.setKeyPresent(false)` — neither is `@Observable`-tracked
(`CloudGateCache` is deliberately not observable; the Keychain isn't
either). Body's tracked reads are `cachedQuota` (via `rows()`),
`isValidating`, `sheet`, `bannerMessage`, `keyDraft`/`keyError` — all
untouched on this path (verified: the only `bannerMessage` write in
`deleteKey` is the `catch` arm, never cleared anywhere — see F4). No
invalidation → no re-render → the row still reads "On" forever (until
leave-and-return rebuilds the view). `testKeyDeleteDisablesTier` polls 10 s
and fails at `AIModelsUITests.swift:46`. The logic is correct — the unit
twin passes — which is exactly why this survived: every suite is green
except the one that looks at pixels.

Same hole, same root cause, no UI coverage (all verified by enumerating
tracked-prop writers — the list is `sheet`/`keyError`/`isValidating`/
`cachedQuota`/`bannerMessage`, and these paths touch none):

- `setTurnedOn(false)`: UserDefaults write only. Toggle-off may render stale
  status/extras; Settings can show ON while the (remounted) chat slot
  excludes the tier.
- `withdrawConsent`: settings + gates only. "Consented <date>" row and "On"
  status stick after withdrawal.
- `setModel`: settings only. Picker displays the old selection.

Contributing structural cause: `TierSettingsStore` is `@Observable` but owns
zero mutable stored properties (`private let defaults` + UserDefaults
method calls publish nothing), so its docstring promise — "so `AIModelsView`
rows and the chat tier slot re-render when consent/toggles change" — is
false for both consumers. In-settings updates ride the VM's tracked props
(or don't, per above); the chat slot rides tab-switch remount
(`HomeView` unmounts chat on tab change), not observation.

Fix (structural, per §4 — move "remember to notify" into the type, don't
add "remember to bump a counter" convention):
1. `TierSettingsStore`: keep write-through `@Observable` stored mirrors for
   toggle + consent-date per tier (init from `defaults`, every setter writes
   both). Then all settings paths publish, and the shared instance makes the
   chat slot live without remount.
2. `AIModelsViewModel`: mirror key presence as a stored
   `[ModelTier: Bool]` updated alongside every `gates.setKeyPresent` call
   (`refresh`, `saveKey`, `deleteKey`); `rows()` reads the mirror for
   `hasKey`. Gates stay the sync bridge for the catalog; the mirror is the
   render truth.
Minimal alternative if the above is too wide: a `private(set) var revision`
bumped on the four paths — but that is precisely the conventional
remember-to-bump the store fix avoids; prefer (1)+(2).
Re-verify: `testKeyDeleteDisablesTier` green + manual toggle-off/withdraw/
picker pass. CORRECTION (round-1 erratum — the UI test as-written proves
nothing about F1): it (a) aborts at `AIModelsUITests.swift:204` on
`XCTAssertTrue(false, "TMP deleteFrame=…")` before the status poll, and
(b) never taps the Delete button — lines 200–209 scroll to it, assert
`isHittable`, log the frame, then poll the status with no intervening tap.
So the 10 s timeout fires even against a fixed app. The F1 diagnosis is
unaffected (it rests on enumerating tracked-prop writers, and the unit twin
`keyDeleteDisablesTier` passes, localizing the gap to render), but the
"failing UI test in hand" claim was wrong: fix the test (delete the TMP
line, add `tapTrailing(delete)` after the hittability assert), then use its
green/red as the F1 signal. The old residual below is superseded — there is
no tap to miss yet; re-evaluate hittability only after the tap exists.
SUPERSEDED round-1 residual (kept for the record, do not act on): the old
text suspected `tapTrailing` missing the narrow Delete button despite
`isHittable` — moot until the tap exists.

### F2. [HIGH, latent until first prod `liveTiers` flip — ~10 lines] Launch gate-cache fill races first render; consent (sync-readable) is needlessly async

Location: `HealthLoomApp/DI/AppEnvironment.swift` (~`Task { await
Self.fillGateCache… }` in the `else` branch).

Failure scenario: production launch, user previously consented + enabled
PCC, never opens Settings. `fillGateCache` (consent from `UserDefaults`,
presence from Keychain) runs in a fire-and-forget `Task`; the chat tier
slot (`enabledTierNames`, read live per render) can render before the fill
lands, showing "On-device" instead of "On-device · Apple cloud (PCC)" until
any tab bounce remounts the view. No error, no retry, no observable nudge
on completion. Latent *today* only because production `liveTiers ==
[.onDevice]` (F3) makes the PCC conjunct false regardless — it bites the
moment the P-1.5/entitlement flip (progress.md WP-28 L3) or WP-32 lights a
cloud row in prod. Name the gate: **first prod `liveTiers` flip must fix or
absorb this**.

Fix: seed consent inline in `init` (synchronous `UserDefaults` reads, exactly
like the scenario branch already does) before building the catalog; leave
only the Keychain presence reads in the `Task`, and have completion nudge
render state once F1's mirrors exist (or re-seed on chat `onAppear`).

### F3. [MEDIUM — ~15 lines + 1 CoachKit visibility change] Non-live rows walk full consent + live-network key validation in production and store keys for tiers that can never serve

Location: `AIModelsViewModel.setTurnedOn` /
`AIModelsView.acceptConsent` + `saveKey`; production wiring
`AppEnvironment.swift` (`ModelCatalog.live(...)` with default
`liveTiers == [.onDevice]`, confirmed by grep — the only override is the
UI-test scenario).

Failure scenario (production, today): Settings → AI Models → toggle Claude.
`setTurnedOn` checks consent/key but never liveness, so the user gets the
consent sheet ("Enable Claude (your key)?" / "Accept and continue"),
then a *live-network* 1-token validation ping, then a real Keychain write —
for a tier whose `availability` is `notLive` and whose `isEnabled` is
unconditionally false. End state: consent recorded + API key at rest for
processing that never happens, row reading "Ships in a later update." with
the toggle ON. The sheet's promise ("Accept and continue" → enable) is
broken by construction. PCC same shape minus the key. (WP-28 F5 blessed
dead provider code "by design" — but nothing documents *collecting consent
and keys early* as the design; if it is, the copy must say so.)

Fix (either, explicitly decided inline): (a) disable row toggles for
non-live rows (keep the "Ships in a later update." status as the ladder
documentation) — needs `ModelCatalog.isLive` exposed `public` (currently
`private`; note `TierAvailability.notLive/needsConsent/needsKey` are
`internal`, which is also why the app and UI tests re-type reason strings
instead of asserting *which* constant — make them `public` and assert the
constant per §4); or (b) bless pre-registration: consent copy gains a
"not serving yet" line, key entry says the key is stored for launch, status
reads accordingly. (a) is smaller and honest; (b) matches the L3 "flip reads
already-stored keys" future if that's the actual plan.

### F4. [LOW — 1 line] `bannerMessage` is write-only: a transient Keychain failure banners permanently

Location: `AIModelsViewModel.swift:168,288` (writes); zero clears
(`grep -rn "bannerMessage = nil"` empty).

Failure scenario: first appear coincides with a Keychain hiccup →
"Couldn't read stored keys" banners. Every later `refresh()` succeeds but
never clears it (and `.task` re-runs on every appear, succeeding silently
under the stale banner) until the view is rebuilt. Fix: clear at the top of
`refresh()` (and keep the `catch` writes).

### F5. [LOW — ~10 lines + 1 test] Gemini maps *any* 400 to `invalidKey` without checking the body — contradicting the file's own comment

Location: `CloudKeyValidator.swift` (`perform` discards `Data`;
`validateGemini` passes `invalidStatusCodes: [400]`).

Failure scenario: the header correctly states "400 with API_KEY_INVALID =
invalid key", but `perform` never reads the body (`(_, response)`), so any
400 on `GET /v1beta/models` — e.g. a disabled-API or malformed-request 400
with a *valid* key — reports "That key was rejected. Check it and try
again." The user re-pastes a good key in a loop. (Rare on a key-only GET,
hence low — but the comment documents the stricter contract, so implement
it: keep `data`, treat 400 + `API_KEY_INVALID` in the payload as
`.invalidKey`, other 400s as `.transportError`.) Coverage twin: no VM-level
or UI test ever walks the Gemini row (grep: zero `gemini` hits in
`AIModelsViewModelTests`; one absence-assertion in UI) and `modelPicker`
pins only the Claude default — add the Gemini default/options row (3 lines)
or explicitly defer it with the Gemini undeferral.

### F6. [LOW — 5 lines] `shortModelName` uses the guideline's named-bad pattern: `lowercased().contains`

Location: `AIModelsView.swift` (`let lower = modelID.lowercased()`).

Failure scenario: tr/az locale — `"CLAUDE-HAIKU…".lowercased()` folds `I`
to dotless `ı`, `contains("haiku")` fails (same for `gemini` → falls to the
`"pro"` arm by luck, `haiku` falls through to the raw ID). Deterministic
display bug, picker labels only. Fix: `modelID.range(of: "haiku",
options: .caseInsensitive) != nil` (or fixed-locale lowercasing). Flagged
because §3.2 names this exact shape.

### F7. [LOW, plausible — ~10 lines] `StubTransport.next` is shared mutable state across parallel Swift Testing cases

Location: `CloudKeyValidatorTests.swift` (`nonisolated(unsafe) static var
next`, no lock, no `.serialized`).

Failure scenario (not observed — suite is 4/4 green; marked plausible per
§1): Swift Testing runs cases in parallel by default; two cases setting
`next` around an `await` boundary can cross (`valid` consuming `invalidKey`'s
401 → red, flakily). No `.serialized` precedent exists in-repo to copy.
Fix: ` @Suite(.serialized)` on the suite, or a per-test transport (separate
`URLProtocol` subclass per case / instance-keyed stub). TSan would settle
it; the fix is cheaper than the proof.

### F8. [LOW — comment-only] `CloudKeyStoring.swift` header describes wiring that doesn't exist

Location: `CloudKeyStoring.swift` header ("the UI-test launch uses the real
Keychain … with provider keys scrubbed at launch") vs `AppEnvironment.swift`
(scenario branch wires `InMemoryCloudKeyStore()`; nothing scrubs).
`LaunchConfiguration`'s comment (preferences reset) is the accurate one.
Fix the header to match the code (in-memory keys under
`-UITestAIModels`). Same class of drift: `AIModelsViewModel.refresh()`'s
"re-runs when a sheet dismisses re-triggers the view's `.task`" premise —
sheet presentation doesn't destroy the parent view, so `.task` doesn't
re-fire; the `cachedQuota` guard is correct regardless, the justification
isn't. Fix all three comments, no behavior change. (Round-1 erratum: this
finding originally said "both" but listed only two drifts while missing a
third in the same file family — `CloudGateCache.swift`'s header names
`refreshCloudGates()` as the launch-fill entry point, but no such symbol
exists. The launch fill is `AppEnvironment.fillGateCache`, the per-appear
fill is `AIModelsViewModel.refresh()`. The same header also points the chat
slot at "the same view-model-owned path (see
`CoachChatViewModel.enabledTierNames`)" when the slot actually reads
`TierSettingsStore` + `ModelCatalog` through its own `CoachChatViewModel`,
not through `AIModelsViewModel`.)

### Nits (log only)

- N1: `UserDefaults(suiteName: …)!` + ~15 `.first(where:)!` force-unwraps in
  the new tests vs §7.2 (`guard let` + `Issue.record`). Precedent exists
  (`SyncPreferencesTests.swift:106`), so low heat — but a 5-line
  `row(_:)` helper with `Issue.record` + `return nil` would stop the spread.
- N2: the `invalidKey` UI run leaves Claude consent in the simulator's
  `UserDefaults.standard` (scenario resets at launch, never scrubs at
  exit) — subsequent *dev* launches inherit it. Document or scrub on the
  scenario path.

## Spec compliance (plan WP-29 + WP-28 deferrals)

| Plan item | Verdict | Evidence |
|---|---|---|
| Per-tier row (status, model picker where applicable) | ✅ | `AIModelsView.rows/extras`, `rows()` |
| Claude/Gemini key entry (SecureField → Keychain, 1-token ping, delete) | ✅ (Claude) / ⏳ (Gemini deferred, renders `notLive`) | `saveKey`/`deleteKey`, `LiveCloudKeyValidator` |
| PCC row quota line + availability | ✅ | `quotaLine`, `refresh` quota read |
| Consent screen (destination, data-leaves, privacy, forget-forward) + per-tier timestamp | ✅ | `TierConsentCopy`, `recordConsent` |
| UI: blocked without key (Claude) | ✅ | `testClaudeEnableBlockedWithoutKeyThenSaved` |
| UI: blocked without consent (all off-device incl. PCC) | ✅ | `testPCCEnableBlockedWithoutConsent` |
| UI: key delete disables tier | ❌ | `testKeyDeleteDisablesTier` fails — test bug first (TMP abort at :204 + missing Delete tap, poll at :209 unreachable), real app bug F1 underneath; test must be fixed before it can signal F1 |
| UI: tier switcher shows only enabled tiers | ⚠️ | Implemented as read-only slot (`enabledTierNames` + `testChatSlotShowsOnlyEnabledTiers`); interactive switching explicitly deferred to WP-32 — accepted deferral, WP-32 owns the menu |
| Gemini undeferred | ⏳ | Out of scope per WP-28b; F5 notes the untested seams |

## Tests (§5.3 — "catches" per new test)

All 12 `AIModelsViewModelTests` + 4 `CloudKeyValidatorTests` are functional
(break-the-guard → red, checked by reading): `pccBlockedWithoutConsent`
catches a missing consent gate; `dismissConsentStaysOff` catches
dismiss-records-consent; `acceptConsentEnablesPCC` catches a missing
toggle-flip; `claudeConsentThenKeyFlow` catches store-before-validate;
`invalidKeyStoresNothing` / `transportErrorStoresNothing` catch storing on
rejection / conflating transport with invalid (incl. the copy distinction);
`keyDeleteDisablesTier` catches a gate that doesn't drop (unit half — the UI
twin as-written cannot localize anything until its TMP abort + missing tap
are fixed; F1's render localization rests on tracked-prop enumeration, not
on the UI test);
`withdrawConsentDisables` catches sticky enablement;
`toggleOffKeepsCredentials` catches credential-wiping toggle-off *and* a
re-enable that re-prompts; `modelPicker` catches a dropped override write;
`settingsStore` catches default/reset regressions; `consentCopyCoverage` is
the deliberate-change pin (destinations distinct per tier); validator
`valid`/`invalidKey`/`serverErrorIsTransport`/`offlineIsTransport` pin the
2xx/401/400 vs 429/5xx/throw mapping. No mock theatre: doubles implement
semantics (`InMemoryCloudKeyStore` real presence; gate-cache wiring
identical to production; `StubTransport` real HTTP statuses).

## Round 2 re-review (2026-09-06 — tree unchanged, no fix attempt)

**Method:** `git status` / `git diff --stat` identical to round 1 (same 6
tracked files, 199+/8-, same 9 new files, no new commits); re-grepped
every fix point on the live tree instead of trusting round-1 memory.
No rebuild/retest: the tree is the tree round 1 measured, so round-1
measurements stand — re-running would reproduce them exactly.

| Prior item | Status | Verification |
|---|---|---|
| F1 blocker (unobservable mutations; `testKeyDeleteDisablesTier` fails) | ❌ open | No mirrors/revision/counter in VM or store; UI test unfixed |
| F2 high (async consent seed races first render) | ❌ open | Production branch still defers both consent+keys to `Task`; no inline seed |
| F3 medium (non-live rows walk consent/key flows in prod) | ❌ open | `isLive` still private, `notLive` still internal, `setTurnedOn` unchecked |
| F4 low (sticky `bannerMessage`) | ❌ open | Zero `bannerMessage = nil` writes repo-wide |
| F5 low (Gemini 400→invalid without body check; no Gemini flow tests) | ❌ open | `(_, response)` still discards body; comment still promises `API_KEY_INVALID` |
| F6 low (`lowercased().contains`) | ❌ open | `AIModelsView.swift:206` unchanged |
| F7 low, plausible (`StubTransport.next` race) | ❌ open | No `.serialized`, still `nonisolated(unsafe)` shared static |
| F8 low (Keychain header drift + `.task` comment) | ❌ open | "real Keychain … scrubbed at launch" header verbatim |
| N1 (`!` in tests) / N2 (simulator defaults pollution) | ❌ open | Untouched |

No new findings: nothing changed, and round 1 already read the full
diff plus collaborators — there is no unread code to mine. (Per §6, items
promote after surviving two *fix* rounds; zero fix rounds have occurred,
so nothing promotes yet — but the next round with no movement should
promote F1 to merge-hold escalation rather than repeating it.)

**Verdict unchanged: DO NOT MERGE.** The blocker still has a failing UI
test in hand. Checklist items 1–6 carry over verbatim; item 1 (F1 +
`testKeyDeleteDisablesTier` green) remains the merge gate.

---

## Round 3 re-review (2026-09-06 — fix round landed, verified)

**Range delta vs round 2:** `ModelCatalog.swift` +11/-5 (F3 visibility),
`AppEnvironment.swift` reworked fill (F2), `TierSettingsStore.swift` mirrors
+ `resyncFromDefaults()` (F1), VM `keyPresence` mirror + `isLive` row field
+ `setTurnedOn` guard (F1/F3), validator body-marker (F5),
`range(of:.caseInsensitive)` (F6), `@Suite(.serialized)` + `nextBody` (F7),
header/comment corrections (F8), 2 new unit tests (F3 non-live, F5 body).
**Method:** fix-point grep → full read of reworked regions → build ✅ →
CoachKit beta 186/186 ✅ + stable 185/185 ✅ (delta = 1 beta-only test) →
app unit 86/86 ✅ (84 + 2 new) → `AIModelsUITests` 5/5 ✅ **including
`testKeyDeleteDisablesTier` (29.9 s)** — the round-1 blocker diagnosis
(no re-render path) is confirmed by its cure.

| Prior item | Status | Verification |
|---|---|---|
| F1 blocker (unobservable mutations) | ✅ fixed | Mirrors publish on all four paths; failing UI test now green |
| F2 high (async consent seed) | ✅ fixed | Consent seeded inline pre-catalog; `Task` keeps Keychain-only `fillKeyPresence` |
| F3 medium (non-live enable flows) | ⚠️ partial | Toggle + `setTurnedOn` guarded; **side door open → F9** |
| F4 sticky banner | ✅ fixed | Cleared at `refresh()` start, re-set on failure |
| F5 Gemini 400 mapping | ✅ fixed | `invalidBodyMarker` + realistic `API_KEY_INVALID` fixture + bare-400 test |
| F6 locale folding | ✅ fixed | `range(of:options:.caseInsensitive)` (folding, locale-independent — correct) |
| F7 shared stub state | ✅ fixed | `@Suite(.serialized)` with the rationale in-comment |
| F8 doc drift | ✅ fixed | Header now states `InMemoryCloudKeyStore`; `.task` comment corrected |
| N1 (`!` in tests) / N2 (sim-defaults pollution) | ❌ open | 17 `first(where:)!` sites (up from 15); no exit scrub |

### F9. [MEDIUM — ~8 lines + 1 test] F3 fix guards the toggle but not the "Enter key" side door: non-live rows still walk live-network validation + Keychain storage

Location: `AIModelsViewModel.beginKeyEntry` (no liveness guard) +
`saveKey` (no liveness guard) + `AIModelsView` key extras
(`if row.tier.requiresAPIKey` — no `isLive` gating; `AIModelsView.swift:~146`).

Failure scenario (production, today): Claude row — toggle disabled ✓ —
but the extras section still offers "No key stored / Enter key". Tap it
→ key sheet → Save → **live 1-token ping + real Keychain write for a tier
whose gate is unconditionally false**. Consent can't follow (that path is
guarded), so the key sits inert — the round-1 F3 shape minus consent, via
the one entry point the fix didn't touch (N−1 of N, §3.1:
`setTurnedOn` guarded, `beginKeyEntry` not). The view comment at
`AIModelsView.swift:84-87` overclaims the fix ("production never walks
consent + live-network validation + Keychain storage") — validation and
storage still walk. `setModel`/picker for non-live rows is the same
class but preference-only (no network, no secret at rest) — hide for
consistency or leave; say which inline.

Fix (structural — one choke point, both callers covered): guard
`beginKeyEntry` on `deps.catalog.isLive(tier)` (covers toggle path +
button path at once) AND hide the Enter-key button for `!row.isLive` so
production doesn't offer a dead control. Test: non-live `beginKeyEntry`
is a no-op (or assert the button hidden — one UI assertion). Effort: minutes.

Residual note (not a finding): the chat slot reads key presence through
gates (untracked) while consent/toggle now publish via mirrors — a key
added/deleted while staring at the chat tab shows on next remount. Rare
(keys change only from this screen) and strictly better than round 1;
closing it means an observable key-presence source shared with the slot —
fold into WP-32's switcher work if cheap, otherwise accept inline.

**Verdict: DO NOT MERGE — one medium (F9).** Everything else from rounds
1–2 is closed; F9 is minutes + one test. Re-review bar: F9 fix +
`AIModelsUITests` 5/5 + unit bundle re-run with counts.

---

## Round 4 re-review (2026-09-06 — F9 fixed, all suites green)

**Range delta vs round 3:** `beginKeyEntry` liveness guard (choke point),
Enter-key button hidden for `!isLive`, `nonLiveTierStaysOff` extended with
the side-door assertion, view comment corrected to describe both halves.
**Method:** fix-point grep → closed-set audit of `.keyEntry` writers →
build ✅ → app unit 86/86 ✅ → `AIModelsUITests` 5/5 ✅.

| Prior item | Status | Verification |
|---|---|---|
| F9 medium (Enter-key side door) | ✅ fixed | Both `.keyEntry` writers audited: L241 (`acceptConsent`, reachable only via guarded `setTurnedOn`) + L275 (`beginKeyEntry`, now guarded) — unreachable for non-live tiers, invariant documented at L269; dead button hidden; test asserts the no-op |
| N1 (`!` in tests) / N2 (sim-defaults pollution) | ❌ open | Log-only nits; never merge-blocking |

No new findings. Mutation spot-check on the extended test: removing the
`beginKeyEntry` guard re-opens the sheet assertion → red. The `saveKey`
path needs no separate guard (unreachable-state argument above, not
convention) — accepted as structural, not conventional.

**Verdict: SHIP IT.** All findings F1–F9 closed with failing-test-first
evidence (F1) and green suites throughout: CoachKit beta 186/186 +
stable 185/185 (round 3), app unit 86/86, UI 5/5 (this round). N1/N2 ride
as log-only nits for the next touch. WP-29 spec table: every plan item ✅
except the WP-32-owned interactive switcher (⚠️ accepted deferral) and
the deferred Gemini row (⏳). Gated checklist for the *next* WP: none
carried — the sheet is clean.

---

## Gated checklist for re-review

1. [ ] Test bug fixed first: TMP debug assert at `AIModelsUITests.swift:204`
   removed, missing `tapTrailing(delete)` added after the hittability
   assert — without both, the test cannot signal F1. Then F1 fixed (store
   mirrors + VM key-presence mirror, or decided alternative) —
   `testKeyDeleteDisablesTier` green, plus manual
   toggle-off / withdraw / picker re-render pass.
2. [ ] F2: consent seeded synchronously at launch (or chat `onAppear`
   re-seed); decided inline with the prod-`liveTiers`-flip owner (L3).
3. [ ] F3: decided (a) disable non-live toggles or (b) blessed
   pre-registration with copy; `TierAvailability` reason constants public
   with tests asserting the constant.
4. [ ] F4/F5/F6/F8 one-liners landed (or explicitly deferred inline).
5. [ ] F7: `.serialized` or per-test transport (or TSan evidence it's safe).
6. [ ] Full `HealthLoomTests` (84+) + `AIModelsUITests` (5/5) re-run on the
   beta toolchain, counts recorded.
