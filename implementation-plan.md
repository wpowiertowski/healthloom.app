# Implementation Plan — HealthLoom (iOS 27 / Swift 6.4)

Executable, agent-ready work packages implementing [architecture.md](architecture.md),
grounded in [google-health-healthkit-base-knowledge.md](google-health-healthkit-base-knowledge.md).
Testing requirements per package are summarized here; the full strategy is in
[test-plan.md](test-plan.md).

**Target:** iOS 27+, Xcode 27 beta+ (Apple Silicon only), Swift 6.4 (language mode 6).
**AI:** Foundation Models framework end-to-end — on-device model by default, Apple's
Private Cloud Compute server model as the free bigger-model tier, and Claude
(official `ClaudeForFoundationModels` package) / Gemini (Firebase SDK) through iOS 27's
public `LanguageModel` protocol (architecture D9/D14). No hand-rolled provider REST
clients or SSE parsing anywhere in this plan.

**Toolchain note (temporary, revisit before launch):** package manifests stay at
`// swift-tools-version: 6.2` — that is a *minimum*, parses under both Xcode 26 and 27,
and nothing here needs 6.4-only manifest APIs. GitHub now ships the Xcode 27 beta on a
dedicated `xcode-27` preview runner image (actions/runner-images#14196), so the app job
runs `xcodebuild build test` there unconditionally (the skip guard is gone); the
per-package `swift test` jobs stay on `macos-26` with Xcode 26.x (they build for the
macOS host, so 6.2 keeps them green without the preview image). Local development uses
the Xcode 27 beta (Swift 6.4 compiler).

**HealthKit-sheet test quarantined; the rest of the XCUITest suite is back in CI
(2026-07).** The preview image's iOS 27 beta 3 runtime does not deliver
XCUITest-synthesized taps to the out-of-process HealthKit permission sheet
(com.apple.HealthPrivacyService), so `OnboardingUITests` cannot pass there (diagnosis in
PR #7). The same limitation made it fail on a dev Mac, and since `make test` is this
repo's pre-commit hook (`.git/hooks/pre-commit`), that left the gate permanently red and
every commit needing `--no-verify`.

That test now self-skips via `XCTSkipUnless`, so it reports as *skipped* rather than
failing and the reason travels with the test. Re-run it on demand with
`TEST_RUNNER_HEALTHLOOM_RUN_HEALTHKIT_SHEET_TEST=1 xcodebuild test …` (verified: the
variable reaches the runner and the test really does execute); delete the skip once a
newer beta makes it pass. Because it self-skips, CI's blanket
`-skip-testing:HealthLoomUITests` is gone and the other four UI tests (Dashboard x2,
Activities, Today) now run on the runner. No narrowed `-skip-testing` replaced it on
purpose: a second mechanism skipping the same test would hand a green CI to whoever
eventually deletes the `XCTSkip`, without the test ever having run.

Remaining WP-38 launch-checklist work: flip manifests to 6.4, re-enable UI tests in CI
once a newer beta lands on the runner image, and move the app job from the preview image
back to the regular macOS image once Xcode 27 goes GA there.

---

## How to use this plan (agent handoff protocol)

Each work package (WP) is sized for one focused agent session and is self-contained:

- **Before starting a WP**, read: this file's entry for the WP, the `architecture.md`
  sections it cites, and the listed input files. Do not read the whole repo.
- **Scope discipline:** touch only the package(s) named in the WP. If you believe another
  module must change, stop and report instead of editing it.
- **Every WP ends with:** (1) code compiling under Strict Concurrency = Complete with zero
  warnings, (2) the WP's required tests written and passing (`swift test` for packages,
  `xcodebuild test` for app-target work), (3) a one-paragraph completion note appended to
  `progress.md` (create it on first use) stating what was built, what was deliberately
  deferred, and any surprises.
- **Blocked?** If an SDK API named here doesn't match reality (this plan predates your SDK),
  prefer the current SDK, keep the *behavior* specified here, and note the deviation in
  `progress.md`. Signatures in this plan are starting points, not contracts.
- **Dependencies:** listed per WP. WPs with no mutual dependency are parallelizable.
- **Fixtures:** JSON fixtures for Google API responses live in
  `Fixtures/GoogleHealth/*.json` inside the consuming package's test target. WP-05 creates
  the initial set; later WPs add to it. Never invent fixture shapes — derive them from the
  base-knowledge doc §2–3 and record assumptions in the fixture file as a `"_comment"` key.

Dependency graph (phases can overlap where arrows allow):

```
WP-01 ─┬─ WP-02 ─┬─ WP-07 ─┐
       ├─ WP-03 ─┤         ├─ WP-09 ── WP-10   (P0 vertical slice)
       │         ├─ WP-04 ─┤
       │         └─ WP-05 ─┘
       └─ WP-06 ─── WP-08 ─┘
P0 done ──▶ WP-11..18 (P1, mostly parallel)
P0 done ──▶ WP-19..26 (P2; needs P1's data breadth only for polish)
WP-27 needs WP-21..25 · WP-28..30 need WP-27 · WP-31 needs WP-23+27 · WP-32 needs WP-28..29
P4 (WP-33..39) needs P1 + P2; WP-33 can start after WP-10.
```

---

## Phase P-1 — Environment & prerequisites (human, not agent, tasks)

These gate everything; start them on day one. Agents cannot do them.

1. **Xcode 27 beta** installed (Apple Silicon Mac required — Xcode 27 dropped Intel);
   physical **Apple-Intelligence-capable device** (iPhone 15 Pro+) on the **iOS 27 beta**
   with Apple Intelligence enabled and the model fully downloaded (availability reports
   `.modelNotReady` while downloading). The simulator does not run the on-device model
   reliably — AI work is device-tested.
2. **Apple Developer Program**: App ID with HealthKit capability.
3. **Google Cloud project**: enable Google Health API; create an iOS OAuth 2.0 client.
4. **Start Google OAuth verification now** (launch long pole #1): all Health API scopes
   are Restricted ⇒ verified domain, live homepage, privacy policy, per-scope written
   justification. Track status in `progress.md`.
5. **Apply for the Private Cloud Compute entitlement now** (launch long pole #2, gates
   WP-28a): requires App Store Small Business Program enrollment and <2M first-time
   downloads across all the developer's apps, plus an application on the developer site.
   There is no paid tier above the threshold. Track status in `progress.md`.
6. A test Google account (**personal, not Workspace** — Workspace is unsupported by the
   Health API) paired with a Fitbit Air or Pixel Watch producing real data.
7. AI provider API keys (Anthropic and Google/Firebase) for **testing** the BYO-key
   tiers — end users supply their own at runtime. (No OpenAI key: that tier is deferred,
   architecture §7.6.)

---

## Phase P0 — Foundations + first vertical slice

**Phase goal:** steps, heart rate, sleep, weight flow Google → HealthKit end-to-end,
idempotently, visible on a minimal dashboard.

### WP-01 · Project skeleton + packages + CI
**Depends on:** nothing · **Touches:** repo root, all package manifests
**Objective:** Compilable workspace with the module boundaries from architecture.md §2.
**Steps:**
1. New Xcode project → App → SwiftUI lifecycle → name `HealthLoom`, deployment target iOS 27.
2. Create local packages `CoreModel`, `Secrets`, `GoogleHealthClient`, `SyncKit`,
   `CoachKit` under `Packages/`, each with a test target. Wire the dependency order from
   architecture.md §2 (SyncKit depends on CoreModel, Secrets, GoogleHealthClient; CoachKit
   on CoreModel, Secrets; app on all).
3. In every `Package.swift`: `swift-tools-version: 6.2` (a minimum — kept below 6.4
   deliberately; see the Toolchain note at the top of this file), platforms
   `.iOS("27.0")` (+ `.macOS` at the newest version CI hosts can run), and
   ```swift
   swiftSettings: [
       .defaultIsolation(MainActor.self),
       .enableUpcomingFeature("NonisolatedNonsendingByDefault"),
       .enableUpcomingFeature("InferIsolatedConformances")
   ]
   ```
4. App target: add **HealthKit** capability; **Background Modes** → background processing;
   Info.plist keys `NSHealthShareUsageDescription`, `NSHealthUpdateUsageDescription`
   (specific, honest strings — App Review reads them), `BGTaskSchedulerPermittedIdentifiers`
   (`com.healthloom.sync.refresh`), and the OAuth redirect URL scheme.
5. Set Strict Concurrency = Complete on all targets.
6. CI: GitHub Actions workflow `ci.yml` — macOS runner, `swift test` per package +
   `xcodebuild build test` for the app scheme on an iOS 27 simulator (Xcode 27 beta;
   the app job auto-skips with a `::warning` until the runner image ships it — see the
   Toolchain note). Cache SPM. CI must go red on warnings
   (`SWIFT_TREAT_WARNINGS_AS_ERRORS=YES` or `-warnings-as-errors`).
7. Move the design mockups into `Design/` (they are reference, not build inputs).
**Done when:** empty app builds and runs; `swift test` passes (empty suites) in CI.
**Tests:** none beyond CI plumbing.

### WP-02 · CoreModel — SwiftData models + value types
**Depends on:** WP-01 · **Touches:** `Packages/CoreModel`
**Objective:** The persistence layer and shared vocabulary. No I/O, no HealthKit import.
**Steps:**
1. `GoogleDataType`: `enum` of every row in base-knowledge §3, with computed properties
   `endpointName` (kebab-case), `filterName` (snake_case), `scope`
   (`.activityAndFitness/.healthMetrics/.sleep/.nutrition/.ecg/.irn`), and
   `writability: .healthKit(HKIdentifierName) | .localOnly | .skip` (string identifier,
   not HK types — CoreModel doesn't import HealthKit).
2. SwiftData models exactly as below (keep secrets OUT of SwiftData):
   ```swift
   @Model final class SyncState {
       @Attribute(.unique) var dataType: String
       var lastSyncedAt: Date?
       var backfillCursor: Date?      // walks backward; nil = backfill done/not started
       var lastStatus: String         // "idle" | "ok" | "error"
       var lastError: String?
       var itemCount: Int
   }
   @Model final class LocalSample {   // ONLY non-HK-writable types (architecture D2)
       @Attribute(.unique) var externalID: String
       var dataType: String
       var payloadJSON: Data          // full normalized point, type-specific shape
       var start: Date; var end: Date
       var source: String
       var linkedWatchWorkoutUUID: UUID?  // set by WP-12b when a Fitbit session defers to a watch workout (D13)
   }
   @Model final class KnowledgeProfile { /* fields: sections [ProfileField], updatedAt */ }
   @Model final class DerivedInsight  { /* text, createdAt, sourceProvider, sourceFields */ }
   @Model final class PromptVersion   { /* body, createdAt, isDefault */ }
   @Model final class ChatTurn        { /* role, content, provider, contextSnapshotID, createdAt */ }
   @Model final class ContextSnapshot { /* json: Data — exact HealthContext sent */ }
   ```
   `ProfileField` (Codable struct): `key`, `displayText`, `source`, `asOf: Date`,
   `excludedFromAI: Bool`, `isClinical: Bool` (clinical ⇒ excluded by default, D8).
3. `HealthContext`: Codable struct — profile fields (filtered), locale/units, today's date.
4. `ModelContainer` factory `CoreModel.makeContainer(inMemory:)`; production container
   sets `NSFileProtectionComplete` on the store URL (D11).
**Done when:** package tests pass; container round-trips every model in memory.
**Tests:** unique-constraint enforcement (`externalID`, `dataType`); `GoogleDataType`
casing (`body-fat` vs `body_fat`); writability table matches base-knowledge §5 for all
rows (table-driven test); clinical fields default-excluded.

### WP-03 · Secrets — Keychain wrapper
**Depends on:** WP-01 · **Touches:** `Packages/Secrets`
**Objective:** One tiny, safe secret store.
**Steps:**
1. `actor KeychainStore` with `get(_ key: SecretKey) -> String?`,
   `set(_ value: String, for key: SecretKey)`, `delete(_ key: SecretKey)`,
   `deleteAll(matching prefix:)`.
2. `SecretKey`: enum-backed strings — `google.refreshToken`, `google.accessToken`,
   `provider.claude.apiKey`, `provider.openai.apiKey`, `provider.gemini.apiKey`.
3. `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly` on every item. No iCloud sync.
4. Never log values; conform errors to a `SecretsError` that carries status codes only.
**Done when:** round-trip tests pass on simulator.
**Tests:** set/get/delete/overwrite; missing-key returns nil; prefix delete removes all
provider keys and nothing else.

### WP-04 · GoogleAuthManager — OAuth 2.0 + PKCE
**Depends on:** WP-02, WP-03 · **Touches:** `Packages/GoogleHealthClient`
**Objective:** Consent, token exchange, silent refresh, Workspace detection.
**Steps:**
1. PKCE: generate `code_verifier` (43–128 chars, RFC 7636), `code_challenge` = S256.
2. `beginConsent(scopes:)`: build the authorization URL (iOS client ID, redirect URI,
   requested scopes, `access_type=offline`), present via `ASWebAuthenticationSession`
   with `prefersEphemeralWebBrowserSession = true`, capture redirect, exchange
   `code + code_verifier` at the token endpoint. Store refresh token via `KeychainStore`.
3. `validAccessToken()`: return cached token if >60 s from expiry; otherwise refresh
   (`grant_type=refresh_token`). **Single-flight**: the actor holds an in-progress refresh
   `Task` so concurrent callers await one refresh. On `invalid_grant`, clear tokens and
   throw `.reconsentRequired`.
4. Incremental scopes: `grantedScopes` parsed from token response; `ensure(scopes:)`
   triggers consent only for missing ones (used by P1 settings).
5. Workspace detection: after first consent call the `userinfo` endpoint; if `hd` claim
   present ⇒ throw `.workspaceAccountUnsupported` (onboarding shows the dedicated screen).
6. Networking behind `protocol HTTPSession` (thin `URLSession` wrapper) so tests inject
   a stub. Never log tokens or URLs containing codes.
**Done when:** consent works against real Google on device; refresh works with Wi-Fi
toggled; Workspace account shows the unsupported screen.
**Tests (stubbed HTTP):** PKCE challenge correctness (known verifier → known S256);
token exchange request encoding; refresh single-flight (10 concurrent callers ⇒ 1 refresh
request); expiry margin honored; `invalid_grant` ⇒ `.reconsentRequired`; Workspace `hd`
claim detection.

### WP-05 · GoogleHealthClient — typed v4 REST client
**Depends on:** WP-02, WP-04 · **Touches:** `Packages/GoogleHealthClient`
**Objective:** Paged, resilient, normalized reads.
**Steps:**
1. Endpoints (per base-knowledge §2): resource pattern
   `users/me/dataTypes/{dataType}/dataPoints:{method}` — implement `reconcile`
   (primary read, D1) and `dailyRollup` (daily types). Kebab-case in paths.
2. `GoogleDataPoint` (Sendable): `id`, `dataType`, `start`, `end`,
   `source: DataSource` (`platform`, `deviceDisplayName`, `recordingMethod`),
   `values: [String: Double]`, `sessionPayload: Data?` (sleep/exercise nest structures).
   Decode the nested `<data_type>.<field>` + `dataSource` wrapper into this flat shape.
3. **Normalize units on decode** (base-knowledge §2 "odd base units"): mm → m for
   distances; document every conversion in one `UnitNormalizer` table.
4. Pagination: `reconcile(type:since:until:pageToken:)` returns
   `Page(points:, nextPageToken:)`. `since/until` are the request window; the page token
   continues within that window (do not re-derive the window per page).
5. Resilience: on 401 → one token refresh + single retry; on 429/5xx → exponential
   backoff with jitter (base 1 s, cap 60 s, max 5 attempts) then throw; honor
   `Retry-After` if present.
6. All calls `@concurrent`/nonisolated; inject `HTTPSession`; bearer from `GoogleAuthManager`.
7. Create fixtures: `steps.json`, `heart-rate.json`, `sleep.json`, `weight.json`,
   `paged-steps-p1.json`/`-p2.json`, `error-429.json` under `Fixtures/GoogleHealth/`.
**Done when:** real-account smoke test pulls a week of steps on device.
**Tests (fixtures + stubbed HTTP):** decode each fixture to expected `GoogleDataPoint`s;
mm→m normalization; pagination stitches 2 pages, preserves window; 401→refresh→retry
exactly once; 429 backoff schedule (virtual clock); malformed JSON throws typed error.

### WP-06 · HealthKit authorization
**Depends on:** WP-01 · **Touches:** `Packages/SyncKit` (+ app onboarding stub)
**Objective:** Request the right permissions, degrade gracefully.
**Steps:**
1. `HealthKitAuth` wrapping one shared `HKHealthStore`. `isAvailable` gate
   (`HKHealthStore.isHealthDataAvailable()` — iPad!).
2. `requestWrite(for: [GoogleDataType])`: map via the WP-02 writability table to HK types;
   request share authorization. P0 set: `stepCount`, `heartRate`, `bodyMass`,
   `sleepAnalysis`.
3. `requestRead(_:)` is used twice later: in P1 by `WatchCoverageIndex` (WP-12b — read
   workouts + heart rate to detect Apple Watch recording windows) and in P2 by
   CoachKit's KnowledgeStore read set. Shape the API for incremental read requests.
4. Per-type status surface: `writeStatus(for:) -> .authorized | .denied | .notDetermined`
   (HK reveals write denial as `sharingDenied`; reads never reveal denial — document this
   in the API's doc comment and code defensively).
**Done when:** permission sheet shows the 4 P0 types; denying one is reflected in status.
**Tests:** unit-test the GoogleDataType→HKType mapping table; authorization itself is
covered by UI tests (test plan §5).

### WP-07 · TypeMapper v1 (steps, heart rate, sleep, weight)
**Depends on:** WP-02, WP-05 · **Touches:** `Packages/SyncKit`
**Objective:** Pure, table-driven `GoogleDataPoint → MappedObject?`. Correctness lives here.
**Steps:**
1. ```swift
   enum MappedObject { case quantity(HKQuantitySample); case category([HKCategorySample])
                       case localOnly; case skip }
   enum TypeMapper { static func map(_ p: GoogleDataPoint) -> MappedObject }
   ```
2. Quantity rows: steps → `.stepCount`/count; weight → `.bodyMass`/kg (Google field is
   grams or kg — verify against a real payload and pin in a fixture); heart-rate →
   `.heartRate`/count/min.
3. Sleep: one Google sleep session → array of `HKCategorySample(.sleepAnalysis)` stage
   segments. Stage map: `awake→.awake`, `light→.asleepCore`, `deep→.asleepDeep`,
   `rem→.asleepREM`, unknown stage → `.asleepUnspecified`. Segments must not overlap;
   clamp to session bounds.
4. Metadata on every sample (D4):
   ```swift
   [HKMetadataKeyExternalUUID: p.id,
    "healthloom.externalID": p.id,
    "healthloom.sourceDevice": p.source.deviceDisplayName]
   ```
5. Unknown/unmapped `dataType` → `.skip` (never crash); ECG/AZM/IRN → `.localOnly`.
**Done when:** golden-file tests pass for all four types.
**Tests:** golden tests — fixture JSON in, exact expected HK type/unit/value/dates/metadata
out, one per type; sleep multi-stage session (incl. unknown stage, zero-length segment);
out-of-range values (negative steps, HR 0 / 400) — decide and pin behavior (drop + count).

### WP-08 · HealthKitWriter
**Depends on:** WP-06, WP-07 · **Touches:** `Packages/SyncKit`
**Objective:** Batched, idempotent writes; scoped deletes.
**Steps:**
1. Put HK access behind `protocol HealthStoreProtocol` (save, delete, execute-query) so
   SyncEngine tests can run without a HealthKit entitlement.
2. `existingExternalIDs(type:start:end:) -> Set<String>`: one `HKSampleQuery` with
   `HKQuery.predicateForObjects(withMetadataKey: HKMetadataKeyExternalUUID, allowedValues:)`
   — or, if `allowedValues` proves unavailable at this scale, a date-window query mapping
   metadata client-side. One query per page window, **never per sample** (D4).
3. `save(_ batch: [HKObject])` — single `HKHealthStore.save` call per page.
4. `delete(externalIDs:type:)` and `deleteAllAppData()` (delete-by-source) for wipe/update.
5. Workouts deferred to WP-12 (needs `HKWorkoutBuilder`) — leave a stub that throws.
**Done when:** simulator integration test writes, dedupes, and deletes samples.
**Tests:** with mock store — batch grouping, dedupe diff logic; with real simulator HK
store (integration tag) — save then `existingExternalIDs` finds them; delete-by-externalID
removes only the target; re-save of same IDs is skipped by the diff.

### WP-09 · SyncEngine v1
**Depends on:** WP-05, WP-07, WP-08 · **Touches:** `Packages/SyncKit`
**Objective:** Orchestrate pull→map→write with cursor+lookback (D3), per type.
**Steps:**
1. `actor SyncEngine` (injected: client, writer, `ModelContainer`, clock). In-flight set
   drops duplicate concurrent syncs per type.
2. Per type:
   ```
   window.start = (syncState.lastSyncedAt ?? now − initialWindow) − lookback(type)
   window.end   = now
   for each page of client.reconcile(type, window):
       mapped   = points.map(TypeMapper.map)
       existing = writer.existingExternalIDs(type, pageWindow)
       writer.save(new quantity/category objects not in existing)
       persist .localOnly payloads to LocalSample (upsert by externalID)
   on full-window success: syncState.lastSyncedAt = window.end; status ok; itemCount += n
   on failure: status = error + message; lastSyncedAt NOT advanced (window re-pulled next run — safe because idempotent)
   ```
   `lookback`: 72 h default, 7 d for sleep (D3). `initialWindow`: 7 d (backfill is WP-15).
   Leave a pass-through `ConflictFilter` hook between mapping and the existence diff —
   identity in P0; WP-12b installs the real watch-priority resolver there (D13). P0
   dual-device users may see workout-window double counting until WP-12b lands; accepted.
3. `syncAll(types:)` runs types sequentially (predictable quota usage), collecting a
   per-type result report.
4. SwiftData access from the actor via its own `ModelContext`; `LocalSample` upsert keyed
   on unique `externalID`.
**Done when:** two consecutive `syncAll` runs against fixtures produce zero duplicate writes.
**Tests (mock client + mock writer):** idempotency (second run writes 0); pagination
consumed fully; cursor advances only on success; failure mid-window leaves cursor and is
retried; lookback window computed correctly (virtual clock); late-arriving sample (older
timestamp, new ID) inside lookback gets written; concurrent `sync(type:)` calls coalesce.

### WP-10 · Minimal dashboard + onboarding (P0 UI)
**Depends on:** WP-04, WP-06, WP-09 · **Touches:** app target
**Objective:** Prove the slice visibly. Plain SwiftUI — Yacht club design lands in WP-33.
**Steps:**
1. Onboarding flow: welcome → HealthKit permission → Google consent → first sync.
   Include the Workspace-unsupported and HK-unavailable states.
2. Dashboard list: 4 types × (last-sync time, item count, status icon, error text) driven
   by `SyncState`; a "Sync now" button calling `syncAll`; a data-freshness header
   ("data reaches Google ~15 min after device sync" — set expectations, D-context §1).
3. Wire `ModelContainer`, DI of engine/auth into the SwiftUI environment.
**Done when (= P0 exit):** a real Fitbit Air/Pixel account's steps, HR, sleep, weight
appear in Apple Health attributed to HealthLoom, no duplicates after repeated manual
syncs, and errors render rather than vanish.
**Tests:** UI test — onboarding happy path with stubbed auth (launch argument
`-UITestStubGoogle`); dashboard renders per-type states from a seeded in-memory container.

---

## Phase P1 — Full sync

**Phase goal:** every mappable type, incremental + background, resilient,
user-controllable — and correct for the core dual-device user (Fitbit worn 24/7 +
Apple Watch for dedicated workouts, architecture D13).
WP-11–14 are parallel; WP-12b after WP-12; WP-15–18 after WP-11.

### WP-11 · TypeMapper full table
**Depends on:** WP-07 · **Touches:** `SyncKit`, fixtures
**Objective:** Implement every ✅ row of base-knowledge §5.
**Steps:** one row at a time, each with fixture + golden test **before** moving on:
distance (mm→m, `.distanceWalkingRunning`), floors, active/total energy (Google gives a
single total — map active energy to `.activeEnergyBurned`; only derive basal if the API
provides it separately, otherwise don't invent a split), resting HR, HRV (`heartRateVariabilitySDNN`
— confirm Google's HRV metric is SDNN; if RMSSD, convert nothing and store RMSSD app-local
+ note), SpO₂ (fraction 0–1 in HK!), respiratory rate, VO₂max + Run VO₂max, body fat
(fraction in HK), height (m), blood glucose (unit from payload — mg/dL vs mmol/L), core
body temperature, hydration (`dietaryWater`, liters).
**Done when:** golden test per row; every conversion documented in `UnitNormalizer`.
**Tests:** golden per type; property test: mapping never produces a sample with
`end < start`; SpO₂/body-fat outputs are in 0…1.

### WP-12 · Exercise → HKWorkout
**Depends on:** WP-08, WP-11 · **Touches:** `SyncKit`
**Steps:**
1. Decode Google Exercise sessions (`sessionPayload`) — type, duration, distance, energy.
2. Map the ~13 coarse Google exercise types → `HKWorkoutActivityType` via one explicit
   table (default bucket `.other`); document the table in code and in `architecture.md`
   is NOT needed — a doc comment suffices.
3. Build with `HKWorkoutBuilder` (`HKWorkout` initializers are deprecated):
   `beginCollection → add(samples) → endCollection → finishWorkout`; attach distance/energy
   samples; stamp metadata (D4).
**Tests:** golden per exercise type incl. unknown-type default; workout dedupe by
externalID; builder integration test on simulator store.

### WP-12b · Watch-priority conflict resolution + Activities view
**Depends on:** WP-08, WP-09, WP-12 · **Touches:** `SyncKit`, app target
**Objective:** Implement architecture D13 — Apple Watch wins during recorded activities;
Fitbit supplements. This is the phase's correctness centerpiece for dual-device users.
**Read first:** architecture.md D13 (mechanics 1–6) and §6 (ordering-hazard rows).
**Steps:**
1. `WatchCoverageIndex` (SyncKit): query HealthKit for workouts whose
   `sourceRevision.productType` / `HKDevice` indicates an Apple Watch (any recording app);
   emit coverage windows padded ±5 min; cache per sync run. Put source detection behind
   `protocol WorkoutSourceClassifier` so tests inject windows (simulator can't fake a
   watch source). Requires HK *read* authorization for workouts + heart rate (WP-06's
   `requestRead`) — request it in the P1 onboarding update, with copy explaining why.
2. `ConflictResolver`, installed in WP-09's `ConflictFilter` hook:
   - **Sessions:** Google Exercise overlapping a watch workout (≥50 % of shorter duration,
     or start *and* end within 10 min) ⇒ do not write `HKWorkout`; persist to `LocalSample`
     with `linkedWatchWorkoutUUID`; mark supplement fields (AZM, recovery metrics).
   - **Streams:** heart rate / active energy / steps / distance samples fully inside a
     coverage window ⇒ suppressed (counted in the sync log as "deferred to Apple Watch",
     never written). Partially overlapping interval samples: split at the window edge if
     the type is cumulative (steps, energy, distance); drop if instantaneous (HR).
3. **Retroactive cleanup:** at the start of each type's sync, re-evaluate the lookback
   window against the current coverage index; delete app-written samples/workouts (by
   external ID, D4) that now fall inside coverage. Late-arriving watch workouts are the
   norm when the watch was away from the phone.
4. Settings toggle "Prefer Apple Watch during workouts" (default ON; OFF ⇒ resolver is
   identity and Apple Health source priority governs). Toggling OFF does not restore
   previously suppressed samples retroactively (document in UI copy); toggling ON cleans
   up on next sync via step 3.
5. **Activities view** (app target): consolidated list — one entry per activity; watch
   workout primary (duration, distance, GPS badge, source icon); linked Fitbit session's
   supplementary fields inline ("+ 32 Active Zone Minutes · Fitbit Air"); Fitbit-only
   activities (no watch) shown as full entries. Chronological, grouped by day.
**Done when:** a recorded dual-wear workout produces exactly one workout in Apple Health
(the watch's), no doubled steps/HR/energy for that window, and one consolidated entry
in-app; a Fitbit-only workout still imports fully.
**Tests:** overlap classifier truth table (exact match, 49 %/51 %, start+end tolerance,
padding edges, back-to-back workouts); cumulative-split vs instantaneous-drop at window
edges; retroactive cleanup (import Fitbit first → inject watch workout into lookback →
next sync deletes conflicts); toggle OFF ⇒ identity; suppression counts logged; UI test
for the consolidated Activities entry with seeded data.

### WP-13 · Nutrition correlations
**Depends on:** WP-11 · **Touches:** `SyncKit`
**Steps:** Nutrition Log → `HKCorrelation(.food)` grouping per-meal
`dietaryEnergyConsumed`, protein, carbs, fat; hydration handled in WP-11. Meal grouping
key = Google log entry ID; partial nutrient sets allowed.
**Tests:** golden meal with all nutrients; meal missing macros; correlation dedupe.

### WP-14 · Non-writable types → LocalSample + badges
**Depends on:** WP-09 · **Touches:** `SyncKit`, app target
**Steps:** ECG, Active Zone Minutes, Active Minutes, IRN persist to `LocalSample`
(payloadJSON keeps full fidelity); dashboard rows show a "Not in Apple Health" badge;
mark IRN/ECG rows `isClinical` so D8 excludes them from AI by default.
**Tests:** localOnly routing; upsert on re-sync (no dupes); clinical flag set.

### WP-15 · Historical backfill
**Depends on:** WP-09, WP-11 · **Touches:** `SyncKit`, app target
**Objective:** D5 — chunked, resumable backward walk.
**Steps:**
1. `BackfillCoordinator` (actor): per type, walk from `min(lastSyncedAt, now)` backward in
   30-day chunks to the user-chosen horizon (30 d / 90 d default / 1 y / all);
   checkpoint `SyncState.backfillCursor` after each completed chunk; process types
   round-robin so one huge type doesn't starve others; inter-chunk delay for quota.
2. Runs at `.utility` priority; suspends when a foreground incremental sync is active
   (SyncEngine exposes an `isBusy` signal); resumes on next launch/BG task if killed.
   Chunk-checkpoint persistence wrapped in `withTaskCancellationShield` (Swift 6.4) so
   a cancellation mid-write can't tear `backfillCursor`.
3. UI: progress per type ("Mar 2026 … done"), pause/resume, chosen horizon changeable
   (extending re-opens the walk).
**Tests:** chunk boundaries exact (no gap/overlap between chunks); kill-resume from
checkpoint; horizon extension; round-robin fairness (virtual clock); idempotency with
overlapping incremental sync.

### WP-16 · Background sync
**Depends on:** WP-09 · **Touches:** app target, `SyncKit`
**Steps:**
1. Register `BGAppRefreshTask` (`com.healthloom.sync.refresh`) at launch; schedule next
   on every run and in the handler (always reschedule, even on failure).
2. Handler: run `syncAll` for due types with a hard time budget (~20 s: check
   `task.expirationHandler`, cancel gracefully, cursors make partial runs safe;
   shield the final `SyncState` cursor write with `withTaskCancellationShield`).
3. Optionally a `BGProcessingTask` for backfill chunks (requiresExternalPower = false,
   network = true).
**Tests:** unit-test the "due types + budget" planner as a pure function; manual:
`e -l objc -- (void)[[BGTaskScheduler sharedScheduler] _simulateLaunchForTaskWithIdentifier:@"com.healthloom.sync.refresh"]`
in lldb; verify reschedule-on-every-path via debug log.

### WP-17 · Sync settings + incremental scopes
**Depends on:** WP-10, WP-11 · **Touches:** app target, `GoogleHealthClient`
**Steps:** Settings screen: per-type sync toggles (grouped by Google scope); enabling a
type whose scope isn't granted triggers `ensure(scopes:)` incremental consent; disabling
stops sync but keeps written data (deletion is WP-35's wipe). Persist toggles in
`UserDefaults`.
**Tests:** scope-computation from toggle set (pure function); disabled type skipped by
`syncAll`.

### WP-18 · Sync log + diagnostics
**Depends on:** WP-09 · **Touches:** `SyncKit`, app target
**Steps:** ring-buffer log (SwiftData or file) of sync runs — timestamps, types, counts,
error strings; **never health values, never tokens** (D11). Settings → "Sync log" viewer +
export-as-text for support. Add `os.Logger` categories with the same redaction rule.
**Tests:** log entry redaction (feed a fake error containing a token-like string; assert
stored entry passes the redaction filter); ring-buffer capping.

---

## Phase P2 — On-device AI coach

**Phase goal:** default coach experience: private, on-device, transparent, prompt-controllable.
WP-19→20→21 are sequential; WP-22 parallel with 19–21; WP-23–26 after.

### WP-19 · KnowledgeStore
**Depends on:** P0 (data present), WP-02 · **Touches:** `CoachKit`
**Objective:** Derive the compact, human-readable `KnowledgeProfile` (D7).
**Steps:**
1. Read set: HealthKit statistics queries (steps daily avg 30 d, resting HR trend, HRV
   baseline, sleep duration/stage split 14 d, workouts 30 d — all sources, so Apple Watch
   workouts are first-class; merge linked Fitbit supplements from `LocalSample` per D13.6,
   never describing both copies of one activity) + the user's **heart-rate zone
   configuration** (new iOS 27 HealthKit zones API — a profile field and future strain
   input, architecture D6) + `LocalSample` (AZM; clinical types only produce `isClinical`
   fields). Request HK *read* authorization here for exactly this set (via WP-06's
   `requestRead`).
2. Each derived `ProfileField`: display text ("~8,200 steps/day (30-day avg)"),
   `source` ("HealthKit · Fitbit Air"), `asOf`, flags. User goals (from settings) and
   pinned user corrections (WP-30) are fields too — corrections beat re-derivation.
3. `refresh()` triggers off SwiftData's `HistoryObserver` (iOS 27) observing SyncKit's
   persistent-history writes — no hand-wired completion signal — throttled to at most
   hourly; pure derivation functions take sample arrays in ⇒ unit-testable without HK.
4. Summary API for tools: `sleepSummary(nights:)`, `stepsSummary(days:)`,
   `workoutsSummary(days:)`, `vitalsSummary()` — all reading derived data, never raw dumps.
**Tests:** derivation functions with synthetic sample arrays (avg/trend math, empty data,
single day, DST-crossing days); correction pinning wins; clinical exclusion default;
staleness (`asOf`) propagation.

### WP-20 · ContextAssembler
**Depends on:** WP-19 · **Touches:** `CoachKit`
**Steps:**
1. `context(for purpose: .chat|.dailyInsight) -> HealthContext` from `KnowledgeProfile`
   only; drop `excludedFromAI` fields; clinical fields only if user opted in (D8).
2. Token budget: estimate (chars/4 heuristic); if over budget for the active tier
   (query the model where exposed; working constants: on-device ~4K tokens, PCC 32K,
   Claude/Gemini large), drop fields by priority rank (vitals > sleep > activity >
   history) until it fits. Over-budget on-device is also the trigger for a PCC
   escalation *offer* (D14.2), decided in WP-27 — this WP only reports the overflow.
3. Every assembled context is persisted as `ContextSnapshot` and its ID returned with the
   context (chat turns link to it — trace UI, WP-32).
**Tests:** exclusion honored (excluded string never appears in serialized context —
substring assert); clinical default-out/opt-in; budget trimming order; snapshot ID
round-trip.

### WP-21 · PromptManager + SafetyLayer
**Depends on:** WP-02 · **Touches:** `CoachKit`
**Steps:**
1. `SafetyLayer.text`: immutable constant — non-medical disclaimer, "do not diagnose,
   do not interpret ECG/AFib/irregular-rhythm data — recommend a clinician", scope limits,
   "encourage professional help for disordered-eating signals". Written once, reviewed by
   a human (flag in progress.md for review).
2. `effectivePrompt(base:) = userBase + "\n\n" + SafetyLayer.text` — suffix always last,
   not editable, not removable (D10).
3. `PromptVersion` history: save on edit, reset-to-default, diff-vs-default data
   (store both strings; UI diffs in WP-26).
**Tests:** suffix always present and always last (property test over random user bases,
including a base that *contains* the suffix text — still appended); version history
append/reset; default prompt non-empty.

### WP-22 · Foundation Models availability gate + session factory
**Depends on:** WP-01 · **Touches:** `CoachKit`
**Steps:**
1. `AvailabilityGate` mapping `SystemLanguageModel.default.availability` to UI states:
   `.available`, `.deviceNotEligible`, `.appleIntelligenceNotEnabled`, `.modelNotReady`
   (each with user-facing copy + the next-tier fallback suggestion). Shape it to also
   carry PCC states when WP-28a lands: offline / entitlement missing / `quotaUsage`
   near-limit / at-limit (D14.3–4).
2. `CoachSessionFactory`: builds `LanguageModelSession(model:tools:instructions:)` for
   any `any LanguageModel` (on-device `SystemLanguageModel.default` in this WP; PCC /
   Claude / Gemini plug in via WP-28 with zero factory changes — that's D9's point).
   Expose `respond`, `streamResponse`, `prewarm()`, `isResponding`. One session per
   conversation; fresh session per one-shot task (insights).
3. Keep a thin `protocol CoachSession` seam over the session so tests can inject a
   scripted stream without a model.
**Tests:** availability/quota mapping (inject each case); session lifecycle rules (fresh
vs reused) as unit logic; real generation covered by on-device manual tests (test plan §7).

### WP-23 · ReadinessEngine + @Generable DailyInsight
**Depends on:** WP-19, WP-22 · **Touches:** `CoachKit`
**Steps:**
1. `ReadinessEngine.score(inputs:) -> Readiness` — deterministic (D6):
   inputs HRV-vs-baseline, RHR-vs-baseline, sleep duration+efficiency, prior-day strain;
   weights in one constant table; missing signals renormalize weights and report
   `signalsUsed`. Output 0–100 + delta vs 30-day average (feeds the hero + tick scale).
2. `DailyInsight` guided generation:
   ```swift
   @Generable struct DailyInsight {
       @Guide(description: "One-sentence, encouraging headline.") let headline: String
       @Guide(description: "2–3 concrete, personalized suggestions.") let suggestions: [String]
       @Guide(.anyOf(["low", "moderate", "high"])) let effortLevel: String
   }
   ```
   Generated from `context(.dailyInsight)` + readiness result via a fresh session.
**Tests:** ReadinessEngine — golden vectors (inputs → exact score), missing-signal
renormalization, delta math, monotonicity (better HRV never lowers score); DailyInsight —
schema decodes from fixture transcripts; generation itself is device/manual + eval set.

### WP-24 · Tools
**Depends on:** WP-19, WP-22 · **Touches:** `CoachKit`
**Steps:** implement `Tool`s backed by KnowledgeStore summaries: `getRecentSleep(nights:)`,
`getSteps(days:)`, `getWorkouts(days:)`, `getVitals()`. Tool output is the same
user-visible summary text as the profile (nothing the trace UI can't show). Register on
session creation. Clamp arguments (nights ≤ 30 etc.).
**Tests:** each tool against seeded KnowledgeStore (output text golden); argument
clamping; tools respect exclusions (excluded field never in any tool output).

### WP-25 · Chat UI
**Depends on:** WP-22, WP-21, WP-20 · **Touches:** app target
**Steps:** Coach tab — message list (`ChatTurn`s), streaming tokens via
`streamResponse`, input disabled while `isResponding`, `prewarm()` on appear, stop button,
error/unavailable states from `AvailabilityGate`, "What did the coach see?" expander per
assistant message (reads linked `ContextSnapshot` — full UI in WP-30). Persist turns.
Leave a slot in the toolbar for WP-32's tier switcher.
**Tests:** UI test with a scripted mock `CoachSession` (WP-22's test seam): send → stream renders →
turn persisted → relaunch shows history; unavailable state rendering.

### WP-26 · Prompt Editor
**Depends on:** WP-21 · **Touches:** app target
**Steps:** editable base prompt, live token estimate, reset-to-default, version history
list (restore), diff-vs-default, and **"Preview effective prompt"** showing the exact
final string including the safety suffix, visually marked as locked.
**Tests:** UI test — edit → preview contains edit + suffix; reset restores default;
history restore works.

---

## Phase P3 — Multi-tier coach (Private Cloud Compute / Claude / Gemini)

**Phase goal:** same coach, user-selectable model tier, every off-device hop strictly
opt-in. iOS 27's `LanguageModel` protocol carries all of it (architecture D9/D14/D15) —
this phase writes catalog/consent/orchestration glue, not model clients.

### WP-27 · ModelCatalog + orchestrator on the `LanguageModel` protocol
**Depends on:** WP-21–25 · **Touches:** `CoachKit`
**Objective:** The OS protocol *is* the provider seam (D9); build the app-owned pieces
around it.
**Steps:**
1. `ModelCatalog`: table of tiers — `.onDevice` (`SystemLanguageModel.default`),
   `.privateCloudCompute`, `.claude`, `.gemini` — each entry: display name,
   `makeModel() -> any LanguageModel`, `runsOnDevice`, `requiresAPIKey`,
   `requiresConsent`, availability check. `isEnabled` = on-device, or
   (consent recorded ∧ (no key needed ∨ key in Keychain)). This WP ships the catalog
   with only `.onDevice` live; WP-28 fills the other rows.
2. `CoachOrchestrator`: owns prompt assembly (always via PromptManager ⇒ safety suffix
   on every tier, D10/D8), context snapshotting, dispatch through `CoachSessionFactory`
   (WP-22), and error normalization over the framework's `LanguageModelError`
   (`.rateLimited` / `.contextSizeExceeded` / `.timeout` / guardrail cases) plus
   provider-specific errors (e.g. `ClaudeError.missingCredential`).
3. Escalation offers per D14.2: on-device context-over-budget (reported by WP-20) or an
   explicit "deeper analysis" request ⇒ *offer* PCC; never auto-switch.
**Tests:** catalog gating truth table (key × consent × availability); orchestrator always
includes suffix regardless of tier (assert on a spy `LanguageModel` conformance);
snapshot stored per turn; error-normalization table; escalation offered exactly on the
documented triggers.

### WP-28 · Off-device tiers (a: Private Cloud Compute, b: Claude, c: Gemini)
**Depends on:** WP-27 · **Touches:** `CoachKit`, app entitlements ·
**Parallelizable per tier.**
**Route rule (D9):** every tier is a `LanguageModel` conformance handed to the existing
session factory — no REST clients, no SSE parsing, no request encoding in this repo.
- **a — Private Cloud Compute:** `PrivateCloudComputeLanguageModel()` behind the
  catalog. Add the PCC entitlement (granted in P-1.5). Handle `quotaUsage` pre-dispatch
  (near-limit warning, at-limit fallback to on-device, D14.3), reasoning-level
  selection, and offline unavailability (D14.4). No API key; consent screen still
  required (D14.1).
- **b — Claude:** depend on Anthropic's official `ClaudeForFoundationModels` package
  (github.com/anthropics/ClaudeForFoundationModels). Build
  `ClaudeLanguageModel(name:auth:)` per session with `.apiKey` read from `KeychainStore`
  (it's the *user's* key entered at runtime — the package's don't-embed-a-key warning
  targets developer keys baked into binaries; `.proxied` mode remains available if a
  relay ships later). Model picker from the `ClaudeModel` constants table.
  **`serverTools` is never configured** — `.webSearch`/`.webFetch`/`.codeExecution`
  would move health-derived text into search infrastructure (D11). Map `ClaudeError`
  + `LanguageModelError` into WP-27's normalized errors.
- **c — Gemini:** the Firebase Apple SDK's `LanguageModel` conformance; key/config +
  consent identical in shape to Claude. Keep the Firebase dependency scoped to
  CoachKit — nothing else imports it.
- **OpenAI: deferred** until an official/vetted `LanguageModel` conformance exists
  (architecture §7.6; WWDC26 session 339 is the conformance recipe if one must be
  built later). Do not hand-roll a REST client.
**Tests (per tier):** catalog integration via a stubbed `LanguageModel` conformance;
key-missing throws before any dispatch (Claude/Gemini); injected quota states render
warning/fallback (PCC); error-mapping tables; guardrail/content-filter surfaced as a
user-visible state, not a crash. Live smoke against real PCC/Claude/Gemini is a manual
device test (test plan §7), not CI.

### WP-29 · Key management + consent UI
**Depends on:** WP-28 · **Touches:** app target
**Steps:** Settings → AI Models: per-tier row (status, model picker where applicable).
Claude/Gemini rows get key entry (SecureField, stored via KeychainStore, validate with a
1-token ping, delete key). The PCC row has no key but shows quota state ("Apple cloud —
included; daily limit tied to your iCloud account") and its availability. Every
off-device tier requires a **consent screen** before first enable: names the destination
(Apple Private Cloud Compute / Anthropic / Google), states what data leaves (profile
fields + messages) and the tier's privacy properties (PCC: not stored, not used for
training; BYO-key: provider's terms apply), notes prior turns already sent can't be
recalled ("forget" applies forward). Consent recorded per tier with timestamp.
**Tests:** UI test — enable flow blocked without key (Claude/Gemini); blocked without
consent (all off-device tiers incl. PCC); key delete disables tier; tier switcher in
chat shows only enabled tiers.

### WP-30 · Knowledge transparency UI ("You" tab)
**Depends on:** WP-19, WP-20, WP-27 · **Touches:** app target
**Steps:**
1. **Profile:** render every `ProfileField` (display text, source, as-of, AI on/off
   toggle per field; clinical fields visually distinct, default off).
2. **Correct:** edit a derived field ⇒ pinned user override (beats re-derivation, WP-19).
3. **Trace:** per-message "What did the coach see?" → rendered `ContextSnapshot` + the
   tier that served the turn (D15.b — "…and where did it run?").
4. **Forget:** per-field exclusion, global derived-insight reset, chat-history wipe.
**Tests:** UI test — toggling a field off ⇒ next context (via debug inspector or mock
provider capture) lacks it; correction persists across refresh; forget clears; trace
shows the correct tier badge.

### WP-31 · Coach evals on the Evaluations framework
**Depends on:** WP-23, WP-27 · **Touches:** `CoachKit` (eval target), CI
**Objective:** Implement test-plan §9 on Apple's new Evaluations framework (WWDC26
sessions 298/299) instead of a hand-rolled harness: grounding (insights reference only
context-snapshot values), `DailyInsight` structure stability, the safety red-team set
(clinical refusals, prompt-injection via the user-editable base), and cross-tier
consistency (on-device / PCC / Claude / Gemini must agree on safety outcomes).
Wire the hill-climbing workflow (session 335) for SafetyLayer and default-prompt
tuning — **proposals are human-reviewed, never auto-adopted**.
**Tests:** the eval sets are the deliverable; runs nightly/pre-release on a macOS 27
host or designated device (not per-push CI — model-in-the-loop).

### WP-32 · Tier switcher via Dynamic Profiles
**Depends on:** WP-28, WP-29 · **Touches:** `CoachKit`, app target
**Objective:** Architecture D15 — mid-conversation model switching that preserves the
transcript, built on Foundation Models' Dynamic Profiles.
**Steps:** in-chat tier menu (enabled tiers only, from `ModelCatalog`); swap
model/tools/instructions via Dynamic Profiles without discarding the transcript;
re-apply `effectivePrompt` (user base + safety suffix) on every swap; re-check consent
on any off-device target; stamp each `ChatTurn` with its serving tier (feeds WP-30's
trace badge).
**Tests:** suffix survives N random tier switches (property test); switch to a
non-consented tier is blocked at the menu *and* at dispatch; transcript preserved
across swaps; turn badges correct; escalation *offer* (WP-27.3) routes through the
same switcher UI.

---

## Phase P4 — Product polish & launch

### WP-33 · Today view — Yacht club design
**Depends on:** WP-10, WP-23 (readiness) · can start visual work right after WP-10.
**Inputs:** `Design/HealthLoomTodayView-YachtClub.swift`, `Design/healthloom-final-yachtclub.html` (the spec).
**Steps:**
1. Port `Theme` tokens + `TickScale` + panel components into the app target, bound to
   real data: readiness hero ← `ReadinessEngine` (incl. "based on N of 4 signals" state),
   metric rows ← HealthKit/KnowledgeStore today-values, sync status ← `SyncState`
   ("Fitbit Air · synced 9m ago"), coach panel ← latest `DailyInsight` (tap → Coach tab).
2. Metric-row reordering via SwiftUI's iOS 27 reorderable-content API (no custom
   Edit-mode drag plumbing); order in `UserDefaults`; add/remove metrics from the full
   synced-type list.
3. **Design deviations (mandated, D12):** Dynamic Type — replace fixed `helv(size)` with
   `ScaledMetric`-relative sizes; dark-mode palette variant (derive: canvas→near-black
   warm, ink→light teal, keep rust accent, re-check ≥4.5:1 contrast); all rows get
   VoiceOver labels ("Heart rate, 62 beats per minute, resting, steady").
4. Empty states: no data yet (pre-first-sync), stale data (>24 h), readiness insufficient
   signals.
**Tests:** snapshot tests light/dark × Dynamic Type XS/XL; reorder persistence unit test;
UI test for edit mode; accessibility audit (test plan §6).

### WP-34 · Scheduled insights + notifications
**Depends on:** WP-16, WP-23
**Steps:** after the overnight BG sync completes (first run after 5 am local), generate
`DailyInsight` (on-device by default; PCC allowed if the user enabled that tier *and*
"insights via Apple cloud" separately — still no third-party hop for unattended
generation; BYO-key tiers are chat-only for insights), post a local notification
(headline only — no health values on the lock screen by default; toggle for full text).
Request notification permission in context, not at launch.
**Tests:** scheduling logic (pure function: last-run + clock → should-run); notification
content redaction; UI test for permission flow.

### WP-35 · Export & deletion
**Depends on:** P1 complete
**Steps:** Settings → "Disconnect & wipe": revoke Google token (`oauth2.googleapis.com/revoke`),
delete Keychain items, delete SwiftData store, optional delete of all app-written
HealthKit samples (delete-by-source, per-type progress). Per-provider key removal (WP-29).
Export: JSON dump of `LocalSample` + profile + chat (user-initiated, share sheet).
**Tests:** wipe leaves keychain/store empty (integration); HK delete-by-source removes
only app-written samples (simulator); export JSON schema snapshot.

### WP-36 · (Optional) Webhooks + push freshness
**Depends on:** WP-16 · **Decision gate:** ship v1 polling-only (architecture §7.2).
If pursued: serverless receiver for Google Health auto-subscribing webhooks → APNs silent
push → app pulls just the changed type. Separate repo/deliverable; not on the launch path.

### WP-37 · Accessibility, localization & performance pass
**Depends on:** WP-33, WP-25
**Steps:** full VoiceOver pass (every screen operable, tick scale gets `accessibilityValue`),
Dynamic Type audit at largest sizes, Reduce Motion honored, unit localization
(HKUnit user-locale rendering; km/mi, kg/lb), first-token latency (prewarm verified),
sync memory profile on a 1-year backfill (Instruments — no unbounded page accumulation).

### WP-38 · Launch checklist (human + agent mix)
- [ ] Google OAuth verification **approved** for Restricted scopes (started in P-1).
- [ ] **PCC entitlement granted** (applied in P-1.5); PCC quota behavior verified on a
      real iCloud account; app degrades correctly if the entitlement lapses.
- [ ] Toolchain finalization: ~~CI un-guarded onto Xcode 27~~ (done 2026-07 — app job
      runs on the `xcode-27` preview image, see Toolchain note); still open: package
      manifests bumped to `swift-tools-version: 6.4`, built against the iOS 27 GA SDK,
      app job moved back to the regular macOS image once Xcode 27 GA ships there.
- [ ] App Review prep: HealthKit usage strings accurate; demo video of Google consent for
      review notes; privacy nutrition label (Health & Fitness data — linked-to-user? no
      tracking) covering PCC and BYO-key tiers; non-medical disclaimer surfaced in
      onboarding **and** SafetyLayer.
- [ ] Off-device-AI consent screens name destinations (Apple PCC / Anthropic / Google);
      on-device is default; Claude `serverTools` confirmed absent from every code path.
      No health values in logs/analytics/crash reports (verified per test plan §8).
- [ ] Graceful degradation matrix verified (test plan §7): no Apple Intelligence, no
      Google account, HK denied, offline.
- [ ] Built only on Google Health API (Fitbit Web API sunsets Sept 2026 — no legacy calls;
      grep CI guard for `api.fitbit.com`).
- [ ] Display name **HealthLoom** consistent across Info.plist, App Store Connect, and
      HealthKit source attribution.
- [ ] Dual-wear verification executed on a real Apple Watch + Fitbit Air day
      (test plan §7 manual scripts).

### WP-39 · (Optional) Siri & Spotlight via App Intents
**Depends on:** WP-23, WP-33 · **Decision gate:** nice-to-have, not on the launch path.
**Steps:** iOS 27 App Intents adoption — **entity schemas** contribute readiness and
today-metrics to the Spotlight semantic index; **intent schemas** for natural-language
actions ("What's my readiness?", "Sync my Fitbit now"); **View Annotations** on the
Today view so on-screen values are referenceable in Siri conversations. Exposing health
values to the system index is opt-in and default OFF (D11 posture). Validate with the
new **App Intents Testing framework** (real system pathways — Siri/Shortcuts/Spotlight —
no UI automation).
**Tests:** AppIntentsTesting suite per intent; opt-out ⇒ entities absent from the index;
sync intent respects the same in-flight coalescing as every other trigger (WP-09).

---

## Sequencing summary

```
P-1 Human prereqs (OAuth verification + PCC entitlement = long poles) ... day one
P0  WP-01..10  auth + 4-type slice ................... proves the pipe
P1  WP-11..18  full mapping, backfill, background ..... complete data
P2  WP-19..26  on-device coach + transparency ......... private AI
P3  WP-27..32  PCC/Claude/Gemini tiers, consent, evals  model choice
P4  WP-33..39  Yacht club UI, insights, wipe, launch .. polish
```

Day-one priorities: **Google OAuth verification** (P-1.4), the **PCC entitlement
application** (P-1.5), and the **TypeMapper golden test suite** (WP-07/11) — the first
two gate launch, the third guards correctness for everything downstream.
