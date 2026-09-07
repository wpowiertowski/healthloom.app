# Progress log

Append one entry per completed work package (agent handoff protocol,
implementation-plan.md). Newest entries at the bottom.

## WP-01 · Project skeleton + packages + CI

Built the full workspace skeleton: five local Swift packages under `Packages/`
(`CoreModel`, `Secrets`, `GoogleHealthClient`, `SyncKit`, `CoachKit`), each
`swift-tools-version: 6.2` with `platforms: [.iOS("26.0"), .macOS("26.0")]` and
the exact `swiftSettings` block from the plan (`.defaultIsolation(MainActor.self)`,
`NonisolatedNonsendingByDefault`, `InferIsolatedConformances`) on both the
library and test target, wired per architecture.md §2
(GoogleHealthClient → CoreModel+Secrets; SyncKit → CoreModel+Secrets+GoogleHealthClient;
CoachKit → CoreModel+Secrets), each with one placeholder source file and one
passing Swift Testing test; the app target `HealthLoom` (bundle id
`com.healthloom.app`, iOS 26.0 deployment target) generated via `xcodegen`
(present at `/opt/homebrew/bin/xcodegen`, v2.45.4; `tuist` not installed) from
a hand-written `project.yml` implementing WP-01 step 4: HealthKit entitlement,
honest/specific `NSHealthShareUsageDescription` / `NSHealthUpdateUsageDescription`
strings, `UIBackgroundModes: [processing]`, `BGTaskSchedulerPermittedIdentifiers:
[com.healthloom.sync.refresh]`, and a `CFBundleURLTypes` OAuth redirect scheme;
plus `.github/workflows/ci.yml` (macOS runner, per-package `swift test
-Xswiftc -warnings-as-errors` matrix job with SPM caching, then an app job
that runs `xcodegen generate` + `xcodebuild build test` on a real iOS
simulator, `SWIFT_TREAT_WARNINGS_AS_ERRORS=YES`); and moved the two design
mockups into `Design/` via `git mv`, fixing the now-relative links in
architecture.md's companion-docs list. **Verification performed in this
session** (not just written): `swift test` passes with zero warnings in all
five packages, and `xcodebuild build test -scheme HealthLoom` passes on a real
iOS 26.4.1 simulator (toolchain found: Xcode 26.4.1 / Build 17E202, Swift
driver 6.3.1 (swiftlang-6.3.1.1.2), macOS 26.5.1 host). **Deliberate
deferrals:** no real model/keychain/networking code — every package ships
only a marker enum plus a placeholder test, per WP-01 scope; the app target is
otherwise an empty SwiftUI "hello world" (`ContentView`) since onboarding/
dashboard is WP-10. **Deviations / surprises, tracked here per the handoff
protocol's "blocked?" clause:** (1) the default `swift package init` on this
toolchain emits `swift-tools-version: 6.3`; used `6.2` as specified anyway —
it built and tested cleanly, so no downgrade was needed. (2) `.macOS("26.0")`
was added to every `Package.swift` (beyond the plan's iOS-only framing)
specifically so `swift test` runs natively on this Mac, per WP-01's own
platform-requirement note; this doesn't affect the app target, which only
consumes the iOS library products. (3) The generated `.xcodeproj` is
deliberately **not** committed (`.gitignore` excludes it) — `project.yml` is
the source of truth and CI regenerates it via `xcodegen generate`; this is
standard xcodegen practice and avoids pbxproj merge conflicts, but it's a
choice beyond what WP-01's text states outright. (4) The OAuth redirect URL
scheme (`com.healthloom.app` / `CFBundleURLName: com.healthloom.app.oauth`) is a
**placeholder** — no real Google iOS OAuth client exists yet (that's P-1.3, a
human prerequisite). WP-04 must reconcile this with whatever redirect URI the
real Google Cloud OAuth client actually issues (commonly the reversed client
ID as the scheme) before `ASWebAuthenticationSession` can work end-to-end. (5)
Locally, `xcodebuild` initially reported all destinations (device *and*
simulator) as unavailable ("iOS 26.4 is not installed") even though
`xcrun simctl list runtimes` showed iOS 26.2 installed and `-showsdks` showed
the iOS 26.4 SDK on disk — Xcode's platform-component registration was
incomplete until `xcodebuild -downloadPlatform iOS` pulled the matching
26.4.1 simulator runtime (8.46 GB); this is a local-machine environment gap,
not a project misconfiguration, but a fresh CI runner or a fresh Xcode install
could hit the same wall and should have the iOS platform pre-provisioned (GH's
hosted macOS images normally ship simulator runtimes preinstalled). (6)
`ci.yml` pins `runs-on: macos-26` and `xcode-version: "26.4"` — GitHub's
actual hosted-runner image/label for Xcode 26 was not verified against a live
GitHub Actions environment in this session (no network access to
github.com from here); whoever first runs this CI should confirm/adjust the
runner label and Xcode version pin. **Human follow-up still required per the
plan:** opening `HealthLoom.xcodeproj` in Xcode at least once to eyeball
signing/team settings before running on a physical device — not needed for
simulator builds, which already pass headlessly.

## WP-03 · Secrets — Keychain wrapper

Built `Packages/Secrets` per the plan: `public actor KeychainStore` with
`get(_:) -> String?`, `set(_:for:)`, `delete(_:)`, and
`deleteAll(matching prefix:)`; `public enum SecretKey: String` with the five
required cases (`googleRefreshToken` → `"google.refreshToken"`,
`googleAccessToken` → `"google.accessToken"`, `claudeAPIKey` →
`"provider.claude.apiKey"`, `openAIAPIKey` → `"provider.openai.apiKey"`,
`geminiAPIKey` → `"provider.gemini.apiKey"`); and `public enum SecretsError`
(`.keychain(status: OSStatus)`, `.undecodableValue`) whose `description`
renders only the OS's generic status message via `SecCopyErrorMessageString`
— never a key name or stored value, matching architecture.md D11 and the
plan's "never log values" instruction (nothing in this package logs
anything). `SecretKey`'s raw values are namespaced by a leading dot-segment
(`google.*` / `provider.*`) specifically so `deleteAll(matching: "provider.")`
removes exactly the three provider keys and `deleteAll(matching: "google.")`
removes exactly the two Google keys — verified by a dedicated round-trip
test in both directions. Every write goes through
`kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly` with
`kSecAttrSynchronizable` explicitly `false` (`KeychainSecurityBackend.write`).
**Testing-note seam, as anticipated by the WP-03 brief:** all `SecItem*`
calls sit behind an internal `protocol KeychainBackend` (get/set/delete/
enumerate by account string); the required Swift Testing suite
(`KeychainStoreTests.swift` — set/get/delete/overwrite round-trip per key and
across all five keys, missing-key → nil, delete-when-absent is a no-op,
prefix delete both directions, prefix-with-no-match is a no-op, plus a small
namespacing-invariant suite) runs against `InMemoryKeychainBackend`, a
lock-protected in-memory fake in the test target. A second suite,
`KeychainSecurityBackendTests.swift`, is the one integration-style test that
attempts the **real** Keychain end-to-end (same round-trip, via
`KeychainSecurityBackend` pointed at a throwaway
`"com.healthloom.secrets.integration-test"` service so it can never touch a
real secret); it gates itself with a `.enabled(if:)` trait backed by a
probe (`isRealKeychainUsable()`) that attempts a real add+delete first. **On
this Mac, the probe fails and the test skips itself** with an explanatory
message rather than failing the suite — confirmed by hand with a standalone
`SecItemAdd` call outside the test harness, which returned **`OSStatus
-34018` / "A required entitlement isn't present"** (`errSecMissingEntitlement`),
exactly the failure mode the WP-03 brief warned about for unsigned `swift
test` runners on macOS. Also added `kSecUseDataProtectionKeychain: true` to
every query per the brief's suggestion, for iOS/macOS behavioral consistency
— it didn't change the entitlement outcome on this Mac (the process itself
lacks the keychain-access entitlement, which `kSecUseDataProtectionKeychain`
doesn't grant), but it's the correct flag for the app to ship with regardless
and is a no-op on iOS. **Verification performed in this session:** `swift
test -Xswiftc -warnings-as-errors` passes in `Packages/Secrets` — 14 tests
across 3 suites, 0 failures, 1 test gracefully skipped (the real-Keychain
integration test, for the reason above), 0 warnings. **Deliberate
deviations from the plan's literal text (behavior preserved, per the
handoff protocol's "blocked?" clause):** (1) `KeychainStore`'s methods are
declared `throws(SecretsError)` (typed throws) rather than the silent
`-> String?` / `Void` signatures shown in the plan — Keychain calls can
genuinely fail for reasons other than "key absent" (e.g. a locked device,
or the very entitlement gap seen here), and swallowing those into a bare
`nil`/success would hide real errors from callers like `GoogleAuthManager`
(WP-04) that need to distinguish "no refresh token yet" from "Keychain
call failed." `get` still returns plain `nil` for the not-found case, only
non-"not found" statuses throw. (2) Kept `Sources/Secrets/Secrets.swift`
(the WP-01 `SecretsPlaceholder` marker enum) in place rather than deleting
it: `CoachKit`, `SyncKit`, and `GoogleHealthClient`'s WP-01 placeholder
sources reference `SecretsPlaceholder.moduleName` directly, and WP-03's
scope is `Packages/Secrets` only — removing it would have broken those
out-of-scope packages' compilation. All new WP-03 API lives in separate
files alongside it. (3) `KeychainBackend`, `KeychainSecurityBackend`, and
`KeychainSecurityBackend.service` are internal, not public — the plan
doesn't specify a backend seam at all (it just lists `KeychainStore`'s
methods), but the testing note explicitly asked for one; kept it minimal
and unexported since it's a test seam, not app-facing API. **Note on the
wider workspace observed during this session:** `Packages/CoreModel` (WP-02)
did not build in this session's checkout — `swift test` there fails with
"cannot find 'PromptVersion'/'ChatTurn'/'ContextSnapshot' in scope," and
that breakage cascades into `GoogleHealthClient`, `SyncKit`, and `CoachKit`
(none of which I touched). This looks like WP-02 mid-flight elsewhere
(concurrent agent) rather than anything WP-03 caused; `Packages/Secrets`
was verified fully in isolation (`cd Packages/Secrets && swift test`), which
is what WP-03 requires and does not depend on CoreModel.

## WP-02 · CoreModel — SwiftData models + value types

Built the full CoreModel package: `GoogleDataType`, a 39-case enum covering every row
of base-knowledge §3 (verified by a test asserting `allCases.count == 39`), raw-valued
by its snake_case `filterName` with `endpointName` derived by swapping `_`→`-`
(`body_fat`/`body-fat` round-trips exactly, plus a generic round-trip test over all
cases); `scope` (`.activityAndFitness/.healthMetrics/.sleep/.nutrition/.ecg/.irn`); and
`writability: .healthKit(String)/.localOnly/.skip` derived from base-knowledge §5 (22
`.healthKit` rows, 4 `.localOnly`, 13 `.skip` — no HealthKit import anywhere, per
architecture.md D2). The seven SwiftData `@Model` classes are exactly as specified
(`SyncState` with `backfillCursor`, `LocalSample` with `linkedWatchWorkoutUUID: UUID?`,
`KnowledgeProfile`, `DerivedInsight`, `PromptVersion`, `ChatTurn`, `ContextSnapshot`),
plus the `ProfileField` and `HealthContext` Codable structs (`ProfileField.excludedFromAI`
defaults to `isClinical`'s value unless explicitly overridden — D8 — with an explicit
opt-in test). `CoreModel.makeContainer(inMemory:)` builds the schema from a single
`CoreModel.modelTypes` array (so the container and the "round-trips every model" test
can't drift); the production path opens the store under
`Application Support/HealthLoom/CoreModel.store` and applies `NSFileProtectionComplete`
via `FileProtectionType.complete`, guarded `#if os(iOS)` since Data Protection classes
are meaningless on the macOS host this package's tests actually run on (noted in a doc
comment, per the WP-02 spec's own anticipation of this). All required tests pass in
`Packages/CoreModel`: unique-constraint enforcement for `SyncState.dataType` and
`LocalSample.externalID` (insert-same-key-twice ⇒ one row, last-write-wins — SwiftData's
`.unique` behaves as an upsert, not a thrown error); the casing round-trip; a
table-driven test asserting every one of the 39 types' `writability` against a
hand-transcribed base-knowledge §5 table; clinical-default-exclusion (plus explicit-
override in both directions); and a container round-trip inserting one instance of all
seven models and re-fetching each. 15 tests / 6 suites (39 sub-cases inside the
writability test), 0 failures, 0 warnings — verified via
`swift test -Xswiftc -warnings-as-errors` from a clean `.build` in this session, not
just written. **Deviations/judgment calls (handoff protocol's "blocked?" clause):**
(1) base-knowledge §5's mapping table doesn't name-match §3 1:1 for several rows —
"Daily Resting Heart Rate" is the *only* resting-HR row in §3 so it gets the ✅
mapping as written, but "Heart Rate Variability," "Oxygen Saturation," and "VO2
Max"/"Run VO2 Max" each have a same-scope "Daily X" sibling in §3 that §5 never
mentions; I mapped the sample-level (S) type §5 names literally and routed its
unmapped daily-rollup sibling to `.skip` as a redundant aggregate duplicate (documented
inline per case in `GoogleDataType.swift`). §5's bare "Respiratory Rate" has no exact
match in §3 at all (only "Daily Respiratory Rate" and "Respiratory Rate Sleep
Summary" exist) — resolved to the sample-level "Respiratory Rate Sleep Summary" on
the same reasoning. (2) §5's "Active Energy Burned / Total Calories →
activeEnergyBurned / basalEnergyBurned" row is a positional pairing; I encoded it
literally (`totalCalories` → `HKQuantityTypeIdentifierBasalEnergyBurned`) even though
WP-11 explicitly warns not to *invent* a basal-only split from Google's single total —
this table only declares an available target string, not a decision to actually write
it; that call is TypeMapper's (WP-11) to make. (3) Despite ECG's ❌ "Works?" marker in
§5 ("cannot reconstruct in Apple Health"), I routed it to `.localOnly` rather than
`.skip`, matching D2's explicit list and WP-14's step 1 ("ECG, Active Zone Minutes,
Active Minutes, IRN persist to LocalSample") — ❌ in §5 means "no HK write target,"
not "discard the data." All four of those types are `.localOnly`; `.skip` is reserved
for types with no established destination anywhere in the plan (misc/rollup types like
Activity Level, Altitude, Food Measurement Unit, Sedentary Period, Swim Lengths Data,
Time in Heart Rate Zone, Calories In Heart Rate Zone, and the unmapped Daily-rollup
duplicates from (1)). (4) `Exercise` and `Food`/`Nutrition Log` don't correspond to a
single `HKQuantityTypeIdentifier`/`HKCategoryTypeIdentifier` string, so their
`.healthKit` payload is a documented sentinel (`"HKWorkoutType"`,
`"HKCorrelationTypeIdentifierFood"`) rather than a real HealthKit rawValue — flagged in
doc comments for WP-12/WP-13 to consume correctly. (5) Kept the WP-01
`CoreModelPlaceholder` marker enum in `CoreModel.swift` alongside the real WP-02 types:
`SyncKit`, `CoachKit`, and `GoogleHealthClient`'s WP-01 placeholder sources reference
`CoreModelPlaceholder.moduleName` at compile time, and WP-02's scope is
`Packages/CoreModel` only — deleting it would have broken those out-of-scope packages'
builds (confirmed: re-verified all three build and test cleanly from a clean `.build`
against the finished CoreModel). (6) `SwiftData` stored `[ProfileField]` (a plain
Codable struct array, on `KnowledgeProfile.sections`) and `[String]`
(`DerivedInsight.sourceFields`) directly with no special handling needed — worth
flagging only because it was a real "will this even compile" risk going in, and it
didn't require a `Data`-encoded workaround. **Deliberately deferred:** everything
downstream that *uses* this vocabulary (TypeMapper's actual unit conversions, the real
HK↔Google plumbing, KnowledgeStore derivation) — WP-02 is vocabulary + persistence
only, no I/O, per its own objective line.

## WP-06 · HealthKit authorization

Built `Packages/SyncKit/Sources/SyncKit/HealthKit/` as four files split along the
platform boundary the WP-06 brief asks for. Two are HealthKit-import-free and always
compile: `HealthKitAuthTypes.swift` (`HealthKitAuthorizationStatus` —
`.authorized`/`.denied`/`.notDetermined`, mirroring `HKAuthorizationStatus` without
naming it; `HealthKitAuthError` — `.healthDataUnavailable`, `.noHealthKitMapping`,
`.unresolvedIdentifier`, `.underlying`) and `HealthKitIdentifier.swift` (the required
"pure, unit-testable function": `HealthKitIdentifierClassifier.classify(_:)` takes a
HealthKit identifier string from CoreModel's `GoogleDataType.writability` table —
consumed as the single source of truth, never re-duplicated — and classifies it into
`HealthKitIdentifierKind.quantity/.category/.workout/.correlationFood` by prefix
match (`HKQuantityTypeIdentifier`/`HKCategoryTypeIdentifier`) plus the two documented
sentinels (`"HKWorkoutType"`, `"HKCorrelationTypeIdentifierFood"`) CoreModel's
`GoogleDataType.swift` doc comments and this file's WP-02 deviation note (4) call
out for `.exercise`/`.food`/`.nutritionLog`; unrecognized strings return `nil`, never
a guess). The other two are `#if canImport(HealthKit)`-guarded per the brief's
platform constraint: `HealthKitObjectTypeResolver.sampleType(for:)` turns a
classified identifier into the concrete `HKSampleType` (`HKQuantityType`/
`HKCategoryType`/`HKWorkoutType`/`HKCorrelationType` all being `HKSampleType`
subclasses, so one return type covers every kind), throwing
`UnresolvedHealthKitIdentifier` — never dropping silently — for anything the
classifier or HealthKit itself doesn't recognize; and `HealthKitAuth`, the actual
deliverable class: `init()` owns one `HKHealthStore` (documented as
one-per-app-shared, DI'd like `KeychainStore`/`GoogleAuthManager`), `isAvailable`
(`HKHealthStore.isHealthDataAvailable()`), `requestWrite(for: [GoogleDataType])` and
`requestRead(_:)` (both `async throws(HealthKitAuthError)`, both validate every
type's HealthKit mapping *before* checking `isAvailable` or touching the store —
so a bad type is rejected identically on every platform rather than being masked by
the availability gate — then throw `.healthDataUnavailable` with no system prompt if
unavailable, then call `HKHealthStore.requestAuthorization(toShare:read:)`), and
`writeStatus(for:) -> HealthKitAuthorizationStatus` (returns `.notDetermined` without
touching the store when unavailable or unmapped; otherwise maps
`.sharingAuthorized`/`.sharingDenied`/`.notDetermined` straight through). `requestRead`'s
and the type's own doc comments spell out, per the brief's explicit instruction, that
HealthKit never reveals read denial — only write/share status is queryable — and that
every caller must treat an empty read result as "no data or denied," never a hard
error. `HealthKitAuth.p0WriteTypes = [.steps, .heartRate, .weight, .sleep]` is the P0
write set (WP-06 step 2), derived from — not re-declaring — CoreModel's writability
strings (`HKQuantityTypeIdentifierStepCount`/`HeartRate`/`BodyMass`,
`HKCategoryTypeIdentifierSleepAnalysis`). **Tests** (`Tests/SyncKitTests/HealthKit/`,
21 total): `HealthKitIdentifierClassifierTests` (always compiles, no HealthKit
import) is the WP-06-required completeness test — every one of the 22 `.healthKit`
rows across all 39 `GoogleDataType` cases classifies to a non-nil kind, all four
structural kinds are exercised by at least one real case, the P0 set and the two
sentinels classify exactly as expected, unknown/malformed strings classify to `nil`,
and `.localOnly`/`.skip` cases are confirmed excluded from the `.healthKit` walk;
`HealthKitObjectTypeResolverTests` and `HealthKitAuthTests` (both
`#if canImport(HealthKit)`-guarded) add real-HealthKit-type coverage — every
`.healthKit` string resolves to the right concrete subclass, round-trips its
`.identifier`, the P0 set resolves to the exact real `HKObjectType` constants, both
sentinels resolve correctly, unknown identifiers throw and carry the offending
string, and `HealthKitAuth`'s validation ordering/gating (`.noHealthKitMapping` for
`.localOnly`/`.skip` types, `.healthDataUnavailable` when ungated, `.notDetermined`
fallbacks) all behave as documented.

**Verification performed in this session, and why it took an unusual path:**
`Packages/GoogleHealthClient` is mid-edit by a concurrent agent (WP-04/WP-05) and
currently fails to build for an unrelated reason: two source files share the literal
basename `GoogleHealthClient.swift` — the original WP-01 placeholder
(`Sources/GoogleHealthClient/GoogleHealthClient.swift`) and a new WP-05 file
(`Sources/GoogleHealthClient/DataClient/GoogleHealthClient.swift`) — which both plain
`swift test` ("multiple producers... GoogleHealthClient.swift.o") and
`xcodebuild build -scheme HealthLoom -destination 'generic/platform=iOS Simulator'`
("Filename \"GoogleHealthClient.swift\" used twice") reject outright, since SyncKit's
`Package.swift` depends on `GoogleHealthClient` per architecture.md §2 and I was not
permitted to touch that package. Confirmed via `stat`/`git status` that this is a
live, active edit (files touched to the second at the time I was checking), not a
stale artifact, and re-ran `swift test -Xswiftc -warnings-as-errors` in
`Packages/SyncKit` four times over the session (with a clean `.build` in between) —
same error every time; the failure is entirely inside `GoogleHealthClient` (verified
by reading its two colliding files) and reproduces identically outside SwiftPM via
`xcodebuild`. Rather than block on someone else's in-flight work, I verified WP-06's
own code two ways that don't route through `GoogleHealthClient` at all: (1) a scratch
SwiftPM package outside the repo
(`/private/tmp/.../scratchpad/wp06-verify`, deleted before finishing — never part of
the repo) with a copy of this session's four `Sources/SyncKit/HealthKit/*.swift` and
three `Tests/SyncKitTests/HealthKit/*.swift` files, depending only on the real
`Packages/CoreModel` (no `GoogleHealthClient` in its graph) — `swift test -Xswiftc
-warnings-as-errors` there: **21 tests, 3 suites, 0 failures, 0 warnings**; (2) direct
`xcrun swiftc -typecheck` of the same four `Sources/SyncKit/HealthKit/*.swift` files
against a real `CoreModel.swiftmodule` built for `arm64-apple-ios26.0-simulator`
(iPhoneSimulator26.4 SDK), with the exact flags `Package.swift` specifies
(`-swift-version 6 -strict-concurrency=complete -default-isolation MainActor
-enable-upcoming-feature NonisolatedNonsendingByDefault -enable-upcoming-feature
InferIsolatedConformances`): zero errors, zero warnings — confirming the real
`HKHealthStore.requestAuthorization`/`authorizationStatus`/`HKObjectType.*`
usage in `HealthKitAuth`/`HealthKitObjectTypeResolver` compiles for iOS with
HealthKit actually imported. Both checks together substitute for the blocked
in-repo `swift test`/`xcodebuild` runs per the handoff protocol's guidance to verify
"another way" when a concurrent package's in-flight state blocks the normal path.
**Once `GoogleHealthClient`'s duplicate-filename conflict is resolved (its own
scope, not touched here), `swift test -Xswiftc -warnings-as-errors` in
`Packages/SyncKit` and `xcodebuild build -scheme HealthLoom -destination
'generic/platform=iOS Simulator'` should be re-run as the authoritative in-repo
confirmation — nothing in this session's evidence suggests they'll fail, but they
were not able to actually complete end-to-end.** Also confirmed as an aside:
`HKHealthStore()`, `HKObjectType.quantityType(forIdentifier:)`/`categoryType`/
`workoutType()`/`correlationType(forIdentifier:)`, and
`HKHealthStore.authorizationStatus(for:)` are all safe to call on this macOS host
without a HealthKit entitlement or Info.plist usage strings (verified with disposable
scratch scripts, not part of the package) — only `requestAuthorization` itself would
need a real prompt, which no test in this suite calls (the `isAvailable`-gated tests
confirm `HKHealthStore.isHealthDataAvailable()` is `false` on this Mac and short-circuit
before ever reaching that call, guarding each such assertion with `guard !auth.isAvailable
else { return }` so the test steps aside harmlessly if ever run somewhere HealthKit
data really is available). **Deviations/judgment calls:** (1) `requestWrite`/
`requestRead` validate type→HealthKit-type resolution *before* the `isAvailable`
gate (the WP-06 brief doesn't specify an order) specifically so `.noHealthKitMapping`/
`.unresolvedIdentifier` are reachable and testable on any platform, including this
macOS host where `isAvailable` is unconditionally `false` and would otherwise mask
every other error path. (2) `HealthKitAuth`/`HealthKitObjectTypeResolver` are guarded
with `#if canImport(HealthKit)` as instructed, even though on this repo's current
macOS SDK (Xcode 26.4.1) `HealthKit.framework` is actually importable for native
macOS (`API_AVAILABLE(..., macos(13.0))` on `HKHealthStore` itself) and
`isHealthDataAvailable()` just returns `false` at runtime rather than failing to
compile — so the guard is currently a no-op on this machine, kept anyway as the
forward-looking, portable boundary the brief asks for. (3) Did not add a
`protocol HealthStoreProtocol`-style seam for `HealthKitAuth` — WP-06's own "Tests:"
line scopes required testing to the mapping table only and defers real-authorization
testing to UI tests (test plan §5); that seam is WP-08's stated job
(`HealthStoreProtocol` for save/delete/query), not WP-06's. (4) Left the WP-01
`SyncKitPlaceholder` marker in `SyncKit.swift` untouched (unlike CoreModel/Secrets'
placeholders, nothing outside `SyncKit` itself references it, so it could have been
removed, but leaving it matched prior WPs' conservative precedent and kept this
session's diff scoped to new files only). **Deliberately deferred:** the app
onboarding stub implementation-plan.md's WP-06 line mentions in its "Touches" list —
this session's explicit scope was `Packages/SyncKit` only, no app-target sources;
WP-10 owns the actual onboarding screen. `TypeMapper` (WP-07), `HealthKitWriter`
(WP-08), and `WatchCoverageIndex`/`ConflictResolver` (WP-12b) are unstarted, as
expected — this WP only had to make write/read authorization requestable and the
identifier mapping table resolvable and complete.

## WP-04 · GoogleAuthManager — OAuth 2.0 + PKCE

## WP-05 · GoogleHealthClient — typed v4 REST client

Built both WPs together in `Packages/GoogleHealthClient` (WP-05 depends on WP-04;
implemented in the stated order, one package, one session). **WP-04:** `PKCE` (enum,
`generateCodeVerifier`/`generateState` via `SecRandomCopyBytes`, `codeChallenge` via
CryptoKit SHA256 + base64url, verified against RFC 7636 Appendix B.1's own worked
example verifier→challenge pair); `GoogleOAuthScope.urlString(for:access:)` mapping
CoreModel's `GoogleDataType.Scope` families to the literal
`https://www.googleapis.com/auth/googlehealth.{scope}.{readonly|writeonly}` URL
(base-knowledge §2) — HealthLoom only ever requests `.readonly`; `GoogleAuthConfig`
(client ID, redirect URI/scheme, the three Google endpoints, `additionalScopes`
defaulting to `["openid","email"]` so the post-consent userinfo/`hd` call has
something to authenticate with); `actor GoogleAuthManager` — `validAccessToken()`
(cached-token + 60s expiry margin), single-flight refresh (`coalescedRefresh()`:
concurrent callers all await the one in-flight `Task`, cleared only by whichever call
created it, race-free because the check-and-set has no `await` between them under
actor serialization), `forceRefresh()` (unconditional refresh for WP-05's 401 path),
`completeConsent(code:codeVerifier:redirectURI:)` (token exchange → store refresh
token → userinfo call → `hd` claim present ⇒ `.workspaceAccountUnsupported`, tokens
cleared), `missingHealthScopes(from:)` (pure incremental-scope diff), and the
iOS-only `beginConsent`/`ensure` (in `GoogleAuthManager+Consent.swift`, `#if
os(iOS)`, presents `ASWebAuthenticationSession` with
`prefersEphemeralWebBrowserSession = true`, then calls back into the cross-platform
`completeConsent`). Token persistence goes through a new small
`protocol GoogleTokenStoring` (get/set refresh + access token) that
`Secrets.KeychainStore` satisfies via a same-file protocol-conformance extension
(`KeychainStore+GoogleTokenStoring.swift`) rather than a wrapper type — no
`@retroactive` needed since this package owns the protocol and imports `Secrets`.
**WP-05:** `GoogleHealthClient` (data client struct, `DataClient/GoogleHealthDataClient.swift`
— same name as the module per architecture.md's key-types list; had to rename the
*file* to avoid an SPM "multiple producers" clash with WP-01's placeholder
`GoogleHealthClient.swift`, which still holds the untouched `GoogleHealthClientPlaceholder`
marker `SyncKit` references) — `reconcile`/`dailyRollup`, both `@concurrent`, hitting
`users/me/dataTypes/{endpointName}/dataPoints:{method}` with a POST body of
`startTime`/`endTime`/`pageToken`; `GoogleDataPoint`/`DataSource`/`Page` (flat decode
target); `UnitNormalizer` (table-driven, currently one row: `distance.distance`
mm→m); resilience loop (401 → `auth.forceRefresh()` → exactly one retry, else
`.unauthorized`; 429/5xx → `BackoffPolicy` exponential+jitter, base 1s/cap 60s/max 5
attempts, `Retry-After` header honored verbatim when present) with **all** timing
behind injected `BackoffSleeper`/`JitterSource` protocols (no direct `Task.sleep` in
the retry loop) and all wall-clock reads behind `TokenClock` — both fully virtual in
tests. All networking (`HTTPSession` protocol) is injected; no real network in any
test. Fixtures under `Tests/GoogleHealthClientTests/Fixtures/GoogleHealth/`:
`steps.json`, `heart-rate.json`, `sleep.json`, `weight.json`,
`paged-steps-p1.json`/`-p2.json`, `error-429.json` per WP-05 step 7, **plus one
addition beyond the literal list**, `distance.json`, added specifically to exercise
the required mm→m normalization test (none of the seven listed fixtures contain a
distance field) — every fixture carries a `"_comment"` key recording that its
envelope shape (top-level `point` array + `nextPageToken`, `dataSource`
platform/device.displayName/recordingMethod, `value` object keyed
`<dataType.filterName>.<field>`) is hand-derived from base-knowledge §2, since that
doc describes the nesting convention but not an exact response envelope — this is
flagged as an assumption to reconcile against real API access (still gated on P-1.3,
the Google Cloud OAuth client). **Concurrency note surfaced by this WP:** both
packages set `.defaultIsolation(MainActor.self)` (WP-01), which turns out to apply
not just to this package's own declarations but transitively to CoreModel's
user-declared computed properties too (`GoogleDataType.endpointName`/`.filterName`
are MainActor-isolated in *their* module for the same reason) — resolved by reading
`type.endpointName` once via `await` per request (outside the retry loop) in the
data client, and by using `GoogleDataType.rawValue` (compiler-synthesized, not
subject to the default-isolation inference the same way) instead of `.filterName`
in `UnitNormalizer`/prefix-stripping, documented inline at both call sites so a
future reader doesn't "fix" it back to `.filterName` and reintroduce the isolation
error. **Verification performed in this session:** `swift test -Xswiftc
-warnings-as-errors` passes in `Packages/GoogleHealthClient` from a clean `.build` —
35 tests / 7 suites, 0 failures, 0 warnings — covering every required test from both
WPs' "Tests:" lines (PKCE known-vector + shape; token exchange request encoding for
both grant types; refresh single-flight, 10 concurrent callers ⇒ 1 refresh request,
asserted via the recording HTTP stub; expiry margin at the exact 60s boundary via a
manual/settable clock; `invalid_grant` ⇒ `.reconsentRequired` with tokens cleared;
Workspace `hd`-claim detection *and* a personal-account non-detection counterpart;
fixture decode goldens for steps/heart-rate/sleep/weight incl. the sleep session's
nested stage segments preserved verbatim in `sessionPayload`; mm→m normalization,
both via the `distance.json` fixture and directly against the `UnitNormalizer` table;
2-page pagination stitching with an asserted-identical request window across both
pages; 401→forceRefresh→retry exactly once, plus a persistent-401 case proving it
gives up after exactly one retry instead of looping; 429 backoff schedule
`[1.0, 2.0, 4.0, 8.0]` against the recording sleeper with zero jitter, plus a
separate 5xx-backoff case and a `Retry-After`-honored case; malformed JSON and
missing-required-field decode failures ⇒ `.decodingFailed`) plus a redaction
tripwire (a fake refresh token and a fake authorization code are asserted absent
from every `GoogleAuthError.description` on the relevant failure paths, and from the
result of a deliberately-mismatched redirect-state extraction). Also re-verified
after this session's changes: `Packages/CoreModel` (15 tests), `Packages/Secrets` (14
tests), `Packages/SyncKit` (22 tests — WP-06 landed concurrently in this checkout),
and `Packages/CoachKit` (1 placeholder test) all still build and pass cleanly in
isolation — none of them were touched. **The one thing `swift test` structurally
cannot verify:** the iOS-only `#if os(iOS)` block in
`GoogleAuthManager+Consent.swift` (the actual `ASWebAuthenticationSession` /
`beginConsent`/`ensure` presentation code) never compiles under a macOS `swift test`
run at all, by design — so as an extra check beyond the task's minimum bar, this
session also ran `xcodebuild build -scheme GoogleHealthClient -destination
"generic/platform=iOS Simulator"` directly against the SPM package (Xcode can treat
a `Package.swift` as a project via `-list`/`-scheme`), which built the whole package
including the iOS-only file for arm64 **and** x86_64 simulator slices with zero
errors and zero warnings — real device/simulator behavior (presenting the actual
consent sheet, receiving a real redirect) is still unverified, since that requires
the real Google Cloud iOS OAuth client from P-1.3, which remains outstanding.
**Deviations / judgment calls (handoff protocol's "blocked?" clause):** (1) the
Health API's exact `reconcile`/`dailyRollup` request shape is under-specified in
base-knowledge.md (it documents the resource pattern and method names but not a
request verb/body) — implemented as `POST` with a JSON `{startTime, endTime,
pageToken?}` body against `.../dataPoints:{method}`, following Google's general
custom-method REST convention (colon-suffixed method name); this is a best-guess
interface to reconcile once real API access/docs exist, not a confirmed contract.
(2) `ensure(scopes:)` and `beginConsent` are iOS-only per the task brief's own
framing ("ASWebAuthenticationSession is iOS-only UI"); `missingHealthScopes(from:)`
itself is plain actor-isolated (not `nonisolated`) since it reads `grantedScopes`,
and is tested directly via `@testable import` rather than through the UI-facing
`ensure` wrapper. (3) `grantedScopes` lives only in actor memory, populated from the
token/refresh response's `scope` field — not persisted across app launches; a fresh
launch re-derives it from a fresh refresh's `scope` response before `ensure` can
correctly gate anything, which is fine for P0 (no settings screen calls it yet) but
worth a callback for whoever builds WP-17's incremental-consent settings screen. (4)
`BackoffPolicy`'s jitter is `capped_delay * (1 + jitterFraction * jitterMaxFraction)`
(default `jitterMaxFraction = 0.25`, so up to +25% on top of the exponential value)
rather than the more common "full jitter" (random *within* `[0, capped_delay]`) —
chosen so the *test* schedule with a zero-jitter fake is the clean, exactly-doubling
sequence the WP-05 test line implies ("429 backoff schedule... against a virtual
clock"), while production still gets real jitter; this is a reasonable reading of
"exponential backoff with jitter," not a literal spec, since base-knowledge.md
doesn't prescribe a jitter formula. (5) Did not persist `cachedAccessToken` reads
from Keychain on `GoogleAuthManager` init (i.e., a fresh `GoogleAuthManager` always
performs one refresh before its first `validAccessToken()` returns, even if a still-
valid access token was stored from a previous run) — `SecretKey.googleAccessToken`
is written on every successful refresh/consent for future use (e.g. diagnostics) but
never read back on startup; this trades one extra refresh call per app launch for
simplicity, and is a reasonable place for a future WP to optimize if refresh-quota
pressure ever shows up. **Outstanding per the handoff protocol:** the real-Google
smoke test in both WPs' "Done when" (consent against real Google on device; a real
account's week of steps) requires the human-provisioned OAuth client (P-1.3) —
skipped, as instructed, and still gated on that prerequisite; also still open is
P-1.3 itself and reconciling `project.yml`'s placeholder OAuth redirect scheme
(`com.healthloom.app`, per WP-01's note) against whatever real reversed-client-ID
scheme Google issues once that client exists.

## WP-07 · TypeMapper v1 (steps, heart rate, sleep, weight)

Built `Packages/SyncKit/Sources/SyncKit/TypeMapper/` as four new files, following the
pure/impure split WP-06 established (`HealthKitIdentifierClassifier` vs.
`HealthKitObjectTypeResolver`) rather than the single `HKQuantitySample`/`HKCategorySample`-
returning function the plan's illustrative sketch shows: **`MappedTypes.swift`**
(HealthKit-free, no CoreModel/GoogleHealthClient import either) — `MappedUnit`
(`.count`/`.countPerMinute`/`.kilogram`), `MappedSleepStage` (an `Int` enum whose raw
values are hardcoded to match HealthKit's real `HKCategoryValueSleepAnalysis` constants —
`asleepUnspecified=1, awake=2, asleepCore=3, asleepDeep=4, asleepREM=5` — cross-checked
against the real enum in a HealthKit-guarded test so a future SDK change can't drift them
apart silently), `MappedMetadata`, `MappedQuantitySample`, `MappedCategorySample`, and the
pure result type `MappedDecision` (`.quantity/.category/.localOnly/.skip`); **`TypeMapper.swift`**
— `enum TypeMapper { static func decide(_ p: GoogleDataPoint) -> MappedDecision }`, the
actual "correctness lives here" mapping/dropping logic, still HealthKit-free; **`SleepSessionDecoding.swift`**
— decodes `GoogleDataPoint.sessionPayload`'s `"sleep.segment"` array (matching the existing
`sleep.json` fixture's shape) via a `nonisolated` `JSONDecoder` + two `ISO8601DateFormatter`s
(mirroring, but not reusing — it's not `public` — GoogleHealthClient's own
`ISO8601Formatting.swift`); and **`MappedObject.swift`** — the plan's literal required shape,
`public enum MappedObject { case quantity(HKQuantitySample); case category([HKCategorySample]);
case localOnly; case skip }` with the two HealthKit cases behind `#if canImport(HealthKit)`,
plus `extension TypeMapper { static func map(_ p: GoogleDataPoint) -> MappedObject }` that
calls `decide(_:)` and wraps its result into real HK objects. **On this repo's macOS test
host, HealthKit is importable** (WP-06 already established this) and constructing sample
*objects* needs no entitlement/store/simulator, so both layers — and all required golden
tests — run for real under plain `swift test`, matching WP-07's "Done when" bar exactly.
**Routing (step 5):** dispatches off CoreModel's `GoogleDataType.writability` — `.localOnly`
→ `.localOnly`, `.skip` → `.skip`, `.healthKit` → a second switch on the four implemented P0
types (steps/heartRate/weight/sleep); any *other* `.healthKit` row (distance, bodyFat,
exercise, food, ...) also currently falls to `.skip` since this WP doesn't implement it yet —
**flagged here as the scope note WP-11's implementer needs**: broaden `decideHealthKitMapped`'s
switch, don't touch the routing shape. **Metadata (step 4):** every emitted sample carries
`HKMetadataKeyExternalUUID = p.id`, `"healthloom.externalID": p.id` (note `healthloom.*`, not
`bridge.*` — matches the app's rename per architecture.md's naming section), and
`"healthloom.sourceDevice": p.source.deviceDisplayName` (carried through as `nil`, never
coerced to `""`, when Google didn't report a device name — tested explicitly). **Sleep
(step 3):** stage map `awake→.awake, light→.asleepCore, deep→.asleepDeep, rem→.asleepREM`,
anything else (including a literal `"unknown"`) `→.asleepUnspecified`; segments are sorted by
start and walked with a monotonically non-decreasing cursor so every emitted segment's start
is clamped forward to at least the previous emitted segment's end (guarantees no overlap) and
both start/end are clamped into the session's own `[start, end]` bounds; a segment that's
zero-length on arrival or fully consumed by clamping is dropped, and a session left with zero
usable segments after this process maps to `.skip` (never an empty `.category([])`).
**Out-of-range decision, pinned (step "Tests:" line):** negative steps and heart rate outside
`1...300` bpm are **dropped** (routed to `.skip`) — 300 is a deliberately generous upper bound
so the filter only catches sensor-glitch values like the plan's own "400" example, not real
exercise data (190 bpm and the boundary value 300 itself are both tested as accepted, 300.01
as dropped); zero steps (as opposed to negative) is a normal reading and is accepted. The
plan's "count" half of "drop + count" is **deliberately not implemented here** — `TypeMapper`
is a pure function with no side channel, and `CoreModel.SyncState.itemCount` already exists
for whichever pipeline stage (WP-09's `SyncEngine`) actually tallies outcomes; documented
inline at the `heartRateValidRange` declaration so this isn't mistaken for an oversight.
**Weight unit (step 2):** base-knowledge.md's "odd base units" note names only distance's
millimeters, never weight; the existing WP-05 `weight.json` fixture explicitly documents its
`70.5` value as already-kilograms with no `UnitNormalizer` conversion applied, punting final
confirmation to this WP — pinned here as **kilograms, no scaling** (70.5 reads as a plausible
adult body weight in kg; it would be an implausible ~70 g or ~70500 g under the other
candidate units), with a doc-comment flagging it as still-unconfirmed pending real API access
(P-1.3). **Fixtures:** per the handoff protocol's reuse instruction, could not literally share
GoogleHealthClient's `Fixtures/GoogleHealth/*.json` files (different package's test target,
and `decodeDataPoint` is package-internal) — instead `Tests/SyncKitTests/TypeMapper/TypeMapperFixtures.swift`
reconstructs the exact same four scenarios (`steps-0001`, `hr-0001`, `weight-0001`,
`sleep-0001` — same IDs/timestamps/device names/values) as literal `GoogleDataPoint` values,
with every default parameter traced back to its source JSON fixture in a doc comment.
**Tests** (`Tests/SyncKitTests/TypeMapper/`, 34 new, all passing): `TypeMapperGoldenTests`
(9) — one golden test per P0 type (exact HK identifier string/unit/value/dates/metadata) plus
routing tests (`.localOnly` for ECG/AZM/activeMinutes/IRN, `.skip` for a redundant-rollup type
and for an unimplemented-but-`.healthKit` type, missing-field and missing-device-name
handling); `TypeMapperSleepStageTests` (6) — unknown stage + zero-length segment in one
session (three segments emitted, not four), a dedicated overlapping-segments scenario (a
short segment fully nested inside a preceding one is suppressed, not doubled), bounds-clamping
on both edges, an all-dropped session, and missing/malformed `sessionPayload`;
`TypeMapperOutOfRangeTests` (9) — negative steps, HR 0/400/negative, HR at 190 and exactly at
the 300 boundary (accepted) vs. 300.01 (dropped), non-positive weight;
`TypeMapperPropertyTests` (3, one parameterized over 3 windows) — mapper never emits
`end < start` across all four P0 decision paths including a deliberately reversed window, plus
an exhaustive-switch placeholder documenting the WP-11 "fraction outputs stay 0...1" pattern
for whenever `MappedUnit` gains a fraction case; `TypeMapperHealthKitMappingTests` (7,
`#if canImport(HealthKit)`) — confirms `map(_:)` wraps each golden decision into a real
`HKQuantitySample`/`HKCategorySample` with the right `HKQuantityType`/`HKUnit`/`HKQuantity`/
dates/metadata, the `MappedSleepStage`-vs-real-enum cross-check, and that `.localOnly`/`.skip`/
out-of-range decisions pass through `map(_:)` unchanged.
**MainActor-isolation gotcha (anticipated per the task brief, and hit as expected):**
`GoogleDataType.writability` is a *computed* property in CoreModel, which — like SyncKit —
opts into `.defaultIsolation(MainActor.self)` (architecture.md §3), so it is itself
MainActor-isolated, unlike `GoogleDataPoint`/`DataSource`'s plain *stored* properties (both
structs are explicitly `nonisolated`, per WP-05). Resolved the same way WP-06's
`HealthKitAuth.resolveSampleType` already did: left `TypeMapper.decide`/`.map` at their
implicit MainActor isolation (no `nonisolated` annotation) rather than fighting it, so reading
`point.dataType.writability` inside them needs no `await` — same-actor synchronous access.
Hit a second, related instance while writing `SleepSessionDecoding.swift`: the closure passed
to `JSONDecoder.dateDecodingStrategy = .custom` is a synchronous, non-actor-isolated closure
type, so a MainActor-isolated `date(from:)` helper couldn't be called from inside it at all
(not even with `await`, since the closure isn't `async`) — this one *required* an explicit
`nonisolated` (on the whole `SleepSessionDecoding` enum, plus `nonisolated` on the
`SleepSessionWire`/`Segment` structs so their compiler-synthesized `Decodable` conformance —
`InferIsolatedConformances` — is itself nonisolated and callable from the nonisolated decode
path), rather than the "leave it MainActor-isolated" resolution used everywhere else in this
package. **Deviations from the plan's illustrative sketch:** (1) `GoogleDataPoint`'s real
shape (`id, dataType: GoogleDataType, start, end, source: DataSource, values: [String: Double],
sessionPayload: Data?`) matches the plan's prose description closely, but `source.deviceDisplayName`
is `String?`, not a non-optional `String` — handled by carrying `nil` through
`MappedMetadata.sourceDevice` rather than coercing it. (2) The plan's `MappedObject` sketch is
a single flat enum wrapping real `HK*` types directly; built `MappedDecision` (HealthKit-free)
underneath it instead, per this WP's own explicit instruction to provide a HealthKit-free
representation for unit-testability — `MappedObject`/`TypeMapper.map(_:)` still exist exactly
as specified, `TypeMapper.decide(_:) -> MappedDecision` is additive, not a replacement. (3) Did
not touch `Packages/SyncKit/Sources/SyncKit/HealthKit/` at all (read-only, per scope) and did
not touch any other package. **Verification performed in this session:** `swift test -Xswiftc
-warnings-as-errors` in `Packages/SyncKit` — **56 tests / 8 suites, 0 failures, 0 warnings**
(22/3 pre-existing WP-06 tests + 34/5 new); then re-ran the same command in each of
`Packages/CoreModel` (15/6), `Packages/Secrets` (14/3), `Packages/GoogleHealthClient` (35/7),
and `Packages/CoachKit` (1/0) without editing any of them — all five still pass together, 0
failures, 0 warnings across the board. **Deliberately deferred:** distance/bodyFat/HRV/SpO2/
etc. (`.healthKit` rows beyond the P0 four — WP-11), Exercise→`HKWorkout` (WP-12),
food/hydration correlations (WP-13), and any actual counting of dropped/out-of-range points
(WP-09's `SyncEngine`, which owns `SyncState.itemCount`) — all as scoped.

## WP-08 · HealthKitWriter

Built `Packages/SyncKit/Sources/SyncKit/HealthKitWriter/` as three new files, all guarded
`#if canImport(HealthKit)` except the pure error/report types, mirroring WP-06's
`HealthKitAuth.swift` posture rather than WP-07's pure/impure split — WP-08's whole job is
the real save/delete/query mechanics, so there's no HealthKit-free "decision layer" to
carve out the way `MappedDecision` was for TypeMapper. **`HealthKitWriterTypes.swift`**
(no HealthKit import, always compiles) — `HealthKitWriterError` (`.workoutsNotYetImplemented`,
`.underlying(String)`, matching `HealthKitAuthError`'s redaction posture) and
`AppDataWipeReport` (`[String: Int]` keyed by `HKObjectType.identifier`, plus a `.total`),
deliberately HealthKit-free so both are unit-testable without importing HealthKit at all.
**`HealthStoreProtocol.swift`** — `protocol HealthStoreProtocol` (save, existingExternalIDs,
deleteObjects(ofType:externalIDs:), deleteAllAppData(ofType:)) plus `HealthKitStore`, the
real `HKHealthStore`-wrapping conformer. **`HealthKitWriter.swift`** — the public
orchestration class apps/`SyncEngine` (WP-09) hold: `existingExternalIDs(type:start:end:)`,
`save(_:)`, `delete(externalIDs:type:)` + a generic `delete(externalIDs:types:)` multi-type
overload, `deleteAllAppData(types:)`, and `saveWorkout(_:)` (the required WP-12 stub — always
throws `.workoutsNotYetImplemented` rather than silently no-op-ing). Every write/delete
method is typed-throws `HealthKitWriterError`, matching `HealthKitAuth`'s house style.
**Critical design correction made before writing any production code (see
`HealthStoreProtocol.swift`'s header for the full writeup):** an early design that had the
protocol pass raw `NSPredicate`/`HKQuery` objects through (closer to the plan's illustrative
"`HKQuery.predicateForObjects(...)`" phrasing) was rejected once actually working through
how `MockHealthStore` would conform to it — HealthKit's predicate factory methods return
opaque, HealthKit-private `NSPredicate` subclasses that only a real `HKHealthStore`'s query
engine can evaluate (`.evaluate(with:)` against an in-memory array is unsupported), and
`HKSource` has no public initializer, so a mock could never fabricate a "foreign app" source
to prove delete-by-source doesn't touch it. So `HealthStoreProtocol` is one level higher:
each method names the HealthKit-semantic operation needed (existence-by-window,
delete-by-external-ID, delete-by-this-app's-own-writes) rather than how to query for it;
`HealthKitStore` is the only place real `HKQuery` predicates get built, and
`MockHealthStore` (test target) implements identical semantics against a plain in-memory
array with an explicit `isAppWritten` bookkeeping flag standing in for `HKSource`
attribution. This is the single biggest deviation from the plan's literal sketch, and is
exactly the kind of "signatures are starting points, not contracts" call the handoff
protocol anticipates — the *behavior* WP-08 asks for (batched existence checks, scoped
deletes, HK entitlement-free unit testing) is preserved, arguably better served, than a
literal `NSPredicate`-passing seam would have been. **Existence-query strategy (WP-08 step
2, D4):** `existingExternalIDs(ofType:start:end:)` combines HealthKit's date-range
predicate (`HKQuery.predicateForSamples(withStart:end:options:)`), a metadata-key-*existence*
predicate (`HKQuery.predicateForObjects(withMetadataKey: HKMetadataKeyExternalUUID)` — no
`allowedValues:`, since this method's signature is a time window, not a candidate-ID list)
and a same-app-source predicate (`HKQuery.predicateForObjects(from: .default())`) into one
`NSCompoundPredicate`, run through exactly **one** `HKSampleQuery` (limit
`HKObjectQueryNoLimit`, bridged to async/await via `withCheckedThrowingContinuation` since
the newer `HKSampleQueryDescriptor<Sample>` requires a concrete `Sample: HKSample` generic
fixed at compile time and doesn't fit this method's runtime-erased `HKSampleType` parameter)
— literally one HK query per (type, window), per D4's invariant. The brief's suggested
`allowedValues:` predicate form *is* used, just in `deleteObjects(ofType:externalIDs:)`
instead: there, unlike the window-based existence check, a concrete candidate external-ID
set already exists, so `HKQuery.predicateForObjects(withMetadataKey:allowedValues:)` lets
HealthKit do the membership filtering server-side in the same single call — and needs no
date window at all, which is exactly what D13.4's retroactive cleanup needs (a conflicting
sample can be anywhere in the lookback window, not a contiguous range). Both predicate
forms named in the WP-08 brief ended up used, each in the call site its actual signature
fits, rather than picking one and falling back on the other. **Genericity for WP-12b/WP-35
(explicit brief requirement):** neither `delete(externalIDs:types:)` nor
`deleteAllAppData(types:)` hardcodes today's four P0 types (steps/heart rate/weight/sleep)
anywhere — both take the type list as a caller-supplied parameter, so WP-12b's retroactive
conflict cleanup (which may need to sweep a mix of quantity samples and an `HKWorkout`
sharing one external-ID set) and WP-35's disconnect-and-wipe flow (which by then will cover
far more than four types, per WP-11/12/13) can reuse the exact same primitives without any
change here. `AppDataWipeReport` reports an explicit entry (including an explicit `0`) per
requested type, satisfying WP-35's "per-type progress" wording. **Verified real-API
compilation two ways, both required since this session had no HealthKit entitlement or
booted/authorized simulator (same constraint WP-06 hit):** (1) `xcrun swiftc -typecheck`
scratch checks of the full protocol/adapter/writer/mock design against the real
`HealthKit.framework` for both `arm64-apple-macos26.0` and `arm64-apple-ios26.0-simulator`
targets, with this repo's exact `Package.swift` flags (`-swift-version 6
-strict-concurrency=complete -default-isolation MainActor -enable-upcoming-feature
NonisolatedNonsendingByDefault -enable-upcoming-feature InferIsolatedConformances`) —
zero errors, zero warnings on both targets, confirming every real HealthKit API used
(`HKHealthStore.save`/`.delete`/`.deleteObjects(of:predicate:)` — all as genuine
completion-handler-derived `async throws` methods, not guesses — `HKSampleQuery`,
`HKQuery.predicateForObjects(withMetadataKey:)`/`(withMetadataKey:allowedValues:)`/`(from:)`,
`HKQuery.predicateForSamples(withStart:end:options:)`, typed throws on a protocol
requirement) exists and behaves as documented before writing a single production file; (2)
in-repo `xcodebuild build -scheme SyncKit -destination 'generic/platform=iOS Simulator'` —
**BUILD SUCCEEDED**, compiling this WP's three new Sources files for real
`arm64-apple-ios26.0-simulator` **and** `x86_64-apple-ios26.0-simulator` slices — followed
by `xcodebuild build-for-testing -scheme SyncKit -destination 'generic/platform=iOS
Simulator'` from a fully clean DerivedData — **TEST BUILD SUCCEEDED**, additionally
compiling `MockHealthStore.swift`, `HealthKitWriterTests.swift`, and
`HealthKitStoreIntegrationTests.swift` (all real `HKQuantitySample`/`HKObjectType`
construction) for iOS. **Tests** (`Tests/SyncKitTests/HealthKitWriter/`, 17 new): with
`MockHealthStore` (no HealthKit entitlement, no real `HKHealthStore` — `HealthKitWriterTests.swift`,
16 tests) — batch composition (one `save` call for a 3-sample batch, empty batch never
calls the store), existence-check window/metadata/type filtering (in-window found,
out-of-window excluded, no-metadata excluded, cross-type leakage excluded), the literal
dedupe-diff pattern from WP-09's own sketch (seed one existing ID, confirm it's the only
one `existingExternalIDs` reports, filter it out of an incoming batch, confirm exactly the
two new ones get saved and the store ends up with 3 total), delete-by-externalID (removes
only the target, doesn't cross-contaminate a same-ID sample of a different type, empty-ID
delete never calls the store, the generic multi-type overload sums correctly across types),
deleteAllAppData (removes only `isAppWritten` entries and leaves a "foreign" seeded sample
alone, reports an explicit `0` for a type with nothing to delete, sweeps multiple types
independently), the workouts stub throwing without ever touching `save`, and error
propagation from the underlying store passing through unchanged. Plus one gated real-store
integration suite (`HealthKitStoreIntegrationTests.swift`, 1 test) exercising the exact
test-plan.md §3 sequence — save → `existingExternalIDs` finds it → the diff correctly
skips a re-save → delete-by-externalID removes only the target — against the real
`HealthKitStore`/`HKHealthStore`, gated by a synchronous, side-effect-free
`.enabled(if: hasRealHealthKitStepWriteAuthorization())` trait (checks
`HKHealthStore.isHealthDataAvailable()` and `authorizationStatus(for:) == .sharingAuthorized`
for step count — never attempts a write itself) that skips with a clear explanatory message
rather than failing, the exact same pattern WP-03's `KeychainSecurityBackendTests.swift`
established for its real-Keychain round-trip. **Confirmed it actually skips (not silently
passes) in this session:** `swift test` reports `➜ Test "real store: save ->
existingExternalIDs finds it -> ..." skipped: "Real HealthKit write authorization for
HKQuantityTypeIdentifierStepCount is not currently granted to this test process..."` —
expected, since `HKHealthStore.isHealthDataAvailable()` is `false` on this repo's macOS test
host (WP-06/07 both already found this) and HealthKit authorization can only ever be
granted through interactive UI, never headlessly. **This is flagged as required follow-up,
not a blocker:** re-run `HealthKitStoreIntegrationTests` on a real device or simulator where
HealthLoom has already been launched once and the user granted write access to steps via the
real onboarding flow (WP-10) — nothing in this session's mock-store coverage or the two
compilation checks above suggests it will behave differently, but it has not actually
executed against a real store end-to-end. **Verification performed in this session:**
`swift test -Xswiftc -warnings-as-errors` in `Packages/SyncKit` from a clean `.build` —
**73 tests / 10 suites, 0 failures, 0 warnings** (72 pass + 1 expected skip; 56 pre-existing
WP-06/07 tests + 17 new); then re-ran the same command in each of `Packages/CoreModel`
(15/6), `Packages/Secrets` (14/3), `Packages/GoogleHealthClient` (35/7), and
`Packages/CoachKit` (1/0) without editing any of them — all five still pass together, 0
failures, 0 warnings across the board. **Deviations from the plan's literal text (handoff
protocol's "blocked?" clause):** (1) the protocol-shape correction described above (the
single biggest deviation, fully justified above and in-code); (2) `deleteAllAppData` and
the multi-type `delete` overload take an explicit `types:` parameter rather than the plan's
bare `deleteAllAppData()` — deliberate, per the WP-08 brief's own explicit instruction not
to over-fit to today's four P0 types; (3) added typed throws (`HealthKitWriterError`) to
every `HealthStoreProtocol`/`HealthKitWriter` method, matching `HealthKitAuth`'s house style,
where the plan's sketch shows plain (unlabeled) throwing signatures. **Deliberately
deferred, as scoped:** `HKWorkoutBuilder`/Exercise→`HKWorkout` integration (WP-12, behind
the explicit stub); the real diff/upsert orchestration against `SyncState`/`LocalSample`
(WP-09's `SyncEngine`, which will hold a `HealthKitWriter` and call
`existingExternalIDs`/`save` per page); D13's actual watch-priority conflict resolution
(WP-12b) — this WP only had to make sure `delete`'s primitives are generic enough for
WP-12b to reuse, not implement the resolver itself.

## WP-09 · SyncEngine v1

Built `Packages/SyncKit/Sources/SyncKit/SyncEngine/` as three new files, following the
pure/impure split every prior SyncKit WP established (`HealthKitIdentifierClassifier`/
`HealthKitObjectTypeResolver`; `MappedDecision`/`MappedObject`;
`HealthKitWriterTypes.swift`/`HealthKitWriter.swift`): **`SyncEngineTypes.swift`**
(no HealthKit import, always compiles) — `SyncConfiguration` (initialWindow 7d,
defaultLookback 72h, sleepLookback 7d, `lookback(for:)`), `SyncClock`/`SystemSyncClock`
(mirrors `GoogleHealthClient`'s own `TokenClock` seam exactly, same doc-comment lineage),
`GoogleReconcileClient` (a narrow protocol over just `reconcile(type:since:until:pageToken:)`
— WP-09's "the Google client, or a narrow protocol over it, so tests can stub it"),
`ConflictFiltering`/`IdentityConflictFilter` (the WP-12b hook, see below), and
`SyncStatus`/`SyncOutcome` (the per-type result report `syncAll` collects). **All
protocol requirements are declared `nonisolated`**, matching every existing protocol in
this codebase (`HTTPSession`, `TokenClock`, `BackoffSleeper`, `JitterSource`), so that a
conforming type's own actor affinity (or lack of one) never blocks satisfying the
requirement. **`GoogleHealthClient+SyncEngine.swift`** — `extension GoogleHealthClient:
GoogleReconcileClient {}` with zero additional code (the real client's
`reconcile(type:since:until:pageToken:)` signature already matches exactly; its default
`pageToken: String? = nil` doesn't block conformance) — not a retroactive conformance,
since SyncKit (this module) owns the protocol even though it doesn't own
`GoogleHealthClient`, the identical pattern WP-04/05 already used for
`KeychainStore+GoogleTokenStoring.swift`. **`SyncEngine.swift`** (`#if canImport(HealthKit)`,
matching `HealthKitWriter.swift`'s own guard, since it needs `HKObject`/`HKSampleType` and
`HealthKitWriter` itself) — `public actor SyncEngine`, constructed with an injected
`GoogleReconcileClient`, `HealthKitWriter`, `ModelContainer`, `SyncClock` (default
`SystemSyncClock`), `SyncConfiguration` (default), and `ConflictFiltering` (default
`IdentityConflictFilter`); `sync(type:)` (in-flight-deduplicated, single-execution
coalescing), `syncAll(types:)` (sequential, continues past a failing type), and the private
`performSync`/`processPage`/`fetchOrCreateSyncState`/`upsertLocalSample` pipeline.

**Exactly what `SyncState.itemCount` counts (WP-09's explicit "decide and document" ask,
and the wiring of WP-07's deferred out-of-range counting):** one Google *data point*
processed in a run, counted exactly once regardless of how many HK samples it expanded
into (a multi-stage sleep session's whole array of category segments is one item, not N).
Each processed point contributes to the run's count in exactly one of three ways: (1)
**newly written** to HealthKit — its external ID wasn't already present per the batched
existence diff (architecture.md D4); an already-present point contributes 0, so an
idempotent re-run never inflates this component; (2) **`.localOnly` upserted** into
`LocalSample` — every upsert counts, insert or update, since `LocalSample` (unlike the HK
path) has no "already present, skip" branch in this WP; (3) **`.skip`** — an
unmapped/unimplemented/out-of-range point `TypeMapper` dropped, wiring up WP-07's
explicitly deferred "counting is the SyncEngine's job" note. `SyncState.itemCount` itself
is a **running cumulative total across the type's entire history**, incremented by a run's
count only when that run's *entire* window succeeds; `SyncOutcome.itemCount` (the
in-memory per-run report) still reports whatever partial count was reached before a
mid-window failure (informational — useful for a future sync-log/diagnostics UI, WP-18),
but that partial count is never added to the persisted `SyncState.itemCount`.

**Cursor semantics implemented exactly per architecture.md D3 and this WP's brief:**
`window.start = (SyncState.lastSyncedAt ?? now − initialWindow) − lookback(type)`,
`window.end = now`; `SyncState.lastSyncedAt` only advances to `window.end` when every page
of the run's fetch succeeds. A page's writes/upserts are **not rolled back** on a later
page's failure — they're idempotent (D4), so leaving them in place and simply not
advancing the cursor means the next run safely re-pulls the *entire* window (confirmed by
the "failure mid-pagination" test asserting the retried run's first-page request has an
identical `since`/`until` to the failed run's). **One deliberate efficiency improvement
over the plan's illustrative per-page phrasing** ("`existing = writer.existingExternalIDs(
type, pageWindow)`" inside the per-page loop): this implementation calls
`existingExternalIDs` **once per (type, whole-run window)**, before the page loop starts,
then threads the resulting `Set<String>` through `processPage` by `inout`, growing it with
each page's newly-written IDs. This still satisfies D4's "batched, never per-sample"
invariant (arguably more strictly — one query per run instead of one per page) and
additionally guards against a point appearing in two pages of the same window being
double-written within a single run; flagged here per the handoff protocol's "signatures
are starting points" clause since it's a structural, not just cosmetic, deviation from the
sketch.

**In-flight de-duplication** (architecture.md §3's `Set<GoogleDataType>` note,
implemented as `[GoogleDataType: Task<SyncOutcome, Never>]` instead of a bare `Set` so
concurrent callers *coalesce onto the same result* rather than merely being turned away):
`sync(type:)` checks `inFlight[type]` and, if present, awaits that existing `Task`'s
`.value` instead of starting a new pipeline run; the check-and-insert has no `await`
between them, so under actor serialization it's race-free by construction (same pattern
`GoogleAuthManager.coalescedRefresh()` already established in `GoogleHealthClient`).
`syncAll(types:)` awaits `sync(type:)` once per type in a plain sequential `for` loop
(architecture.md's "predictable quota usage") and can't be interrupted by one type's
failure, since `sync(type:)` itself never throws — every failure becomes an `.error`
`SyncOutcome`, not a thrown error.

**`LocalSample` upsert is fetch-then-mutate, not a blind re-insert:** even though WP-02's
own tests confirmed SwiftData's `.unique` attribute behaves as last-write-wins on a raw
re-insert, `upsertLocalSample` explicitly fetches any existing row by `externalID` first
and mutates its fields in place when found. This is deliberate, not incidental: a blind
re-insert would reconstruct the whole `LocalSample` object fresh each time, silently
resetting `linkedWatchWorkoutUUID` to `nil` on every routine re-sync — a field WP-12b's
`ConflictResolver` will set later (architecture.md D13.2) and that this WP must never
clobber. `LocalSample.payloadJSON`'s shape (`SyncEngineLocalPayload`, private to
`SyncEngine.swift`) is a WP-09-invented minimal `Codable` capturing `GoogleDataPoint`'s
fields verbatim — not a spec handed down by the plan (WP-14 owns the real per-type
payload schema for the in-app "Not in Apple Health" badge rows and may replace this
shape entirely; flagged in that file's own doc comment).

**The `ConflictFiltering` hook (WP-09's explicit ask: "a pass-through/identity stage...
so WP-12b can install real watch-priority conflict resolution without changing
SyncEngine's structure"):** implemented as a protocol (`resolve(_:MappedObject, for:
GoogleDataPoint) async -> MappedObject`) rather than a closure, operating on `MappedObject`
— the already-HK-wrapped decision — because that's exactly the representation immediately
upstream of the existence-diff/write step it sits in front of, and exactly what D13.2's
real resolver needs to downgrade (`.quantity`/`.category` → `.localOnly`, when a Google
Exercise session overlaps a watch workout). Declared `async` even though this WP's own
`IdentityConflictFilter` never suspends, specifically because WP-12b's real resolver will
need to consult `WatchCoverageIndex` (HealthKit reads, inherently async) — avoids a
signature-breaking change later. A second test conformer
(`SuppressingConflictFilter`, test-file-local) proves the seam is genuinely wired between
mapping and the write step, not just accepted-and-ignored.

**MainActor-isolation gotcha (anticipated by WP-07's own TypeMapper.swift header, and hit
exactly as predicted):** `actor SyncEngine` is its own, distinct actor — **not** MainActor
— per architecture.md §3's explicit list (`actor SyncEngine`, `actor GoogleAuthManager`,
`actor KeychainStore`), unlike almost everything else in this package (`TypeMapper`,
`HealthKitObjectTypeResolver`, `HealthKitWriter`, …), which are all implicitly
MainActor-isolated because none of them declares its own isolation and the package
default is `.defaultIsolation(MainActor.self)`. Crossing from `SyncEngine` into that
MainActor-isolated code — `type.writability`, `HealthKitObjectTypeResolver.sampleType(
for:)`, `TypeMapper.map(_:)` — needed an explicit `await` at each call site, exactly the
"standard cross-actor call syntax for a synchronous isolated function" WP-07's own header
called out by name as the expected resolution for "a future actor-isolated caller (e.g.
WP-09's actor SyncEngine)." **One additional instance not previously seen in this
package,** surfaced only once real code was compiled rather than reasoned about: a private
`Codable` struct (`SyncEngineLocalPayload`, used only inside `upsertLocalSample`) failed
to compile with "main actor-isolated initializer ... in a synchronous actor-isolated
context" and "main actor-isolated conformance of 'SyncEngineLocalPayload' to 'Encodable'
cannot be used in actor-isolated context" — resolved by marking the whole struct
`nonisolated`, the same fix WP-05 applied to `GoogleDataPoint`/`DataSource` and WP-07
applied to `SleepSessionDecoding`'s wire types. Verified empirically, not just reasoned
through: `swift build` was run after every isolation-sensitive design choice in this WP,
and this was the *only* compile error the whole implementation actually produced.

**Test-support environment note, not previously hit by WP-04/05/08's own lock-protected
mocks:** `NSLock.lock()`/`.unlock()` are unavailable from `async` contexts on this
toolchain (a push toward async-safe scoped locking) — `MockGoogleReconcileClient.reconcile`
(this WP's `GoogleReconcileClient` test double, `Tests/SyncKitTests/SyncEngine/
MockGoogleReconcileClient.swift`, styled after `MockHealthStore`'s `@unchecked Sendable`
class-with-manual-locking pattern but needing *real* thread-safety since the concurrency
tests genuinely call it from overlapping tasks) had to use `NSLock.withLock { }` instead
of bare `lock()`/`unlock()` around its mutable-state block, called synchronously before
the `await gate.enter()` rendezvous point. Flagged here for whichever future WP's test
double next reaches for `NSLock` inside an `async` function.

**Concurrency test determinism (`concurrentSyncCallsForTheSameTypeCoalesceIntoOneExecution`):**
rather than racing raw `Task`s against timing and hoping, this test uses a small
actor-based rendezvous primitive (`AsyncGate`, same test file's directory) that lets the
first `sync(type:)` call's underlying `reconcile` invocation suspend indefinitely until
released; the test awaits `gate.waitUntilEntered()` — which can only return after
`sync(type:)`'s synchronous "check-and-insert into `inFlight`" prefix has already run,
guaranteeing the in-flight entry is populated — before spawning two more concurrent
`sync(type:)` callers and only then opening the gate. A couple of `Task.yield()` calls
plus a 20ms real sleep are added purely as extra scheduling insurance on top of that
deterministic guarantee (belt-and-suspenders, not the primary correctness argument); none
of this touches `SyncEngine`'s own production code path, which never calls `Task.sleep`
or `Date()` directly (only `clock.now()`, per this WP's constraint).

**Deliberately out of scope, as scoped:** `client.dailyRollup` is never called anywhere in
`SyncEngine` — architecture.md D1 frames it as used "additionally" for daily-summary
types, and the plan's own WP-09 sketch only shows `client.reconcile`; whichever future WP
needs daily-rollup-sourced aggregates will need to decide whether that's a second call
inside this same pipeline or a separate path. `WatchCoverageIndex`/the real
`ConflictResolver` (WP-12b), `BackfillCoordinator` (WP-15), and background scheduling
(WP-16) are all unstarted, as expected — this WP only had to make the `ConflictFiltering`
seam exist and default to identity.

**Tests** (`Tests/SyncKitTests/SyncEngine/`, 14 new, all passing, plus 2 new test-support
files with no `@Test`s of their own — `MockGoogleReconcileClient.swift`/`AsyncGate.swift`'s
`actor AsyncGate` lives in the same file, and `TestSyncClock.swift`): lookback window
computed correctly against the virtual clock, both 72h non-sleep and 7d sleep, and
re-anchored on `lastSyncedAt` (not the initial-window bootstrap) on a second sync;
idempotency (a second identical run writes 0 new HK objects, with fixture timestamps
deliberately close to "now" so they still fall inside the *second* run's narrower,
already-anchored window — a first attempt using `TypeMapperFixtures`' distant default
dates caught a real test-design bug: those timestamps fell outside the shrunk second-run
window, which would make a *correct* implementation look broken); `.localOnly` upsert
(no duplicate `LocalSample` rows across two runs of the same point); itemCount composition
(2 new writes + 1 out-of-range skip in one mixed page ⇒ 3, cross-checked against the
persisted `SyncState.itemCount`); cursor advances only on full-window success across
three consecutive runs (success → failure → success), with `lastSyncedAt`/`lastStatus`/
`lastError` asserted after each; all pages of a paginated response consumed (2 pages, both
recorded with an identical request window); failure mid-pagination leaves the cursor
untouched and is safely retried (page 1's write persists across the failed run; the retry
re-requests the identical window and only page 2's point is newly written); a
late-arriving sample (old timestamp, new external ID) inside the lookback window gets
written on the next run; concurrent `sync(type:)` calls for the same type coalesce into
exactly one execution (`mock.calls.count == 1` across 3 concurrent callers, all three
returned outcomes `==`); `syncAll` runs sequentially (one call per type, in `types`'
order), continues past one failing type, and reports accurate per-type results; the
identity conflict filter passes mappings through unchanged; a custom conflict filter can
suppress a write before the existence-diff/write step, rerouting it to `LocalSample`
instead — proving WP-12b's seam is real. **Verification performed in this session:**
`swift test -Xswiftc -warnings-as-errors` in `Packages/SyncKit` from a clean `.build` —
**87 tests / 11 suites, 0 failures, 0 warnings** (73/10 pre-existing WP-06/07/08 tests +
14/1 new); re-ran the full suite 5 consecutive times (including the concurrency test) to
check for flakiness — stable every time. Then re-ran `swift test -Xswiftc
-warnings-as-errors` in each of `Packages/CoreModel` (15/6), `Packages/Secrets` (14/3),
`Packages/GoogleHealthClient` (35/7), and `Packages/CoachKit` (1/0) without editing any of
them — all five packages still pass together, 0 failures, 0 warnings across the board.
**No public API gaps found in WP-05/WP-07/WP-08's deliverables** — `GoogleHealthClient
.reconcile`, `TypeMapper.map(_:)`/`.decide(_:)`, and `HealthKitWriter.existingExternalIDs`/
`.save`/`.delete` all had exactly the shape this WP needed; the one seam this WP had to
add on top (`GoogleReconcileClient`) is additive (an extension conformance), not a change
to any existing file outside `SyncEngine/`. **Deliberately deferred, as scoped:** WP-12b's
real `ConflictResolver`/`WatchCoverageIndex`, WP-15's `BackfillCoordinator`, WP-16's
background scheduling, and WP-18's sync log/diagnostics (this WP's `SyncOutcome.errorMessage`
is exactly the redacted-string shape that future log will consume, per architecture.md D11 —
no raw error objects or health values are ever stored in `SyncState.lastError`, only
`String(describing:)` of the typed error).

## WP-10 · Minimal dashboard + onboarding (P0 UI)

Built the full app-target UI slice under `HealthLoomApp/`, replacing WP-01's placeholder
`ContentView`. **`DI/`** (4 new files) — `LaunchConfiguration` (reads
`ProcessInfo.processInfo.arguments` for `-UITestStubGoogle`/`-UITestSeedData`, both of
which force an in-memory `ModelContainer`); `AppEnvironment` (`@Observable @MainActor`,
holds `ModelContainer`, `HealthKitAuth`, `GoogleAuthManager`, `SyncEngine`, and a
`consentCoordinator`, injected into the SwiftUI environment via `.environment(_:)` in
`HealthLoomApp.swift`, read back via `@Environment(AppEnvironment.self)`); a small
app-owned `GoogleConsentCoordinating` protocol (`LiveGoogleConsentCoordinator` wraps the
real `GoogleAuthManager.beginConsent`; `StubGoogleConsentCoordinator` used only under
`-UITestStubGoogle`) so onboarding code never depends on the concrete actor directly; and
`StubGoogleReconcileClient` (conforms to SyncKit's `GoogleReconcileClient`, returns empty
pages) so the stubbed first-sync step never touches the network either. **`Onboarding/`**
(7 files) — `OnboardingFlowView` (plain enum-driven state machine: welcome →
healthKitPermission → googleConsent → firstSync, with `healthKitUnavailable` and
`workspaceUnsupported` as explicit side states per architecture.md §6) plus one view per
step. **`Dashboard/`** (2 files) — `DashboardView` (`@Query(sort: \SyncState.dataType)`,
a "Sync now" toolbar button calling `syncEngine.syncAll(types:)`, and a data-freshness
header quoting architecture.md §1's "~15 min" framing) and `SyncTypeRow` (one row per P0
type: status icon, item count, last-synced via `RelativeDateTimeFormatter` ("Synced 9m
ago"), error text when `lastStatus == "error"`). `project.yml` gained a `HealthLoomUITests`
(`bundle.ui-testing`) target and scheme entry (none existed before this WP).

**Real API shapes discovered vs. the plan's illustrative sketches (all read from source
in `Packages/*/Sources` before writing any app code, per the handoff protocol):**
`GoogleAuthManager.beginConsent(scopes:presentationContextProvider:)` is `@MainActor`,
iOS-only, and requires a real `ASWebAuthenticationPresentationContextProviding` — not a
bare closure; `HealthKitAuth.requestWrite(for:)` throws typed `HealthKitAuthError` and
never reports *per-type* denial (HK resolves the completion handler regardless of which
toggles the user leaves on, per that type's own doc comment) — per-type denial is only
ever visible later via `writeStatus(for:)`, which is what the dashboard's status icons
read, not the onboarding screen itself; `SyncEngine.syncAll(types:)` returns
`[SyncOutcome]` and **never throws** (every per-type failure becomes an `.error`
outcome), so no onboarding/dashboard code needed a catch around it; `CoreModel
.makeContainer(inMemory:)` matched the plan exactly. `HealthKitWriter()`'s convenience
init and `GoogleHealthClient`'s real conformance to `GoogleReconcileClient` (an existing
zero-code extension from WP-09) meant the non-stubbed dependency wiring needed no adapter
code at all beyond construction.

**Two genuine SwiftUI/Swift-6 pitfalls found only by actually running `xcodebuild test`
against the simulator, not by reading/reasoning about the code (both are documented
inline at their fix sites for the next WP to avoid re-discovering them):**

1. **A container's `.accessibilityIdentifier` overrides its children's own, more specific
   identifiers**, rather than coexisting with them. `SyncTypeRow`'s outer `VStack` had
   `.accessibilityIdentifier("dashboard.row.<type>")` while its `Image`/`Text` children
   each had their own `.itemCount`/`.lastSynced`/`.error` identifiers; a real accessibility
   snapshot (captured via `xcresulttool export attachments` after a failing test run)
   showed *every* child reporting the container's identifier, not its own. Confirmed a
   second time identically in `WelcomeView` (the "Get Started" button's own
   `onboarding.welcome.continue` identifier was being reported as plain `onboarding.welcome`,
   the VStack's identifier). Fixed by removing every container-level identifier that wraps
   children needing their own (`SyncTypeRow`, `WelcomeView`, `HealthKitPermissionView`,
   `GoogleConsentView`, `WorkspaceUnsupportedView`, `FirstSyncView`) — only leaf elements
   carry identifiers now; `SyncTypeRow`'s "row exists" check uses the display-name `Text`'s
   `.name` identifier instead of a row-level one.
2. **`Text("\(someInt)")` (inline string-interpolation literal) resolves to
   `Text(LocalizedStringKey)`, whose interpolation silently applies locale-aware
   thousands-grouping to interpolated numbers** — `SyncTypeRow`'s item-count label rendered
   `"4,213"` instead of `"4213"` for a seeded fixture of exactly that value, confirmed via
   the real accessibility snapshot. Fixed by building a plain `String` first
   (`String(state?.itemCount ?? 0)`) and passing that to `Text(_:)`, which picks the
   non-localized `Text(String)` overload; applied the same fix to `FirstSyncView`'s
   per-type summary line.

**HealthKit's real "Health Access" system sheet, driven for real in the onboarding UI
test (not stubbed — only Google is stubbed by `-UITestStubGoogle`, per the WP-10 brief's
own framing):** discovered its actual structure only by inspecting a failing test's
accessibility snapshot — one scrollable list of per-category switches (all off initially,
`UIA.Health.Write.<Type>.SwitchCell`), a "Turn On All" cell
(`UIA.Health.AuthSheet.AllCategoryButton`), and "Allow"/"Don't Allow" buttons
(`UIA.Health.Allow.Button`/`.DoNotAllow.Button`) — critically, **"Allow" starts disabled
and stays disabled until at least one switch is on**, so a test that taps "Allow" before
"Turn On All" is a silent, permanent no-op (this is exactly what happened on the first
attempt: the sheet never dismissed, `requestWrite(for:)` never resolved, and every
downstream assertion timed out). Fixed by tapping "Turn On All" first, then "Allow" —
`OnboardingUITests.handleHealthKitPermissionSheetIfPresented`. Also notable: this sheet is
hosted in a *different process ID* in the accessibility snapshot than the app itself, yet
is directly queryable via plain `app.*` element queries (not a cross-process alert an
`addUIInterruptionMonitor` is needed for) — the interruption-monitor approach this file
started with was dead code that never fired and was removed. SwiftUI's `List` is also
lazily rendered (backed by a `UICollectionView`); the freshness header pushes the last two
P0 rows below the fold on first layout, so both UI tests scroll (`app.swipeUp()`) before
asserting on `weight`/`sleep` rows.

**Tests, both required by WP-10's "Tests" line, both passing via a real
`xcodebuild test`, not typecheck-only:** `OnboardingUITests
.testOnboardingHappyPathWithStubbedGoogle` — launches with `-UITestStubGoogle`, drives
the real HealthKit permission sheet, taps the stubbed "Sign in with Google" (resolves in
~200ms with no network call), waits through the stubbed first sync (empty pages, `.ok`
status), and asserts all 4 P0 rows render on the dashboard. `DashboardUITests
.testDashboardRendersPerTypeStatesFromSeededContainer` — launches with `-UITestSeedData`
(seeds `steps`/`heart_rate` as `.ok` with distinct item counts, `weight` as never-synced
`.idle`, `sleep` as `.error` with a specific message) directly into `DashboardView` (no
onboarding, no HealthKit/Google calls at all) and asserts every per-type state renders,
including that the error text is present rather than swallowed (architecture.md's "errors
render rather than vanish").

**Verification performed in this session, on a real simulator, not settled for
typecheck-only (WP-10's explicit ask):** toolchain — Xcode 26.4.1, iOS 26.4.1 simulator
runtime, "iPhone 17 Pro" simulator (`50EC4D33-A8EE-4A91-9617-8B2B757B971D`).
`xcodegen generate` → `xcodebuild build -scheme HealthLoom -destination 'id=...'` —
**BUILD SUCCEEDED**, zero warnings, zero errors. `xcodebuild build-for-testing` —
**TEST BUILD SUCCEEDED**, including the new `HealthLoomUITests` target (which needed its
own `SWIFT_DEFAULT_ACTOR_ISOLATION: nonisolated` override in `project.yml` — the
project-wide `MainActor` default, correct for the app/onboarding/dashboard code, conflicts
with `XCTestCase`'s own `nonisolated` lifecycle methods; individual test methods that
touch `XCUIApplication` are annotated `@MainActor` explicitly instead). `xcodebuild test
-scheme HealthLoom -destination 'id=...'` (the full scheme, both `HealthLoomTests` and
`HealthLoomUITests`) — **TEST SUCCEEDED**: `HealthLoomTests` 1/1 (WP-01's placeholder,
untouched), `HealthLoomUITests` 2/2 (`DashboardUITests`, `OnboardingUITests`), 0 failures,
0 warnings, run three times total during debugging (the last one clean end-to-end).
Re-ran `swift test -Xswiftc -warnings-as-errors` in all five packages after finishing —
still 152/38 combined (CoreModel 15/6, Secrets 14/3, GoogleHealthClient 35/7, SyncKit
87/11, CoachKit 1/0), 0 failures, 0 warnings, confirming this WP touched nothing under
`Packages/`.

**Deviations from the plan's literal text (handoff protocol's "blocked?" clause):** (1)
the two accessibility-identifier/`Text` pitfalls above weren't anticipated by the plan at
all (it just says "verified via view/accessibility identifiers") — the fixes are
structural (no container-level identifiers double as both a row/screen marker *and* a
parent of more specific ones) rather than a one-line patch, so future WPs adding new
screens should follow the same "identifiers only on leaves" rule. (2) The onboarding UI
test drives the real HealthKit permission sheet rather than stubbing it — WP-10's own
"Tests" line only names `-UITestStubGoogle`, and test-plan.md §5 explicitly says "handle
system alert" for this exact smoke test, so this is the plan's intent, not a deviation,
but it does make this one test the slowest and most environment-sensitive in the suite
(a fresh simulator with no prior HealthKit authorization for HealthLoom is required for
the "Turn On All" flow to appear at all; a simulator where authorization was already
granted skips the sheet entirely and the test's waits simply time out quickly and
proceed — both paths were exercised in this session via `xcrun simctl uninstall`
between runs). (3) `GoogleAuthConfig.clientID` is a placeholder string
(`"GOOGLE_IOS_CLIENT_ID_PENDING_P-1.3"`) — still gated on the same human prerequisite
WP-04/05 flagged; the real (non-stubbed) `LiveGoogleConsentCoordinator`/`GoogleAuthManager
.beginConsent` path is fully wired and compiles/builds for iOS, but pressing "Sign in with
Google" in a real (non-`-UITestStubGoogle`) run will fail against Google's real servers
until that client exists — exactly the same outstanding gap WP-04/05 already documented,
now reachable from the UI rather than just the package API. (4) Did not implement a
dedicated UI test for the Workspace-unsupported or HealthKit-unavailable screens (not
required by WP-10's "Tests" line, which names only the happy path + dashboard states) —
both screens exist and are wired into `OnboardingFlowView`'s state machine
(`WorkspaceUnsupportedView`, `HealthKitUnavailableView`), reachable from
`GoogleConsentCoordinator`'s `.workspaceUnsupported` result and `HealthKitAuth.isAvailable
== false` respectively, but neither path was exercised by an automated test in this
session (the Workspace path needs a real Workspace-account consent response to trigger
naturally; the HK-unavailable path needs an iPad destination, out of scope per
`project.yml`'s `TARGETED_DEVICE_FAMILY: "1"` for P0). **P0 exit criterion (WP-10's "Done
when," architecture.md's phase goal) — structurally complete, real-account portion still
gated on P-1.3 as always:** the full pipeline (HealthKit permission → Google consent →
`syncEngine.syncAll` → dashboard reading `SyncState`) is wired end-to-end and provably
runs without crashing or losing errors (both UI tests exercise it against real HealthKit
and a stubbed-but-structurally-identical Google path); a real Fitbit/Pixel account's data
flowing through `GoogleHealthClient`'s real network path remains untestable without the
still-outstanding Google Cloud OAuth client (P-1.3) and Google Health API verification —
exactly the gap every prior WP touching `GoogleHealthClient`/`GoogleAuthManager` already
flagged, not a new one introduced here.

## WP-11 · TypeMapper full table

Extended `Packages/SyncKit/Sources/SyncKit/TypeMapper/` with the thirteen remaining rows
of base-knowledge.md §5, additive to WP-07's existing `MappedDecision`/`MappedObject`
pattern (no restructuring): distance (`.distanceWalkingRunning`, meters — already
normalized mm→m upstream by GoogleHealthClient's WP-05 `UnitNormalizer`, reused rather
than duplicated), floors (`.flightsClimbed`, count), active energy burned
(`.activeEnergyBurned`, kilocalorie), resting heart rate (`.restingHeartRate`,
count/min, reusing WP-07's `heartRateValidRange`), heart rate variability (routed to
`.localOnly`, **not** `heartRateVariabilitySDNN` — see below), oxygen saturation
(`.oxygenSaturation`, fraction), respiratory rate (`.respiratoryRate`, count/min), VO2
Max + Run VO2 Max (both → `.vo2Max`, a composed mL/(kg·min) unit), body fat
(`.bodyFatPercentage`, fraction), height (`.height`, meters), blood glucose
(`.bloodGlucose`, two unit variants — see below), core body temperature
(`.bodyTemperature`, degreeCelsius), and hydration (`.dietaryWater`, liters). Routing
continues to dispatch off `GoogleDataType.writability` exactly as WP-07 established
(`decideHealthKitMapped`'s switch only gained cases; the outer `decide(_:)` routing
shape is untouched). Every new emitted sample goes through the same shared
`metadata(for:)` helper WP-07 wrote, so `HKMetadataKeyExternalUUID`/
`"healthloom.externalID"`/`"healthloom.sourceDevice"` stamping is automatic and was never
re-implemented per type.

**New `MappedUnit` cases** (`MappedTypes.swift`) — `.meter`, `.kilocalorie`, `.fraction`,
`.degreeCelsius`, `.liter`, `.milligramsPerDeciliter`, `.millimolesPerLiter`,
`.vo2MaxUnit` — each verified against the **real** `HKUnit`/`HKQuantityTypeIdentifier`
factory APIs before being written into `MappedObject.swift`'s `makeHKUnit()`, not
guessed: read `HKUnit.h` directly from the iOS 26.4 simulator SDK
(`/Applications/Xcode.app/.../iPhoneSimulator26.4.sdk/.../HealthKit.framework/Headers/HKUnit.h`)
to confirm every factory selector (`gramUnitWithMetricPrefix:`, `moleUnitWithMetricPrefix:
molarMass:`, `percentUnit` — "0.0-1.0" per its own doc comment, confirming `.percent()`
is exactly the `0...1` fraction unit HealthKit itself calls "percent" — `literUnit`,
`degreeCelsiusUnit`, the `HKUnitMolarMassBloodGlucose` `#define` constant
`180.15588000005408`), then ran a scratch `xcrun swiftc -typecheck` against the real
`HealthKit.framework` (arm64-apple-ios26.0-simulator target) exercising every planned
`HKUnit`/`HKQuantityTypeIdentifier` expression verbatim (`HKUnit.literUnit(with:
.milli).unitDivided(by: HKUnit.gramUnit(with: .kilo).unitMultiplied(by: .minute()))` for
VO2 Max; `HKUnit.gramUnit(with: .milli).unitDivided(by: HKUnit.literUnit(with: .deci))`
for mg/dL; `HKUnit.moleUnit(with: .milli, molarMass: HKUnitMolarMassBloodGlucose)
.unitDivided(by: .liter())` for mmol/L; `.percent()`, `.degreeCelsius()`, `.liter()`,
`.meter()`, `.kilocalorie()`) — zero errors before any of it was written into
production code. VO2 Max's unit is built via `HKUnit`'s multiply/divide combinators
(same pattern as WP-07's `.countPerMinute`) rather than `HKUnit(from: "mL/(kg*min)")`
string parsing, to avoid depending on an unverified unit-string grammar.

**HRV — pinned per this WP's explicit instruction, not silently guessed:**
base-knowledge.md §3/§5 names Google's type only as "Heart Rate Variability" and pairs
it with `heartRateVariabilitySDNN` in the mapping table, but documents neither an
algorithm, a field name, nor a unit anywhere — there is no way to *confirm* SDNN from
this doc. CoreModel's writability table (`GoogleDataType.heartRateVariability
.writability`) still declares `"HKQuantityTypeIdentifierHeartRateVariabilitySDNN"` as an
*available* target (per WP-02's own note that the table records availability, not a
write decision — the identical pattern already used for `totalCalories`/
`basalEnergyBurned`), but `TypeMapper.decideHeartRateVariability` unconditionally
returns `.localOnly`, ignoring that available target. The reasoning (flagged explicitly
in-code as **out-of-band knowledge, not sourced from base-knowledge.md**): Fitbit's own
HRV metric is widely documented elsewhere in the wearable industry as an overnight
**RMSSD**-based figure — a different statistic over a different window than SDNN, not a
rescaled version of the same number. Writing an RMSSD value into
`heartRateVariabilitySDNN` would silently mislabel data in Apple Health under a claim
this mapper cannot verify, which is worse than not writing it. Tested explicitly
(`heartRateVariabilityRoutesToLocalOnlyNotSDNN`, `TypeMapperGoldenTests.swift`, and its
HK-layer counterpart in `TypeMapperHealthKitMappingTests.swift`) — the test asserts
*both* that `decide(_:)` returns `.localOnly` *and* that CoreModel's writability table
still declares the SDNN target, so this reads as a deliberate override, not a routing
bug. The raw `rmssd`-named field (fixture-only; `decideHeartRateVariability` never reads
it) is preserved verbatim via `GoogleDataPoint` for WP-09/WP-14 to persist to
`LocalSample.payloadJSON`, just never written to HealthKit under an unconfirmed label.

**Energy split — no basal invented, per this WP's explicit instruction:** only
`.activeEnergyBurned` → `HKQuantityTypeIdentifierActiveEnergyBurned` is implemented.
`.totalCalories` (a distinct Google type CoreModel's writability table pairs with
`HKQuantityTypeIdentifierBasalEnergyBurned`, per §5's positional "Active Energy Burned /
Total Calories → activeEnergyBurned / basalEnergyBurned" reading) is deliberately **not**
handled — it falls through `decideHealthKitMapped`'s `default` case to `.skip`, with an
in-line doc comment explaining why: no fixture/payload evidence anywhere in this session
separates an active-only reading from a basal-only one, and writing Google's
undifferentiated total into `basalEnergyBurned` would fabricate a real basal-only
reading Google never actually reported. Tested explicitly (`totalCaloriesRoutesToSkip`).
If a future WP finds a real payload that *does* separate active from basal, this is the
one function (`decideHealthKitMapped`'s `default` case) to revisit.

**Blood glucose — two fixture variants, no assumed conversion:** base-knowledge.md
documents neither Google's field name(s) for this type nor which of the two
clinically-standard units (US mg/dL vs. most-of-the-rest-of-the-world mmol/L) it
reports, so per this WP's explicit instruction, both variants were built rather than
guessing one: `TypeMapper.decideBloodGlucose` checks for a `mg_per_dl` field first, then
`mmol_per_l`, and emits the corresponding `MappedUnit` — the field's *presence* signals
the unit, not a separate unit-indicator string (an assumption, flagged as such in-code
and in both fixtures' `_comment`s, since neither payload shape is confirmed).
Critically, **no conversion is ever performed between the two units** — each is passed
straight through in its own `HKUnit`; if a real payload turns out to use a single field
name gated by a separate unit indicator instead, `decideBloodGlucose` is the one place to
update. Both variants have golden tests (`bloodGlucoseMgDLGolden`/
`bloodGlucoseMmolLGolden`) and real-`HKQuantity` HK-mapping tests confirming the exact
composed units above.

**SpO2 / body fat — percentage→fraction conversion, tested explicitly, never clamped:**
base-knowledge.md doesn't pin down whether Google's wire payload for either field is
already a `0...1` fraction or a `0...100` percentage; assumed `0...100` (every
consumer-facing SpO2/body-fat reading either platform surfaces to a user is shown as a
percentage) and converted via `/ 100.0` in `decideOxygenSaturation`/`decideBodyFat` —
**never** passed through unconverted, since HealthKit requires `0...1`
(base-knowledge.md §5 "fraction 0-1 in HK!"/"fraction in HK"). Both `decide` functions
guard their raw input to a shared `percentageValidRange = 0.0...100.0` *before*
converting, so an out-of-range input (negative, or >100 — clearly not a percentage) is
**dropped, not clamped** — structurally guaranteeing the emitted fraction lands in
`0...1` rather than merely hoping it does. Tests: golden tests assert the exact `97 →
0.97`/`22 → 0.22` conversion for both types; a dedicated property test
(`fractionOutputsAlwaysStayInUnitInterval`, parameterized over `[0, 22, 55.5, 97, 100]`)
asserts every `.fraction`-unit sample's value is in `0...1`; a companion property test
(`outOfRangePercentageIsDroppedNotClamped`, parameterized over `[-5, -0.01, 100.01,
250]`) asserts out-of-range inputs are dropped, not force-clamped into range.

**Other unit/payload assumptions, each flagged in-code and in the corresponding JSON
fixture's `_comment` (base-knowledge.md documents none of Google's exact wire field
names beyond the `<data_type>.<field>` nesting convention itself, per §2):** floors'
`count`, active energy burned's `kcal`, resting HR's `bpm` (a full-day interval, per
base-knowledge.md §3's "D" = Daily record type), respiratory rate's `breathsPerMinute`,
VO2 Max/Run VO2 Max's `value`, height's `meters`, core body temperature's `celsius`, and
hydration's `liters` are all invented field names, chosen for consistency with the
existing four P0 fixtures' naming style (short, HealthKit-unit-matching) — none are
confirmed against a real payload, same posture WP-07 already established for weight's
`mass` field and flagged as "unconfirmed pending real API access" (P-1.3). Height,
respiratory rate, and core body temperature each got a generous, documented
sensor/unit-mismatch guard range (`heightValidRange`, `respiratoryRateValidRange`,
`coreBodyTemperatureValidRange`), same "comfortably wider than any plausible reading"
philosophy as WP-07's `heartRateValidRange`. Respiratory rate's base-knowledge.md §5 row
("Respiratory Rate") has no exact §3 name match either — resolved identically to WP-02's
own note, to the sample-level `respiratoryRateSleepSummary` case (the "Daily Respiratory
Rate" sibling remains `.skip`, unimplemented, per CoreModel's existing table). Hydration
Log is a Session (Se) record type per base-knowledge.md §3, but WP-11 only asks for a
plain `dietaryWater` quantity mapping (not a session/correlation structure the way
Exercise/Food are) — treated like the other Sample-shaped scalar fixtures rather than
built with `SleepSessionDecoding`-style nested payload parsing; flagged in-code in case
a future WP finds hydration logs actually arrive as multi-entry sessions.

**Fixtures added** under
`Packages/GoogleHealthClient/Tests/GoogleHealthClientTests/Fixtures/GoogleHealth/`
(fixtures only, per this WP's scope — no GoogleHealthClient *source* or test `.swift`
files touched, so these are documentation/spec artifacts SyncKit's own
`TypeMapperFixtures.swift` mirrors as literal `GoogleDataPoint` values, exactly as WP-07
did for the four pre-existing ones): `floors.json`, `active-energy-burned.json`,
`daily-resting-heart-rate.json`, `heart-rate-variability.json`,
`oxygen-saturation.json`, `respiratory-rate.json`, `vo2-max.json`, `run-vo2-max.json`,
`height.json`, `body-fat.json`, `blood-glucose-mgdl.json`, `blood-glucose-mmol.json`,
`core-body-temperature.json`, `hydration-log.json` — fourteen files, each with a
`_comment` recording its envelope/field-name assumptions, matching the existing
fixtures' documentation convention exactly. `distance.json` (WP-05) was reused as-is, no
new distance fixture needed. **No `GoogleDataPoint` field gap was found** — every new
type's payload fits the existing flat `values: [String: Double]` shape (or, for blood
glucose, two mutually-exclusive keys within it); nothing required a new field on
`GoogleDataPoint` itself, so there is no gap to report against GoogleHealthClient's
scope.

**Fixed one now-stale WP-07 test:** `TypeMapperGoldenTests
.unimplementedHealthKitTypeRoutesToSkipForNow` used `.distance` as its "not yet
implemented" exemplar; since this WP implements distance, that exact test would have
started asserting the *wrong* thing (a valid distance point would now map to
`.quantity`, not `.skip`) rather than failing loudly — caught by actually building the
test target (not just reading), fixed by switching the exemplar to `.exercise`
(WP-12's job, still genuinely unimplemented) and updating its doc comment.

**Tests** (`Packages/SyncKit/Tests/SyncKitTests/TypeMapper/`, all in existing WP-07
files, none new — following this WP's explicit instruction not to write a parallel
suite): `TypeMapperGoldenTests.swift` gained one golden test per new row (distance,
floors, active energy burned, resting HR, HRV-routes-to-localOnly, SpO2 with explicit
percent→fraction assertion, respiratory rate, VO2 Max, Run VO2 Max, height, body fat with
explicit percent→fraction assertion, blood glucose mg/dL, blood glucose mmol/L, core
body temperature, hydration) plus `totalCaloriesRoutesToSkip`, and had its stale
`.distance` exemplar fixed as above. `TypeMapperFixtures.swift` gained one builder
function per new type (fourteen total, `vo2MaxPoint` parameterized over `dataType` to
cover both VO2 Max Google types with one function). `TypeMapperPropertyTests.swift`:
`neverEmitsSampleWithEndBeforeStart` and `reversedWindowIsAlwaysDropped` now exercise
all seventeen implemented `.healthKit` rows (not a second parallel test), and the
placeholder `fractionTypedUnitPropertyIsNotYetApplicable` test — WP-07's own
deliberately-exhaustive-switch tripwire, written specifically so adding a fraction case
without a property test alongside it would fail to compile — was replaced by the two
real tests described above (`fractionOutputsAlwaysStayInUnitInterval`,
`outOfRangePercentageIsDroppedNotClamped`); confirmed this tripwire actually fired
before the fix (`swift build --build-tests` failed with "switch must be exhaustive,
add missing case: '.meter'..." etc. until the placeholder was replaced), i.e. WP-07's
guard rail worked exactly as designed. `TypeMapperOutOfRangeTests.swift` gained
per-type negative/implausible-value coverage for every new type with a numeric guard
(distance, floors, active energy, resting HR, respiratory rate, VO2 Max, height, blood
glucose both units, core body temperature, hydration) plus a missing-both-fields blood
glucose case. `TypeMapperHealthKitMappingTests.swift` gained one real-`HKQuantitySample`
test per new HK-mapped type (confirming exact `HKQuantityType`/`HKQuantity`
unit+value/dates) plus the HRV-maps-to-`.localOnly`-through-`map(_:)` counterpart to the
golden-layer test.

**Verification performed in this session:** `swift test -Xswiftc -warnings-as-errors`
from a clean `.build` in `Packages/SyncKit` — **133 tests / 11 suites, 0 failures, 0
warnings** (87/11 pre-existing WP-06/07/08/09 tests + 46 new; no new suite files, all
additions extend the six existing WP-07 TypeMapper test files, per this WP's scope);
same command in `Packages/GoogleHealthClient` — **35 tests / 7 suites, 0 failures, 0
warnings**, unchanged from WP-05 (only JSON fixtures were added, no source or test
`.swift` changes, so the count is identical — confirms the fixture additions didn't
perturb anything). Then re-ran `swift test -Xswiftc -warnings-as-errors` in each of
`Packages/CoreModel` (15/6), `Packages/Secrets` (14/3), and `Packages/CoachKit` (1/0)
without editing any of them — all five packages still pass together, 0 failures, 0
warnings across the board, 198 tests total combined. **Deviations from the plan's
literal text (handoff protocol's "blocked?" clause):** (1) HRV and `.totalCalories` both
deliberately don't use the HealthKit target CoreModel's writability table declares for
them — fully justified above, and exactly the kind of call WP-02's own note anticipated
TypeMapper making; (2) several field names (floors/energy/respiratory-rate/VO2Max/
height/core-body-temp/hydration) are invented, not confirmed, same posture as WP-07's
weight-unit note — flagged per-field above and in each fixture's `_comment` rather than
silently assumed; (3) fixed a pre-existing WP-07 test that this WP's own distance
implementation would have silently made incorrect (see above) — a necessary,
narrowly-scoped edit to an existing SyncKit test file, not a new deviation from this
WP's own instructions. **Deliberately deferred, as scoped:** Exercise → `HKWorkout`
(WP-12), Food/Nutrition Log → `HKCorrelation(.food)` (WP-13), and any real confirmation
of the field-name/unit assumptions above against a live payload — all still gated on
P-1.3 (the outstanding Google Cloud OAuth client), exactly the recurring gap every prior
WP touching `GoogleHealthClient`/`GoogleAuthManager` has already flagged.

## WP-12 · Exercise → HKWorkout

Built the Exercise → `HKWorkout` pipeline entirely within `Packages/SyncKit`, following
the exact pure/impure split every prior SyncKit WP established. **New files:**
**`TypeMapper/ExerciseSessionDecoding.swift`** — a `nonisolated` wire struct
(`ExerciseSessionWire`) decoded from `GoogleDataPoint.sessionPayload` via a plain
`JSONDecoder`, mirroring WP-07's `SleepSessionDecoding.swift` precisely (Exercise is a
Session (Se) record type per base-knowledge.md §3, exactly like Sleep). **`HealthKitWriter/
WorkoutBuilding.swift`** — `protocol WorkoutBuilding` (`beginCollection`/`addSamples`/
`addMetadata`/`endCollection`/`finishWorkout`, all `async throws`) and
`protocol WorkoutBuilderFactory`, abstracting the real, concrete `HKWorkoutBuilder` class
(not itself protocol-based) so `HealthKitWriter.saveWorkout(_:)` is testable without a
HealthKit entitlement — the exact same seam-over-a-concrete-API rationale
`HealthStoreProtocol.swift` (WP-08) already established for `HKHealthStore`.
`HKWorkoutBuilderAdapter`/`HealthKitWorkoutBuilderFactory` are the real production
conformers. Extended **`TypeMapper/MappedTypes.swift`** with `MappedWorkoutActivityType`
(a HealthKit-free enum of 12 named buckets + `.other`) and `MappedWorkout` (activity type,
start/end, optional distance-in-meters/energy-in-kilocalories, `MappedMetadata`), and gave
`MappedDecision` a new `.workout(MappedWorkout)` case. Extended **`TypeMapper/
TypeMapper.swift`** with `decideExercise(_:)` and the required explicit
`googleExerciseActivityTypes: [String: MappedWorkoutActivityType]` table (13 entries, see
below), wired into `decideHealthKitMapped`'s switch under an explicit `case .exercise`
(previously falling through to `default` → `.skip`, exactly the stub WP-11's own entry
flagged as this WP's job). Extended **`TypeMapper/MappedObject.swift`** with
`MappedObject.workout(MappedWorkout)` (deliberately **not** `#if canImport(HealthKit)`-
guarded, since `MappedWorkout` itself is HealthKit-free — unlike `.quantity`/`.category`,
`TypeMapper.map(_:)`'s `.workout` arm is a pure pass-through of the same value, not a
real-`HKWorkout` construction — see below for why), `MappedWorkoutActivityType
.makeHKWorkoutActivityType()` (switches to the real, *named* `HKWorkoutActivityType` case
— deliberately not a raw-`Int` mirror the way `MappedSleepStage` mirrors
`HKCategoryValueSleepAnalysis`, since `HKWorkoutActivityType` has ~80 cases across many OS
versions and hand-mirroring raw values would be far more error-prone), and changed
`MappedMetadata.makeHKMetadataDictionary()` from `fileprivate` to internal (module-default)
access so `HealthKitWriter.swift`, a different file in the same module, can reuse it for
the workout's own metadata and its attached distance/energy samples.

**Why `HKWorkout` isn't constructed the way `HKQuantitySample`/`HKCategorySample` are:**
unlike those two (plain, synchronous initializers), a real `HKWorkout` can only be built
through `HKWorkoutBuilder`'s async, store-backed `beginCollection → add(samples) →
endCollection → finishWorkout` flow (its own direct initializers are deprecated, per
implementation-plan.md's own note) — there is no synchronous "just construct the object"
path the way WP-07's `MappedObject.swift` established for quantity/category samples. So
`TypeMapper.map(_:)`'s `.workout` case is a pure pass-through of the same `MappedWorkout`
value `decide(_:)` produced; the *real* HealthKit-object-construction layer for workouts
is **`HealthKitWriter.saveWorkout(_:)`** itself (HealthKitWriter.swift) — this is what the
task's "keep the decision layer separate from the HK-object-construction layer" instruction
meant concretely for Exercise, and it's why `saveWorkout`'s signature changed from the
WP-08 stub's `([HKObject]) throws` to `(MappedWorkout) async throws -> HKWorkout?`.

**`HealthKitWriter.saveWorkout(_:)` — the real implementation, replacing the WP-08 stub:**
requests a `WorkoutBuilding` from the injected `workoutBuilderFactory` (activity type via
`makeHKWorkoutActivityType()`, `device: nil` — Google's source device is carried as
`healthloom.sourceDevice` metadata, not a real `HKDevice`, matching this codebase's existing
posture of never fabricating one), then `beginCollection(at: workout.start)` →
(if present) builds `HKQuantitySample`s for `HKQuantityTypeIdentifierDistanceWalkingRunning`
(meters) and `HKQuantityTypeIdentifierActiveEnergyBurned` (kilocalories), each stamped with
the workout's own metadata, and `addSamples(_:)`s them together → `addMetadata(_:)` (the
workout's own D4 metadata: `HKMetadataKeyExternalUUID`/`healthloom.externalID`/
`healthloom.sourceDevice`, via the now-internal `makeHKMetadataDictionary()`) →
`endCollection(at: workout.end)` → `finishWorkout()`, returned as-is
(`@discardableResult ... -> HKWorkout?`). **Return-value contract, taken directly from
`HKWorkoutBuilder.finishWorkout()`'s own doc comment** ("If both workout and error are nil
then finishing the workout succeeded but the workout sample is not available because the
device is locked"): a `nil`, non-throwing result is a **documented success**, not an error
— `saveWorkout` never converts it into a thrown failure, and `WorkoutSavingTests.swift`
has a dedicated test (`nilFinishResultWithoutAnErrorIsStillSuccess`) proving this.
`HealthKitWriterError.workoutsNotYetImplemented` was removed (its own WP-08 doc comment
said "never remove this without replacing it with a real implementation" — done); every
`saveWorkout` failure now surfaces as `.underlying(String(describing:))`, matching every
other method in this file. `HealthKitWriter`'s primary initializer gained a
`workoutBuilderFactory: WorkoutBuilderFactory = HealthKitWorkoutBuilderFactory(healthStore:
HKHealthStore())` parameter (default value, so every pre-existing call site — all 17
WP-08 tests plus WP-09's `SyncEngine` construction sites — keeps compiling unchanged); the
`healthStore:`-convenience initializer now builds the workout-builder factory from the same
shared store.

**The Google exercise-type table — 13 entries, invented and flagged for reconciliation**
(this WP's honesty-flag requirement, same posture as WP-11's HRV/blood-glucose notes):
base-knowledge.md §5's mapping-table row for Exercise says only "~13 Google types are
coarse" — it names **zero** actual wire-string values anywhere in the document. The table
below is a reasonable, documented invention based on common Fitbit/Google Fit exercise
categories, **not** a confirmed enumeration of the real Google Health API's actual enum
values, and **must be reconciled against real payloads once P-1.3 (the Google Cloud OAuth
client) unblocks real API access** — flagged here, in `TypeMapper.swift`'s
`googleExerciseActivityTypes` doc comment, and in `MappedWorkoutActivityType`'s own doc
comment (MappedTypes.swift):

| Wire string (invented) | `MappedWorkoutActivityType` | Real `HKWorkoutActivityType` |
|---|---|---|
| `"run"` | `.running` | `.running` |
| `"walk"` | `.walking` | `.walking` |
| `"bike"` | `.cycling` | `.cycling` |
| `"swim"` | `.swimming` | `.swimming` |
| `"hike"` | `.hiking` | `.hiking` |
| `"weights"` | `.traditionalStrengthTraining` | `.traditionalStrengthTraining` |
| `"yoga"` | `.yoga` | `.yoga` |
| `"elliptical"` | `.elliptical` | `.elliptical` |
| `"rowing"` | `.rowing` | `.rowing` |
| `"hiit"` | `.highIntensityIntervalTraining` | `.highIntensityIntervalTraining` |
| `"stair_climbing"` | `.stairClimbing` | `.stairClimbing` |
| `"core_training"` | `.coreTraining` | `.coreTraining` |
| `"workout"` (Google's own generic/unspecified bucket) | `.other` | `.other` |
| *(anything else — genuinely unrecognized)* | `.other` (default) | `.other` |

Any wire string not in the table — not just `"workout"`, which is itself an explicit entry
that also targets `.other` — defaults to `.other` via a plain `?? .other` dictionary
lookup, per this WP's explicit "default bucket .other for anything unrecognized"
instruction; both paths (`"workout"` and a truly-unknown string) are golden-tested
independently so the default-fallback behavior is proven, not just implied by the explicit
entry. The real `HKWorkoutActivityType` case names (12 named buckets + `.other`, all
verified to exist against the real SDK — see "Verification" below) were read directly from
`HealthKit.framework/Headers/HKWorkout.h` on this machine's iOS 26.4 simulator SDK, not
guessed; `HKWorkoutActivityType` itself has on the order of 80 cases across OS versions
(American Football through UnderwaterDiving, plus several `API_DEPRECATED` ones like plain
`.dance`), so this table intentionally picks a conservative dozen unambiguous,
long-stable cases rather than trying to cover every nuance a real payload might eventually
need — broadening it later (e.g. splitting `"bike"` into indoor/outdoor cycling, adding a
dedicated dance/pilates/martial-arts bucket) is a one-line dictionary addition, not a
structural change.

**Exercise session wire-shape assumptions (all flagged, none confirmed against a real
payload — same posture as every WP-11 field-name note):** decoded fields are
`"exercise.activity_type"` (String), `"exercise.distance"` (assumed **meters**, not
millimeters — base-knowledge.md's only confirmed odd-base-unit example is the standalone
`Distance` Google type's own field, normalized by `UnitNormalizer` keyed specifically to
`"distance.distance"`; that table doesn't cover Exercise's nested session payload at all,
and `sessionPayload` is preserved **before** any unit normalization runs, so any
conversion here is this decoder's own responsibility — chose meters, matching WP-11's
"height already in meters" precedent, not the millimeter convention; flagged as needing
reconciliation, and if wrong, only `ExerciseSessionDecoding.swift` needs updating), and
`"exercise.energy"` (assumed kilocalories, matching WP-11's active-energy-burned "kcal"
convention). **Duration is deliberately not a separate decoded field** — the session's own
outer `GoogleDataPoint.start`/`.end` already bound the whole workout (exactly like Sleep),
and those are precisely the two dates `HKWorkoutBuilder` needs for
`beginCollection`/`endCollection`; this is a design decision, not an unconfirmed
assumption, and is documented as such in `ExerciseSessionDecoding.swift`'s header.
A negative distance/energy reading is dropped (nil'd) rather than kept, but — unlike an
out-of-range heart rate, which drops the *entire* point — an implausible auxiliary
attachment doesn't invalidate the whole workout session, so only that one optional field is
nil'd, not the whole decision; tested explicitly
(`negativeDistanceAndEnergyAreDroppedNotKept`). A missing/malformed `sessionPayload`, or one
missing the `activity_type` field entirely, routes to `.skip` (never crashes), matching
Sleep's precedent exactly. **Deviation from the WP-07/11 fixture convention, explicitly
scope-driven:** unlike every WP-07/11 fixture, there is **no** companion JSON fixture under
`Packages/GoogleHealthClient/Tests/GoogleHealthClientTests/Fixtures/GoogleHealth/`
documenting these wire-shape assumptions via a `"_comment"` key — WP-12's stated scope is
`Packages/SyncKit` only ("do NOT touch ... GoogleHealthClient"), so the assumptions are
documented instead in `ExerciseSessionDecoding.swift`'s header and
`TypeMapperFixtures.swift`'s `exercisePoint(...)` doc comment. Flagged here per the
handoff protocol so whoever eventually adds a real GoogleHealthClient exercise fixture
knows to reconcile it against these two files rather than re-deriving the shape from
scratch.

**Necessary cross-file compile fixes outside TypeMapper/HealthKitWriter (flagged per the
handoff protocol's "if you believe another module must change, stop and report" clause —
reported here, and fixed, since leaving them broken would fail this WP's own required
`swift test` gate for the whole package):** adding `MappedObject.workout`/
`MappedDecision.workout` makes two pre-existing **exhaustive** switches elsewhere in
`SyncKit` (added by WP-09, not touched by this WP's nominal TypeMapper/HealthKitWriter
scope) fail to compile unless given a new arm. (1) `SyncEngine.swift`'s
`processPage(_:knownExternalIDs:context:)` switches exhaustively over `MappedObject` to
route `.quantity`/`.category` into the write batch and `.localOnly`/`.skip` elsewhere —
added `case .workout: skipCount += 1`, documented inline as a deliberate no-op-for-now:
wiring workouts through `SyncEngine`'s actual incremental pipeline (a
`HKObjectType.workoutType()` existence-diff before calling the new `writer.saveWorkout(_:)`,
since workouts don't flow through `writer.save(batch)` at all) is genuinely out of this
WP's scope — arguably WP-12b's job, since D13's watch-priority conflict resolution should
run before a Google Exercise session is even considered for writing as an `HKWorkout` (a
watch-covered session should never reach `saveWorkout` in the first place). **This is
flagged here as required follow-up, not silently left undone.** (2)
`SyncEngineTests.swift`'s `SuppressingConflictFilter.resolve(_:for:)` (a test-only
`ConflictFiltering` conformer) has the same kind of exhaustive switch — added
`case .workout: return mapped` (pass-through, matching `.localOnly`/`.skip`'s existing
arm), since that test predates workouts and isn't about them. Both fixes are one arm each,
behavior-neutral for every pre-existing test (all of which pre-date `.workout` and never
produce it), and were required purely to keep the shared `MappedObject`/`MappedDecision`
enums' exhaustiveness satisfied — not a scope creep into WP-09's actual sync logic.

**Verification that the real `HKWorkoutBuilder` API surface matches this design, performed
*before* writing production code** (same "confirm against the real SDK, don't guess"
discipline WP-06/07/08/11 all established): read
`HealthKit.framework/Headers/HKWorkoutBuilder.h` and `HKWorkout.h` directly from the iOS
26.4 simulator SDK on this machine, confirming `beginCollectionWithStartDate:completion:` /
`addSamples:completion:` / `addMetadata:completion:` / `endCollectionWithEndDate:completion:`
/ `finishWorkoutWithCompletion:` all bridge to Swift `async throws` via
`NS_SWIFT_ASYNC_NAME`/`NS_SWIFT_ASYNC_THROWS_ON_FALSE`, and confirming `finishWorkout()`'s
own doc comment's "nil without error is still success" contract; then ran a scratch
`xcrun swiftc -typecheck` (in a disposable directory under this session's scratchpad,
never part of the repo) against the real `HealthKit.framework` for
`arm64-apple-ios26.0-simulator`, using this repo's exact `Package.swift` flags
(`-swift-version 6 -strict-concurrency=complete -default-isolation MainActor
-enable-upcoming-feature NonisolatedNonsendingByDefault -enable-upcoming-feature
InferIsolatedConformances -warnings-as-errors`) — **zero errors, zero warnings** — for (1)
the full `beginCollection → addSamples → addMetadata → endCollection → finishWorkout` call
sequence against a real `HKWorkoutBuilder`, (2) all 13 real `HKWorkoutActivityType` case
names this table needs (`.running`/`.walking`/`.cycling`/`.swimming`/`.hiking`/
`.traditionalStrengthTraining`/`.yoga`/`.elliptical`/`.rowing`/
`.highIntensityIntervalTraining`/`.stairClimbing`/`.coreTraining`/`.other`), and (3) — the
one genuinely tricky question this WP had to resolve empirically rather than by
reasoning — whether a test could construct a real `HKWorkout` fixture at all, given every
`HKWorkout` initializer is `API_DEPRECATED("Use HKWorkoutBuilder", ...)` and this repo
builds with `-warnings-as-errors`. Confirmed, via a disposable scratch **SwiftPM package**
(not just a bare `swiftc` script, since the actual failure mode only shows up through
Swift Testing's macro-generated call site) with a real `import Testing` suite: marking
**both** the deprecated-initializer-calling helper function **and** the `@Test func` that
calls it with `@available(*, deprecated, message: ...)` silences the deprecation
diagnostic entirely, even under `swift test -Xswiftc -warnings-as-errors` — confirmed
empirically (clean build, test passes) before this pattern was used for real in
`MockWorkoutBuilder.swift`'s `makeFakeHKWorkoutForTesting`. This is the *only* way to
fabricate a real, non-nil `HKWorkout` test fixture without a live, authorized
`HKHealthStore` (that's the entire reason `HKWorkoutBuilder` exists), and it's used
**exclusively** in test code — production code (`HealthKitWriter.saveWorkout(_:)`) never
calls a deprecated `HKWorkout` initializer.

**In-repo real-API compilation, per this WP's own required verification path (WP-08's
precedent — `xcodebuild build -scheme SyncKit -destination 'generic/platform=iOS
Simulator'`, confirmed the scheme still exists via `xcodebuild -list`):**
`xcodebuild build -scheme SyncKit -destination 'generic/platform=iOS Simulator'` —
**BUILD SUCCEEDED**, compiling every new/changed production file
(`ExerciseSessionDecoding.swift`, `WorkoutBuilding.swift`, the extended `MappedTypes.swift`/
`TypeMapper.swift`/`MappedObject.swift`/`HealthKitWriter.swift`/`HealthKitWriterTypes.swift`/
`SyncEngine.swift`) for real `arm64-apple-ios26.0-simulator` **and**
`x86_64-apple-ios26.0-simulator` slices, zero errors, zero warnings. Then
`xcodebuild build-for-testing -scheme SyncKit -destination 'generic/platform=iOS
Simulator'` from the same session — **TEST BUILD SUCCEEDED**, additionally compiling every
new test file (`TypeMapperExerciseTests.swift`, `MockWorkoutBuilder.swift` — including its
`@available(*, deprecated)`-guarded real `HKWorkout` fixture helper — `WorkoutSavingTests
.swift`) for iOS, confirmed warning-free by grepping the full build log for
`warning:.*\.swift`/`deprecated` (zero matches; the only unrelated `warning:` line in the
raw log is Xcode's own "Metadata extraction skipped: No AppIntents.framework dependency
found" notice from the `appintentsmetadataprocessor` tool, not a Swift compiler diagnostic
and not something `-warnings-as-errors` governs). **What this does *not* verify, same
limitation WP-06/07/08 already hit and flagged again here:** the full, real
`HKWorkoutBuilder` flow — `beginCollection`/`addSamples`/`addMetadata`/`endCollection`/
`finishWorkout` actually executing against a genuinely authorized `HKHealthStore` on a
booted, HealthKit-authorized simulator or device — was **not** run end-to-end in this
session (no HealthKit entitlement / authorized simulator available here, the identical
constraint every prior HealthKit-touching WP recorded). The mock/protocol-seam tests below
substitute for it, per this WP's own explicit instruction to do exactly that when a real
authorized store isn't available.

**Tests** (28 new, across three files — two new suites plus extensions to three existing
ones): **`TypeMapperExerciseTests.swift`** (new suite, HealthKit-free, exercises
`TypeMapper.decide(_:)` only) — one parameterized golden test over all 13
`googleExerciseActivityTypes` table rows (`recognizedActivityTypeGolden`, 13 cases in one
`@Test(arguments:)`), a dedicated unknown-wire-string test proving the `.other` default
fallback independently of the explicit `"workout"` → `.other` entry
(`unrecognizedActivityTypeDefaultsToOther`), a full golden check of activity type +
start/end + distance + energy + metadata together, missing-distance-and-energy-stay-nil,
negative-distance-and-energy-are-dropped-not-kept, missing-`sessionPayload`-routes-to-skip,
payload-missing-the-activity-type-field-routes-to-skip, reversed-window-routes-to-skip, and
missing-device-display-name-stays-nil (13 tests total, one of which fans out to 13 cases —
26 assertions' worth of coverage from that one file). **`TypeMapperHealthKitMappingTests
.swift`** (extended, `#if canImport(HealthKit)`) — `everyMappedWorkoutActivityTypeMapsToItsRealHKWorkoutActivityTypeCase`
(exhaustive over `MappedWorkoutActivityType.allCases`, so a future case added to the enum
without a matching table entry here is a test failure, not a silent gap — the same
tripwire-by-construction style WP-07/11's `TypeMapperPropertyTests` fraction-unit guard
already established) and `exerciseSessionMapsToAWorkoutDecisionThroughMap` (confirms
`TypeMapper.map(_:)`'s pass-through). **`WorkoutSavingTests.swift`** (new suite,
`#if canImport(HealthKit)`, against `MockWorkoutBuilder`/`MockWorkoutBuilderFactory`) — the
required "workout-builder integration test" and "workout dedupe by externalID" per this
WP's "Tests:" line: `savesFollowTheExactBuilderSequence` (asserts the exact
`beginCollection → addSamples(2) → addMetadata(...) → endCollection → finishWorkout` call
order and payload), `requestsTheCorrectRealHKWorkoutActivityType`,
`attachesDistanceAndEnergyQuantitySamplesWhenPresent` (inspects the real constructed
`HKQuantitySample`s' types/quantities), `neitherDistanceNorEnergySampleIsAddedWhenBothAreNil`,
`stampsExternalUUIDAndSourceDeviceMetadataBeforeFinishing`,
`nilFinishResultWithoutAnErrorIsStillSuccess` (the `finishWorkout()` "device locked" success
case), `aThrownBuilderErrorPropagatesAsUnderlying`, and — the dedupe-by-externalID pair —
`aSavedWorkoutIsDiscoverableThroughTheSameExistingExternalIDsMethod` (seeds the mock
builder's `finishWorkout()` result, built via the test-only deprecated-initializer helper,
directly into the same `MockHealthStore` the writer holds — mirroring
`HKWorkoutBuilder.finishWorkout()`'s real documented behavior of saving straight to the
store, bypassing `HealthStoreProtocol.save(_:)` — then confirms
`writer.existingExternalIDs(type: HKObjectType.workoutType(), ...)`, the **exact same**
method every other type already uses, finds it) and
`callerMustCheckExistingExternalIDsBeforeSavingAgain` (documents/proves that `saveWorkout`
itself performs no dedupe — exactly like `save(_:)`, the existence-diff is the caller's job)
plus `noExistingWorkoutsBeforeAnySave` (confirms `HKObjectType.workoutType()` is accepted by
`existingExternalIDs` at all, not a special-cased no-op). Also extended, minimally:
**`TypeMapperFixtures.swift`** (`exercisePoint(...)` builder, doc comment explaining the
missing-companion-JSON-fixture deviation above), **`TypeMapperPropertyTests.swift`** (added
`.workout` to the exhaustive "never end < start" switch and the reversed-window assertion
list — now 18 rows, not 17), and removed the now-stale WP-08 stub test
(`saveWorkoutThrowsAnExplicitNotYetImplementedError`, `HealthKitWriterTests.swift`) since
the behavior it asserted (`.workoutsNotYetImplemented` always thrown) no longer exists —
the same "fix a test a WP's own change would otherwise silently make wrong" precedent
WP-11 already established for a stale WP-07 test.

**Verification performed in this session:** `swift test -Xswiftc -warnings-as-errors` from
a clean `.build` in `Packages/SyncKit` — **153 tests / 13 suites, 0 failures, 0 warnings**
(133/11 pre-existing WP-06/07/08/09/11 tests + 20 new: 2 new suites —
`TypeMapperExerciseTests`, `WorkoutSavingTests` — plus extensions to
`TypeMapperHealthKitMappingTests` and `TypeMapperPropertyTests`, net of one removed stale
test). Then re-ran `swift test -Xswiftc -warnings-as-errors` in each of `Packages/CoreModel`
(15/6), `Packages/Secrets` (14/3), `Packages/GoogleHealthClient` (35/7), and
`Packages/CoachKit` (1/0) without editing any of them — all five packages still pass
together, 0 failures, 0 warnings across the board, **218 tests total combined**.

**Deviations from the plan's literal text (handoff protocol's "blocked?" clause), all
already detailed above, indexed here for scanning:** (1) the Google exercise-type wire
strings are entirely invented (base-knowledge.md names none) — flagged as needing
reconciliation against real API access (P-1.3), same posture as every WP-11 flag; (2)
`saveWorkout`'s signature changed from the WP-08 stub's `([HKObject]) throws` to
`(MappedWorkout) async throws -> HKWorkout?` — a "signatures are starting points, not
contracts" call, necessary because a `MappedWorkout` (not a pre-built `[HKObject]`) is what
the HealthKit-free decision layer actually produces, and because `HKWorkoutBuilder`'s own
async, multi-step nature has no single-call `[HKObject]`-shaped equivalent to `save(_:)`;
(3) `HealthKitWriterError.workoutsNotYetImplemented` was removed (per its own doc comment's
explicit invitation once a real implementation lands), requiring the one stale WP-08 test
that asserted it be deleted; (4) `MappedObject.workout`/`MappedDecision.workout` forced two
one-line, behavior-neutral compile fixes in `SyncEngine.swift`/`SyncEngineTests.swift` —
files outside this WP's nominal TypeMapper/HealthKitWriter scope, but required to keep the
whole `SyncKit` package building once a shared enum gained a new case; both are narrowly
scoped and explicitly flagged, not silent scope creep; (5) no companion JSON fixture exists
under `GoogleHealthClient`'s test target for Exercise, unlike every WP-07/11 type — purely a
consequence of this WP's explicit `Packages/SyncKit`-only scope, documented inline instead.
**Deliberately deferred, as scoped:** wiring `MappedObject.workout` through `SyncEngine`'s
actual incremental sync pipeline (existence-diff against `HKObjectType.workoutType()`,
calling the new `writer.saveWorkout(_:)`, honoring D13's watch-priority conflict
resolution before ever considering a write) is explicitly **not** done here — flagged above
as required follow-up, most naturally WP-12b's job since D13's `ConflictResolver` needs to
run first for exactly this data type (a Google Exercise session overlapping a watch
workout must never reach `saveWorkout` at all, per architecture.md D13.2); Food/Nutrition
Log → `HKCorrelation(.food)` (WP-13) remains unimplemented, as expected; and the real,
live-simulator/device end-to-end `HKWorkoutBuilder` flow (vs. this session's mock-driven
and real-API-compilation verification) is still outstanding, same recurring gap every
HealthKit-touching WP before this one has already flagged.

## WP-14 · Non-writable types → LocalSample + badges

**Verified, not rebuilt: the ECG/Active Zone Minutes/Active Minutes/Irregular Rhythm
Notification pipeline already worked end-to-end before this WP touched anything.**
CoreModel's `GoogleDataType.writability` (`GoogleDataType.swift`) already routes all four to
`.localOnly` (WP-02); `TypeMapper.decide(_:)` (`TypeMapper.swift`) dispatches purely off that
table (`switch point.dataType.writability { case .localOnly: return .localOnly, ... }`), so
all four were already covered, not hand-listed; `SyncEngine.processPage`/`upsertLocalSample`
(WP-09) already upserts `.localOnly` points into `LocalSample` keyed by `externalID`
(fetch-then-mutate, never a blind re-insert, so `linkedWatchWorkoutUUID` survives a re-sync).
An existing test (`TypeMapperGoldenTests.localOnlyTypesRouteToLocalOnly`) already iterated
exactly these four types; an existing `SyncEngineTests.localOnlyPointsUpsertIntoLocalSample
AndDoNotDuplicateOnResync` already proved the no-dupe-on-resync property, but only for ECG.
**No genuine gap was found in the routing/upsert pipeline** — this WP's actual work was (1) a
small SyncKit-side derivation helper the plan asked for, (2) extending one existing test's
coverage from ECG-only to all four types (belt-and-suspenders, since `upsertLocalSample` has
no per-type branching), and (3) the app-target UI layer, which didn't exist yet at all.

**No CoreModel change needed, confirmed by reading the actual model before assuming
otherwise:** `LocalSample.swift` has no `isClinical` field and doesn't need one —
`LocalSample.dataType` (a `GoogleDataType.rawValue` string) already carries enough
information to derive clinical-ness at read time. Built `Packages/SyncKit/Sources/SyncKit/
Routing/ClinicalClassification.swift` (new `Routing/` subfolder, deliberately outside
`TypeMapper/` — WP-13 was concurrently editing every file in that folder for nutrition
correlations, and this WP's brief calls it off-limits): `public nonisolated func
isClinicalType(_ type: GoogleDataType) -> Bool` (true for `.electrocardiogram`/
`.irregularRhythmNotification`, false for everything else, including the other two
`.localOnly` types) plus a `isClinicalType(rawDataType: String) -> Bool` convenience overload
for callers holding a `LocalSample.dataType` string rather than the enum (returns `false`,
not a crash, for an unrecognized string — same "never crash, just skip" posture
`TypeMapper` uses for unmapped types). Marked `nonisolated` on purpose: it only
pattern-matches the `GoogleDataType` value handed to it (no isolated CoreModel computed
property is touched), so it's callable synchronously from anywhere — `SyncEngine`'s own
actor, plain `swift test`, or a future WP-19/20 `ContextAssembler`/`ProfileField.isClinical`
call site — with no forced `await`, unlike `GoogleDataType.writability` itself (a
MainActor-isolated computed property per TypeMapper.swift's own header note). This is the
one piece of this WP that's genuinely table-driven/derived rather than a fixed list, per the
task's explicit "prefer deriving over adding a redundant stored field" instruction.
**`ProfileField.isClinical`/`.excludedFromAI` (`ProfileField.swift`, WP-02) already exists one
layer up** and already defaults `excludedFromAI` to `isClinical` (architecture.md D8) — that
plumbing was built by WP-02 in anticipation of this WP, confirmed by reading it, not assumed;
wiring an actual `LocalSample` → `ProfileField` conversion through it is WP-19/20's job
(`KnowledgeProfile`/`ContextAssembler` don't exist yet), not this WP's.

**App-target UI (`HealthLoomApp/Dashboard/`), the actual new surface this WP adds:**
`LocalOnlyTypeRow.swift` (new view) renders one row per P1 local-only type from an array of
`LocalSample`s (not a `SyncState`, which these four types never get) — name, item count,
last-sample-relative-time (`RelativeDateTimeFormatter`, mirroring `SyncTypeRow`'s
`lastSyncedText`, "No data yet" when the array is empty), an always-present "Not in Apple
Health" badge, and — only for ECG/IRN, via `isClinicalType(_:)` — an additional "Clinical ·
excluded from AI" indicator. `AppEnvironment.p1LocalOnlyTypes` (new static constant,
`HealthLoomApp/DI/AppEnvironment.swift`, styled after the existing `p0Types`) is the fixed
four-type list `DashboardView` iterates — deliberately a plain literal, not "every
`GoogleDataType` where `.writability == .localOnly`" derived at this call site: this WP's
brief names exactly these four as P1's scope, not "whatever CoreModel's table happens to
mark local-only in the future" (a fifth type appearing there later should be a deliberate
app-target decision, not something that silently starts appearing on the dashboard).
`DashboardView.swift` gained a second `@Query(sort: \LocalSample.dataType)` and a second List
section ("Not in Apple Health"), grouping the query results client-side by `dataType ==
type.rawValue` per P1 type and rendering each via `LocalOnlyTypeRow`; the existing
`SyncState`-backed P0 section/`SyncTypeRow` is untouched. `AppEnvironment
.seedDashboardFixtures` (used only under `-UITestSeedData`) now also inserts one `LocalSample`
per P1 type — ECG/IRN with distinct timestamps, Active Zone Minutes/Active Minutes likewise —
so the dashboard UI test can assert the badges against real seeded `LocalSample` rows, not a
mock.

**Deliberately not wired into `DashboardView.syncNow()`'s `syncAll(types:)` call, flagged
inline in `DashboardView.swift`'s header comment:** `GoogleConsentView`'s OAuth consent
request (`AppEnvironment.p0Types.map(\.scope)`) only covers P0's scopes; ECG and IRN sit
behind their own separate `.ecg`/`.irn` Google scopes (`GoogleDataType.scope`), so calling
`syncAll` with the P1 types today would 403 against a real (non-stubbed) Google account that
never consented to those scopes. Widening onboarding's consent request is out of this WP's
stated file scope (`GoogleConsentView.swift` isn't listed in WP-14's "Touches"). Until a
future WP does that (or wires WP-15's backfill to include these types), the dashboard's
"Not in Apple Health" section is real and correctly wired to `LocalSample`, but only actually
populates in production once *something* syncs these four types — flagged here as the honest
current state, not silently glossed over.

**One real SwiftUI/accessibility pitfall found only by running `xcodebuild test` against the
simulator (not by reasoning about the code), a new instance of the same family WP-10's own
progress.md note already flagged for plain containers:** applying one
`.accessibilityIdentifier` to a SwiftUI `Label(_:systemImage:)` reports that **same**
identifier on *both* of the Label's underlying elements (the image and the text) as separate
accessibility nodes, not one combined element — a query for that identifier then fails with
"Multiple matching elements found," confirmed via a real failing test run's captured
accessibility snapshot. `Label` had never been used with an identifier anywhere in this
codebase before this WP. Fixed in `LocalOnlyTypeRow.swift` by not using `Label` at all for the
badge/clinical rows — an explicit `HStack { Image(...).accessibilityHidden(true);
Text(...).accessibilityIdentifier(...) }` instead, so exactly one element (the `Text`) carries
the identifier and its `.label` is the plain display string. Flagged here for whichever future
WP next reaches for `Label` with an accessibility identifier. A second, smaller issue: the
original WP-10 dashboard UI test asserted `dashboard.freshnessHeader` (the top section) *after*
scrolling down to reach the `sleep` row — harmless when the List had only 4 P0 rows below it,
but this WP's second "Not in Apple Health" section adds 4 more rows below that, and the extra
scrolling needed to reach them evicted the freshness header's cell from the virtualized List's
materialized window, breaking the *existing*, unmodified assertion. Fixed by moving that one
assertion to immediately after launch, before any scrolling (`DashboardUITests.swift`) — the
assertion itself is unchanged, just no longer coupled to how much content happens to render
below it.

**Tests** (7 new in `Packages/SyncKit/Tests/SyncKitTests/Routing/ClinicalClassificationTests
.swift`, 1 new in the existing `SyncEngineTests.swift`, 1 new UI test in the existing
`DashboardUITests.swift`): `isClinicalType`/`isClinicalType(rawDataType:)` — true for ECG/IRN;
false for the other two `.localOnly` types (with a sanity check that they really are
`.localOnly`, since clinical-ness is orthogonal to writability, not implied by it); false for
a representative sample of `.healthKit`/`.skip` types; an exhaustive tripwire over
`GoogleDataType.allCases` proving no case besides those two is ever miscategorized; the
`rawDataType:` overload matches the enum overload for every known type and returns `false`
(not a crash) for an unrecognized string. `SyncEngineTests
.allFourLocalOnlyTypesUpsertIntoLocalSampleAndDoNotDuplicateOnResync` generalizes the existing
ECG-only upsert-no-dupe test to all four types (fresh container/engine per type, sync twice,
assert exactly one `LocalSample` row with the right `externalID`/`dataType` both times) —
belt-and-suspenders confirmation that `upsertLocalSample`'s lack of per-type branching really
does mean nothing type-specific trips up the fetch-by-`externalID` path.
`DashboardUITests.testDashboardRendersNotInAppleHealthBadgesForLocalOnlyTypes` (new,
`-UITestSeedData`, real `xcodebuild test`, not typecheck-only) asserts all four P1 rows
render with the "Not in Apple Health" badge, that ECG/IRN additionally show the clinical
indicator, and that Active Zone Minutes/Active Minutes do not.

**Verification performed in this session:** `swift test -Xswiftc -warnings-as-errors` in
`Packages/SyncKit` — **161 tests / 14 suites, 0 failures, 0 warnings** at the point this WP's
own changes were complete (153 pre-existing + 8 new: 7 in the new `ClinicalClassificationTests`
suite + 1 extending `SyncEngineTests`). Then re-ran `swift test -Xswiftc -warnings-as-errors`
in `Packages/CoreModel` (15/6), `Packages/Secrets` (14/3), and `Packages/GoogleHealthClient`
(35/7) without editing any of them — all passing, 0 failures, 0 warnings. `xcodegen generate`
→ `xcodebuild build -scheme HealthLoom -destination 'id=50EC4D33-A8EE-4A91-9617-8B2B757B971D'`
(the same "iPhone 17 Pro" simulator WP-10 used) — **BUILD SUCCEEDED**, zero warnings,
zero errors. `xcodebuild build-for-testing` — **TEST BUILD SUCCEEDED**. `xcodebuild test`
(both the targeted `DashboardUITests` and the full `HealthLoom` scheme, `HealthLoomTests` +
`HealthLoomUITests`) — **TEST SUCCEEDED** every run, including three repeats while fixing the
`Label`-identifier and freshness-header pitfalls above; the final run: `HealthLoomTests` 1/1,
`HealthLoomUITests` 3/3 (`OnboardingUITests` unaffected, both `DashboardUITests` passing).
**A transient, unrelated failure surfaced mid-session and is recorded here rather than
"fixed," per the handoff protocol's coordination note:** partway through, `swift test` in
`Packages/SyncKit` twice failed on non-exhaustive switches over `MappedUnit`
(`MappedObject.swift`) and then over a new `MappedDecision.correlation(_)` case
(`TypeMapperPropertyTests.swift`) — both entirely inside WP-13's concurrent nutrition-
correlation work in `TypeMapper/`, mid-edit at the moment the build ran (confirmed by file
mtimes moving in real time under `TypeMapper/` during this session). Per this WP's explicit
instruction not to touch WP-13's files, no fix was attempted; a short wait and re-run showed
WP-13 finish propagating the new case, after which the package built and tested clean again.
**Final combined state, re-verified once more immediately before writing this note (now
reflecting WP-13's further progress too, not just this WP's own changes):** `Packages/SyncKit`
**170 tests / 15 suites**, 0 failures, 0 warnings (WP-13 had added a ninth suite and nine more
tests of its own by this point); `CoreModel` 15/6, `Secrets` 14/3, `GoogleHealthClient` 35/7,
`CoachKit` 1/0 unchanged; the app-target build and `DashboardUITests`/`HealthLoomTests` were
re-run against this final state too — still **BUILD SUCCEEDED** / **TEST SUCCEEDED**.

**No CoreModel gap, no genuine routing/upsert bug found, nothing deferred as a blocking
gap.** **Deliberately deferred, as scoped:** actually wiring these four types into a real (or
even stubbed) sync run from the dashboard/onboarding UI (needs broader OAuth consent scopes,
`GoogleConsentView.swift`, out of this WP's file list); `ContextAssembler`/`KnowledgeProfile`
honoring `ProfileField.excludedFromAI` for these types in a real AI turn (WP-19/20, doesn't
exist yet); `WatchCoverageIndex`/real `ConflictResolver` (WP-12b), `BackfillCoordinator`
(WP-15), and background scheduling (WP-16) remain untouched and unstarted, as expected.

## WP-13 · Nutrition correlations

Built the Nutrition Log → `HKCorrelation(.food)` pipeline entirely within
`Packages/SyncKit/Sources/SyncKit/TypeMapper/`, following the exact
`MappedDecision`/`MappedObject` pure/impure split every prior TypeMapper WP established, plus
two coordination-flagged single-arm edits outside that directory (see below). **CoreModel/
WP-06 had already pre-wired this feature** — confirmed by reading rather than assumed:
`GoogleDataType.writability` (`GoogleDataType.swift`) already declares both `.food` and
`.nutritionLog` as `.healthKit("HKCorrelationTypeIdentifierFood")`; `HealthKitIdentifierClassifier`
(`HealthKitIdentifier.swift`) already classifies that sentinel to `.correlationFood`; and
`HealthKitObjectTypeResolver` (`HealthKitObjectTypeResolver.swift`) already resolves it to a
real `HKObjectType.correlationType(forIdentifier: .food)`. None of those three files needed
touching (and weren't touched) — this WP only had to *use* the sentinel string, not invent it.

**Real-SDK verification performed before writing any production code** (same "confirm against
the real SDK, don't guess" discipline WP-06/07/11/12 established): read `HKCorrelation.h`,
`HKTypeIdentifiers.h`, and `HKUnit.h` directly from the iOS 26.4 simulator SDK on this machine,
confirming (1) `HKCorrelation`'s factory initializer
(`+correlationWithType:startDate:endDate:objects:metadata:`) is **not** deprecated and needs no
builder/store round-trip, unlike `HKWorkout` — this is the single biggest structural difference
from WP-12's Exercise pipeline, and the reason this WP's `.correlation` case could follow the
`.quantity`/`.category` "construct it right here" precedent instead of `.workout`'s
pass-through-to-a-dedicated-writer-method one; (2) the four exact HealthKit identifiers WP-13's
brief asked to confirm, not guess: `HKQuantityTypeIdentifierDietaryEnergyConsumed` (kcal,
Cumulative), `HKQuantityTypeIdentifierDietaryProtein`/`DietaryCarbohydrates`/`DietaryFatTotal`
(all g, Cumulative), plus `HKCorrelationTypeIdentifierFood` itself and the plain `HKUnit.gram()`
factory (as opposed to `.kilogram`'s `gramUnitWithMetricPrefix:.kilo}`); (3) ran a scratch
`xcrun swiftc -typecheck` (disposable directory under this session's scratchpad, never part of
the repo) against the real `HealthKit.framework` for `arm64-apple-ios26.0-simulator`, using this
repo's exact `Package.swift` flags, exercising the literal `HKCorrelation(type:start:end:
objects:metadata:)` call shape (both the metadata-only and device+metadata overloads), the four
dietary `HKQuantityTypeIdentifier` cases, `HKObjectType.correlationType(forIdentifier: .food)`,
and the exact `let hkConstituents: [HKSample] = ....compactMap { ... }; Set(hkConstituents)`
covariance pattern this WP's `makeHKCorrelation()` uses — zero errors, zero warnings, before any
of it was written into `MappedObject.swift`.

**New/extended files, `Packages/SyncKit/Sources/SyncKit/TypeMapper/` (all within this WP's
core scope):** **`MappedTypes.swift`** — new `MappedUnit.gram` case; new
`MappedNutritionCorrelation` struct (`healthKitIdentifier`, `start`, `end`,
`constituents: [MappedQuantitySample]`, `metadata`); new `MappedDecision.correlation(_:)` case
(doc-commented with the "why this isn't `.workout`-shaped" reasoning above); updated the
`.skip` case's doc comment to remove the now-stale forward-reference to this WP. **`TypeMapper
.swift`** — added `case .nutritionLog: return decideNutritionLog(point)` to
`decideHealthKitMapped`'s switch (the switch's outer *shape* — one line, additive — is
unchanged, exactly matching WP-07's own "broadening the switch is the extension point" note);
implemented `decideNutritionLog(_:)`; rewrote the `default` case's doc comment to explain both
remaining deliberately-unhandled rows (`.totalCalories`, unchanged from WP-11, and `.food`, new
here). **`MappedObject.swift`** — new `MappedObject.correlation(HKCorrelation)` case (`#if
canImport(HealthKit)`-guarded, like `.quantity`/`.category`); new `.correlation` arm in
`TypeMapper.map(_:)`'s switch; new `.gram` arm in `makeHKUnit()`; new
`MappedNutritionCorrelation.makeHKCorrelation() -> HKCorrelation?` extension, which reuses
`MappedQuantitySample.makeHKQuantitySample()` verbatim per constituent (no second
`HKQuantitySample`-construction code path) and mirrors `makeHKQuantitySample`/
`makeHKCategorySample`'s existing direct `HKObjectType.xxxType(forIdentifier:)`-lookup style
(not routed through `HealthKitObjectTypeResolver`, matching this file's own established
precedent for those two, even though the resolver could technically also do it).

**Grouping-mechanism assumption (this WP's central judgment call, flagged per the task's
explicit instruction, not silently guessed):** base-knowledge.md §3 records **Nutrition Log as
a Sample (S) record type** — the same record kind as Weight/Height/Blood Glucose, *not* a
Session (Se) like Exercise/Sleep. Taking that classification at face value (rather than
assuming a session-style multi-point structure the doc doesn't actually describe for this
type), this mapper assumes **one `GoogleDataPoint` = one whole meal/log entry**, with up to four
macro fields flat in that single point's `values` dict — no `sessionPayload`, no cross-point
grouping step. Under this assumption, WP-13's spec line "meal grouping key = Google log entry
ID" is satisfied *for free*: `GoogleDataPoint.id` already *is* the meal's own external ID,
identical to every other Sample-type row this package already maps (weight, height, blood
glucose, ...) — there is no separate grouping mechanism to build. This is exactly the
brief's own suggested "reasonable assumption" (option (e) in the task's own list), chosen
over the alternative (multiple `GoogleDataPoint`s per meal, grouped by a shared but
differently-keyed meal ID found in metadata/sessionPayload) because base-knowledge.md gives
no evidence for that alternative and the Sample/Session distinction it *does* document points
away from it. **Flagged here as needing reconciliation against the real API** (still gated on
P-1.3, the outstanding Google Cloud OAuth client) — if a real payload instead spreads one
meal's macros across multiple points sharing a differently-shaped meal identifier, only
`TypeMapper.decideNutritionLog` needs a new upstream grouping step; `MappedNutritionCorrelation`
itself (a correlation's worth of constituents) would still apply unchanged. Wire field names
(`energy_kcal`/`protein_g`/`carbs_g`/`fat_g`, read after GoogleHealthClient strips Google's
assumed `nutrition_log.` prefix) are likewise invented and flagged, same posture as every
WP-11/12 field-name note — documented in `decideNutritionLog`'s doc comment and in both new
fixtures' `_comment` keys.

**Partial macro sets — the deliverable's other explicit requirement:** every constituent is
independently optional; `decideNutritionLog` drops a **single** out-of-range (negative) macro
field without invalidating the rest of the meal (same "drop just the bad field" philosophy
WP-12's `decideExercise` established for distance/energy, not WP-07's "drop the whole point"
guard for steps/heart-rate) — zero is an ordinary, accepted reading for any macro (e.g. 0g
protein for a black coffee log). Only when *zero* constituents survive (none reported, or every
reported one was negative and dropped) does the whole point route to `.skip` — never an empty
`HKCorrelation` (same "never emit a degenerate empty result" rule WP-07's `decideSleep`
established for an all-segments-dropped session). Tested explicitly at both the pure-decision
layer (`fullMacroMealGolden`, `partialMacroMealGolden`, `singleMacroMealStillProducesACorrelation`,
`mealWithNoMacrosAtAllRoutesToSkip`, `negativeMacroIsDroppedButOthersSurvive`,
`allNegativeMacrosRoutesToSkip`, `zeroValuedMacroIsAccepted`) and the real-`HKCorrelation` layer
(`fullMacroMealMapsToRealHKCorrelation` — 4 constituents; `partialMacroMealMapsToRealHKCorrelationWithTwoConstituents`
— exactly 2; `mealWithNoMacrosStaysSkippedThroughMap`).

**Metadata placement — stamped on *both* the correlation and every constituent sample,** per
the task's explicit "figure out and document your choice" instruction. Reasoning: (1)
`SyncEngine`'s existence-diff for this type queries only
`HKObjectType.correlationType(forIdentifier: .food)` (D4's per-(type,window) dedupe check only
strictly needs the correlation's own external-ID metadata); but (2) the constituent quantity
samples (`dietaryProtein` etc.) are independently queryable/readable HealthKit objects in their
own right — a future `KnowledgeStore` nutrition summary (WP-19) may read them directly, not
through correlation membership — and architecture.md D4 says "every HealthKit sample," not
"every correlation." This costs nothing extra to implement: `makeHKCorrelation()` builds each
constituent via the already-existing, already-tested `MappedQuantitySample.makeHKQuantitySample()`,
which stamps whatever `MappedMetadata` it's given automatically — no new stamping code was
written. Verified explicitly (`fullMacroMealMapsToRealHKCorrelation` checks
`HKMetadataKeyExternalUUID` on both the correlation itself and each real constituent
`HKQuantitySample`).

**Coordination points — the two minimal, flagged edits outside `TypeMapper/`,** exactly the
kind the task brief anticipated and asked to keep as small as possible: (1)
**`Packages/SyncKit/Sources/SyncKit/SyncEngine/SyncEngine.swift`**, `processPage`'s exhaustive
switch over `MappedObject` — added one arm, `case .correlation(let correlation): guard
!knownExternalIDs.contains(point.id) else { continue }; batch.append(correlation);
newExternalIDs.append(point.id)`, structurally **identical** to the pre-existing `.quantity`
arm immediately above it (not a no-op-with-a-TODO the way WP-12's `.workout` arm had to be —
`HKCorrelation` is a plain `HKObject`/`HKSample`, so it slots into the existing `[HKObject]`
batch/`writer.save(batch)` path with zero new orchestration needed). (2) `Packages/SyncKit/
Tests/SyncKitTests/SyncEngine/SyncEngineTests.swift`'s `SuppressingConflictFilter.resolve(_:for:)`
— added `.correlation` to the existing `case .workout, .localOnly, .skip:` pass-through arm
(now `case .workout, .correlation, .localOnly, .skip:`), required purely to keep that
test-only exhaustive switch compiling once `MappedObject` gained a new case, exactly WP-12's
own precedent for the identical situation with `.workout`. Both edits are one arm each,
behavior-neutral for every pre-existing test, and clearly commented in place as this WP's
addition. **Confirmed live, not just planned:** WP-14 (concurrently editing this same
`SyncEngine`/`SyncEngineTests` area for LocalSample routing) hit exactly the transient
compile break these two arms would cause mid-edit, waited rather than touching this WP's
files, and re-ran once this WP's edit had propagated — see WP-14's own entry above ("a short
wait and re-run showed WP-13 finish propagating the new case") for their side of this
coordination. **`HealthKitWriter/`/`HealthKit/` were never touched** — `HKCorrelation`'s
synchronous constructibility meant no new writer method (no `saveWorkout`-style addition) was
needed at all; `.correlation` reuses `HealthKitWriter.save(_:)`/`existingExternalIDs(type:
start:end:)` completely unmodified.

**Correlation dedupe — reuses the existing path, no parallel mechanism, verified directly
against `HealthKitWriter`+`MockHealthStore` rather than through a `SyncEngine`-level test** (a
deliberate choice to keep this WP's footprint in `SyncEngineTests.swift` to the single
unavoidable arm above): new file `Tests/SyncKitTests/TypeMapper/NutritionCorrelationSavingTests.swift`
(`#if canImport(HealthKit)`, reuses `MockHealthStore` from `Tests/SyncKitTests/HealthKitWriter/`
as-is — that file was read and reused, never modified) proves `HKObjectType
.correlationType(forIdentifier: .food)` flows through the *exact same*
`existingExternalIDs(type:start:end:)`/`save(_:)` methods every `.quantity`/`.category`/`.workout`
write already uses: `noExistingMealsBeforeAnySave`, `aSavedCorrelationIsDiscoverableThroughTheSameExistingExternalIDsMethod`,
`aSavedPartialMacroCorrelationIsAlsoDiscoverable`, `callerMustCheckExistingExternalIDsBeforeSavingAgain`
(mirrors `WorkoutSavingTests`' own dedupe-section test names/shape almost exactly), and
`constituentSamplesAreIndividuallyPresentInTheStoreAfterSave` (documents the mock's boundary —
`MockHealthStore.save(_:)` only records what its top-level `[HKObject]` batch was actually
handed, so the correlation is discoverable as one `HKObject` but its constituents aren't
separately enumerated by this mock the way a real `HKHealthStore` would fan them out
internally — flagged in-code so this isn't mistaken for a production gap). **One authoring bug
caught by the first real test run, not a production bug:** the first draft of
`callerMustCheckExistingExternalIDsBeforeSavingAgain` queried `existingExternalIDs` with the
fixture's *exact* zero-length instant bounds (`start == end`, matching this fixture's
point-in-time meal timestamp, the same shape as weight/height/bloodGlucose elsewhere in this
package) — `MockHealthStore`'s strict `<`/`>` date-window overlap check can never match an
exact zero-length window against an exact zero-length sample, so the test failed on first run.
Fixed by padding the query window (±60s), matching the exact convention every existing
instant-sample dedupe test in `HealthKitWriterTests.swift` already uses (`Self.farPast`/
`Self.farFuture`) — caught and fixed before this note was written, not left broken.

**Fixtures added** under `Packages/GoogleHealthClient/Tests/GoogleHealthClientTests/Fixtures/GoogleHealth/`
(fixtures only, per this WP's explicit scope grant — unlike WP-12's Exercise, which *couldn't*
get a companion JSON fixture due to its stricter SyncKit-only scope, this WP's brief explicitly
grants fixture-only access to GoogleHealthClient's test directory, so the WP-07/11 convention
of a companion `_comment`-documented JSON fixture was followed, not WP-12's exception):
`nutrition-log.json` (`nutrition-0001`, full macro set: 650 kcal/35g protein/70g carbs/22g fat)
and `nutrition-log-partial.json` (`nutrition-0002`, energy + protein only — WP-13's required
"meal missing macros" scenario, macros *absent* from `value`, not present-as-zero/null,
matching blood-glucose-mgdl.json/-mmol.json's existing mutual-exclusion convention). Neither
fixture is referenced by any existing GoogleHealthClientTests `.swift` file (confirmed by
grepping that test target for `Fixtures/GoogleHealth` references before adding them) — same as
every WP-11 fixture addition, they sit inert until a future WP wires a `GoogleDataPointDecodingTests`
case to them; `Packages/GoogleHealthClient`'s own test count is confirmed unchanged (35/7) by
this addition. Mirrored in SyncKit's `TypeMapperFixtures.nutritionLogPoint(...)` (one
parameterized builder covering both the full and partial scenarios, plus a new
`MappedDecision.isCorrelation` convenience alongside the existing `.isQuantity`/`.isCategory`).

**Also fixed one now-stale WP-11/12 test, same "a WP's own change can retroactively make an
older test's premise wrong" precedent WP-11 and WP-12 each already established for one test of
their predecessor's:** `TypeMapperGoldenTests.unimplementedHealthKitTypeRoutesToSkipForNow`
(exemplar `.exercise`, chosen by WP-11 as "still genuinely unimplemented" back when Exercise
itself was still unimplemented) had gone stale the moment WP-12 implemented Exercise — it still
*passed* (an exercise point with no `sessionPayload` still routes to `.skip`, just for a
different reason: missing payload, not "not implemented"), so it wasn't caught by any `swift
test` run, only by re-reading what the test's own name and doc comment claimed. Once this WP
implements Nutrition Log too, there is no longer *any* `.healthKit`-writability
`GoogleDataType` left that's genuinely "not implemented yet" — every `default`-routed case
(`.totalCalories`, `.food`) is now a documented, deliberate non-write decision, not a
placeholder. Renamed to `foodRoutesToSkipDeliberately` (exemplar `.food`) with a doc comment
explaining exactly this, parallel to the existing `totalCaloriesRoutesToSkip` test.

**Tests, final count for `Packages/SyncKit`:** `swift test -Xswiftc -warnings-as-errors` from a
clean `.build` — **178 tests / 16 suites, 0 failures, 0 warnings**. New: `TypeMapperNutritionCorrelationTests`
(9 tests, new suite, HealthKit-free decision layer) and `NutritionCorrelationSavingTests` (5
tests, new suite, `#if canImport(HealthKit)`, dedupe); extended `TypeMapperHealthKitMappingTests`
(+3: full/partial/no-macros real-`HKCorrelation` checks), `TypeMapperPropertyTests` (nutrition
added to both the "never end < start" exhaustive list — now 19 rows — and
`reversedWindowIsAlwaysDropped`), `TypeMapperFixtures` (+1 builder, +1 `MappedDecision`
convenience), `TypeMapperGoldenTests` (1 renamed, not net-new). Note for whoever reads this
next: this package's test/suite count also includes WP-14's concurrent LocalSample-routing
additions (`ClinicalClassificationTests` and others) already present in the tree before this
WP's own edits began — the 178/16 figure is the honest combined total, not this WP's isolated
delta; this WP's own net addition is 25 new/changed tests across two new suites plus five
extended files. **Re-ran the same command in each of the other four packages immediately
before writing this note:** `Packages/CoreModel` **15/6**, `Packages/Secrets` **14/3**,
`Packages/GoogleHealthClient` **35/7**, `Packages/CoachKit` **1/0** — all unchanged from their
prior baselines, all five packages passing together, 0 failures, 0 warnings, **243 tests total
combined**.

**Deviations from the plan's literal text (handoff protocol's "blocked?" clause), all detailed
above, indexed here for scanning:** (1) the one-`GoogleDataPoint`-per-meal grouping assumption
(base-knowledge.md's own Sample-vs-Session record-type distinction is the basis, not a guess
made from nothing, but still unconfirmed against a real payload — gated on P-1.3 like every
prior WP's field-name flags); (2) wire field names (`energy_kcal`/`protein_g`/`carbs_g`/
`fat_g`) are invented, same posture as every WP-11/12 field-name note; (3) `.food` (as opposed
to `.nutritionLog`) is deliberately left unhandled — base-knowledge.md §3 never marks plain
"Food" ✅-writable, only "Nutrition Log" is, despite CoreModel's writability table grouping both
under one sentinel; (4) two one-line, behavior-neutral compile-fix arms in `SyncEngine.swift`/
`SyncEngineTests.swift` — both required, both minimal, both flagged as this WP's coordination
points per the task brief's own explicit allowance for exactly this situation, and confirmed
not to have collided destructively with WP-14's concurrent work in the same area. **Not a
deviation, worth stating explicitly:** `HealthKitWriter/`/`HealthKit/` needed zero changes —
unlike WP-12's Exercise, this feature's real-HealthKit-object construction fit entirely inside
`TypeMapper/`'s existing "construct it right here" pattern. **Deliberately deferred, as
scoped:** wiring `MappedObject.correlation` through any watch-priority conflict resolution
(not applicable — D13 is workout/stream-specific, nutrition correlations have no watch-overlap
concept) is correctly not a concern here; real, live-simulator/device end-to-end
`HKHealthStore.save` of an actual `HKCorrelation` (vs. this session's `MockHealthStore`-driven
verification) remains outstanding, same recurring gap every HealthKit-touching WP before this
one has already flagged, still gated on P-1.3.

## WP-17 · Sync settings + incremental scopes

Built a new `HealthLoomApp/Settings/` folder (three files) plus one new app-target unit test
file — no package under `Packages/` was touched, per this WP's scope.

**`ensure(scopes:)` already existed — no `GoogleAuthManager` change was needed.** Per this
WP's explicit instruction to check before assuming a gap, read
`Packages/GoogleHealthClient/Sources/GoogleHealthClient/Auth/GoogleAuthManager+Consent.swift`
first and found WP-04 had already built exactly what this WP needs:

```swift
@MainActor
@discardableResult
public func ensure(
    scopes: [GoogleDataType.Scope],
    presentationContextProvider: any ASWebAuthenticationPresentationContextProviding
) async throws(GoogleAuthError) -> Bool
```

— it computes `missingHealthScopes(from:)` (the granted-vs-requested diff) internally and only
calls `beginConsent` for the missing subset, returning `true`/no UI at all if nothing was
missing. This is word-for-word the plan's "incremental-scope diffing" ask, so `GoogleAuthManager.swift`
and `GoogleAuthManager+Consent.swift` are **untouched** — the "additively extend" allowance in
this WP's brief turned out not to be needed at all. The one thing `ensure` needs beyond scopes
is an `ASWebAuthenticationPresentationContextProviding`; rather than reopening
`DI/GoogleConsentCoordinator.swift` (explicitly read-only per this WP's brief, and WP-10's
onboarding seam), a small independent copy of its `presentationAnchor(for:)` conformance lives
in the new `IncrementalConsentPresenter.swift` — same ~15 lines, same `MainActor.assumeIsolated`
resolution for the non-isolated protocol requirement, deliberately duplicated rather than shared
so this WP's diff stayed additive-only.

**`SyncPreferences.swift`** (new): a `@MainActor @Observable final class` wrapping a
dependency-injected `UserDefaults` (default `.standard`; tests inject
`UserDefaults(suiteName:)`). `SyncPreferences.syncableTypes` is `GoogleDataType.allCases.filter
{ $0.writability != .skip }` — every type CoreModel's writability table gives a real
destination (22 `.healthKit` + 4 `.localOnly` = 26 types), matching this WP's "every syncable
type, not `.skip` ones" instruction over hand-listing P0's four. Persists the *disabled* set
(absence = enabled, so every existing/fresh install defaults to "everything on," matching prior
behavior before this screen existed). Two pure static functions are the WP's required-tests
target and are also the reusable, documented API for any call site:

```swift
static func filterEnabled(_ types: [GoogleDataType], disabled: Set<GoogleDataType>) -> [GoogleDataType]
static func requiredScopes(for enabledTypes: Set<GoogleDataType>) -> Set<GoogleDataType.Scope>
```

plus instance conveniences (`isEnabled(_:)`, `setEnabled(_:for:)`, `filteredForSync(_:)`,
`requiredScopes(toEnable:)`) that wrap them against the instance's live `disabledTypes`.

**Where the disabled-type filter lives (deliverable 3) — the actual design problem this WP had
to solve given the "don't touch `SyncEngine.swift`/`HealthLoomApp.swift`" fence:** the filter
can't live inside the sync engine (SyncKit, off-limits) or the background-task registration
site (`HealthLoomApp.swift`, off-limits — and, as of this session, WP-16's in-flight territory,
see the build-verification note below). It lives as a pure function on `SyncPreferences`
instead, and **every caller of `SyncEngine.syncAll(types:)` is expected to run its candidate
type list through it first.** This session wires the one call site currently in the app:
`DashboardView.swift`'s `syncNow()` now does

```swift
let typesToSync = SyncPreferences().filteredForSync(AppEnvironment.p0Types)
```

— a fresh `SyncPreferences()` constructed at call time (not held in `@State`) specifically so
it always reflects whatever `SettingsView` (a separate instance, pushed via `NavigationLink`)
most recently wrote to the same `UserDefaults` key, avoiding a staleness trap two independent
`@Observable` instances over the same store would otherwise create. **Coordination point,
flagged per the handoff protocol:** WP-16's background-refresh handler will need to apply the
same filter to its own due-types list before calling `syncAll(types:)` — it should construct
its own `SyncPreferences()` (same `UserDefaults.standard` key, no shared instance needed) and
call `.filteredForSync(_:)` exactly as `DashboardView` does. This is documented in
`SyncPreferences.swift`'s own header comment so both call sites (and whoever reads that file
next) see the same instruction, not just this note. Disabling a type does **not** touch
already-written HealthKit/`LocalSample` data — only future `syncAll` calls that consult this
filter are affected — matching D2/WP-35's separation of "stop syncing" from "delete."

**`SettingsView.swift`** (new): one `List` section per `GoogleDataType.Scope`
(`GoogleDataType.Scope.allCases` order: activityAndFitness/healthMetrics/sleep/nutrition/ecg/irn),
each containing a `Toggle` per type in that scope from `SyncPreferences.syncableTypes`. Turning
a toggle on calls `appEnvironment.googleAuthManager.ensure(scopes:
preferences.requiredScopes(toEnable: type), presentationContextProvider: consentPresenter)`;
failures render inline per-row (`settings.error.<type>`) rather than silently swallowing —
mirrors `GoogleConsentView`'s existing error-surfacing pattern. `AppEnvironment` itself was
**not** modified (explicitly read-only per this WP's brief) — `SettingsView` reads
`appEnvironment.googleAuthManager` from the environment exactly as `GoogleConsentView` already
does, and owns its own `SyncPreferences`/`IncrementalConsentPresenter` instances rather than
routing through `AppEnvironment`.

**`DashboardView.swift`** (minimal additive edit, the one file this WP was explicitly allowed
to touch beyond its own new folder): two changes, both flagged inline in the file with `WP-17`
comments — (1) the `syncNow()` filter shown above; (2) one new `ToolbarItem(placement:
.topBarLeading)` holding a `NavigationLink(destination: SettingsView())` (gear icon,
`dashboard.settings` accessibility identifier), placed at `.topBarLeading` specifically so it
doesn't collide with the existing `.primaryAction` "Sync Now" button. **Coordination point for
WP-15:** if WP-15 also wants a Dashboard nav link (to a backfill screen), `.topBarLeading` now
holds this WP's Settings link — a second link should pick a different toolbar placement (or a
list-section entry) rather than replacing this one. Checked `git status`/file mtimes for a
`Backfill` app-target screen before finishing this session; none existed yet, so no live
collision was possible in-session, but this is recorded here in case WP-15 lands after.

**`project.yml` deviation, not anticipated going in, discovered only by actually running
`xcodebuild test`:** `HealthLoomTests` had no `dependencies:` entry at all (WP-01's placeholder
test never imported anything). Its `BUNDLE_LOADER = "$(TEST_HOST)"` build setting is inferred by
xcodegen regardless, which is enough for Xcode to *host* the bundle inside the app, but **not**
enough for the linker to resolve symbols — the new `SyncPreferencesTests.swift`'s `@testable
import HealthLoom` type-checked fine but failed at link time with dozens of "Undefined symbol"
errors for every `HealthLoom`/`CoreModel` symbol referenced, plus an explicit compiler warning
naming the missing dependency. Fixed by adding

```yaml
HealthLoomTests:
  ...
  dependencies:
    - target: HealthLoom
```

(xcodegen's standard recipe for a hosted unit-test target) — `HealthLoom`'s own transitive
package links (CoreModel, Secrets, GoogleHealthClient, SyncKit, CoachKit) came along for free,
no per-package entry needed. This is a one-line, additive, infrastructure-only change (not a
source file, and not one of the explicitly fenced-off packages/files); flagged here per the
handoff protocol's "blocked? ... prefer the current SDK/setup, keep the behavior specified,
note the deviation" clause, since strictly speaking this WP's brief said "you should not need
to edit project.yml" (true for *source* globbing, but this gap was a pre-existing test-target
wiring hole that only this WP's first real app-target unit test happened to expose).

**Tests** (`HealthLoomTests/SyncPreferencesTests.swift`, 17 new — this WP's own file is the
*first* real test in `HealthLoomTests` beyond WP-01's placeholder): `SyncPreferencesPureFunctionTests`
(9, no `UserDefaults` involved at all) — `filterEnabled` excludes a disabled type, no-op when
nothing's disabled, empties out when everything's disabled, ignores a disabled type absent from
the candidate list (the WP's literal "disabled type skipped by `syncAll`" ask, tested as the
pure filtering function per its explicit "test the filtering function, not full integration"
instruction); `requiredScopes` unions across enabled types, dedupes two same-scope types down to
one, empty-set-in/empty-set-out (the WP's literal "scope-computation from toggle set" ask);
`syncableTypes` excludes every `.skip` type and includes every non-`.skip` type (sanity-checked
against `GoogleDataType.allCases` directly, not a hand-copied list). `SyncPreferencesInstanceTests`
(8, each building its own throwaway `UserDefaults(suiteName:)` and tearing it down before
returning — never touches `UserDefaults.standard`) — fresh instance has everything enabled;
disabling persists and is reflected by `isEnabled`; state persists across two instances sharing
one `UserDefaults`; re-enabling clears the disabled set; `filteredForSync` consults live state;
`requiredScopes(toEnable:)` returns the type's own scope; two instances over *different*
`UserDefaults` suites never see each other's writes (proves the DI seam actually isolates, not
just that the API compiles).

**Verification performed in this session:** `swift test -Xswiftc -warnings-as-errors` in
`Packages/GoogleHealthClient` — **35 tests / 7 suites, 0 failures, 0 warnings**, unedited, as
expected. Re-ran the same command in all five packages together: `CoreModel` 15/6, `Secrets`
14/3, `GoogleHealthClient` 35/7, `SyncKit` 205/24 (grown from 197/20 earlier in the session —
WP-15/WP-16 landing their own tests concurrently, none of it touched here), `CoachKit` 1/0 — all
passing, 0 failures, 0 warnings. `xcodegen generate` + `xcodebuild build -scheme HealthLoom
-destination 'id=50EC4D33-A8EE-4A91-9617-8B2B757B971D'` ("iPhone 17 Pro" simulator, matching
prior WPs' device) — **BUILD SUCCEEDED**, zero errors, zero warnings. `xcodebuild test` (full
`HealthLoom` scheme) — **TEST SUCCEEDED**: `HealthLoomTests` **17 tests / 2 suites, 0 failures**
(the pre-existing placeholder + this WP's 17 new ones); `HealthLoomUITests` **3/3** unaffected
(`DashboardUITests` ×2, `OnboardingUITests` ×1).

**Transient, unrelated failures hit mid-session and recorded rather than fixed, per the handoff
protocol's explicit instruction for exactly this situation:** (1) `Packages/SyncKit` failed
`swift test` twice earlier in the session with compile errors squarely inside
`Sources/SyncKit/Backfill/` (a MainActor-isolation error in
`UserDefaultsBackfillHorizonRecordStore`, then a "no calls to throwing functions" error in a
backfill test) — confirmed via file mtimes moving in real time that this was WP-15 actively
mid-edit in its own fenced-off folder; a background retry loop (`until swift test ...; do sleep
20; done`) confirmed SyncKit reached a clean, passing state (197/20 at that point) before this
session's own app-level build/test ran, and it has since grown further (205/24) as WP-15/WP-16
kept landing work — never touched. (2) A later `xcodebuild build` failed with ten+ MainActor-
isolation errors **entirely inside `HealthLoomApp.swift`** (`BGTaskScheduler` registration,
`logger`/`identifier`/`configuration` static properties referenced from a nonisolated closure
context) — this file is explicitly fenced off as WP-16's territory and was never touched here;
confirmed by reading the errors (all inside WP-16's background-sync registration code, none in
anything this WP added) and by this session's own earlier, fully clean `xcodebuild build`+`test`
run (captured above) predating that edit. A follow-up background retry
(`until xcodebuild build ...; do sleep 20; done`) was started before writing this note to obtain
a final, contemporaneous clean build; if it hasn't completed by the time this note is read, the
earlier BUILD SUCCEEDED/TEST SUCCEEDED run already stands as this WP's own verification — the
failure is entirely WP-16's in-flight code, not this WP's.

**Deliberately deferred, as scoped:** wiring WP-16's background handler to consult
`SyncPreferences` itself (documented as a coordination point, not implemented here — WP-16
owns `HealthLoomApp.swift`/`SyncKit/BackgroundSync/`); any UI test for the Settings screen or the
incremental-consent flow (this WP's "Tests" line only asks for the two pure functions above,
tested as such — not full integration, matching the brief's explicit instruction); an "is this
scope currently granted" indicator per row (would need an async per-row read of
`GoogleAuthManager.currentGrantedScopes`, not required by the brief, skipped to keep the screen
simple); WP-35's actual data-wipe-on-disable flow (explicitly out of scope, called out in both
the plan and this session's UI copy: "Data already written ... is not deleted -- that's a
separate step in a future release").

**Post-note addendum (observed after the above was written, same session):** WP-15 landed its
own `DashboardView.swift` nav link — a new `Section { NavigationLink("Historical Backfill",
destination: BackfillView()) }` appended after the existing list sections — concurrently with
this WP's toolbar edit. Exactly the non-collision this note's "Coordination point for WP-15"
paragraph anticipated: two independent, additive edits to the same file (a new toolbar item
here, a new list section there) landed without conflict or overwrite. No action was needed on
this WP's part; recorded here only to close the loop on that coordination flag.

## WP-15 · Historical backfill

Built `Packages/SyncKit/Sources/SyncKit/Backfill/` (three new files:
`BackfillTypes.swift`, `BackfillCoordinator.swift`,
`SyncEngine+BackfillBusyProbe.swift`) plus `HealthLoomApp/Backfill/` (two new
files: `BackfillView.swift`, `BackfillTypeRow.swift`), per architecture.md D5
and this WP's four steps.

**Architectural decision, made only after reading WP-09's actual code (per
this WP's own explicit instruction): `BackfillCoordinator` does *not*
delegate a chunk's work to `SyncEngine.sync(type:)`.** `SyncEngine.sync(type:)`
(`SyncEngine.swift`) takes **no window parameter at all** — its window is
always internally derived as `(SyncState.lastSyncedAt ?? now - initialWindow)
- lookback(type) ... now`, and on success it advances `SyncState.lastSyncedAt`,
the *incremental* high-water mark. There is no "synthetic window" parameter
to hand it, and even if there were, routing backfill through it would either
corrupt `lastSyncedAt` with a backward-walking value (breaking D3 for every
future incremental sync) or require restructuring `SyncEngine` to accept a
window and choose which cursor field to persist — a restructure of a file
this WP was told to touch minimally, if at all. So `BackfillCoordinator` is
its own, leaner actor that **reuses** every other WP-09/07/08 primitive
directly: the exact same `GoogleReconcileClient` protocol (no adapter
needed — `GoogleHealthClient`'s existing conformance, from
`GoogleHealthClient+SyncEngine.swift`, is reused verbatim), `TypeMapper.map(_:)`,
`ConflictFiltering`/`IdentityConflictFilter` (the WP-12b seam), and
`HealthKitWriter`'s batched `existingExternalIDs`/`save` (architecture.md D4).
Its own `pullMapWrite`/`processPage` (`BackfillCoordinator.swift`) is a
deliberate, small, parallel implementation of `SyncEngine.performSync`/
`.processPage`'s pull → map → conflict-filter → existence-diff → write/upsert
shape, keyed on the backward-walking `SyncState.backfillCursor` instead of
the forward `lastSyncedAt` — the two cursors' semantics are different enough
that unifying them would have cost more (a `SyncEngine` restructure) than it
saved. Full reasoning is in `BackfillCoordinator.swift`'s own header comment.

**One additive change to `SyncEngine.swift` (a coordination point, flagged
per the brief since WP-16 also reads `SyncEngine`'s in-flight state):** added
`public func isBusy(for type: GoogleDataType) -> Bool { inFlight[type] != nil }`
— a one-method, read-only accessor over the *existing* `inFlight` dictionary
(WP-09's own de-duplication bookkeeping), no new state, no restructuring.
This satisfies WP-15 step 2's "SyncEngine exposes an `isBusy` signal" via a
narrow protocol, `BackfillBusyProbe` (`Backfill/BackfillTypes.swift`), that
`SyncEngine` conforms to with a zero-code extension
(`SyncEngine+BackfillBusyProbe.swift`, deliberately placed in this WP's own
`Backfill/` folder rather than adding a file to `SyncEngine/`, to keep this
WP's footprint inside that concurrently-relevant file to the one method).
Checked mid-session: WP-16 never touched `SyncEngine.swift` itself (its own
footprint was `HealthLoomApp.swift` + a new `SyncKit/BackgroundSync/
BackgroundSyncPlanner.swift`), so no collision materialized in practice.

**`backfillCursor`'s literal contract, honored, plus one small side-store
for the one thing it can't represent (the CoreModel-scope gap, documented
instead of editing CoreModel per the handoff protocol):** `SyncState
.backfillCursor`'s own doc comment says `nil` means "backfill hasn't started
or has completed" — `BackfillCoordinator` honors this literally (sets the
cursor to a concrete `Date` after every checkpointed chunk, back to `nil`
exactly when the horizon is reached). But telling "never started" apart from
"completed to horizon X" — needed for WP-15 step 3's "extending an
already-completed backfill re-opens the walk, resuming from where it left
off, not from scratch" — genuinely needs a second fact `SyncState` doesn't
carry. Rather than adding a field to CoreModel (out of this WP's scope),
`BackfillHorizonRecordStore` (`Backfill/BackfillTypes.swift`) is a tiny,
separate, `UserDefaults`-backed key-value store (production:
`UserDefaultsBackfillHorizonRecordStore`, namespaced
`com.healthloom.backfill.completedHorizon.<type>`) recording only "the
deepest horizon this type has fully completed." `BackfillCoordinator
.runNextChunk(for:)` consults both: `backfillCursor` for the resumable
chunk-walk position, the side-store to disambiguate a `nil` cursor and to
compute the correct resume point on an "extend" (the *old* horizon's own
boundary date, not `min(lastSyncedAt, now)` again). **Gap flagged
explicitly, per the handoff protocol's "if you truly need a new field,
document it instead of editing CoreModel" clause:** ideally `SyncState`
would carry a `completedBackfillHorizon: String?` field alongside
`backfillCursor` itself; this side-store is the pragmatic substitute.

**`BackfillHorizon`:** `enum` with `.days30/.days90/.year1/.all` (`.all`
resolves to a fixed practical floor, the Unix epoch, guaranteeing the walk
terminates in a finite number of chunks rather than claiming data really
exists that far back); `.defaultHorizon = .days90` per architecture.md D5.
Narrowing to a shallower horizon after a deeper one already completed is a
documented no-op (this coordinator never deletes already-imported history —
deletion is WP-35's job).

**Round-robin (WP-15 step 1):** `runRound()` calls `runNextChunk(for:)`
exactly once per configured type, in order — one chunk per type per round,
by construction, so no type can outrun another within a round.
`BackfillCoordinator.start()` spawns a `Task(priority: .utility)` background
loop (WP-15 step 2: "runs at `.utility` priority") that calls `runRound()`
repeatedly with a `GoogleHealthClient.BackoffSleeper`-injected delay between
rounds (reused directly from `GoogleHealthClient`'s own seam — no parallel
sleeper protocol invented) until every type reports done or the coordinator
is paused; `pause()`/`resume()` and `setHorizon(_:)` are the UI's three
control-surface calls.

**UI (`HealthLoomApp/Backfill/`):** `BackfillView` — a horizon `Picker`, a
pause/resume `Button`, and a `List` of `BackfillTypeRow`s (one per type,
"Mar 2026 … done" style progress text per WP-15's own illustrative phrasing,
"Reached Mar 2026" mid-walk, "Not started yet" before the first chunk, plus
an error row mirroring `SyncTypeRow`'s existing error-rendering convention).
Deliberately **polls** `BackfillCoordinator.statuses()` on a 1.5 s `.task`
loop rather than driving off `@Query` — `BackfillTypeStatus` folds in the
actor's own `horizon`/`isPausedNow` state and the `UserDefaults`-backed
completed-horizon record, neither of which is SwiftData-observable, so a
`@Query`-only approach could show a fresh cursor next to a stale "is this
actually done for the *current* horizon" answer. `BackfillTypeRow` follows
`SyncTypeRow`/`LocalOnlyTypeRow`'s established "identifiers only on leaves"
rule (own progress.md notes on container identifiers clobbering children's).

**Two coordination-point edits outside `Backfill/`/`Backfill/`, both flagged
in-code and here:** (1) `AppEnvironment.swift` gained one new stored property,
`backfillCoordinator: BackfillCoordinator`, constructed with the same
`reconcileClient`/a fresh `HealthKitWriter()`/the same `modelContainer`
`syncEngine` already uses (so both pipelines dedupe against the same
underlying HealthKit store, D4), and `syncEngine` itself passed as the
`busyProbe:` (its zero-code `BackfillBusyProbe` conformance). This file
wasn't named as any other WP's territory in this WP's brief, but *is* a
DI root other WPs might reasonably also touch — kept to one property + one
init block, and verified (re-reading the file immediately before editing)
that no other agent had a conflicting in-flight edit there at the time.
(2) `DashboardView.swift` gained the one-line nav hook the handoff brief
explicitly asked for: `Section { NavigationLink("Historical Backfill",
destination: BackfillView()) }`, placed after the existing sections rather
than inside the `.toolbar` block WP-17 was concurrently editing there —
confirmed via the addendum WP-17 itself appended above that both edits
landed without conflict.

**Tests** (`Packages/SyncKit/Tests/SyncKitTests/Backfill/`, 27 new — the
suite count jump from 178/16 to 205/24 combines these with WP-16's own
concurrently-landed `BackgroundSyncPlanner` tests, none of which this WP
touched): `BackfillChunkingTests` — exact chunk boundaries (a `.year1`
horizon against the default 30 d chunk size produces 13 chunks, 12 full +
one partial clipped exactly to the horizon date, no gap/overlap between any
two consecutive windows) and kill-resume (run three chunks, discard the
`BackfillCoordinator` instance entirely without calling `stop()`/`pause()`,
reconstruct a brand-new one from the same `ModelContainer` + same horizon
store, verify the fourth chunk resumes from exactly the persisted checkpoint,
not `min(lastSyncedAt, now)` again). `BackfillHorizonExtensionTests` —
completing a 30 d horizon then extending to 90 d resumes from the old 30 d
boundary rather than re-walking `[now-30d, now]` a second time, and reaches
`.alreadyDone` with the completed-horizon record correctly updated to 90 d;
narrowing to a shallower horizon after a deeper one is already complete is a
verified no-op (no new reconcile calls, cursor stays `nil`).
`BackfillRoundRobinTests` — a "huge" type (13 chunks needed) and a "small"
one (1 chunk, via a seeded `lastSyncedAt` already near the horizon) share
one coordinator; round 1 is asserted to advance *both* by exactly one chunk
(proving round-robin isn't starving either direction), and the small type is
asserted to report `.alreadyDone` on every subsequent round while the big
type keeps making steady one-chunk-per-round progress until it too finishes
(14 rounds total for 13 chunks — the extra round is the one that discovers
completion). `BackfillIdempotencyTests` — a `BackfillBusyProbe` reporting a
type busy suspends it with zero reconcile calls and zero cursor movement
(clearing busy makes the identical chunk available again); and, reusing a
*shared* `MockHealthStore`/`HealthKitWriter` between a real `SyncEngine.sync
(type:)` run and a subsequent overlapping `BackfillCoordinator` chunk with
the same external ID, the store ends up with exactly one sample and exactly
one `save` call — proving the dedupe path (architecture.md D4's batched
existence diff) is genuinely shared, not reimplemented, between the two
pipelines.

**Verification performed in this session:** `swift test -Xswiftc
-warnings-as-errors` in `Packages/SyncKit` — **205 tests / 24 suites, 0
failures, 0 warnings** (run twice consecutively for flakiness, stable both
times). Re-ran the same command in each of `Packages/CoreModel` (15/6),
`Packages/Secrets` (14/3), `Packages/GoogleHealthClient` (35/7), and
`Packages/CoachKit` (1/0) without editing any of them — all five packages
pass together, 0 failures, 0 warnings. `xcodegen generate` +
`xcodebuild build -scheme HealthLoom -destination
'id=50EC4D33-A8EE-4A91-9617-8B2B757B971D'` ("iPhone 17 Pro" simulator,
iOS 26.4.1, matching prior WPs' device) — **BUILD SUCCEEDED**, zero errors,
zero warnings, including the new `Backfill/` app-target files.
`xcodebuild build-for-testing` — **TEST BUILD SUCCEEDED**. `xcodebuild test`
(full `HealthLoom` scheme) — **TEST SUCCEEDED**: `HealthLoomTests` 17/2 (WP-17's,
unaffected), `HealthLoomUITests` 3/3 (`DashboardUITests` ×2, `OnboardingUITests`
×1), 0 failures. **One transient, unrelated failure hit and diagnosed rather
than "fixed," per the handoff protocol:** an initial `xcodebuild test` run
reported `TEST FAILED` with `OnboardingUITests` crashing/timing out during
its very first step (waiting for `onboarding.welcome.continue`, before this
WP's own `BackfillView` is ever reachable) with repeated `XCTAS Error:
Error getting main window Unknown kAXError value -25218` — a known
Simulator/accessibility-automation-session instability, not a code issue
(confirmed: re-running the identical test in isolation reproduced the exact
same crash-and-restart pattern at the exact same step). `xcrun simctl
shutdown` + `boot` on the same simulator cleared it completely — a
subsequent full `xcodebuild test` run passed cleanly end-to-end with no code
changes in between, confirming the failure was simulator-session state, not
this WP's (or any other WP's) code.

**Deliberately deferred, as scoped:** wiring the background `.utility`-priority
walk to actually *start* automatically at app launch (this session has
`BackfillView.task` call `start()` on appear instead, so the walk begins
when the user opens the new screen, not at cold launch) — deliberately kept
this way to avoid a second background-task-registration concern competing
with WP-16's own `BGAppRefreshTask` wiring in `HealthLoomApp.swift`, a file
this WP does not touch; a future WP could call `backfillCoordinator.start()`
once from `HealthLoomApp.init()` or a `BGProcessingTask` (the plan's own
WP-16 step 3 optionally mentions this) if always-on backfill without a user
visiting the screen first is desired. `MappedObject.workout`/`.correlation`
routing inside `BackfillCoordinator.processPage` deliberately mirrors
`SyncEngine.processPage`'s own current behavior (workouts counted as skipped
pending WP-12b's conflict-resolution-before-write wiring; correlations flow
through the same batch path) rather than diverging or fixing that
pre-existing gap, which is out of this WP's scope. No `HealthKit`-authorization
UI change was needed (backfill reuses whatever read/write authorization the
existing onboarding flow already requested).

## WP-16 · Background sync

Built `Packages/SyncKit/Sources/SyncKit/BackgroundSync/BackgroundSyncPlanner.swift`
(new folder, this WP's alone) plus edits scoped to exactly `HealthLoomApp/HealthLoomApp.swift`
in the app target, per the handoff brief's collision-avoidance instructions. **SyncKit
side** — three pure, `nonisolated`, HealthKit-and-BackgroundTasks-free pieces, following
the pure/impure split every prior SyncKit WP established: `SyncStateSnapshot` (a plain
`{ lastSyncedAt: Date? }`, not the real SwiftData `SyncState`, so the planner needs no
`ModelContext`); `dueTypes(allTypes:syncStates:now:minInterval:) -> [Type]` (generic over
any `Hashable`, not hard-coded to `GoogleDataType`, per the brief's "(or similar)"
latitude) — a type is due if never synced or `now - lastSyncedAt >= minInterval`, and the
result is ordered **most-overdue-first** (never-synced sorts as `.infinity` staleness;
ties preserve `allTypes`' original order via Swift's stable sort) so a budget-truncated
run always serves the neediest types first; `BackgroundSyncBudget` (`hasRemainingBudget
(elapsed:) -> Bool` over a `limit`, default 20s) and `BackgroundSyncConfiguration`
(bundles `minInterval` default 15 min — matching architecture.md §1's "~15 min" Google
sync cadence —, `budget`, and `reschedulingInterval` default 30 min, mirroring
`SyncConfiguration`'s own centralize-the-constants precedent); and
`shouldRescheduleBackgroundSync(after: [SyncOutcome]) -> Bool`, which always returns
`true` — a function, not just a comment, specifically so the "always reschedule, even on
failure" invariant (stated twice in the plan) is regression-tested (empty/all-ok/all-error/
mixed outcome arrays) without any `BGTaskScheduler` dependency. **21 new tests**
(`Tests/SyncKitTests/BackgroundSync/BackgroundSyncPlannerTests.swift`): never-synced,
recently-synced, stale, exact-boundary (inclusive) and one-second-inside-boundary
(exclusive) cases; a mixed-state ordering test; tie-order-preservation; empty-input and
no-due-types edge cases; budget under/at/beyond-limit; and the reschedule invariant across
all four outcome shapes.

**App-target side (`HealthLoomApp.swift` only, per the brief's file-scope restriction —
did not touch `AppEnvironment.swift`, `Settings/` (WP-17), or `Backfill/` (WP-15)):**
`HealthLoomApp.init()` constructs `AppEnvironment` (unchanged), then — still on
`MainActor`, synchronously, before `init()` returns, matching Apple's "register before
`applicationDidFinishLaunching` returns" contract translated to a SwiftUI-lifecycle app
with no `UIApplicationDelegateAdaptor` — captures `environment.modelContainer`,
`environment.syncEngine`, and `GoogleDataType.allCases.filter { $0.writability != .skip }`
into a new `private struct BackgroundSyncLaunchContext: Sendable`, then calls
`HealthLoomBackgroundSync.registerLaunchHandler(context:)` and `.scheduleNextRun()` (the
"at launch" half of "schedule next... at launch AND in the handler"). A new private enum
`HealthLoomBackgroundSync` (all members `nonisolated`) owns: `registerLaunchHandler`
(`BGTaskScheduler.shared.register(forTaskWithIdentifier: "com.healthloom.sync.refresh",
using: nil) { ... }`); `scheduleNextRun` (submits a `BGAppRefreshTaskRequest`, catching and
logging — never crashing on — `.unavailable`/`.notPermitted`/`.tooManyPendingTaskRequests`);
`handleLaunch(_:context:)` (the actual launch handler: reschedules **unconditionally as
its very first statement**, before any sync work starts, then runs `run(context:)` in a
detached `Task`, wires `task.expirationHandler` to cancel it, and calls
`task.setTaskCompleted(success:)` from a second detached `Task` once the first resolves);
and `run(context:)` (builds a `[GoogleDataType: SyncStateSnapshot]` from a fresh
`ModelContext` — mirroring `SyncEngine.performSync`'s own per-call-context pattern — asks
`dueTypes(...)` which types are due, then calls `SyncEngine.sync(type:)` **one type at a
time**, most-overdue-first, checking `BackgroundSyncBudget.hasRemainingBudget(elapsed:)`
between types and stopping gracefully once the ~20s budget is spent).

**"The list of P0+P1 GoogleDataType cases to sync" (the brief's phrase) is derived, not
hand-duplicated:** `GoogleDataType.allCases.filter { $0.writability != .skip }` — every
type with an actual destination by now (WP-11's full TypeMapper table, WP-12's exercise,
WP-13's nutrition, WP-14's `LocalSample` routing) — rather than reusing
`AppEnvironment.p0Types`/`.p1LocalOnlyTypes` (which live in the file this WP doesn't touch,
and are narrower — the dashboard's own WP-14 comment already documents that its manual
"Sync Now" deliberately excludes the four local-only types pending broader OAuth-scope
consent). This is strictly the broader, more correct P1 set and never drifts from
CoreModel's table as future types are added. **Known consequence, not a bug:** until a
future WP widens onboarding's Google-scope request, background syncs for the
not-yet-consented types (ECG/AZM/activeMinutes/IRN, and any P1 type outside the original
four scopes) will show up as `.error` `SyncOutcome`s (401/403) every run — harmless and
already the documented status quo (WP-14's dashboard comment says the same for the manual
button), not something this WP introduced or needed to fix.

**Concurrency-isolation decision (the WP's explicit "think this through" ask) — read
`SyncEngine.swift`'s actual declaration first, did not assume:** `actor SyncEngine` is its
own, distinct, **non**-`MainActor` actor (architecture.md §3's explicit list), and
`sync(type:)`/`syncAll(types:)` **never throw** (confirmed from `SyncEngine.swift`'s own
doc comments, not just WP-09/10's progress notes). Consequently the BG handler needs **no
hop onto `MainActor`** to call it — entering a different, non-MainActor actor is symmetric
regardless of the caller's own isolation, so hopping to `MainActor` first would only add a
pointless round-trip. Every function in `HealthLoomBackgroundSync` is therefore declared
`nonisolated`; the *only* `MainActor`-isolated step in this whole feature is the one-time
DI capture in `HealthLoomApp.init()`. A related, non-obvious wrinkle surfaced only by
compiling (not by reasoning): this app target's `SWIFT_DEFAULT_ACTOR_ISOLATION: MainActor`
setting makes *every* declaration MainActor-isolated by default unless marked
`nonisolated` — including plain `static let` string/struct constants and even
`BackgroundSyncPlanner.swift`'s own `SyncStateSnapshot`/`BackgroundSyncBudget`/
`BackgroundSyncConfiguration` struct *declarations* in SyncKit (which has the identical
package default) — the compiler rejected calling `SyncStateSnapshot`'s memberwise-adjacent
`init` from the `nonisolated` BG-handler path until the struct declarations themselves
were marked `nonisolated`, not just the free functions operating on them; fixed by adding
`nonisolated` to all three struct declarations (matching `SyncEngineTypes.swift`'s
existing `nonisolated public struct SyncConfiguration` precedent, which this file had
initially, incorrectly, only half-followed). Second wrinkle: `BGTask`/`BGAppRefreshTask`
predates Swift concurrency and carries no `Sendable` annotation (verified against this
toolchain's real `BGTaskScheduler.h`/`.apinotes`, not assumed) even though
`BGTaskScheduler`'s own documented contract hands the launch handler exclusive,
non-overlapping ownership of one task instance per invocation — capturing it into the
completion `Task.detached` closure required a small `private struct BackgroundTaskBox:
@unchecked Sendable { let task: BGAppRefreshTask }` wrapper (documented inline as
reflecting that single-owner contract, not a real data race) plus `@preconcurrency import
BackgroundTasks` (the compiler's own suggested fix once the box existed, for a residual
diagnostic on `BGTaskRequest`'s properties).

**Reschedule-on-every-path:** `scheduleNextRun()` is called from `init()` ("at launch")
and, unconditionally, as `handleLaunch`'s very first statement — **not** duplicated into a
success branch and a failure branch. This is deliberately stronger than "reschedule in
both branches": it also covers the process being killed between the expiration handler
firing and the completion `Task` ever resuming, since there is no branch left
un-instrumented when there's no branching in the guarantee at all.
`shouldRescheduleBackgroundSync(after:)` is additionally called and `assert`-checked (plus
logged) at completion as a documented, testable confirmation of the same invariant — it
never gates the actual reschedule call, since that guarantee must not depend on the
completion closure ever running.

**Budget/expiration — two complementary layers:** (1) proactive — `run(context:)` calls
`SyncEngine.sync(type:)` one type at a time (not the bulk `syncAll(types:)`) so it can
check `BackgroundSyncBudget` between types and stop gracefully with time to spare (the
normal path); (2) reactive backstop — `task.expirationHandler` cancels the detached `Task`
running that loop for the case where even the proactive check wasn't fast enough (one
type's fetch alone overruns); Swift's cooperative cancellation propagates into
`GoogleHealthClient`'s `URLSession` calls and `Task.sleep`-based backoff waits (both
cancellation-aware), so an in-flight fetch fails promptly rather than running to
completion. Neither layer preempts a single type's in-flight network call mid-request on
its own — doing that would mean editing `SyncEngine.swift`, out of this WP's file scope —
but since `sync(type:)` never throws and architecture.md D3's cursor semantics mean an
untouched or interrupted type simply keeps its previous `lastSyncedAt` and safely re-pulls
the same window next time, this is exactly the "cursors make partial runs safe" behavior
the plan describes, not a gap.

**WP-15 coupling — deliberately not implemented, per this WP's explicit instructions:**
WP-15's own progress entry (above) flags that `BackfillCoordinator.start()` could be
called from `HealthLoomApp.init()` or a `BGProcessingTask` "if always-on backfill... is
desired," naming this exact file. Per this WP's brief ("do NOT implement that coupling
yourself"), it is **not wired in** — `HealthLoomBackgroundSync` only ever calls
`SyncEngine.sync(type:)`/incremental sync, never `BackfillCoordinator`. **Extension point
for a future WP:** `HealthLoomApp.init()` already has a natural, obvious slot right after
`HealthLoomBackgroundSync.registerLaunchHandler`/`.scheduleNextRun()` to also register a
second `BGProcessingTask` (per WP-16 step 3's "optionally a BGProcessingTask for backfill
chunks") that calls into a `BackfillCoordinator` instance from `AppEnvironment` the same
way this WP captures `syncEngine`/`modelContainer` — no structural change to this file
would be needed, just a second `BackgroundSyncLaunchContext`-shaped capture and a second
`register`/`submit` pair with a new identifier (which would first need adding to
`project.yml`'s `BGTaskSchedulerPermittedIdentifiers`, currently only listing
`com.healthloom.sync.refresh`) and `UIBackgroundModes` including `processing` in addition
to (see below) `fetch`.

**Possible `project.yml` gap, flagged rather than silently edited or silently ignored (the
brief was explicit: "do NOT edit project.yml" / "should not be needed"):**
`UIBackgroundModes` currently lists only `processing` (WP-01, anticipating
`BGProcessingTask`/backfill). `BGAppRefreshTask` conventionally also needs the `fetch`
background mode declared (Xcode's Signing & Capabilities panel's separate "Background
fetch" checkbox, distinct from "Background processing") for the system to actually wake
the app for it — `BGTaskSchedulerPermittedIdentifiers` alone is enough for
`register(...)`/`submit(...)` to compile, link, and not throw (confirmed: both succeeded
and logged normally on-device^Wsimulator in this session's testing, submit failing only
with the expected, benign `.unavailable` the Simulator always returns), but real
background wake-ups on a physical device may not fire without `fetch` also present. Not
verified against a physical device in this session (no such device available), and
deliberately not fixed here since `project.yml` is out of this WP's stated scope — flagged
for a human or a future WP with `project.yml` authority to add `fetch` alongside
`processing` in `UIBackgroundModes`.

**Manual verification, not automatable in this environment (per the plan's own text,
explicitly not faked):** the real `BGTaskScheduler` register → submit → background-launch
flow is verified via lldb's `e -l objc -- (void)[[BGTaskScheduler sharedScheduler]
_simulateLaunchForTaskWithIdentifier:@"com.healthloom.sync.refresh"]` against a running
debug session — this requires an interactive debugger attached to a live app process and
was **not run in this session** (this agent has no interactive lldb/Xcode-debugger
access). What *was* verified, for real, in this session: (1) `swift test -Xswiftc
-warnings-as-errors` in `Packages/SyncKit` — the new 21-test `BackgroundSyncPlannerTests`
suite passes standalone and as part of the full package (**205 tests / 24 suites**, 0
failures, 0 warnings, including WP-15's concurrently-landed `Backfill` tests); (2) a real
`xcodebuild build`/`test -scheme HealthLoom` on an iOS 26.4.1 simulator, which exercises
`HealthLoomApp.init()` → `registerLaunchHandler`/`scheduleNextRun` for real on every test
launch — device logs (`xcrun simctl spawn ... log show`) confirm
`BackgroundTasks:Framework submitTaskRequest: <BGAppRefreshTaskRequest:
com.healthloom.sync.refresh, earliestBeginDate: ...>` fires on every app launch, followed by
this WP's own redacted log line (`[com.healthloom.app:BackgroundSync] Failed to schedule
next background sync: Error Domain=BGTaskSchedulerErrorDomain Code=1`, i.e.
`.unavailable` — exactly Apple's documented Simulator behavior, "doesn't support
background processing," not a bug) — confirming the registration/schedule code path runs,
compiles, and fails only in the one documented, expected, gracefully-handled way a
simulator can. The actual background-launch handler body (`handleLaunch`/`run`) was
**not** exercised end-to-end by a real background wake in this session (that's exactly the
lldb-simulate-launch gap above) — its logic is covered indirectly by the pure planner
tests plus code review, not by an integration test, and is flagged here as the honest
boundary of what could be verified without interactive tooling.

**Environment note, not a code defect (flagged per the handoff protocol since it cost
real debugging time and could recur for the next agent sharing this Mac):** the first two
`xcodebuild test` attempts against the simulator device UUID named in prior WPs'
progress notes (`50EC4D33-...`, "iPhone 17 Pro") failed with app-process churn (rapid
launch → clean `exit(0)` → relaunch, eventually exceeding `xcodebuild`'s own test-runner
patience) that looked at first like a crash caused by this WP's new code. Investigation
(device logs via `xcrun simctl spawn ... log show`, `ps` for concurrent processes) showed:
(a) the app process's own exit was voluntary, `exit(0)`, never a signal/crash, with this
WP's `BackgroundSync` log lines appearing normally beforehand; (b) a **different**
Claude Code agent process (distinct `/tmp/claude-<id>-cwd` marker, i.e. WP-15 and/or
WP-17's concurrent session) was independently running its own `xcodebuild test -scheme
HealthLoom -destination id=50EC4D33-...` against the **exact same booted simulator** at the
same time — two/three concurrent `xcodebuild test` invocations hammering one simulator
device explains the churn far better than a code bug would. Re-running against a
different, previously-idle simulator (`08CDB949-...`, also "iPhone 17 Pro" — matching
WP-10's originally-calibrated device model) produced a clean, single-process run with
**TEST SUCCEEDED** both before and after the budget-loop refactor described above. No
code changed because of this — noted here purely so a future agent seeing similar
flakiness on this shared Mac checks for a concurrent `xcodebuild`/simulator user before
assuming their own diff is at fault.

**Deviations from the plan's literal text (handoff protocol's "blocked?" clause):** (1)
`dueTypes(...)` is generic over `Type: Hashable`, not hard-coded to `[GoogleDataType]` as
the plan's illustrative signature shows — the plan explicitly allows "(or similar)," and
genericizing keeps `BackgroundSyncPlanner.swift` free of a `CoreModel` import despite
SyncKit already depending on it elsewhere; `HealthLoomApp.swift` calls it at
`Type == GoogleDataType` via ordinary inference. (2) The budget is enforced by iterating
`SyncEngine.sync(type:)` per type rather than calling `syncAll(types:)` once — a
structural choice (see "Budget/expiration" above) so `BackgroundSyncBudget` is genuinely
consulted in the production path, not just unit-tested in isolation; `syncAll(types:)`
itself was left completely untouched (still used by the dashboard's manual "Sync Now").
(3) WP-16 step 3's "optionally a `BGProcessingTask` for backfill chunks" was left
unimplemented, per this session's explicit instructions (see "WP-15 coupling" above) —
documented as a follow-up extension point rather than attempted. **Verification summary:**
`swift test -Xswiftc -warnings-as-errors` — CoreModel 15/6, Secrets 14/3,
GoogleHealthClient 35/7, SyncKit 205/24 (21 new), CoachKit 1/0, all five still pass
together with 0 failures/0 warnings; `xcodegen generate` + `xcodebuild build -scheme
HealthLoom` — **BUILD SUCCEEDED**, 0 warnings/errors; `xcodebuild test -scheme HealthLoom`
on a real iOS 26.4.1 simulator (`08CDB949-2DA3-4F1E-9F03-48FE5514320B`, "iPhone 17 Pro") —
**TEST SUCCEEDED**, `HealthLoomTests` (1 placeholder + WP-17's 17 `SyncPreferences` tests,
untouched by this WP) and `HealthLoomUITests` (3/3, including both pre-existing WP-10
tests) all passing, re-run after the budget-loop refactor to confirm no regression.

## Orchestrator note — post WP-15/16/17 reconciliation

After WP-15, WP-16, and WP-17 landed concurrently, ran independent verification: all five
packages green together (CoreModel 15/6, Secrets 14/3, GoogleHealthClient 35/7, SyncKit
205/24, CoachKit 1/0 — 270 tests), and a solo `xcodebuild test -scheme HealthLoom` on a
single clean simulator (no concurrent agents) — **TEST SUCCEEDED**: `HealthLoomUITests` 3/3,
`HealthLoomTests` 17/17 (the scheme-level XCTest summary line under-reports this suite
since it's Swift Testing, not XCTest — verified with `-only-testing:HealthLoomTests` and
full verbose output to confirm all 17 cases execute and pass).

Reconciled a three-way discrepancy: WP-17 saw an app-exit during UI tests and attributed
it to WP-16's `BGTaskScheduler` registration; WP-15 saw different flakiness and attributed
it to an accessibility-server error; WP-16 diagnosed (correctly, confirmed independently
here) that three agents were each running `xcodebuild test` against the same booted
simulator instance simultaneously, causing process contention that presented differently
to each observer. Solo re-run reproduced neither symptom. Separately confirmed the actual
`BGTaskSchedulerErrorDomain Code=1` log line WP-16's handler emits during tests is a known,
non-fatal Simulator limitation (BGTaskScheduler routinely refuses submission on the
Simulator) — the handler already catches and logs it rather than crashing; no fix needed
there.

Fixed one small, uncontested gap WP-16 flagged: `project.yml`'s `UIBackgroundModes` only
listed `processing` (needed for `BGProcessingTask`) but WP-16 registers a `BGAppRefreshTask`,
which Apple's guidance pairs with `fetch`. Added `fetch` alongside `processing`. Verified
`xcodegen generate` + `xcodebuild build` still succeeds with zero warnings.

WP-18 (sync log + diagnostics) is next, now that WP-17's Settings screen exists for it to
extend.

## WP-18 · Sync log + diagnostics

Built a new `Packages/SyncKit/Sources/SyncKit/Diagnostics/` folder (7 files), a new
`Packages/SyncKit/Tests/SyncKitTests/Diagnostics/` folder (4 files), a new
`HealthLoomApp/Diagnostics/` folder (2 files), one additive nav-link edit to
`HealthLoomApp/Settings/SettingsView.swift`, one minimal additive hook in
`Packages/SyncKit/Sources/SyncKit/SyncEngine/SyncEngine.swift`, and one minimal additive
DI-wiring edit to `HealthLoomApp/DI/AppEnvironment.swift` (justified below). Every other
SyncKit subfolder named read-only in this WP's brief (`TypeMapper/`, `HealthKitWriter/`,
`HealthKit/`, `Routing/`, `Backfill/`, `BackgroundSync/`), plus `HealthLoomApp.swift` and
the app-target `Backfill/` folder, were not touched.

**Ring buffer: file-backed JSON, not a second SwiftData model.** `SyncLogEntry`
(`Diagnostics/SyncLogEntry.swift`) is a pure `{id, timestamp, dataType, status, itemCount,
errorMessage}` struct; `SyncLogStore` (`Diagnostics/SyncLogStore.swift`) is an `actor`
holding a capped `[SyncLogEntry]`, mirrored to disk via an injected `SyncLogPersisting`
seam (`Diagnostics/SyncLogPersistence.swift`) whose production conformer,
`FileSyncLogPersistence`, writes one JSON array to
`Application Support/HealthLoom/SyncLog.json` (a sibling of `CoreModel.store`, `NSFileProtectionComplete`
applied identically to `CoreModel.swift`'s own on-disk store, `#if os(iOS)`-guarded for
the same reason that file documents). Chose file-backed over "a new lightweight SwiftData
model" (the WP's other offered option) because: (1) `CoreModel.modelTypes`'s schema array
is what the app's one `ModelContainer` is built from, and `CoreModel` is read-only for
this WP — a new model would either need to join that closed schema or stand up an entirely
separate second `ModelContainer`/store purely to hold one flat, non-relational record type
nothing else ever queries; (2) ring-buffer eviction (append, then evict-oldest-past-cap) is
a two-line array operation with a plain JSON array, versus SwiftData's fetch/sort/delete
dance for the same operation, for a data shape with no relational structure at all.
**Cap and eviction policy:** `SyncLogStore.defaultCapacity = 500`, strict FIFO (oldest
entries evicted first via `removeFirst(overflow)` once appending would exceed the cap,
never size/LRU/random). Sized against this app's own worst-case emission rate — one entry
per `GoogleDataType` per completed `SyncEngine.sync(type:)` run, ~26 syncable types
(CoreModel's non-`.skip` count, matching `AppEnvironment.backfillTypes`'s own derivation),
triggered at most every ~15 min (`BackgroundSyncConfiguration.minInterval`) plus manual
"Sync Now" taps — comfortably covering several days of activity before the oldest entries
roll off. `NullSyncLogPersistence` is the in-memory-only test/preview double; `AppEnvironment`
picks it over `FileSyncLogPersistence` whenever `launchConfiguration.useInMemoryContainer`
is set (the same flag that already forces an in-memory `ModelContainer` for UI tests), so
UI test runs never write a real `SyncLog.json` either.

**Redaction strategy, decided and justified per the brief's explicit ask: denylist-of-
token-shaped-patterns, not allowlist-of-safe-fields.** `SyncLogRedactor`
(`Diagnostics/SyncLogRedactor.swift`) is the one filter, applied to the one free-text
field a `SyncLogEntry` carries, `errorMessage`. Every *other* field
(`dataType`/`status`/`itemCount`/`timestamp`) is a structured, non-free-text type an
allowlist doesn't even apply to — there is nothing to allowlist within a `GoogleDataType`
case or an `Int` count, so no filter runs on them at all; the allowlist *is* the strategy
for those fields, implicitly, by construction. `errorMessage`, though, is
`String(describing: error)` over whatever surfaced from the *entire* pull → map → write
pipeline (`GoogleHealthClientError`, `HealthKitWriterError`, a SwiftData error, a plain
`URLError`, or any future error type) — there is no fixed, enumerable "safe shape" to
allowlist for arbitrary text, so the only workable strategy is pattern-matching *known
token shapes* (Google OAuth access tokens `ya29.*`, refresh tokens `1//*`, Google API keys
`AIza*`, Anthropic keys `sk-ant-*`, OpenAI-style keys `sk-*`, generic `Bearer <token>`
headers) plus a conservative catch-all (any 24+-character run of token-alphabet characters
`[A-Za-z0-9._-]`) for unknown/future token shapes, replacing every match with a fixed
`[REDACTED]` marker. Chose over-redaction of an occasional benign long identifier over
under-redaction of a real secret — the correct direction for this trade-off. This is
defense-in-depth, not the primary safeguard: `GoogleAuthManager`'s own `GoogleAuthError`
already never interpolates a raw token into its `description` (WP-05's own "redaction
tripwire" test) — this filter exists for the unaudited remainder of the error surface, and
for genuine defense-in-depth even where it has already been audited.

**The one hook added to `SyncEngine.swift` (minimal, additive, exactly the shape the
brief itself suggested):** a new `private let runRecorder: (any SyncRunRecording)?`
property and matching `init` parameter, defaulting to `nil` — every pre-existing
`SyncEngine(...)` call site (every WP-09..17 test, and `AppEnvironment` before this WP)
keeps compiling and behaving identically. `SyncRunRecording`
(`Diagnostics/SyncRunRecording.swift`) is a one-method protocol
(`func record(_ outcome: SyncOutcome) async`); `performSync` gained exactly two
`await runRecorder?.record(outcome)` lines, one immediately before each of its two
existing `return` statements (the `.ok` success path and the `.error` catch path) — no
other control flow in that file changed. The production conformer,
`SyncEngineLogRecorder`, builds a `SyncLogEntry` from the outcome (timestamp via an
injected `SyncClock`, never a direct `Date()` call, so it stays testable against a virtual
clock exactly like the rest of this file), redacts `errorMessage` through
`SyncLogRedactor.redact(_:)` before it ever reaches `SyncLogEntry`'s initializer, appends
it to a `SyncLogStore`, and mirrors it into `os.Logger` (`DiagnosticsLog.sync`).

**`AppEnvironment.swift` wiring — a second minimal, additive, explicitly-flagged edit,
following WP-15's own established precedent for this exact file.** WP-18's own brief
poses the question directly ("does SyncOutcome already carry what's needed and can you
subscribe/record without editing SyncEngine.swift itself?") and its answer path leads
to "an optional injected `SyncRunRecording` callback... on SyncEngine" — but that hook
still needs a production wire-up, and every other production consumer of `SyncEngine`
(`DashboardView`'s `syncNow()`, `HealthLoomApp`'s background handler) is either out of this
WP's stated file scope or fenced off entirely. `AppEnvironment.swift` is the app's one DI
root and is *not* in this WP's forbidden-files list (unlike `HealthLoomApp.swift` and the
app-target `Backfill/` folder, which are named explicitly) — and WP-15 already established
that a single new stored property plus one new constructor argument on the existing
`SyncEngine(...)` call, clearly flagged in a doc comment, is an acceptable minimal
DI-wiring edit to this specific file (see its own progress.md entry: "This file wasn't
named as any other WP's territory in this WP's brief, but *is* a DI root other WPs might
reasonably also touch"). Added exactly one property (`let syncLogStore: SyncLogStore`,
constructed with `NullSyncLogPersistence` under UI-test launch configs, `FileSyncLogPersistence`
otherwise) and one new argument to the pre-existing `SyncEngine(...)` call
(`runRecorder: SyncEngineLogRecorder(store: syncLogStore)`) — nothing else in that file
changed. No other agent is running concurrently in this session (confirmed by the task
framing), so there was no collision risk to reconcile, unlike WP-15's own session.

**`BackfillCoordinator`/`Backfill/` — deliberately NOT wired in, per the hard scope fence,
not an oversight.** The brief's deliverable 2 asks to "record backfill chunk completions
from WP-15's `BackfillCoordinator` if a similarly clean hook exists there (same rule:
minimal additive change only if unavoidable)" — but this WP's own constraints list
`Backfill/` among the explicitly read-only SyncKit subfolders, with no carve-out (unlike
the framing for `SyncEngine.swift`, which the brief explicitly anticipated a minimal hook
in). `BackfillCoordinator` has no existing recording seam reachable from outside that
file (`runNextChunk`/`runRound` are called only from its own private `runLoop()`; nothing
external observes a `BackfillChunkOutcome` stream), so recording backfill-chunk completions
would require editing `Backfill/BackfillCoordinator.swift` itself — squarely inside the
fenced-off folder. Per the handoff protocol's "if you believe another module must change,
stop and report instead of editing it" rule, this is reported rather than done: backfill
chunk completions are **not** recorded into the sync log in this WP. `BackfillTypeStatus`
(`BackfillCoordinator.statuses()`) remains the sole progress signal for backfill (surfaced
in `BackfillView`, unchanged), and `DiagnosticsLog.backfill` is declared (see below) ready
for whichever future WP owns `Backfill/` to wire in.

**`os.Logger` categories (`Diagnostics/DiagnosticsLog.swift`).** Checked for WP-16's
existing usage before adding anything, per the brief's explicit instruction: `HealthLoomApp.swift`'s
`HealthLoomBackgroundSync` enum already declares `Logger(subsystem: "com.healthloom.app",
category: "BackgroundSync")`, `private` to that file and unreachable from this package
(different module entirely). `DiagnosticsLog.background` reuses the identical subsystem
string and category name (the closest thing to "reuse, don't duplicate" achievable across
a package/app-target boundary) rather than inventing a second near-identical spelling;
this WP adds no new call site for it (WP-16's own lines already cover background-sync
logging). `DiagnosticsLog.sync` is the one category with a real call site in this WP
(`SyncEngineLogRecorder.emit(_:)` — `.log` for `.ok`, `.error` for `.error`, every
interpolated field `.public` since `dataType`/`status`/`itemCount` are structurally safe
and `errorMessage` has already been through `SyncLogRedactor`). `DiagnosticsLog.backfill`
and `.auth` are declared for the same one-category-per-subsystem forward consistency but
have no call site in this session — `Backfill/` is read-only (see above) and
`GoogleHealthClient` (which would own auth-flow logging) is likewise read-only for this WP.

**Settings → "Sync Log" viewer (`HealthLoomApp/Diagnostics/`).** `SyncLogView.swift` reads
`appEnvironment.syncLogStore` (matching `BackfillView`'s own "read the DI root's actor
directly" convention) and polls `recentEntries()` on a `.task` loop (3 s interval — this
data changes far less often than backfill progress, so a slower poll than `BackfillView`'s
1.5 s is appropriate) plus `.refreshable` pull-to-refresh; not `@Query`-driven since
`SyncLogStore` is a plain actor, not SwiftData-backed (documented in that file's header,
mirroring `BackfillView`'s own identical reasoning for its own actor-backed state).
`SyncLogRow.swift` renders one row (status icon, type, relative timestamp, item count,
redacted error text if present) following `SyncTypeRow`/`BackfillTypeRow`'s established
"dumb row, smart container" split and "identifiers only on leaves" accessibility-ID rule.
Export uses SwiftUI's `ShareLink` over `SyncLogTextExporter.export(_:)`
(`Diagnostics/SyncLogTextExporter.swift`, SyncKit — pure, package-tested, newest-first,
one header line + one line per entry: ISO-8601 timestamp, type, status, item count,
error text only when present). `SettingsView.swift` gained exactly one new `Section` with
one `NavigationLink("Sync Log", destination: SyncLogView())` between the existing
disclaimer section and the per-scope toggle sections — nothing above or below it in that
file changed.

**Tests.** New: `Packages/SyncKit/Tests/SyncKitTests/Diagnostics/` (23 tests) —
`SyncLogRedactorTests` (9: each named token shape individually — Google access/refresh
token, Google API key, Anthropic key, OpenAI-style key, bearer header — the catch-all
opaque-run fallback for an unnamed shape, ordinary error prose left untouched, and
multiple tokens in one message all redacted); `SyncLogStoreTests` (5) — the WP's required
ring-buffer-capping test (`pushingMoreEntriesThanTheCapEvictsOldestFirstAndRetainsExactCount`:
8 pushes through a cap of 5 leaves exactly 5, oldest 3 evicted, newest 5 retained in
order, exact count asserted both via `recentEntries().count` and `store.count()`), plus
under-cap behavior, a `limit:`-windowed read, `clear()`, and a persistence-round-trip test
proving a freshly reloaded store re-applies the same cap defensively; `SyncRunRecordingTests`
(6) — the WP's required log-entry-redaction test at two levels (recorder→store directly,
and end-to-end through a real `SyncEngine.sync(type:)` failure with a token-shaped
`GoogleHealthClientError.decodingFailed(...)` message), a plain-message-passthrough
control, a successful-outcome-has-no-error-message case, and two `SyncEngine`-wiring
tests proving the new `runRecorder:` hook fires exactly once per completed run (success
and failure) plus a regression test that omitting `runRecorder:` entirely behaves exactly
as before; `SyncLogTextExporterTests` (3) — newest-first ordering, header shape, and a
redaction-survives-export check (not one of the two explicitly required "Tests:" lines,
added since this is new, real, pure logic backing the export deliverable). **Verification
performed in this session:** `swift test -Xswiftc -warnings-as-errors` in
`Packages/SyncKit` — **228 tests / 28 suites, 0 failures, 0 warnings** (grown from 205/24;
23 new). Re-ran the same command in each of `Packages/CoreModel` (15/6), `Packages/Secrets`
(14/3), `Packages/GoogleHealthClient` (35/7), and `Packages/CoachKit` (1/0) without editing
any of them — all five packages pass together, 293 tests total, 0 failures, 0 warnings.

**App build/test.** Simulator contention precedent from prior WPs' notes: shut down all
booted simulators and rebooted a single previously-idle one
(`08CDB949-2DA3-4F1E-9F03-48FE5514320B`, "iPhone 17 Pro," the same device WP-16's
post-reconciliation note used) before building, since no other agent should be sharing it
this session. `xcodegen generate` + `xcodebuild build -scheme HealthLoom -destination
'id=08CDB949-2DA3-4F1E-9F03-48FE5514320B'` — **BUILD SUCCEEDED**, zero errors, zero
warnings, including the new `Diagnostics/` app-target files. `xcodebuild test` (full
`HealthLoom` scheme) — **TEST SUCCEEDED**: `HealthLoomUITests` 3/3 (`DashboardUITests` ×2,
`OnboardingUITests` ×1, all pre-existing and unaffected), `HealthLoomTests` — re-run with
`-only-testing:HealthLoomTests` and verbose output (per WP-16/17's own note that the
scheme-level XCTest summary under-reports a Swift Testing suite) confirms **17 tests / 2
suites, 0 failures** (WP-17's `SyncPreferences` suite, untouched by this WP — this WP
added no new `HealthLoomTests` file, since its two required "Tests:" lines are both
package-level pure-logic tests already covered in `Packages/SyncKit`).

**Deviations / judgment calls (handoff protocol's "blocked?" clause):** (1) chose
file-backed JSON over a second SwiftData model for the ring buffer (justified above);
(2) `AppEnvironment.swift` received a second minimal DI-wiring edit beyond this WP's
literal "your scope" bullet list (which named only the two new folders + the one
`SettingsView.swift` nav edit) — justified above as the necessary, precedented production
wiring point for the `SyncEngine.swift` hook the same bullet list's surrounding prose
explicitly anticipates; (3) `BackfillCoordinator` chunk completions are **not** recorded,
reported rather than implemented, since doing so would require editing the explicitly
fenced-off `Backfill/` folder with no available external hook — flagged as a gap for
whichever future WP owns that folder; (4) added `SyncLogTextExporterTests` beyond the two
literally-required "Tests:" lines, since the export deliverable is real, pure, and
otherwise unverified. **Deliberately deferred:** a "clear log" UI action (the `SyncLogStore.clear()`
primitive exists, kept for symmetry/testability, but no button calls it — not asked for);
distinguishing "manual Sync Now" vs. "background sync" vs. "backfill" as a `source` field
on `SyncLogEntry` (the `SyncEngine.sync(type:)` hook point structurally can't tell what
triggered a run, and adding a trigger-source parameter to `SyncEngine.sync(type:)` itself
would be a larger, non-additive change than this WP's scope allows — every recorded entry
is simply "a completed incremental sync run for this type," which matches the plan's own
"timestamps, types, counts, error strings" wording without needing a trigger label).

**Phase P1 rollup.** *[Correction, appended by the WP-12b session below: this rollup
originally claimed "WP-12/12b's exercise/conflict-resolution pipeline" was complete. That
was wrong -- WP-12b had never been implemented at the time this was written (no
`WatchCoverageIndex`, no `ConflictResolver`, no Activities view existed in the tree, and
`SyncEngine.processPage`'s `.workout` arm still silently skipped every mapped workout,
exactly as WP-12's own entry above flagged as "required follow-up"). P1 was therefore
complete for single-device users only; workouts did not import at all. WP-12b's own entry
below is where that gap actually closes.]* With WP-18 complete, all of WP-11 through
WP-18's stated "Done when" criteria (except WP-12b's -- see the correction above) are met
and independently re-verified together in this session: WP-11's full
TypeMapper table and WP-12's exercise mapping, WP-13's nutrition
correlations, and WP-14's LocalSample/badge routing all still pass their own golden/property
suites inside this session's 228-test SyncKit run; WP-15's chunked backfill and WP-16's
background sync both still pass their own suites and their own app-target build/test
evidence stands unchanged (this WP touched neither's source, only re-verified they still
build/pass alongside the new Diagnostics code); WP-17's settings/incremental-scope screen
now also hosts this WP's Sync Log entry point, verified via the same `xcodebuild test` run.
One caveat carried forward from every prior P1 WP's own notes, not introduced here: the
real Google Cloud OAuth client (P-1.3) remains outstanding, so no WP in this phase has
been exercised against a real Google account end-to-end — every "Done when" that depends
on that (WP-11's real-payload confirmations, WP-15/16/17's real-consent flows) is verified
against fixtures/stubs only, a pre-existing, explicitly-tracked gap, not a new one. With
that caveat, Phase P1 ("full sync") is functionally complete and ready for Phase P2.

## WP-R1 · iOS 27 / Xcode 27 beta / Swift 6.4 retarget (post-WWDC26 platform review)

Reviewed the WWDC 2026 releases (iOS 27, Xcode 27 beta, Swift 6.4) and retargeted the
project and all planning docs at them, with the AI-capability review driving the largest
changes. **What changed and why:** (1) architecture.md D9 rewritten — iOS 27's Foundation
Models framework now ships a public `LanguageModel` protocol that any provider can back
(`SystemLanguageModel`, the new `PrivateCloudComputeLanguageModel`, Anthropic's official
`ClaudeForFoundationModels` package, Gemini via Firebase), which deletes the planned
custom `CoachProvider` protocol, REST clients, and `SSEParser` from the design before any
of them were built (CoachKit is still the WP-01 placeholder — nothing to migrate);
(2) new D14 (model ladder: on-device → free Apple PCC server model [32K context,
reasoning, per-user daily quota, Small Business Program + entitlement] → BYO-key
Claude/Gemini) and D15 (mid-chat tier switching on Dynamic Profiles); (3) P3 of the
implementation plan rebuilt around catalog/consent/orchestration glue instead of model
clients — WP-28's OpenAI sub-item deferred pending an official `LanguageModel`
conformance; new WP-31 adopts Apple's Evaluations framework for the test-plan §9 eval
sets, new WP-32 is the Dynamic Profiles tier switcher, new optional WP-39 covers iOS 27
App Intents (entity/intent schemas, View Annotations, App Intents Testing framework);
(4) P-1 gains a second launch long pole: the PCC entitlement application; (5) smaller
weaves: iOS 27 HealthKit heart-rate-zone read into WP-19/D6, SwiftData `HistoryObserver`
as WP-19's refresh trigger, SwiftUI reorderable-content for WP-33, Swift 6.4's
`withTaskCancellationShield`/async-`defer` in the concurrency model and WP-15/16, new §6
edge rows (PCC quota, watchOS 27 rebuilt HR engine baseline shift, Health-app nutrition
camera double-logging). **Toolchain reality check (deliberate deviation):** deployment
targets bumped to iOS 27.0 (project.yml + all five package manifests), but manifests
deliberately stay at `swift-tools-version: 6.2` and packages keep `.macOS("26.0")`
because GitHub's macos-26 runner image ships no Xcode 27 beta yet
(actions/runner-images#14196) — this keeps all five `swift test` CI jobs green (they
build for the macOS host), while the app-scheme job now detects Xcode 27 on the runner
and skips with a `::warning` until the image ships it. Un-guarding CI and bumping
manifests to 6.4 is tracked in WP-38's new toolchain-finalization checklist item.
**Deliberately deferred:** any code adoption of iOS-27-only APIs (nothing in the shipped
P0/P1 pipeline needs them; CoachKit will consume Foundation Models iOS 27 surface
directly in P2/P3); multimodal image input for the coach (architecture §7.5, v1 stays
text-only). **Surprise worth recording:** Apple's own AI health coach (Project Mulberry)
slipped past WWDC 26 — the market positioning for a user-controlled, multi-tier coach on
consolidated dual-device data is stronger than when the architecture was first written.

## WP-12b · Watch-priority conflict resolution + Activities view

Implemented architecture.md D13 end-to-end -- the P1 work package the previous rollup
incorrectly reported as done (see the correction stamped into WP-18's "Phase P1 rollup"
above). **SyncKit, new `Sources/SyncKit/Conflict/` folder (4 files):**
`WatchCoverage.swift` -- pure, HealthKit-free `WatchCoverageWindow` (unpadded watch-workout
spans + `workoutUUID`), `WatchConflictPolicy` (the D13 tuning constants: ±5 min padding,
≥50 % of shorter duration, 10 min start+end tolerance -- architecture.md §7.3's
beta-tunable table), `StreamSlice`/`StreamResolution` (keep/suppress/split), and
`WatchCoverageIndex`, which owns both pure classification rules: `matchingWorkout(
forSessionStart:end:)` (D13.2, against unpadded bounds, earliest match wins for
back-to-back workouts) and `resolveStream(start:end:cumulative:)` (D13.3, against padded
spans merged where padding makes neighbors touch, so back-to-back workouts behave as one
covered span; cumulative types split at edges, instantaneous drop whole, zero-duration
instants boundary-inclusive). `WatchPriorityPreference.swift` -- the D13.5 preference seam
(`AlwaysOn` + `UserDefaults` conformers; key shared with the app's Settings toggle;
absent-key-means-ON so the default is ON without a registration step).
`WatchCoverageProvider.swift` -- `WorkoutSourceClassifier` protocol seam (D13.1's
injectable source detection; production `ProductTypeWorkoutSourceClassifier` matches
`sourceRevision.productType` "Watch*" or `HKDevice.model` containing "Watch" -- per-device,
any recording app) + `HealthKitWatchCoverageProvider` (one `HKSampleQuery` over
`workoutType()` per call, skipping this app's own external-ID-stamped imports).
`WatchConflictResolver.swift` -- the real `ConflictFiltering` conformer, its own actor,
owning the per-run coverage cache, D13.4 retroactive cleanup, deferred-session links, and
the suppressed count. **Seam changes (all additive/non-breaking):** `ConflictFiltering`
gained three requirements with no-op default implementations (`beginRun(type:windowStart:
windowEnd:)`, `drainDeferredSessionLinks()`, `drainSuppressedCount()`) so
`IdentityConflictFilter` and every pre-existing test conformer compile unchanged;
`SyncOutcome` gained `suppressedCount: Int` (defaulted 0); `SyncLogEntry` gained
`suppressedCount: Int?` (optional so pre-existing `SyncLog.json` files still decode);
`HealthStoreProtocol`/`HealthKitStore`/`HealthKitWriter` gained `appWrittenSampleRecords
(ofType:start:end:)` returning the new HealthKit-free `AppWrittenSampleRecord` (external
ID + interval -- cleanup needs the interval, which `existingExternalIDs` deliberately
doesn't return); `MockHealthStore` implements it against its in-memory list.
`MappedObject` gained `case quantities([HKQuantitySample])` -- the carrier for one point
split into pro-rated part samples; **only the resolver ever produces it** (`TypeMapper
.map` never does), and all samples share the point's external-ID metadata, the exact
one-point-many-samples precedent `.category`'s sleep segments set, so D4's existence diff
and delete-by-external-ID treat the parts as one unit. Exhaustive-switch arms added in
`SyncEngine.processPage`, `BackfillCoordinator.processPage`, and `SyncEngineTests
.SuppressingConflictFilter` (same one-arm shape as WP-12/13's own additions).
**Pipeline wiring (`SyncEngine.swift` + `BackfillCoordinator.swift`, deliberately
identical in both):** (1) `try await conflictFilter.beginRun(...)` at the top of each
run/chunk, *before* the existence query, so cleanup deletions are reflected in the
existence snapshot and the same run's re-pull re-resolves the affected points; (2) the
`.workout` arm is now real -- `guard !knownExternalIDs.contains(point.id)` then
`writer.saveWorkout(workout)` then insert into the known set (same dedupe set as every
other arm; only the write path differs, unavoidably, since `HKWorkoutBuilder
.finishWorkout()` saves directly to the store) -- **closing the "every Google Exercise
session is mapped then silently dropped" hole** WP-12 flagged; (3) `.quantities` batches
like `.category`; (4) after the pages, deferred-session links are drained and applied to
`LocalSample.linkedWatchWorkoutUUID` (fetch-by-externalID sees same-context pending
inserts; done on the failure path too, harmlessly, since the window re-pulls next run);
(5) `SyncEngine`'s outcomes carry `suppressedCount` on both paths (drains double as
state reset). **Resolver semantics worth recording:** the session rule uses *unpadded*
workout bounds, the stream rule *padded* ones (a session sitting entirely inside the
padding defers nothing -- pinned by test); suppressed counting is one per point --
fully-suppressed stream sample, split (partially deferred) sample, and deferred session
each count once; `beginRun` early-returns for every type except the four covered stream
types (heartRate/steps/distance/activeEnergyBurned) + `.exercise`, so watch-priority
costs one workout query per *relevant* type per run, not per type of a 26-type
`syncAll`. **Error posture, deliberately asymmetric (judgment call):** coverage/cleanup
*reads* that fail degrade to identity-for-this-run instead of failing the sync --
critical because onboarding's very first sync runs before HK read authorization exists,
and D13.4's next-run retroactive cleanup makes this self-correcting -- while cleanup
*deletes* that fail propagate and fail the run (a known-but-unremovable conflict must
not stand silently; cursor untouched, safely retried). **Isolation changes:** the
`Mapped*` stored-property structs (`MappedMetadata`/`MappedQuantitySample`/
`MappedCategorySample`/`MappedWorkout`/`MappedNutritionCorrelation`) and the
quantity-wrapping extension methods (`makeHKMetadataDictionary`/`makeHKUnit`/
`makeHKQuantitySample`) are now explicitly `nonisolated` -- the exact `GoogleDataPoint`/
`DataSource` precedent from WP-05, required because the resolver (its own actor, not
MainActor) reads `MappedWorkout.start/.end` and rebuilds pro-rated
`MappedQuantitySample`s synchronously. **App target:** `AppEnvironment` installs one
`WatchConflictResolver` per pipeline (shared coverage provider; separate instances
because drain state is per-run and the two pipelines can overlap -- documented in the
resolver's header) with each pipeline's own writer; Settings gained the "Prefer Apple
Watch during workouts" toggle (new `WatchPriorityPreferences` observable over the shared
SyncKit key; footer copy documents D13.5's forward-only OFF); onboarding's HealthKit
screen now also requests *read* for `[.exercise, .heartRate]` with updated copy
(WP-12b step 1); and the new `HealthLoomApp/Activities/` folder (4 files) implements the
consolidated Activities view -- `ActivitiesModels.swift` (HealthKit-free
`WorkoutSummary`/`FitbitActivitySupplement`/`ActivityEntry` + `ActivityConsolidator`,
one entry per activity, watch primary with the linked Fitbit session's
distance/energy/source inline, Fitbit-only workouts as full entries, sessions linked to
an unreadable workout surfaced standalone rather than vanishing),
`ActivitiesProvider.swift` (the one HK-touching piece; returns `[]` on any read failure
so the screen degrades to Fitbit-only), `ActivitiesView.swift`/`ActivityRow.swift`
(day-grouped list; `@Query` for LocalSample + `.task`/`.refreshable` for workouts),
reachable via a new Dashboard nav-link section; `seedDashboardFixtures` seeds one
deferred exercise session for the UI test. Sync log surfaces render the new count
("N deferred to Apple Watch" -- `SyncLogRow` + `SyncLogTextExporter`, test-plan.md
§2.3's bookkeeping line). **Tests written (test-plan.md §2.3 coverage):**
`Tests/SyncKitTests/Conflict/WatchCoverageIndexTests.swift` (19 tests -- the full
overlap-classifier truth table incl. 49 %/51 %/exact-50 % boundaries, both-ends vs
one-end tolerance, back-to-back windows, long-session-containing-short-workout,
padding-is-stream-only, reversed windows; suppress/keep/split/instantaneous-drop stream
cases at padded edges incl. merged back-to-back spans and zero-duration instants; and
the composition property test over 200 seeded pseudo-random window/sample sets -- kept
slices never intersect padded coverage, never overlap each other, never escape the
sample interval); `WatchConflictResolverTests.swift` (11 tests, resolver installed in a
real `SyncEngine` with `MockGoogleReconcileClient`/`MockHealthStore`/
`MockWorkoutBuilderFactory`/`TestSyncClock` and injected windows -- session deferral
with the LocalSample link; Fitbit-only workout import + second-run dedupe; HR
suppression; steps pass-through outside coverage; split pro-rating asserted to the
exact slice bounds and 550-of-600 value through the whole pipeline; instantaneous
straddle dropped; weight-inside-coverage untouched; retroactive cleanup of samples
(delete call + re-pull suppression + third-run idempotency) and of an imported workout
(reversed-order dual-wear variant, sweep covers workout+distance+energy types, session
re-defers with link); toggle-OFF identity incl. zero coverage reads; coverage-read-
failure degradation; suppressed count landing in the `SyncLogEntry` and the text
export); app-target `ActivityConsolidatorTests.swift` (6) + `WatchPriorityPreferencesTests
.swift` (3, throwaway suites, cross-checked against the SyncKit reader); and
`HealthLoomUITests/ActivitiesUITests.swift` (the required consolidated-entry UI test,
via the seeded session and the documented unlinked-session fallback, since the
simulator's HK store can't hold a watch workout). **VERIFICATION -- IMPORTANT, READ
BEFORE TRUSTING THIS ENTRY:** this session ran in a Linux remote container with **no
Swift toolchain and no Xcode** -- unlike every prior WP entry, *nothing here has been
compiled or test-executed*. Every API this code calls was read from the actual sources
in this repo (signatures, isolation annotations, init parameter orders, test-double
shapes), the strict-concurrency patterns follow the repo's own post-Xcode-27-beta
conformance-isolation fixes (PR #5), and the deprecated-HKWorkout-fixture call sites
carry the same `@available(*, deprecated, ...)` annotations WorkoutSavingTests
established for `-warnings-as-errors` -- but the authoritative gate is `make test` on a
Mac with the Xcode 27 beta (the repo's own pre-commit gate), which **must be run before
this branch merges** and can be expected to surface mechanical fixups (isolation
annotations are the likeliest category). **Deliberately deferred:** GPS-route badge on
Activities rows (needs `HKWorkoutRoute` reads -- not requested in onboarding's read
set); surfacing per-chunk suppressed counts for backfill (drained and discarded --
`BackfillTypeStatus` tracks cursor progress only); marking supplement fields beyond
distance/energy/source (AZM lives in its own `LocalSample` rows via WP-14, not joined
to activities yet); `DashboardView.syncNow` still syncs only the P0 four types (so
`.exercise` flows through background sync and backfill, not the manual button --
pre-existing WP-10/17 scoping, not changed here); and the real dual-wear device
verification (test-plan.md §7's manual scripts), which remains gated on P-1.3's
Google OAuth client like every other real-account check in this log.

## WP-33 · Today view — Yacht club design

Ported the locked Yacht club design (`Design/HealthLoomTodayView-YachtClub.swift` +
`Design/healthloom-final-yachtclub.html`, architecture.md D12) into the app target as a
new `HealthLoomApp/Today/` folder (8 files), started per the plan's own "can start
visual work right after WP-10" clause -- WP-23 (ReadinessEngine) has not landed, so the
readiness/coach bindings ship as the explicit pending states this WP's step 4 mandates
anyway, never invented numbers. **Theme (`Theme.swift`):** the four Figma palette values
and their derived roles ported token-for-token, with both D12-mandated deviations
implemented: (a) Dynamic Type -- `Theme.font(_:_:relativeTo:)` wraps
`Font.custom("Helvetica Neue", size:relativeTo:)` so every mockup size scales anchored
to a semantically-matched text style; (b) a derived dark palette (canvas -> warm
near-black #201D1A, ink -> light teal #A8CBD8 ~9.5:1, rust accent kept as a hue but
lightened to #C98A63 ~5.7:1 since the original #733E24 sits near 2:1 on near-black),
every token a UIColor dynamic-provider pair; hand-computed contrast figures are
documented in the file header and flagged for WP-37's real audit.
**TickScale (`TickScale.swift`):** mockup geometry verbatim (28 ticks, rust-below /
gray-above / ink cursor), plus caller-supplied VoiceOver label/value ("Readiness, 82 of
100" -- test-plan.md §6), input clamping, and a `nil`-value pending form (all-gray, no
cursor) for the pre-readiness hero. **Data bindings (step 1):** sync-status header <-
`@Query SyncState` (newest `lastSyncedAt`; device label from the newest
`LocalSample.source`) through the pure `TodaySyncStatus` model with all three states --
fresh (rust dot, "Fitbit Air · synced 9m ago"), stale >24 h (gray dot, "last synced 2d
ago"), never-synced; metric rows <- HealthKit today-values via `TodayMetricsProvider`
(cumulative sums since midnight for steps/distance/active energy -- source-merged, so
D13.3's watch+Fitbit composition is honest -- latest-sample for HR/SpO2/weight,
last-night asleep-stage sum for sleep; any per-kind read failure degrades to that row's
"No data yet" state); readiness hero <- `ReadinessDisplay.pending` (the `.scored(score:
delta:signalsUsed:)` case, including the "based on N of 4 signals" caption, is already
plumbed so WP-23 binds without reshaping the view); coach panel <- placeholder copy
(same rust-tint panel, no chevron) until WP-23/34 produce a `DailyInsight`.
**Edit mode (step 2):** order + visibility live in `TodayMetricPreferences`
(UserDefaults; one stored array of visible kinds in display order so order/visibility
can't drift apart; absent key = the mockup's default four; unknown raw values dropped
on load), edited via a themed sheet -- reorder through `List`/`.onMove` under an active
`EditMode` (system drag handles), explicit minus/plus buttons for remove/add
(deterministic for the UI test, single obvious VoiceOver affordance). The full metric
list is the 7 kinds with a meaningful HealthKit "today" reading (heart, steps, sleep,
blood oxygen, weight, distance, active energy); LocalSample-only types stay on the Data
tab. **App shell:** new `HomeView` hosts the mockup's tab-bar component; `RootView`
routes onboarded users to it (Today first), and the pre-existing `-UITestSeedData`
route lands on the Data tab so every `DashboardUITests` assertion still finds
`dashboard.syncNow` immediately -- zero churn there; `OnboardingUITests` gained exactly
one tap (the Data tab) after onboarding completes. Onboarding's HealthKit read request
(WP-12b's `requestRead`) widened to the Today metric kinds, same single sheet, same
invisible-denial posture. **Deviations, all documented in code:** (1) the plan's
"iOS 27 reorderable-content API" could not be verified in this environment (no SDK) --
the sheet + `List`/`.onMove` path satisfies "no custom Edit-mode drag plumbing" and
binds the same preferences store; swapping to in-place reorderable-content once
buildable on the Mac is a contained view-only change; (2) the mockup's tab set
(today/coach/you/settings) ships as Today/Data/Activities/Settings until P2/P3 build
Coach and You -- dead tabs would be worse, and the swap is a two-line change in
`HomeView`; (3) the mockup's "Good morning, Sam" renders without a name (none is
collected anywhere); (4) steps goal is a constant 10,000 (`TodayMetricFormatter
.defaultStepGoal`) pending a real goal setting. **Tests:**
`HealthLoomTests/TodayMetricsTests.swift` (16 tests across three suites) -- the WP's
required reorder-persistence unit test (move persists across instances), hide/show
persistence, no-duplicate add, unknown-raw-value decode, absent-vs-empty key
distinction; formatter goldens (grouped counts under an injected en_US locale,
"7h 12m" durations, SpO2 fraction->percent, steps goal percent + capped progress bar,
empty-row accessibility text); sync-status states incl. the exact 24 h boundary and the
terse relative ages, plus greeting hours. `HealthLoomUITests/TodayUITests.swift` -- the
WP's required edit-mode UI test: seeded launch -> Today tab -> asserts header/hero/
coach/default rows -> add Weight, remove Sleep via the editor -> panel reflects both ->
relaunch (without the new `-UITestResetTodayMetrics` flag, which the first launch uses
to stay idempotent across runs) -> persisted order verified. **Deliberately deferred:**
snapshot tests (test-plan.md §4 -- light/dark x Dynamic Type XS/XL) require adding the
swift-snapshot-testing package, which this environment cannot resolve or build; flagged
as the first Mac-side follow-up for this WP, alongside re-running the WP-37 contrast
audit on the derived dark palette; readiness/coach real bindings (WP-23/34); a real
step-goal setting; metric-row add/remove *of LocalSample-only types* (they have no
"today" reading to render). **VERIFICATION -- same caveat as WP-12b's entry, read
before trusting:** authored in a Linux remote container with no Swift toolchain or
Xcode -- nothing compiled or test-executed here. All API use mirrors patterns already
proven in this repo (`@Query`, `@Observable`+`@State`, dynamic UIColor, HK statistics/
sample queries bridged via continuations identical to `HealthKitStore`'s), but
`make test` on a Mac with the Xcode 27 beta remains the authoritative gate and must run
before merge; likeliest fixups are isolation annotations and any SwiftUI API
availability drift.

## Verification note — WP-12b / WP-33 confirmed on real Xcode 27 beta toolchain (2026-08-27)

Both entries above (WP-12b, WP-33) were authored in a Linux remote container with no
Swift toolchain and explicitly flagged themselves as unverified, pending `make test` on
a Mac with the Xcode 27 beta. That gate has now been run, on a Mac with
`/Applications/Xcode-beta.app` at Xcode 27.0 (build 27A5218g): all five package suites
pass under `-warnings-as-errors` (CoreModel 15, Secrets 14 [1 environment-gated
real-Keychain test self-skips under the sandboxed `swift test` process, as already
documented in WP-03's entry], GoogleHealthClient 35, SyncKit 260, CoachKit 1), and
`xcodebuild build test` on an iOS 27.0 simulator passes with zero failures (5 UI tests,
1 self-skipped — `OnboardingUITests`' HealthKit-sheet test, per the toolchain note above).
No mechanical fixups were needed; the isolation annotations and API usage both entries
carried over from prior sessions' precedents compiled as written. This closes the
verification gap flagged in both entries' headers — nothing else about their content
changes.

`README.md` was also updated in this pass: it had drifted since WP-12b/WP-33 merged
(still listed watch-priority conflict resolution as unbuilt, WP-12b as a remaining
phase item, and stale test counts) — corrected to match the current tree and this
session's real counts.

## WP-19 · KnowledgeStore

Implemented architecture.md D7's `KnowledgeStore` -- the first real content in `CoachKit`
(the WP-01 placeholder file/test are deleted; nothing outside CoachKit referenced them).
**New `Packages/CoachKit/Sources/CoachKit/Knowledge/` folder (5 files):**
`HealthReadTypes.swift` -- HealthKit-free `Sendable` value types (`DailyQuantityValue`,
`QuantityReading`, `SleepStageKind`/`SleepStageSegment`, `WorkoutRecord`), every one marked
`nonisolated` per WP-12b's exact precedent (SyncKit's `MappedMetadata` et al.) since
CoachKit's package-wide `.defaultIsolation(MainActor.self)` would otherwise make their
initializers MainActor-isolated and uncallable from the nonisolated HealthKit-query
completion closures that construct them -- caught by `-warnings-as-errors`, not guessed.
`HealthReadStore.swift` -- the `HealthReadStore` protocol (steps/resting-HR/HRV/sleep/
workouts reads over a date window) + `HealthKitReadStore`, the real `#if canImport(HealthKit)`
adapter (`HKStatisticsCollectionQuery` for daily steps/resting-HR/HRV, `HKSampleQuery` for
sleep-analysis segments and workouts, `HKWorkout.allStatistics` for energy/distance --
deliberately not the deprecated `totalEnergyBurned`/`totalDistance` properties). `KnowledgeDerivation.swift`
-- every pure derivation function (steps daily avg, resting-HR/HRV baseline+trend with a
documented ±5% "steady" band, sleep duration + stage-split with a night-bucketing rule
tested across a DST-adjacent midnight boundary, workouts, and one generic `.localOnly`-type
handler covering all four of AZM/Active Minutes/ECG/IRN). `LocalSamplePayloadDecoding.swift`
-- `ExerciseSupplement` (mirrors `ActivitiesModels.FitbitActivitySupplement`'s exact,
already-proven `JSONSerialization` decode contract for `LocalSample.payloadJSON`'s
`sessionPayload` field verbatim, rather than inventing a second one) and `sumPayloadValues`
(sums every numeric value in the payload's top-level `values` dict -- a deliberate
judgment call, documented inline: no fixture exists for `active_zone_minutes` to pin its
exact key name, and AZM is a single-field interval type per base-knowledge.md §3/§5, so
summing is equivalent to reading that one field regardless of its name). `KnowledgeStore.swift`
-- the orchestrator: `refresh(now:)` fetches all five HealthKit windows concurrently
(`async let`), fetches every `LocalSample`, derives one `ProfileField` per signal that has
data (never a placeholder "no data" field), and persists to the single `KnowledgeProfile`
row. `KnowledgeRefreshTrigger.swift` -- `KnowledgeRefreshThrottle.shouldFire` (the pure,
always-compiled "at most hourly" rule) plus `KnowledgeRefreshTrigger` (the real
`HistoryObserver`-wired class, `#if compiler(>=6.4)`-gated -- see toolchain note below).

**Design decisions beyond the plan's literal text, all judgment calls:**
(1) **Read-authorization stays inside CoachKit, no app-target change.** The plan's step 1
says "Request HK read authorization here... via WP-06's `requestRead`"; WP-14's own
`ClinicalClassification.swift` header separately instructs this WP to call
`isClinicalType` rather than re-deriving it. Both together settle a real ambiguity this
WP would otherwise have had to stop and ask about: architecture.md §2's module-map
ordering (`CoreModel, Secrets, GoogleHealthClient, SyncKit, CoachKit` -- "each depends
only on packages above it") permits CoachKit to depend on SyncKit, so `CoachKit`'s
manifest now does (added to both the `CoachKit` and `CoachKitTests` targets), and
`KnowledgeStore.requestReadAuthorization()` calls SyncKit's real `HealthKitAuth
.requestRead(_:)` directly -- no onboarding/app-target UI change, since this WP's own
"Touches" line names only `CoachKit`. The method exists and is called by nothing yet;
flagged as a real gap for whichever future WP first gives the coach an app-target
surface (WP-25's Chat UI is the next candidate) to wire up, with its own copy. This
degrades safely in the meantime because HealthKit read-denial is invisible regardless
(HealthKitAuth.swift's documented rule) -- un-requested and denied authorization both
just mean fewer signals, never a crash or a broken intermediate state.
(2) **Heart-rate zone configuration -- omitted, real deviation.** Step 1 also names "the
user's heart-rate zone configuration (new iOS 27 HealthKit zones API)." Searched the
actual iOS 27.0 SDK headers (`HealthKit.framework/Headers`, Xcode 27.0 build 27A5218g)
for "zone": the only hit is `HKLiveWorkoutZoneUpdate`, a live in-workout zone-*crossing*
event, not a readable configuration object. No such API exists to call. Omitted entirely
rather than guessed, per the plan's own "Blocked?" clause; flagged here for whoever
revisits architecture.md D6's zones mention once/if Apple ships the real API.
(3) **Correction pinning implemented via the existing `ProfileField.source` field, no
CoreModel change.** WP-19 step 2 requires "pinned user corrections... beat re-derivation,"
but the actual correction-writing UI is WP-30's (P3, not yet built). Rather than add a new
stored flag to `ProfileField` (CoreModel, out of this WP's declared scope) or invent a
UI, this WP defines `KnowledgeStore.correctionSourceLabel = "User correction"`: any field
in the persisted profile carrying that exact `source` string survives `refresh()`
untouched, including for keys this cycle didn't derive anything for (e.g. a future goal
field with no HealthKit counterpart). The mechanism is real and tested end-to-end now;
WP-30 only needs to write fields with that `source` value, nothing more.
(4) **D13.6's "never describing both copies of one activity"** is implemented as: every
`HKWorkout` counts once; a linked `.exercise`-type `LocalSample` (WP-12b's deferred-session
supplement) contributes nothing extra when its `linkedWatchWorkoutUUID` matches a counted
workout, but *does* count as an additional activity when unlinked or linked to a workout
outside the current window (mirrors D13.2's "surfaces standalone rather than vanishing" at
the Activities view, in prose form here) -- pinned by three dedicated tests including the
outside-window case, which is easy to get wrong (naively re-checking link presence alone
would silently drop a real activity whenever its watch workout ages out of the read
window before the Fitbit supplement does).
(5) **Sleep gets duration + stage-split only, no efficiency field.** Architecture D6 (a
different WP's concern, ReadinessEngine/WP-23) mentions "sleep duration/efficiency," but
WP-19's own step 1 text says only "sleep duration/stage split" -- efficiency needs
`inBed`/`awake` category segments this WP deliberately doesn't fetch (matching
`TodayMetricsProvider`'s WP-33 precedent of asleep-stages-only), so no efficiency number
is invented here; WP-23 owns that if/when it needs `inBed` reads.
(6) **Toolchain split, verified against both real SDKs, not assumed:** `HistoryObserver`
does not exist at all in Xcode 26.4.1's SwiftData module (grepped its macOS
`.swiftinterface` -- zero matches; it is new in the iOS/macOS 27 SDK). CI's `packages`
job deliberately pins CoachKit's `swift test` to Xcode 26.4.1 (this file's own "Toolchain
note"), so referencing `HistoryObserver` unconditionally would have broken that job.
`KnowledgeRefreshTrigger` (the `HistoryObserver`-wired class) is gated `#if compiler(>=6.4)`
-- Xcode 26.4.1 ships Swift 6.3.1, Xcode 27 beta ships Swift 6.4, so this exactly (if a
little coincidentally) tracks SDK availability today; the pure throttle rule
(`KnowledgeRefreshThrottle.shouldFire`) lives outside the guard so it compiles and is
tested identically on both toolchains. Also hit and fixed along the way: even under
Xcode 27 beta, `HistoryObserver` initially failed with "only available in macOS 27 or
newer" because this package's *deployment target* stays at macOS 26.0 on purpose (same
toolchain note) even though the SDK itself is 27.0 -- fixed with an explicit
`@available(macOS 27, iOS 27, *)` on the class, exactly as the compiler's own fix-it
suggested.
**Tests (39, up from CoachKit's 1-test placeholder):** `KnowledgeDerivationTests.swift`
(avg/trend math incl. steady/higher/lower bands, empty input, single-day input, sleep
night-bucketing across a midnight boundary, the three workout/supplement merge cases
above, clinical-vs-non-clinical `.localOnly` field shape incl. asserting the clinical
path never leaks an aggregated value); `LocalSamplePayloadDecodingTests.swift` (full
decode, missing `sessionPayload`, garbage `payloadJSON`, `sumPayloadValues` against
missing/empty payloads); `KnowledgeRefreshTriggerTests.swift` (the pure throttle's four
boundary cases); `KnowledgeStoreTests.swift` (end-to-end `refresh()` against an in-memory
`ModelContainer` + a scripted `MockHealthReadStore` -- persistence round-trip via a
second, fresh `ModelContext`; staleness/`asOf` propagation across two refresh cycles;
correction pinning wins, both for a re-derived key and an untouched one; clinical default-
exclusion through the full persisted profile; all four tool-facing summaries, including
their "no data" sentences). **VERIFIED, not just written:** this session had the actual
Xcode 27 beta *and* Xcode 26.4.1 both installed -- ran `swift build`/`swift test -Xswiftc
-warnings-as-errors` for CoachKit under both toolchains directly (catching the
`nonisolated`, access-control, and `HistoryObserver`-availability issues above for real,
before they could reach CI), then ran the repo's full `make test` end to end: all five
package suites (CoreModel 15, Secrets 14, GoogleHealthClient 35, SyncKit 260, CoachKit 39),
the app target's `HealthLoomTests` (43), and `xcodebuild build test` on an iOS 27.0
simulator (5 UI tests, 1 self-skipped per the existing toolchain note) all pass, zero
warnings, zero failures. **Deliberately deferred (later WPs' explicit scope):**
`ContextAssembler` (WP-20, reads the persisted `KnowledgeProfile` this WP produces);
wiring `KnowledgeRefreshTrigger`/`requestReadAuthorization()` into the app's DI/onboarding
(no app-target WP claims this yet -- flagged above); user goals as profile fields (WP-19's
step 2 mentions them, but no settings UI or owning WP exists for entering one, so none is
invented); a real payload schema for `LocalSample.payloadJSON` (still none exists anywhere
in the codebase; this WP adds a third independent decoder against the same undocumented
wire shape rather than a fourth wrong guess -- consolidating into one shared, public type
is flagged as a good, but out-of-scope, follow-up for whoever next touches this).

## Code review fixes — WP-19 Knowledge module (code-review-findings.md, 2026-08-28)

Addressed all 15 findings from the 2026-08-28 code review of `Packages/CoachKit/Sources/CoachKit/Knowledge/`
(9-parallel-angle review + direct verification against a local toolchain). 14 fixed; one
(#8) investigated, a real fix attempted and rejected because it does not compile, and
documented as an accepted, bounded limitation instead of a false "fixed."

**`KnowledgeStore.swift`:**
- **#1 (`Dictionary(uniqueKeysWithValues:)` traps on a duplicate correction key):** switched
  to `Dictionary(_:uniquingKeysWith:)` keeping the first occurrence -- degrades
  deterministically instead of crashing if two correction-sourced fields ever share a key.
- **#2 (`try? context.save()` swallows failures):** `refresh(now:)` is now `async throws`;
  `performRefresh` calls `try context.save()` and lets the error propagate. No caller existed
  yet to update besides this WP's own tests (nothing wires `refresh()` into app/UI code yet).
- **#3 (no reentrancy guard -- a slow earlier call could save after and overwrite a faster
  later one):** added a FIFO async lock (`isRefreshing`/`refreshWaiters`, `CheckedContinuation`-
  based) around `performRefresh` -- overlapping calls now execute strictly in call order, never
  interleaved. **Could not** implement this as `Task<KnowledgeProfile, Error>` chaining (the
  obvious approach): confirmed by direct compilation that `KnowledgeProfile` (a `@Model`
  reference type) has its `Sendable` conformance explicitly marked unavailable by SwiftData,
  so it can never be a `Task`'s/`async let`'s result type. The lock pattern sidesteps this
  entirely (nothing Sendable-constrained crosses a task boundary). Verified with a real timing
  test (`KnowledgeStoreReentrancyTests`, `MockHealthReadStore.nextDailyStepsDelayNanoseconds`)
  that reproduces the exact regression shape and confirms the fix under real `Task` scheduling,
  not just code inspection.
- **#4 (unlinked-workout count ignored the 30-day window) / #10 (`refresh()` fetched every
  `LocalSample` row ever stored, unbounded):** one fix covers both -- the `LocalSample` fetch
  is now bounded by a `#Predicate` to `min(workoutsStart, localOnlyStart)` (the widest window
  any derivation actually needs), so `cachedExerciseSupplements` can no longer contain a
  sample older than `workoutsWindowDays` in the first place. `ExerciseSupplement` gained a
  `start: Date` field (see LocalSamplePayloadDecoding.swift below) so `workoutsSummary(days:)`
  can also re-slice it directly instead of a secondary lookup back into `cachedLocalSamples`
  by `externalID` (that lookup is gone now, a simplification alongside the fix).
- **#5 (tool-facing summaries windowed against wall-clock `.now` instead of `refresh()`'s
  `now`):** added `referenceNow`, set to `now` at the top of each `performRefresh`; every
  summary method's window/`asOf` now reads `referenceNow`, never `.now`.

**`HealthReadStore.swift`:**
- **#6 (workout distance only ever read from `distanceWalkingRunning`):** added the other
  eight activity-specific distance `HKQuantityTypeIdentifier`s (cycling, swimming, wheelchair,
  downhill/cross-country skiing, paddle sports, rowing, skating) and take whichever one is
  actually present in `workout.allStatistics` -- verified every identifier exists in the real
  iOS 27.0 SDK headers before using it, not assumed.
- **#7 (`HKQuery.predicateForSamples` default options match on any overlap, diverging from
  `MockHealthReadStore`'s start-date-only filter and from both methods' own "for [start, end]"
  doc comments):** added `.strictStartDate` to `sleepStageSegments`'s and `workouts`'s
  predicates so production semantics match the documented contract and the mock exactly.
- **#15 (`HealthKitReadStore` implicitly MainActor-isolated, serializing every `async let` in
  `KnowledgeStore.refresh()` through MainActor before its first suspension point):** marked
  `nonisolated`, same precedent as `HealthReadTypes.swift`'s value types.

**`KnowledgeDerivation.swift`:**
- **#9 (`localOnlyField`'s window had no upper bound -- a future-dated sample, e.g. from
  device clock skew, would count forever):** added `$0.start <= asOf` alongside the existing
  lower bound.
- **#11 (unlinked exercise sessions hardcoded the literal word "Fitbit" in coach-facing
  text):** now names the actual `ExerciseSupplement.source`; when every unlinked supplement
  shares one source it's named, a genuinely mixed set falls back to "other" rather than
  asserting any one of them.
- **#12 (`localOnlyField`'s device-label pick, `matching.first?.source`, was nondeterministic
  over SwiftData's unordered fetch):** now picks the most-recent sample's source
  (`matching.max(by: start)`), a pure function of the input set regardless of array order.
- **#13 (independently-rounded sleep-stage percentages could sum to 99% or 101%):**
  implemented the largest-remainder method (`largestRemainderRounding`) -- floors every
  percentage, then distributes the shortfall to the largest fractional remainders first,
  guaranteeing the displayed breakdown always sums to exactly 100.

**`LocalSamplePayloadDecoding.swift` / new `CoreModel/ExercisePayloadDecoding.swift`:**
- **#14 (the exercise-payload JSON decoder was hand-duplicated, byte-for-byte, between
  `ExerciseSupplement` here and the app target's `ActivitiesModels.FitbitActivitySupplement`):**
  extracted the shared decode logic to `LocalSample.decodedExercisePayload` (new
  `ExercisePayloadFields` struct) in CoreModel -- the common ancestor package both CoachKit and
  the app target already depend on. Both `ExerciseSupplement.init(sample:)` and
  `FitbitActivitySupplement.init(sample:)` now call this one implementation. Hit and fixed
  the same MainActor-default-isolation issue as #15 along the way: `@Model`-generated types
  are themselves `nonisolated` (to support SwiftData's background contexts), so
  `LocalSample.decodedExercisePayload`'s isolation is inferred from `LocalSample`, not from
  CoreModel's package-wide MainActor default -- `ExercisePayloadFields` needed an explicit
  `nonisolated` to be constructible from that context (confirmed by direct compilation, same
  category of issue WP-19's own entry already hit once for `HealthReadTypes.swift`). Added
  `ExercisePayloadDecodingTests.swift` (CoreModel) pinning the shared contract directly.
- `ExerciseSupplement` also gained `start: Date` and `source: String` fields (see #4/#11
  above) via its `init(sample:)`.

**`KnowledgeRefreshTrigger.swift` -- #8 (a change landing between `onChange` firing and the
deferred `observeChanges()` re-registration completing is silently missed), investigated, not
"fixed":** the seemingly obvious fix -- re-register tracking synchronously inside `onChange`,
before the `Task`/MainActor hop, so the gap shrinks to near-zero -- **does not compile**:
verified by direct compilation that `onChange`'s closure runs in a nonisolated context
(`withObservationTracking` is a plain nonisolated global function), so calling this class's
MainActor-isolated `observeChanges()` from it is a hard compiler error, not a style choice.
Closing the gap for real would need a different mechanism entirely (e.g. an AsyncSequence-
based observation bridge), which is out of proportion to a WP-19 follow-up fix. Left as
Apple's own documented recursive-registration idiom (matches the WWDC/Observation-framework
sample verbatim) with its same known, narrow limitation, now spelled out in the code comment
instead of silently present: the window is one MainActor hop wide, and a missed write is a
deferred refresh, not lost data -- it self-corrects the moment any other write lands.

**Tests:** 7 new/expanded test cases across `KnowledgeDerivationTests.swift` (duplicate-key
degradation is exercised at the store level; sleep-percentage-sums-to-100, future-dated-
sample exclusion, deterministic source label, actual-vs-generic unlinked-source label),
`KnowledgeStoreTests.swift` (duplicate correction keys don't trap, old unlinked exercise
sample excluded from the bounded fetch, a genuine timing-based reentrancy regression test),
and `CoreModelTests/ExercisePayloadDecodingTests.swift` (3, pinning the newly-shared decoder).
CoachKit: 39 → 46 tests. CoreModel: 15 → 18 tests.

**VERIFIED, not just written (same standard as WP-19's own entry):** every fix was compiled
and test-driven on this session's real Xcode 27 beta *and* Xcode 26.4.1 toolchains directly
(catching the `Sendable`/`Task` and `nonisolated`-inference issues above for real, before they
could reach CI), then the repo's full `make test` was run end to end: all package suites
(CoreModel 18, Secrets 14, GoogleHealthClient 35, SyncKit 260, CoachKit 46), the app target's
`HealthLoomTests` (43, including `ActivityConsolidatorTests` against the now-shared decoder),
and `xcodebuild build test` on an iOS 27.0 simulator all pass, zero warnings, zero failures.

## Code review fixes, round 2 — WP-19 Knowledge module (2026-09-01)

A second review pass (5-parallel-angle review + direct verification against a local toolchain)
over the same `Packages/CoachKit/Sources/CoachKit/Knowledge/` module the 2026-08-28 round
covered, once more with fresh eyes now that the module has settled. 17 findings; 14 fixed, 3
deliberately left as documented, out-of-proportion cleanups rather than false "fixed"s.

**`KnowledgeStore.swift`:**
- **`fetchOrCreateProfile`'s `try? context.fetch(...)` swallowed a real fetch error the same
  as "no profile exists yet":** now `throws` and propagates, matching `refresh()`'s own
  already-documented "propagate `ModelContext.save()`'s error, don't swallow it" posture (round
  1's #2) instead of contradicting it one call away. A genuine fetch failure could otherwise
  insert a second `KnowledgeProfile` row, breaking the store's documented single-row invariant.
- **The bounded `LocalSample` fetch (round 1's #4/#10) had a lower bound only, no upper
  bound:** added `&& $0.start <= now` to the `#Predicate`, matching `localOnlyField`'s own
  `asOf` bound (round 1's #9) a layer downstream -- a future-dated sample (device clock skew)
  no longer ages into the cache forever. Its `try? ... ?? []` was swallowing real fetch errors
  too, the same bug as `fetchOrCreateProfile` above and with a worse consequence: since
  `profile.sections` is rebuilt from scratch every cycle, a transient failure silently erased
  every previously-persisted local-only/clinical field instead of leaving it stale. Now
  propagates via `throws` as well.
- **`untouchedCorrections` re-filtered `profile.sections` directly, with no dedup of its
  own** (unlike the `corrections` dictionary a few lines above it, which already dedups via
  `Dictionary(_:uniquingKeysWith:)` for round 1's #1): two correction-sourced fields sharing a
  key this cycle never derives anything for (e.g. a user goal) would both survive into
  `profile.sections`, forever. Now built from `corrections.values` -- the already-deduped set --
  instead of re-scanning the raw array.
- **The tool-facing summaries (`stepsSummary`/`sleepSummary`/`workoutsSummary`) read
  `cachedSteps`/`cachedSleepSegments`/`cachedWorkouts`/`referenceNow` directly with no
  coordination with the round 1 `acquireRefreshLock()`/`releaseRefreshLock()` pair, which only
  guards `performRefresh` itself:** a concurrent summary call mid-`performRefresh` could observe
  a cache straddling two different refresh generations (one array already updated to the new
  cycle, another still from the old one). Fixed by committing every cached array + `referenceNow`
  together with zero `await` between the assignments, instead of assigning each as its own
  `async let` resolves -- Swift's cooperative scheduling guarantees no other MainActor task can
  interleave between two statements with no suspension point between them, so the commit is
  effectively atomic from a reader's perspective.
- **Same three summary methods also didn't clamp the caller's requested `days`/`nights`
  against the fixed window `refresh()` actually cached** (`stepsWindowDays`/`sleepWindowNights`/
  `workoutsWindowDays`): a request wider than the cache was a no-op over the real data yet still
  rendered a wider-sounding label (e.g. `stepsSummary(days: 90)` claiming "(90-day avg)" backed
  by ≤30 days of real data). Now clamped before both the slice and the displayed label.

**`KnowledgeDerivation.swift`:**
- **`localOnlyField`'s device-label tie-break (round 1's #12, `matching.max(by: { $0.start <
  $1.start } })`) wasn't actually order-independent on a tie:** the surrounding comment claimed
  determinism "independent of array order," but Swift's `max(by:)` breaks a genuine tie by
  traversal order, not a rule that ignores it. Paired `externalID` in as a secondary key
  (`@Attribute(.unique)` on `LocalSample`, so it can never itself tie) -- the comparator is now a
  true strict ordering with no remaining ties, genuinely order-independent rather than usually so.
- **`Int(total.rounded())` in the non-clinical branch had no bounds check:** `sumPayloadValues`
  is deliberately unbounded by design (its own doc comment: sums every numeric value present,
  "would only overcount, never throw") -- but the `Int` conversion downstream traps once that sum
  exceeds `Int`'s range, contradicting the same "never throw" contract one layer up. Clamped to
  `0...1_000_000_000` before rounding/converting.
- **`duration(seconds:)` had no clamp for negative input:** a `SleepStageSegment` with `end <
  start` (clock-skewed/malformed HealthKit data) produced a negative `totalMinutes`, and Swift's
  truncating `/`/`%` on a negative dividend yielded misleading text (e.g. a -25 hour skew
  rendering as "0m" -- silently hiding the error rather than flagging it). Clamped to `0`.

**`HealthReadStore.swift`:**
- **`distance(for:)` (round 1's #6) assumed a workout populates at most one activity-specific
  distance type and returned the first match:** true for single-sport workouts, false for a
  multisport one (e.g. a triathlon `HKWorkout`, which populates `distanceSwimming`,
  `distanceCycling`, and `distanceWalkingRunning` simultaneously) -- silently dropping every leg
  but the first. Now sums whichever of the nine distance types are actually present.
- **`dailyCollection` (backing `dailySteps`/`dailyRestingHeartRate`/`dailyHeartRateVariability`)
  never got round 1's #7 `.strictStartDate` fix**, applied at the time only to
  `sleepStageSegments`/`workouts` -- the identical any-overlap-vs-start-date-only divergence from
  `MockHealthReadStore`'s semantics was left live here. Added.
- **`dailyCollection` anchors its statistics buckets at `start`'s calendar-day midnight, but
  `quantitySamplePredicate` only counts samples from the exact (non-midnight) `start` instant
  onward:** the oldest bucket in every window is therefore a genuinely partial day, yet
  `stepsField`/`vitalsField` downstream average every returned day equally -- systematically
  biasing the reported "~N/day" average low on essentially every refresh, not just as a rare edge
  case. Dropped that leading partial bucket (`guard statistics.startDate >= start else { return
  }`) rather than let it masquerade as a full one.

**`ExercisePayloadDecoding.swift` (CoreModel) / three app-target views:**
- **The snake_case→Title Case transform round 1's #14 shared as `LocalSample
  .decodedExercisePayload` was itself a fourth independent copy of an algorithm already
  hand-duplicated three more times** (`SettingsView.displayName(_:)`, `SyncLogRow.displayName`,
  `BackfillTypeRow.displayName`'s `default:` case -- the last of which even comments that it's
  copying the first two "the same way"). This diff's own stated purpose (round 1's #14) was
  eliminating exactly this kind of duplication, one level up; it had reintroduced it one level
  down. Added `GoogleDataType.displayName`/`.titleCased(_:)` (mirroring the existing
  `.filterName`/`.endpointName` pattern on the same enum) as the one shared implementation; all
  four call sites -- the three app-target views plus `ExercisePayloadDecoding.swift` itself --
  now call it. `titleCased(_:)` needed an explicit `nonisolated` for the same reason round 1's
  #14 entry already hit once for `ExercisePayloadFields`: it's called from
  `decodedExercisePayload`'s own `nonisolated` context (inferred from `LocalSample`), not from
  CoreModel's package-wide MainActor default.

**`MockHealthReadStore.swift` (CoachKitTests):**
- **Missing `nonisolated`, unlike the production `HealthKitReadStore` (round 1's #15, marked
  `nonisolated` for exactly this reason):** CoachKitTests carries the same package-wide
  `.defaultIsolation(MainActor.self)` as CoachKit itself, so the mock's methods were implicitly
  MainActor-isolated under test. That mismatch meant the `async let` reads in
  `KnowledgeStore.performRefresh()` never actually ran concurrently off-MainActor under test the
  way they do in production -- a regression that accidentally removed `nonisolated` from
  `HealthKitReadStore` (silently reintroducing round 1's #15) would go uncaught by every test
  here. Added.

**Investigated, left as documented, accepted gaps rather than false "fixed"s:**
- **`HealthKitReadStore.displayName(for:)` (HK-only, coach-facing text) duplicates
  `ActivitiesProvider.activityName(_:)` (app-target, Activities-view text) over the same ~13
  `HKWorkoutActivityType` cases, with different label choices for several ("Running" vs. "Run",
  "Cycling" vs. "Ride")**: not merged. The two differences look deliberate, not accidental --
  one surface is a natural-language coach sentence, the other a compact list-row label -- and
  collapsing them into one shared table means either picking one register for both surfaces (a
  product call, not a code-review call) or introducing new plumbing neither module currently has
  (`HealthReadStore.swift` and `ActivitiesProvider.swift` don't import SyncKit's canonical
  `MappedWorkoutActivityType`, and reverse-mapping the real `HKWorkoutActivityType` back onto it
  safely is itself close to the ~80-case fragile-switch problem `MappedWorkoutActivityType` was
  introduced to avoid). Flagged here for whoever next touches either label list.
- **The bounded `LocalSample` fetch (`KnowledgeStore.performRefresh`) is inlined directly via
  `ModelContext`/`FetchDescriptor` instead of going through a protocol seam the way every
  HealthKit read does (`HealthReadStore`)**: left as is. Introducing a second protocol seam
  purely to make one call site swappable is a real architectural improvement but a bigger one
  than this fix-pass's scope -- no second `LocalSample` consumer exists yet to motivate it, and
  `KnowledgeStoreTests` already exercises this path directly against a real in-memory
  `ModelContainer`.
- **`KnowledgeStore.calendar` and `HealthKitReadStore.calendar` are independently injectable
  (both default to `.current`) with nothing enforcing they agree**: left as is -- both default
  identically today, so this is a latent risk (a future caller wiring the two with different
  calendars would see silently disagreeing day boundaries), not a live bug, and there's no
  actionable fix short of a larger composition-root redesign forcing one shared `Calendar`
  through both.

**Tests:** 6 new test cases -- `KnowledgeDerivationTests.swift` (a genuine `start`-tie resolved
deterministically via `externalID`, an extreme payload value that no longer traps `Int(...)`,
negative-seconds clamping to `"0m"`, positive-seconds regression coverage for the same function),
`KnowledgeStoreTests.swift` (duplicate untouched-correction keys collapse to one instead of both
surviving, all three tool-facing summaries clamp their label to the actual cached window).
CoachKit: 46 → 52 tests.

**VERIFIED, not just written:** every fix was compiled and test-driven against this session's
real Xcode 27 beta toolchain (`DEVELOPER_DIR` pointed at `/Applications/Xcode-beta.app`, matching
`Makefile`'s `test` target exactly), package tests run with `-warnings-as-errors` for CoreModel/
SyncKit/CoachKit, then the full `xcodebuild build test` against an iOS 27.0 simulator (app build +
`HealthLoomTests` + `HealthLoomUITests`) -- all pass, zero warnings, zero failures.

## WP-20 · ContextAssembler

Built `Packages/CoachKit/Sources/CoachKit/Knowledge/ContextAssembler.swift` per the
plan: `@MainActor final class ContextAssembler` reading the persisted
`KnowledgeProfile` only (never HealthKit/`LocalSample` directly, architecture.md §2).
`assemble(for: .chat|.dailyInsight)` drops every `excludedFromAI` field (the single
exclusion rule -- clinical default-out falls out of `ProfileField`'s init mapping nil
to `isClinical`, so opted-in clinical fields pass with no second rule to drift),
trims to a token budget via the chars/4 heuristic in priority order vitals > sleep >
activity (steps + activity prefixes) > history/everything-else (unknown keys degrade
to last), and persists every assembled `HealthContext` as a `ContextSnapshot`
(same-`now` `createdAt`) returning its ID for `ChatTurn.contextSnapshotID` (WP-30/32
trace join). Pure/impure split mirrors WP-19: static `selectFields(from:tokenBudget:)`
+ `estimatedTokens(for:)` + `priorityRank(for:)` are SwiftData-free; only `assemble`
touches `ModelContext`. Overflow is reported (`estimatedTokens` + `didTrim`), never
acted on -- escalation offers are WP-27's call (D14.2). Guarantees at least the top
field when anything is eligible (a zero-field context from a non-empty profile would
be useless); missing profile assembles an empty-but-snapshotted context. Working
budgets: on-device 4K, PCC 32K, cloud 100K (WP-27 replaces with per-model queries).
One compiler fix during build: `Self` in a default-argument expression
(`tokenBudget: Int = Self.onDeviceTokenBudget`) is rejected -- used the explicit
`ContextAssembler.onDeviceTokenBudget`.

**Tests:** `ContextAssemblerTests.swift`, 9 tests -- excluded-field substring assert
over the serialized snapshot JSON, clinical default-out + explicit opt-in, trimming
order (seeded lowest-priority-first, budget fits exactly vitals+sleep), fitting
budget keeps all in rank order, zero budget keeps top-1 with overflow reported,
snapshot JSON decodes back to the exact struct + `ChatTurn` link resolves, missing
profile snapshots empty, locale/unit flow (US default imperial, explicit override).
CoachKit: 52 → 61 tests.

**VERIFIED, not just written:** `swift test -Xswiftc -warnings-as-errors` in
`Packages/CoachKit` on this session's Xcode 26.4.1 toolchain -- 61 tests in 16
suites pass, zero warnings, zero failures. (Full `make test` + `xcodebuild build
test` not re-run: no other package or the app target was touched.)

## Code review fixes — WP-20 ContextAssembler (round 1)

Six findings over `ContextAssembler.swift`, all fixed and test-driven; two
touched neighboring files where the finding demanded a shared source of truth.

1. **Trim loop could drop a higher-priority field (#1, correctness):** the old
   skip-and-continue scan kept a smaller lower-priority field while dropping a
   larger higher-priority one, and the keep-one fallback never triggered because
   `kept` was already non-empty. `selectFields` is now strict-prefix: the scan
   `break`s at the first non-fitting field, so nothing ever jumps the queue.
   Same rewrite fixes the sibling edge (single eligible field alone over budget
   reported `didTrim == false`): `AssembledContext.didTrim` is now
   `trimmed-anything || (non-empty && total > budget)`.
2. **Estimate omitted serialized framing (#2, correctness):**
   `estimatedTokens(for:)` now measures the actual `JSONEncoder` byte size / 4
   (rounded up) instead of `key+displayText+source` chars, so `asOf`/flags/JSON
   punctuation count; new `estimatedShellTokens(localeIdentifier:unitSystem:today:)`
   covers the per-context `localeIdentifier`/`unitSystem`/`today` framing, and
   `assemble` reserves the shell before selecting fields. Reported total = shell
   + fields (off by two `[]`-vs-`[...]` bytes -- noted in code, conservative).
3. **Per-field ceiling sum vs batched formula (#3, correctness):** eliminated by
   construction -- every fit check calls the batched `estimatedTokens(for:)` over
   the whole candidate set; no per-field summation remains anywhere.
4. **Duplicated single-row fetch (#4, reuse):** new internal
   `KnowledgeStore.fetchProfile(from:)` (newest-`updatedAt`-first, `fetchLimit`
   1 -- a no-op while the invariant holds, deterministic freshest-row choice if
   violated); `fetchOrCreateProfile` and `assemble` both resolve through it. A
   schema-level unique constraint would enforce rather than resolve the invariant
   but needs a synthetic key + migration -- documented, deferred.
5. **No coordination with in-flight `refresh()` (#5, plausible):** accepted and
   documented in `assemble`'s doc comment (graceful-degradation posture; the
   snapshot records what was actually sent, `asOf`-bounded; sharing the refresh
   lock would couple turn latency to HealthKit latency; revisit if WP-30 needs a
   "refresh was running" signal). No behavior change.
6. **Rank prefixes duplicated derivation literals (#6, reuse):** `KnowledgeDerivation`
   gained `steps/vitals/sleep/activity/clinicalKeyPrefix` constants; all six full
   keys and both `localOnly` constructions compose from them, and `priorityRank`
   matches on them -- a rename now breaks compilation, not trimming.

**Tests:** 5 new (`topFieldNeverJumped`, `loneOverBudgetReportsTrim`,
`singleFormula`, `rankTracksDerivationKeys`, `shellAccounted`); 2 updated to the
new accounting (`trimmingOrder` now passes explicit `now`/`locale` with an exact
shell+fields budget and asserts the exact total; `emptyProfileSnapshotsEmpty`
asserts the total equals the reserved shell). CoachKit: 61 → 66 tests.

**VERIFIED, not just written:** `swift test -Xswiftc -warnings-as-errors` in
`Packages/CoachKit` on this session's Xcode 26.4.1 toolchain -- 66 tests in 16
suites pass, zero warnings, zero failures. No other package or the app target
references the changed APIs (verified by grep).

## WP-21 · PromptManager + SafetyLayer

Built `Packages/CoachKit/Sources/CoachKit/Prompt/` per the plan:
`SafetyLayer.text` (immutable suffix -- non-medical disclaimer, no-diagnosis /
no-ECG-AFib-irregular-rhythm-interpretation with clinician redirect, scope
limits, disordered-eating help-seeking nudge) and `PromptManager` (compiled-in
`defaultPrompt`, pure `effectivePrompt(base:) = base + "\n\n" + suffix` with the
suffix unconditionally last even when the base already contains it,
`PromptVersion` history via append-only `save(base:)` / `resetToDefault()`,
`defaultBase()` / `currentBase()` / `defaultAndCurrent()` for the WP-26 editor).
`history()` returns value snapshots (`PromptVersionSnapshot`), never live
SwiftData objects -- every method builds its `ModelContext` locally, so
returning model rows would fault against a dead context in WP-26's version
list; history excludes seeded `isDefault` baselines, so "never customized"
reads empty. Token estimates count UTF-8 bytes/4, the same rule as WP-20's
context estimator (one canonical estimator, not two). Writes carry
monotonicized timestamps (1 ms bump on ties) plus a deterministic
(createdAt-desc, body-asc) read order, so same-instant save+reset can never
leave "current" ambiguous.

> **⚠️ HUMAN REVIEW REQUIRED (WP-21 step 1 deliverable):** `SafetyLayer.text`
> is unreviewed medical-disclaimer copy. A human must review the exact wording
> before launch -- scope limits, the ECG/AFib refusal rule, and the
> disordered-eating nudge are product/clinical decisions, not code-review
> calls. This flag stays open until that review happens.
>
> **✅ REVIEWED 2026-09-03 -- approved by Wojtek Powiertowski (repo owner)
> in review session, as written** (no edits; text byte-identical since).
> Recorded here as the sign-off of record: approver identity + date +
> exact-text review (full text was surfaced in-session). Any future edit to
> `SafetyLayer.text` re-opens this flag: re-review required before launch.

**Tests:** `PromptManagerTests.swift`, 12 tests -- suffix always present/last
(incl. adversarial base containing the suffix, empty/unicode/10K bases),
default non-empty, fresh fallback, save/reset history, seeded-default baseline
with empty history, same-instant ordering, UTF-8 byte counting (family emoji =
7 tokens, not 1), snapshot return values.

## WP-22 · Availability gate + session factory

Built `Packages/CoachKit/Sources/CoachKit/Session/` per the plan:
`AvailabilityGate.status(for:)` mapping every
`SystemLanguageModel.Availability` case to a `CoachAvailability` UI state with
user-facing copy + next-tier fallback suggestion (pure, injectable; `current()`
reads the live model); `CoachSession` protocol seam (`isResponding`,
`prewarm`, `respond`, `stream`) with a documented **incremental-delta**
contract (joining chunks reproduces the response); `LiveCoachSession` adapter
(`@Observable` so the chat UI's input-disabled binding re-renders, cumulative
framework snapshots diffed to deltas, consumer cancellation propagated to the
driving task so a dismissed turn can't wedge the reused session busy);
`CoachSessionFactory` with the lifecycle rule load-bearing in a single
`makeSession(for:instructions:tools:)` (conversation sessions cached per
instructions, one-shots always fresh, prompt edits bust the cache,
`resetConversation()` drops it) and an injectable builder so unit tests use a
scripted double and never touch the model. Deliberately concrete over
`SystemLanguageModel` -- no generic model-protocol API: that protocol exists
only in the iOS 27 / macOS 27 SDK while the package matrix builds on macOS 26,
where the symbol is absent and `@available` cannot gate it. WP-28 generalizes
when the floor allows. Real generation stays on on-device manual tests (test
plan §7).

**Tests:** `AvailabilityGateTests.swift`, 5 tests -- every availability case
maps, unavailable states carry copy + fallback, lifecycle predicate, and a
factory test with an injected scripted builder asserting identity semantics
(conversation reuses `===`, one-shots differ, edits bust the cache, reset
drops it) plus the scripted-stream seam check WP-25's UI test will rely on.

## Code review fixes — WP-21/22 (round 1)

Fifteen findings, all fixed and test-driven; the first was a build-breaker.

1. **Package didn't compile on the repo toolchain (#1, build-breaker):** the
   generic `<M: LanguageModel>` factory methods referenced a protocol absent
   from the macOS 26 SDK (`cannot find type 'LanguageModel' in scope` on
   Xcode 26.4.1; `@available` can't gate a missing declaration), and the same
   annotation wrongly claimed `watchOS 27` for a watchOS-unavailable
   framework. Deleted the generics entirely; the factory is concrete over
   `SystemLanguageModel` with a documented WP-28 generalization note.
   **Verified on both toolchains:** CoachKit builds and passes on Xcode 26.4.1
   (Swift 6.3.1, macOS 26 SDK) *and* Xcode 27 beta.
2. **Stream forwarded cumulative snapshots as deltas (#2, correctness):**
   `LiveCoachSession.stream` now diffs consecutive snapshot contents and
   yields only the new suffix (non-monotonic fallback yields full content,
   never drops text); the delta contract is documented on the protocol and
   the scripted double already speaks deltas, so WP-25 concatenates safely.
3. **Unstructured stream task never cancelled (#3, correctness):** the driving
   task is now held and `continuation.onTermination = { _ in task.cancel() }`
   set, with per-iteration `checkCancellation()` -- a dismissed turn can't
   leave `isResponding` true and poison the reused session with
   `concurrentRequests`.
4. **Wrapper not `@Observable` (#4, correctness):** `LiveCoachSession` is now
   `@Observable`, so the chat UI's `isResponding` binding re-renders.
5. **Trimmer discarded standalone user facts first (#5, correctness):**
   `ContextAssembler.orderingRank` lifts correction-sourced fields no
   derivation produces (standalone goals) ahead of rank 0; shadowing
   corrections keep their derived key's rank (the previously documented
   invariant, now actually true for both cases).
6. **Budget ignored the system prompt (#6, correctness):** `assemble` takes
   `promptTokens` (callers pass `PromptManager.estimatedTokens(for:
   effectivePrompt)`), reserved before shell + fields; the reported total
   covers prompt + request, feeding WP-27's escalation signal truthfully.
7. **`didTrim: false` for lone over-budget fields via the pure API (#7,
   correctness):** the over-budget check moved inside `selectFields`, so the
   container-free half WP-27 reads is correct on its own.
8. **Manager returned dead-context model objects (#8, correctness):**
   `history()`/`save()`/`resetToDefault()` return `PromptVersionSnapshot`
   values (id + body + createdAt + isDefault); the type system now makes the
   WP-26 use-after-fault impossible.
9. **Grapheme-cluster vs UTF-8-byte estimators disagreed (#9, correctness):**
   `PromptManager.estimatedTokens` counts `.utf8` bytes, same rule as WP-20.
10. **Equal-timestamp writes made "current" nondeterministic (#10,
    correctness):** writes monotonicize timestamps (1 ms bump on ties) and
    reads use a deterministic (createdAt-desc, body-asc) order.
11. **Unbounded snapshot persistence (#11, privacy/storage):** `assemble`
    prunes beyond `maxStoredSnapshots` (working constant 200, oldest-first
    with deterministic id tie-break, parameterizable); WP-30 owns real trace
    retention.
12. **Missing progress.md flag (#12, process):** this entry *is* the WP-21
    step-1 human-review flag (see the callout above); WP-21/WP-22 entries now
    exist like every prior WP.
13. **Factory test touched the model with vacuous asserts (#13, tests):** the
    lifecycle test now injects a scripted builder (zero model contact) and
    asserts identity semantics that can actually fail.
14. **Four factory methods, rule enforced nowhere (#14, design):** collapsed
    to one purpose-driven `makeSession` with a cached conversation session;
    `requiresFreshSession` remains as the unit-testable pure rule the method
    implements.
15. **Seeded defaults counted as user history (#15, correctness):**
    `history()` filters `isDefault`, so seeded baselines aren't "restore"
    entries and `history().isEmpty` means never-customized.

**Tests:** 10 new (`sameInstantWritesAreOrdered`, byte-counting, snapshot
return, load-bearing lifecycle identities, `correctionsRankFirst`,
`shadowingCorrectionKeepsRank`, `promptTokensReserve`,
`selectFieldsReportsLoneOverflow`, `snapshotPruning`, plus seam coverage);
CoachKit: 66 → 88 tests.

**VERIFIED, not just written:** `swift test -Xswiftc -warnings-as-errors` in
`Packages/CoachKit` on **both** toolchains -- Xcode 26.4.1 (this repo's
toolchain: 88 tests in 20 suites pass) and Xcode 27 beta (88 pass) -- zero
warnings, zero failures.

## Code review fixes — WP-21/22 (round 2)

Fifteen more findings over the WP-21/22 branch, all fixed and test-driven.

1. **Prune pass could delete the just-inserted snapshot (#1, correctness):**
   a past-dated `now` ranked the new row for eviction while its UUID was
   already returned. `assemble` now passes `exemptIDs: [snapshot.id]`, and the
   probe from the review (2033 seed + 2001 `now`, cap 1) keeps the returned ID
   resolvable. Found in passing: same-context fetches don't observe
   uncommitted inserts, so the insert is saved *before* pruning -- otherwise
   the keep window is computed over stale rows.
2. **Cap evicted `ChatTurn`-linked snapshots (#2, correctness):** prune now
   exempts every snapshot ID still referenced by a `ChatTurn`, so linked rows
   survive regardless of age (verified: oldest linked row outlives the cap
   while unlinked peers are deleted). Exemptions can transiently exceed the
   cap; steady state converges.
3. **Cache ignored `tools` (#3, correctness):** the conversation cache key is
   now `(instructions, toolNames)` -- a new tool busts the cache like a prompt
   edit does. Covered with a minimal stub `Tool` (name-only double).
4. **Grapheme-prefix diff duplicated emoji/combining-mark text (#4,
   correctness):** the rule now diffs over UTF-8 bytes (prefix-preserving like
   scalars, but via the certain `String(decoding:as: UTF8)` API after the
   scalar-slice conversion failed to compile) -- ZWJ extensions and combining
   marks yield only the new bytes.
5. **Seeded default could clobber a user edit (#5, correctness):**
   `currentBase()` prefers the newest *user* row and consults seeded defaults
   only when no customization exists; the seed moves the diff baseline, never
   the effective prompt. Covered by a regression test.
6. **`@unknown` mapped to download copy (#6, correctness):** new neutral
   `CoachAvailability.unavailable` case ("isn't available right now", no named
   cause); the unknown-reason branch maps there. A test asserts the copy never
   mentions downloading.
7. **Dropped `eligible` guard regressed empty-context `didTrim` (#7,
   correctness):** restored -- an empty context with an over-budget prompt
   reports `false` (remedy: shorten the prompt), while a genuine whole-request
   overflow with fields present still reports `true`. Covered.
8. **`save` accepted empty/unbounded bases (#8, correctness):** rejects
   blank bases (`.emptyBase`) and caps at `maxBaseCharacters` (10k,
   `.baseTooLong`) -- the single write path, so WP-26 inherits the guard.
9. **Delta rule untestable inline (#9, tests):** extracted as pure static
   `LiveCoachSession.delta(previous:snapshot:)` with 6 unit tests (prefix,
   identical, empty, ZWJ, combining mark, join reconstruction).
10. **Whole-table prune fetch (#10, perf):** eviction candidates come from a
    sorted fetch with `fetchOffset = keeping` (the `fetchProfile` idiom) plus
    one small `ChatTurn` link query -- no whole-table load on the hot path.
11. **Whole-table prompt reads (#11, perf):** `defaultBase`, `currentBase`,
    and the monotonicity probe use sorted `fetchLimit = 1` reads; only
    `history()` (whose job is the list) loads rows.
12. **Quadratic budget selection (#12, perf):** the accepted candidate's token
    count is cached per iteration and reused for the report -- no final
    re-encode, identical results.
13. **Duplicated doc abstract (#13, docs):** removed the second copy of
    `assemble`'s summary; one abstract with the `- Parameter` list.
14. **Misleading `now` parameter (#14, API):** dropped -- instance
    `effectivePrompt()` takes no arguments; time-bounded reads don't exist.
15. **No purpose on snapshots (#15, trace/retention):** `ContextSnapshot`
    gains a `purpose` column (`"chat"`/`"dailyInsight"`, default `"chat"` for
    pre-column rows); `assemble` threads its `Purpose` through instead of
    discarding it, so retention and the WP-30 trace can operate per producer.

**Tests:** 13 new (6 delta, past-dated self-eviction probe, linked-survival,
purpose recording, empty-context prompt overflow, user-wins-over-seed,
validation trio, tools-bust identity); CoachKit: 88 → 101 tests.

**VERIFIED, not just written:** `swift test -Xswiftc -warnings-as-errors` in
`Packages/CoachKit` on **both** toolchains (Xcode 26.4.1: 101 in 22 suites;
Xcode 27 beta: 101 in 22 suites), CoreModel 18 pass (schema-additive purpose
column, defaulted init keeps old call sites), zero warnings, zero failures.

## Code review fixes — WP-21/22 (round 3)

Fourteen findings, all fixed and test-driven.

1. **Migration hazard on the new column (#1, correctness):** `purpose` now
   carries a declaration-level default (`= "chat"`), which is what the
   `@Model` macro turns into the store schema default -- the `init`-only
   default it had does nothing for lightweight migration of on-disk stores
   (this repo has no migration plan). Documented inline so the next added
   column follows the same rule.
2. **Linked exemption removed the bound (#2, correctness/storage):** prune no
   longer exempts linked rows -- eviction past the window nulls the row's
   `ChatTurn` links first (nil renders "context expired", never a dangling
   ID), then deletes. The 200-row bound is real again, README's claim
   restored to accurate. `assemble` prunes pre-insert with `keeping - 1`,
   reserving the incoming row's slot.
3. **Whole chat-history load per turn (#3, perf):** the link pre-fetch is
   gone. Steady state costs one offset query and zero turn queries; each
   actually-evicted row costs one targeted nulling query
   (`contextSnapshotID == <id>`, UUID hoisted to a local because the
   predicate macro reads member access as a key path).
4. **Silent prompt-only overflow (#4, correctness):** `didTrim` signals any
   over-budget request again, and new `AssembledContext.promptOverBudget`
   (prompt + shell alone exceed budget) separates the remedies -- shorten
   the prompt vs escalate for dropped fields. The test that had enshrined
   the guarded behavior now asserts the loud one.
5. **Byte-based length cap (#5, correctness):** `maxBaseCharacters` is now
   `maxBaseBytes` (10k UTF-8 bytes ≈ ≤2.5k tokens for any script), validated
   with the same estimator the budget uses. A 10k-CJK base (30k bytes) is
   now rejected; covered.
6. **Hash-order corrections (#6, correctness):** `untouchedCorrections` are
   key-sorted before appending in `KnowledgeStore.refresh` -- hash order
   would otherwise make the surviving correction vary across launches now
   that those fields trim first. Covered.
7. **Continuation-byte delta (#7, correctness):** the shared prefix walks
   back past UTF-8 continuation bytes, so a mid-sequence revision can't emit
   U+FFFD. Covered (revision + shrink cases).
8. **Double commit (#8, correctness/perf):** single commit -- prune
   pre-insert (slot reserved arithmetically), then insert + save once. A
   prune failure can no longer leave a committed-but-unlinked snapshot, and
   turns pay one store round-trip.
9. **Duplicated prefix table (#9, reuse):** single `derivedKeyRanks`
   table consulted by both `priorityRank` and `hasDerivedKeyPrefix` -- drift
   impossible, existing rank tests unchanged.
10. **Trim-vs-store mismatch (#10, correctness):** `save` persists the
    trimmed base it validated (padding collapses to content). Covered.
11. **Unbounded history reads (#11, perf):** `history(limit: = 100)` uses the
    descriptor idiom; `ordered(_:)` retired with its last caller gone.
12. **Quadratic selection (#12, perf):** incremental byte accounting -- each
    field encoded once, candidate size derived arithmetically
    (brackets + fields + commas, byte-exact for JSONEncoder's deterministic
    formatting), report reused without a final re-encode. Existing exact-total
    tests (`trimmingOrder`, `shellAccounted`, `singleFormula`) prove
    equivalence with the batched formula.
13. **Tool-name cache collisions (#13, correctness):** `makeSession` takes an
    explicit caller-controlled `toolSetID` (nil falls back to joined names);
    same names + different IDs bust the cache. Covered with the stub tool.
14. **Inert `@Observable` (#14, docs):** removed, with a comment recording the
    true mechanism (the wrapped session is observable; the read happens
    during body evaluation) so no future edit trusts the old rationale.

**Tests:** 3 new (`multibyteRevisionBoundary`, `shrinkingYieldsEmpty`,
`untouchedCorrectionsAreKeySorted`) plus rewrites (`evictionNullsLinks`,
prompt-overflow assertions, trim-store/byte-cap validation, toolSetID
identities); CoachKit: 101 → 104.

**VERIFIED, not just written:** `swift test -Xswiftc -warnings-as-errors` in
`Packages/CoachKit` on **both** toolchains (Xcode 26.4.1 and Xcode 27 beta:
104 in 23 suites each), CoreModel 18 pass, full `make test` TEST SUCCEEDED,
zero warnings, zero failures.

## Code review fixes — WP-21/22 (round 4)

Thirteen findings reviewed; ten fixed, three deliberately not (below).

1. **A cap of 0 disabled pruning entirely (#1, correctness):** `assemble`
   passes `maxStoredSnapshots - 1`, so cap 0 reached `pruneSnapshots` as -1
   and hit its `guard keeping >= 0` early return -- making 0 the one value
   that retained *every* row instead of the fewest, inverting the constant's
   meaning. Now clamped (`max(keeping, 0)`): a negative window means "retain
   none of the pre-existing rows", and the in-flight row still survives so
   the returned `snapshotID` always resolves. Covered by
   `zeroCapPrunesEverythingButTheNewRow`.
2. **`history(limit:)` treated 0 as unbounded (#2, correctness):**
   `FetchDescriptor.fetchLimit` reads 0 (and negatives) as *no limit*, so
   "give me none" returned every stored body. Guarded to return `[]`.
   Covered by `nonPositiveHistoryLimitReturnsNothing`.
3. **`promptOverBudget` off by the boundary (#3, correctness):** `>` became
   `>=` -- at exact equality the field budget is already 0, so no selection
   can fit and the remedy is a shorter prompt, not escalation. Covered by
   `promptExactlyFillingBudgetIsOverBudget`.
4. **Monotonicity probe included seeded defaults (#4, correctness):** a
   future-dated shipped default stamped every later user edit past it,
   permanently dating WP-26's version list in the future. The probe is now
   scoped to the same non-default set whose ordering it protects (matching
   `currentBase()`). Covered by `seededDefaultDoesNotStampUserEdits`.
5. **Two copies of the budget formula (#5, correctness/docs):** round 3's
   incremental accounting hand-rolled JSONEncoder's array framing next to
   `estimatedTokens(for:)`'s own, and both doc comments still claimed a
   single shared formula. Extracted `encodedBytes(for:)` and
   `tokens(forFieldBytes:count:)`; `estimatedTokens(for:)` and
   `selectFields` now both go through them, so there is genuinely one
   formula and one place to update if the encoder's formatting ever changes.
   Keeps round 3's per-field-encoded-once performance. Existing exact-total
   tests still pass unchanged.
6. **Unbounded eviction fetch (#6, perf):** the offset descriptor gained
   `fetchLimit = maxSnapshotEvictionsPerAssembly` (64), so a transition case
   (pre-cap store, or a lowered cap) can't materialize thousands of
   health-context blobs on the turn path; the backlog drains over successive
   assemblies. Steady state is unchanged (one row).
7. **`delta` copied the response per snapshot (#7, perf):** walks the
   `utf8` views in place instead of materializing two `[UInt8]` arrays --
   the old form was O(response bytes x snapshot count) of MainActor churn.
   Behavior identical; all existing delta tests cover it.
8. **The streaming pump had no test (#8, test coverage):** extracted the
   plumbing as `deltaStream(snapshots:)`, generic over the snapshot
   sequence, so the loop, the error path and the empty case run without a
   `LanguageModelSession` -- both round-1 bugs lived here and were covered
   by nothing. New `DeltaStreamTests` suite (3 tests). Cancellation via
   `onTermination` is still only covered by inspection: every deterministic
   test for it needs timing assumptions, and a flaky CI test is worse than
   an honest note.
9. **`promptTokens` defaulted to 0 (#9, API):** the default made the reserve
   opt-in, so a caller that simply forgot it reproduced the overflow the
   parameter exists to prevent. Now required -- no production caller existed
   yet, and every test site states its intent explicitly.
10. **Hand-translated purposes (#11, reuse):** `CoachSessionFactory.Purpose`
    gained `init(_: ContextAssembler.Purpose)`, so the chat -> conversation /
    insight -> one-shot mapping lives in one place rather than at every
    future WP-23/WP-25 call site, where a missed mapping would leak chat
    history into an insight. The enums stay separate (different layers).
    Covered by `purposeMapping`.
11. **Cache-key namespace collision (#12, correctness):** `toolSetID ?? joined
    names` was one flat space, so an explicit ID spelling the same string as
    a tool name handed back the wrong session. The two forms are now
    prefixed (`id:` / `names:`). Covered by
    `toolSetIDIsNamespacedAgainstToolNames`.
12. **Stale README count (#13, docs):** CoachKit row 88 -> 113.

**Not fixed, deliberately:**

- **Snapshot retention still severs `ChatTurn` trace links (#10).** Round 3
  moved *from* exempting linked rows (which removed the storage bound
  entirely) *to* nulling their links on eviction; round 4 objects that this
  destroys the D7 trace for turns still on screen. Both are true: the two
  tables need a *joint* retention policy, which is a product decision about
  how long trace data lives, not a code fix. Flipping the behavior back and
  forth between review rounds is worse than leaving it stable and stating
  the tradeoff. Left for WP-30, which owns the trace UI.
- **`defaultUnitSystem` folds `.uk` into `.metric`.** Raised across three
  review passes. `Locale.MeasurementSystem` has three cases and the UK
  conventionally mixes units (miles, stone), so this may well be wrong --
  but the doc comment states the two-way rule as intended behavior, and
  changing what units a user's data is described in is a product call.
  Flagged for a decision rather than silently changed.
- **Priority is a key-prefix lookup, not a field property.** A future
  `nutrition.*` family would silently land in rank 3 until someone edits
  `ContextAssembler`. Real, but the fix is a schema change to `ProfileField`
  (a `priority`/`category` column minted by `KnowledgeDerivation`), which is
  a migration, not a review fix.

**Tests:** 9 new (`zeroCapPrunesEverythingButTheNewRow`,
`promptExactlyFillingBudgetIsOverBudget`, `nonPositiveHistoryLimitReturnsNothing`,
`seededDefaultDoesNotStampUserEdits`, `toolSetIDIsNamespacedAgainstToolNames`,
`purposeMapping`, plus the three `DeltaStreamTests`); CoachKit: 104 → 113.

**VERIFIED, not just written:** `swift test -Xswiftc -warnings-as-errors` in
`Packages/CoachKit` (113 in 24 suites, zero warnings), CoreModel 18 pass.

## WP-23 · ReadinessEngine + @Generable DailyInsight

Built `Packages/CoachKit/Sources/CoachKit/Readiness/` per the plan (depends on
WP-19/WP-22, no new dependencies): `ReadinessEngine`, a pure deterministic
scorer (D6 -- the Today hero's 0-100 comes from here, never the LLM), plus the
`DailyInsight` guided-generation shape, its prompt composer, and the generator
seam.

`ReadinessEngine.score(inputs:recentScores:)` takes numeric `ReadinessInputs`
(HRV ratio, resting-HR delta, sleep hours + efficiency fraction, 0-1
prior-day strain -- all optional) and returns `Readiness(score 0-100,
deltaVsAverage?, signalsUsed)`. One constant weight table (HRV .30, RHR .25,
sleep .30, strain .15); missing or invalid readings (non-finite, negative
ratios/hours, out-of-range fractions) count as missing and renormalize, with
`signalsUsed` rendering "based on N of 4 signals"; zero signals yields
neutral 50 with nil delta (callers gate the hero's pending state on
`signalsUsed`). Subscore maps are monotone in the healthy direction with
documented working constants, pinned by golden vectors (93 / 76 / 56). The
engine keeps no history -- `recentScores` is caller-supplied. Sourcing the
numeric inputs from HealthKit reads is later wiring (WP-33's hero); the
engine takes them as parameters so the formula stays store-free and
testable.

`DailyInsight` is the plan's exact `@Generable` shape (headline, suggestions,
`effortLevel` with `.anyOf(low/moderate/high)` + `effortLevels` source of
truth); `prompt(readiness:fields:)` composes the deterministic turn prompt
(readiness line + field display text, data only -- instructions ride the
session); `DailyInsightGenerator` wraps generation in an injectable closure
(tests script it) with a `live(session:)` path requiring a fresh one-shot
session. `LiveCoachSession` gained a `respond(to:generating:)` variant using
the iOS 26 / macOS 26 generics API, so it stays available on the package's
macOS 26 matrix. Real generation is on-device manual tests (test plan §7) +
the WP-31 eval set, never unit tests.

**Tests:** `ReadinessEngineTests.swift` (3 golden vectors incl. delta math,
renormalization to 76 on two signals, unknown-50, efficiency-alone-is-nothing,
HRV + RHR monotonicity grids, 0/100 clamps, delta rounding) and
`DailyInsightTests.swift` (prompt composition incl. empty-context line,
effort-level validity, injected generation incl. error propagation);
CoachKit: 113 → 127 tests.

**VERIFIED, not just written:** `swift test -Xswiftc -warnings-as-errors` in
`Packages/CoachKit` on **both** toolchains (Xcode 26.4.1 and Xcode 27 beta:
127 in 28 suites each) -- the `@Generable` macro and the generic
`respond(to:generating:)` both compile on the macOS 26 SDK -- zero warnings,
zero failures.

## Code review — WP-23 (round 1)

Eight findings (2 critical, 6 correctness) plus informational and
simplification notes, all addressed and test-driven.

**Critical:**

1. **Generator's live path uncallable (#1):** `respond(to:generating:)` is
   now a `CoachSession` protocol requirement (generic over `Content`, no
   `Self`/associated-type involvement -- stays callable through `any
   CoachSession`), implemented on the scripted double, and
   `DailyInsightGenerator` holds a session *source* so every `insight` call
   builds a fresh one-shot session -- the no-history-leak invariant is
   structural now, not a doc comment. Covered end to end: scripted factory →
   live generator → fixture insight, plus a build-count test proving two
   insights build two sessions.
2. **Safety-gate sign-off (#2):** the approval record now names the approver
   (repo owner, 2026-09-03 in-session review of the exact surfaced text,
   byte-identical since) instead of a bare "owner". Code comment updated to
   match. CI-skips-md / no-CODEOWNERS hardening (CODEOWNERS file for the
   Prompt dir) offered to the owner, not unilaterally imposed.

**Correctness:**

3. **Instruction in the "data-only" prompt (#3):** the imperative tail line
   is gone (the generation schema already injects the shape via
   `includeSchemaInPrompt`), field lines sit inside explicit DATA markers,
   and the doc comment no longer claims instruction-freedom it didn't have.
4. **NaN equality (#4):** custom `Equatable`/`Hashable` (NaN == NaN, hashes
   as nil) -- safe in sets and SwiftUI identity positions. Covered.
5. **History overflow trap (#5):** averaging accumulates in `Double` and the
   delta clamps back via `Int(exactly:)`, so corrupt histories degrade
   instead of trapping -- matching the engine's stated posture. Covered
   (Int.min histories both directions).
6. **Suggestion-count schema (#6):** `.count(2...3)` guide composed on the
   array property (verified compiling on the macOS 26 SDK) plus an
   `isValidSuggestionCount` check mirroring `effortLevels`. Covered.
7. **Zero-ratio doc gap (#7):** documented alongside negatives; boundary
   covered (ratio 0 → missing).
8. **Raw-array prompt parameter (#8):** `prompt` takes the filtered
   `HealthContext`, not `[ProfileField]` -- a raw `KnowledgeProfile.sections`
   array no longer compiles as an argument.

**Deliberate non-change:** the `@MainActor` on `prompt()` stays -- the
review's rationale against it is factually wrong (`ProfileField` members
*are* MainActor-bound via CoreModel's package-wide default isolation;
removing the annotation breaks the build, verified). The comment now records
the true mechanism instead.

**Informational (no code change):** `DerivedInsight` flattening stays a
WP-25/34 integration task; weight-sum float epsilon is inherent to any float
formula and pinned deterministically by golden vectors on both toolchains;
`hrvRatio` sourcing shares logic with `KnowledgeDerivation` only when WP-33
wires it (noted there, not duplicated now); `delta == 0` renders
"unchanged" (polished + tested); Today placeholders repointed to WP-25/33/34.

**Simplification (all applied):** shared `clamped` (uniform call shapes, no
more vestigial asymmetry); `valid(_:in:)` single validity pattern (HRV's
zero-exclusion stays inline, documented); local `average(of:)` (Knowledge
-derivation consolidation left as a follow-up -- minimal diff); 4-line
`accumulate` blocks collapsed; delta ternary → plain if/var; prompt paren
written once; `field()` fixture helper shared across test files instead of
reimplemented.

**Tests:** 19 new (3 golden vectors + delta/renormalization/unknown cases,
HRV + RHR monotonicity grids, clamps, NaN/overflow/zero boundaries, prompt
composition incl. zero-delta + markers, schema-guard checks, live-seam +
freshness + error generator tests); CoachKit: 113 → 132.

**VERIFIED, not just written:** `swift test -Xswiftc -warnings-as-errors` in
`Packages/CoachKit` on **both** toolchains (Xcode 26.4.1 and Xcode 27 beta:
132 in 29 suites each -- incl. the `@Guide(..., .count(2...3))` composition
on the macOS 26 SDK), zero warnings, zero failures.

## WP-24 · Coach tools

Built `Packages/CoachKit/Sources/CoachKit/Tools/` per the plan (depends on
WP-19/WP-22): four `Tool`s backed by the `KnowledgeStore` summaries --
`getSteps(days:)`, `getRecentSleep(nights:)`, `getWorkouts(days:)`,
`getVitals()` (no arguments) -- plus a `CoachTools.all(store:)` builder for
registration on session creation (WP-25 wires it into chat; one-shot insight
sessions stay tool-free).

Tool output is the stores' own user-visible summary text, untransformed
(live answers equal the summary call, pinned by test); numbers and prose
flow end to end from seeded HealthKit reads. Arguments clamp to 1...30 at
the tool layer (summaries clamp further to their cache windows); the vitals
tool's empty `@Generable` arguments struct compiles on both toolchains.

Exclusions are enforced by a gate, not by the summaries: the summary
methods re-derive from raw caches that know nothing of `excludedFromAI`, so
each tool checks `KnowledgeStore.isAnyExcludedFromAI(coveredKeys)` first
(new, small method on the store) and refuses with a settings sentence on
any match -- one excluded sleep/vitals subfield silences the whole topic
rather than leaking its substance. Covered: exact refusal text, excluded
numbers absent from output, unrelated exclusions passing through, gate
defaults (no profile / empty keys → false).

Isolation pattern (new for this package): the tool structs stay `@MainActor`
with the store captured in an injected `@MainActor @Sendable` answer
closure, while every `Tool` witness (`name`, `parameters`, `call`, clamps)
is explicitly `nonisolated` for the framework's executor contexts --
`Arguments` is a nonisolated `@Generable` struct for the same reason. Tests
inject scripted closures, never a store read they don't seed.

**Tests:** `CoachToolsTests.swift` (wiring incl. output-equals-summary and
data-flow phrases, clamp helpers + clamped-call equivalence, four exclusion
cases + gate defaults); CoachKit: 132 → 143 tests.

**VERIFIED, not just written:** `swift test -Xswiftc -warnings-as-errors` in
`Packages/CoachKit` on **both** toolchains (Xcode 26.4.1 and Xcode 27 beta:
143 in 32 suites each -- incl. empty `@Generable` arguments and the
nonisolated witnesses on the macOS 26 SDK), zero warnings, zero failures.

## Code review — WP-24 (round 1)

Thirteen findings (3 correctness, 1 structural flag, 6 reuse, 1 efficiency,
1 consistency note, plus ruled-out checks), all addressed and test-driven.

**Correctness:**

1. **Fail-open gate (#1, High):** the four `live()` closures no longer
   `try?`-swallow gate fetch errors into answering -- `answer` closures are
   now `async throws`, and both the gate and the shared helper propagate, so
   a fetch failure surfaces as a tool error instead of silently defaulting
   to "not excluded". Covered by an injected-throw propagation test.
2. **Sleep 1-30 promise vs 14-night cache (#2):** `GetRecentSleepTool`
   clamps to `KnowledgeStore.sleepWindowNights` (now internal, one
   compiler-tied constant) and its `@Guide` text says 1-14 -- the schema
   promises only what the store can deliver. Covered (500 ≡ 14).
3. **Fallbacks echoed unclamped windows (#3):** all three summary
   no-data sentences now render the clamped window actually examined.
   Existing in-window assertions unchanged.

**Structural flag (#4, no behavior change):** documented on
`isAnyExcludedFromAI` -- no write path sets these flags yet, and a naive
settings flip would be wiped by the next `refresh()` (only
correction-sourced fields survive); durable exclusion needs a WP-30 design
that accounts for that.

**Reuse:** one `Clamping.window(_:maximum:)` helper serves all six clamp
sites (tool `call()` bodies + the three summary methods -- the per-tool
`clampDays/clampNights` methods are gone, covered behaviorally); one
`KnowledgeStore.gatedAnswer(coveredKeys:excludedMessage:summary:)` collapses
the four `live()` bodies to one line each and fixes #1 in one place;
`call(arguments _:)` on vitals; `CoachTools.toolNames` deleted as an unused
third copy; `coveredKeys` lists carry update-both-together pointers against
future derivation-key drift (compiler-tied to the key constants, but list
membership itself can't be compiler-checked). Redundant `parameters` /
`includesSchemaInInstructions` overrides removed (defaults verified on both
SDKs); `name` stays explicit (model dispatch contract), `Output` /
`description` have no defaults and stay.

**Efficiency (#12):** the gate reads a per-refresh cached excluded-key set
(populated from the just-written profile, and on cold checks from the
fetched row) -- steady state costs zero store fetches; out-of-band
mutations (tests, future settings UI) call
`invalidateCachedExclusions()`, covered by a refresh-populated-cache test
(correction-sourced exclusion surviving refresh silences with no
invalidation call).

**Consistency (#13):** topic-level tool refusal vs per-field context
filtering asymmetry documented on `CoachTools` for WP-25's UI copy review.

**Tests:** 2 new (`errorsPropagate`, `refreshCacheSilences`) plus rewrites
(behavioral clamping incl. sleep-14, invalidation contract);
CoachKit: 143 → 145.

**VERIFIED, not just written:** `swift test -Xswiftc -warnings-as-errors` in
`Packages/CoachKit` on **both** toolchains (Xcode 26.4.1 and Xcode 27 beta:
145 in 32 suites each), zero warnings, zero failures.

## Code review — WP-24 (round 2)

Ten findings (2 correctness, 1 structural flag, 5 reuse, 2 trivial,
plus re-checked-clean notes), all addressed and test-driven.

**Correctness:**

1. **Cache populated before save (#14, High):** `cachedExcludedKeys` is now
   assigned only after `try context.save()` succeeds -- on throw the previous
   generation's set (matching the still-persisted row) stays put, so the gate
   can never report "not excluded" for a still-excluded row. Raw caches stay
   assigned pre-save deliberately: a failed save leaves summaries answering
   from an unpersisted generation (transient staleness, self-healing on the
   next refresh), not a privacy leak -- re-plumbing derivation reads around
   that would be disproportionate churn.
2. **Cold-path cache warming (#15):** the no-profile branch sets
   `cachedExcludedKeys = []` (safe: `refresh()` overwrites on first write),
   so pre-first-refresh turns cost one fetch ever, not one per call.
3. **Steps/workouts ceilings tied (#18):** `stepsWindowDays` /
   `workoutsWindowDays` dropped `private`; both tools clamp to them, so a
   narrowed window breaks compilation, not the schema promise.

**Structural flag (#16):** converted from convention to API -- new
`KnowledgeStore.setExcludedFromAI(_:forKey:)` persists the flag *and*
refreshes the cache together, so the gate and `ContextAssembler`'s live read
agree immediately. Tests use it instead of direct mutation; WP-30's settings
UI calls it instead of flipping rows. `invalidateCachedExclusions()` stays
as the escape hatch, documented.

**Reuse:** one `Clamping.window` helper (dropped from the tools' own clamp
methods, covered behaviorally); one `windowStart(daysBack:from:)` covering
all 8 date-arithmetic sites; one `joinedDisplayText` for the two joins; one
`excludedKeys`/`includedInAI()` definition on `[ProfileField]` serving the
store (×3 sites) and `ContextAssembler`; one shared `DaysArguments` for both
day-windowed tools; one `excludedMessage(forTopic:)` template (per-tool lets
kept as stable API). Removed the redundant `parameters` /
`includesSchemaInInstructions` overrides (SDK defaults verified on both
SDKs); `name` stays explicit as the model dispatch contract, `Output` /
`description` have no defaults. Deleted unused `toolNames`. Vitals
`call(arguments _:)`.

**Tests:** 3 new (`setExcludedRoundTrip` incl. both directions with no
invalidation call, `sharedArgumentsShape`, `refusalTemplate`);
CoachKit: 145 → 148.

**VERIFIED, not just written:** `swift test -Xswiftc -warnings-as-errors` in
`Packages/CoachKit` on **both** toolchains (Xcode 26.4.1 and Xcode 27 beta:
148 in 33 suites each), zero warnings, zero failures.

## WP-25: Chat UI

Coach tab (`HealthLoomApp/Coach/`): message list over persisted `ChatTurn`s,
token streaming into a draft bubble (incremental deltas per the WP-22
contract), input disabled while responding, `prewarm()` + best-effort
knowledge refresh on appear, stop button (cancels the stream; a visible
partial persists so the stored turn matches what the user saw), and
error/unavailable states from `AvailabilityGate`. Each assistant message
carries a "What did the coach see?" expander reading its linked
`ContextSnapshot` (field list; full UI in WP-30), cached per snapshot ID
(snapshots are immutable/prune-only, so the cache never invalidates).
Toolbar holds a static "On-device" label as WP-32's tier-switcher slot.
One `CoachSessionFactory` conversation session per app lifetime (the WP-22
"transcript is the memory" rule) with `CoachTools.all(store:)` registered
under tool-set ID `wp25-chat-v1`; instructions are the effective prompt
(D10); per-turn context assembled + snapshotted for `.chat`.

UI tests (`CoachUITests`, via `-UITestScriptedCoach` + a Debug-only scripted
session through WP-22's `build:` seam): send → in-flight stop button →
scripted reply streams → turn persisted → relaunch shows history (the flag
deliberately uses the on-disk store; runs assert on a UUID-marked message).
Two simulator-ground-truth corrections during implementation: the iOS 27
simulator's model reports `.available`, so unavailable rendering takes a
forced `.modelNotReady` flag (`-UITestCoachUnavailable`), and the scripted
stream runs 6 chunks × 500ms so the in-flight state survives XCUI polling.
`make test` green (all suites incl. the 2 new UI tests).

## Code review — WP-25 (chat UI)

Twenty findings, all addressed and test-driven.

**Correctness:** newest-first capped read (descending fetch + display
reverse; sends append in hand, `onAppear` is the only re-fetch); the stop /
error paths rewritten so every non-empty-draft exit persists (success,
cancellation before first token leaves no empty turn, mid-stream model
error persists the visible partial *and* reports, persist failures surface
instead of silently dropping); warm-up and streaming get separate task
handles (`send` cancels best-effort warm-up first -- same shared session,
no `concurrentRequests` overlap); `send` returns `Bool` and the view keeps
typed text on `false`; snapshot resolution moved from render into row
expansion tasks, with transcript/draft reads scoped to sibling views so a
token re-renders the bubble, not the list.

**Seams/consistency:** `CoachAvailabilityChecking` protocol (live + fixed)
replaces the bare closure; `-UITestCoachUnavailable[=<case>]` forces any
unavailable case (unknown values fall back to `.modelNotReady`);
`InitialRoute` replaces the boolean matrix; the scripted double is a plain
always-compiled type (StubGoogle precedent) with single-flight enforcement,
`isResponding` across all call kinds, and a scriptable structured reply;
`HealthContext.framedAsData` is the one "data, not instructions" definition
(`DailyInsight.prompt` adopts it); `ContextAssembler.decodeSnapshot` is the
one snapshot reader; banner/error/bubbles use `ThemedCallout` /
`ThemedErrorText` / `Theme` tokens; refresh failures log via `Logger`
(warm-up stays silent by design, send surfaces); warm-up refresh throttled
hourly via `KnowledgeRefreshThrottle`.

**Tests:** 6 new `HealthLoomTests` view-model tests (in-memory container,
stubbed reads/factory/availability -- stream+link, 505-turn cap ordering,
stop-before-first-token, mid-stream error, stop truncation, send-false);
`framedAsData` (CoreModel) + `decodeSnapshot` round-trip/reject (CoachKit)
tests. Counts: CoreModel 18 → 20, CoachKit 148 → 150, HealthLoomTests
43 → 49.

**Simulator ground truth (kept):** the iOS 27 simulator's model reports
`.available`, so unavailable rendering stays flag-forced; the scripted
stream stays 6 × 500ms so the in-flight state survives XCUI polling.

**VERIFIED, not just written:** full `make test` green (packages on both
toolchains, `xcodebuild TEST SUCCEEDED` incl. all UI suites).

## Code review — WP-25 (round 2)

Fifteen findings (the round re-reviewed the amended commit rather than
trusting round-1 annotations -- and caught two real round-1 gaps), all
addressed and test-driven.

**Correctness:** tab switches no longer truncate replies -- `onDisappear`
cancels warm-up only, the stream survives on the AppEnvironment-owned view
model and the remounted view reattaches (warm-up skips while streaming);
`-UITestStubGoogle` routing restored to onboarding (the `.data` branch is
`seedDashboardData` only again); `DailyInsight`'s empty-context wording
restored exactly (preamble stays in the non-empty branch) and locked by an
exact-text test; `send` re-queries the live gate as the stream task's first
step (stale `.available` aborts with an error, covered); warm-up prompt
failures log like refresh failures; one long-lived view-model
`ModelContext` replaces all throwaway contexts (single `persist(_:)`
path); `-UITestScriptedCoach` wins the in-memory decision unconditionally;
`endCall()` precedes `finish()` (no spurious `concurrentRequest`);
`onAppear` cancels a previous warm-up first; `scriptedStructured` is
lock-guarded; one `CoachSessionMode` drives session + availability +
store selection; chat input lives on the view model (survives unmounts).

**Consistency/docs:** `CoachChatView` joins the `ThemedScreen` scaffold
(`isScrollable: false`, transcript owns its scroll; tier slot is a header
action) -- which exposed an accessibility subtlety (container identifiers
override children without explicit `.contain`); `HomeView` header and all
stale README "coach has no UI" passages swept.

**Tests:** 3 new view-model tests (tab-switch survival, stale-cache abort,
launch-flag matrix incl. the stubGoogle regression) + 1 exact-text insight
test. Counts: CoachKit 150 → 151, HealthLoomTests 49 → 52.

**VERIFIED, not just written:** full `make test` green (packages on both
toolchains, `xcodebuild TEST SUCCEEDED` incl. all UI suites).

## WP-26: Prompt Editor

Coach prompt editor (`HealthLoomApp/Coach/PromptEditorView{,Model}.swift`),
reached from a Settings "Coach Prompt" nav row: editable base prompt with a
live token estimate (the canonical estimator, shared with the context
budget), save to the append-only version history, reset-to-default, restore
of any history entry (append-only, so restores reach pre-reset edits),
line-diff vs the shipped default (LCS, removed-first on ties per unified
convention), and the exact effective prompt preview -- working copy plus the
safety suffix in a locked, tinted section (D10: the suffix is never
editable). All live values are computed from the working copy (dirty flag
derives from a saved-text comparison), never stored; validation failures
map to user-facing copy instead of NSError boilerplate.

Tests: `PromptEditorUITests` (seeded launch -- edit → preview contains edit
+ suffix; reset restores default; newest-first history restore reaches the
pre-reset edit) + 6 `HealthLoomTests` view-model/diff suites. Two
accessibility notes for the future: container identifiers override
children's without explicit `.contain` (locked section, history rows --
same collapse `chat.screen` hit in WP-25 round 2). Counts:
HealthLoomTests 52 → 58, HealthLoomUITests 7 → 8.

**VERIFIED, not just written:** full `make test` green (`xcodebuild TEST
SUCCEEDED` incl. all UI suites; no package changes this WP).

## Code review — WP-26 (prompt editor)

Fourteen findings, all addressed and test-driven.

**Correctness:** successful save/reset/restore busts the cached
conversation session (the next turn runs under the new prompt; previously
theTranscript-is-the-memory rule meant a silent memory wipe -- covered by a
session-identity test); the three writes share one `performWrite` path that
clears both message slots up front (stale-notice bug structurally fixed);
diff rows live in a contained group with per-row identifiers; the editor
adopts the persisted trimmed body with a stated footnote instead of a
surprise rewrite; Reset disables unless it would change something
(`canReset`, preserving "empty history means never customized"); the token
counter measures the validated trimmed string; `load()` assigns only on
full success (no half-refreshed mix).

**Simplification/efficiency:** the LCS table is replaced by the stdlib's
`difference(from:)` (linear walk, removed-first); the diff builds once per
render; writes apply the returned snapshot in memory (no post-write
re-fetch); the locked suffix stays hand-rolled deliberately
(`ThemedCallout`'s combine would swallow the suffix identifier -- noted);
the preview's base block derives from the same assembly it displays.

**Tests:** 5 new suites (session-bust identity, notice clearing, reset
guard, trimmed estimate, preview derivation) + a fresh-screen
reset-disabled UI assertion. Counts: HealthLoomTests 58 → 63.

**VERIFIED, not just written:** full `make test` green (no package changes
this round; `xcodebuild TEST SUCCEEDED` incl. all UI suites).

## Code review — WP-26 (round 2)

Four findings, all addressed and test-driven.

**Correctness:** no-op writes (restore-the-active-row, whitespace-only
save, effect-unchanged reset) now return early with an explanatory notice
-- no duplicate history row and, critically, no session reset for an
unchanged prompt. The explicit `resetConversation()` stays for genuine
changes only (where the factory's own instructions check would rotate
anyway; the call keeps the invalidation visible at the edit site).
`canReset` compares strings, not diffs (provably coincident, and it closes
the second twice-per-render path); `previewBase`'s dead fallback became a
Debug assertion; in-memory history prepends honor the fetch's 100-row
bound.

**Tests:** 4 new suites (whitespace no-op, restore-current no-op incl.
session preservation, reset-discard-draft, 105-write cap). Counts:
HealthLoomTests 63 → 67.

**VERIFIED, not just written:** full `make test` green (no package changes
this round; `xcodebuild TEST SUCCEEDED` incl. all UI suites).

## WP-27: ModelCatalog + CoachOrchestrator

New `CoachKit/Orchestration/` group: `ModelTier` (D14 ladder metadata,
`SecretKey` mapping in the `provider.*` namespace), `ModelCatalog`
(`isEnabled` = on-device availability, else consent ∧ (no key ∨ key in
Keychain); per-tier `availability(for:)` naming the blocker; only
`.onDevice` live, `isLive` is the single WP-28 fill-in point),
`CoachError` (normalized UI-facing failures), `CoachOrchestrator`
(PromptManager instructions ⇒ suffix on every tier, snapshot per turn,
dispatch via `CoachSessionFactory`, escalation *offers* on over-budget /
deeper-analysis, never auto-switch).

**Toolchain gate (load-bearing):** the stable matrix toolchain (Xcode
26.4.1, Swift 6.3.1) SDK has `LanguageModelSession`/`SystemLanguageModel`
but NEITHER the `LanguageModel` protocol NOR `LanguageModelError` (verified
against both SDK swiftinterfaces); the beta (Swift 6.4) has both. All
protocol-touching code (`makeModel`, the framework error mapping, its
tests) sits behind `#if swift(>=6.4)` + the SDK's own
`@available(iOS/macOS 27, *)`. The spy-conformance test the plan names
proved infeasible (the protocol has an associated-type `Executor`), so the
suffix assertion spies at the factory seam (captured instructions) -- the
tier-independent carrier of the suffix. Gated tests compile on beta and
execute on macOS 27+ hosts (early return on macOS 26 package-test hosts).

**Isolation note:** `ModelCatalog.live()` (not a default argument) wires
`AvailabilityGate` because default args evaluate outside actor isolation;
same reason the orchestrator takes `catalog:` as an optional defaulting to
nil-then-live in its `@MainActor` body.

**Tests:** 21 new test runs across 3 suites (truth table incl.
non-live-dominates-setup, blocker reasons, error table, suffix capture,
snapshot round-trip, both escalation triggers + overflow dominance,
disabled-tier no-dispatch, failure normalization, framing). Counts:
CoachKit 151 → 169 (beta) / 167 (stable -- 2 gated tests compile out).

## WP-27 review round (reviews/wp-27-10bc02b.md)

Two-part review, addressed test-first and amended into the WP commit.

**Fixed now:** shared `HealthContext.promptBlock` composer + sentence
constant -- `turnPrompt`/`chatPrompt`/`DailyInsight.prompt` converge on
one literal (R1); `ScriptedCoachSession.failure` kills the bespoke
`FailingScriptedSession` copy (R2); `TierAvailability` reason constants,
tests assert which blocker, not its spelling (R3); shared
`bytesToTokens` for both estimators, math unchanged (R4);
tier-owned `tokenBudget(for:)` with `respond` defaulting to it (§5);
single-line ≤300-char sanitizer on every `.underlying`/`.unsupported`
payload at construction (§7); explicit `@MainActor` on the catalog API
(§10); `openAIAPIKey` annotated deferred (§9); doc typo + `isLive`
dominance + `unavailableReason` coincidence notes (§11/§12);
`unsupported*` arms constructed except `Transcript.Entry` (documented);
near-miss phrase pins; offer-snapshot linkage test; `let` deps (O4);
locale-independent phrase matching (O2).

**Spec decision (§3, option b):** trimmed-but-fitting turns answer with
`didTrim` surfaced on `OrchestratorTurn.reply` (quiet UI affordance, no
offer -- per-turn offers on every rich-profile turn would be fatigue);
only `promptOverBudget` offers.

**Declined with rationale:** pre-assemble phrase check (O3 -- would break
offer/snapshot linkage for WP-32); purpose-enum collapse (R5 -- the split
is D15's Dynamic Profiles seam, "don't add a third" honored);
per-turn encoder/shell caching (O1 -- no metric proving the MainActor
path hot); offer-snapshot retention (accepted -- shared `pruneSnapshots`
cap covers both linkages).

**Deferred to WP-28 (review-gated, latent until a second row goes
live):** tier-aware session cache (§1), tier-dependent
`offerEscalation` (§2), `missingCredential` pre-dispatch check (§4),
non-onDevice never-escalates + consent-before-key order tests (§11).

**Counts after round:** CoachKit 169 → 172 (beta) / 170 (stable);
CoreModel +2 (`promptBlock`).

## WP-27 review round 2 (reviews/wp-27-10bc02b.md Part 3)

Three one-line residues + test hardening, all addressed and amended.

**Residues:** `makeModel` uses `TierAvailability.notLive` (N1);
`estimatedShellTokens` delegates to `bytesToTokens` -- last `+3)/4` copy
gone (N2); `@unknown default` sanitizes (N3 -- the highest-leak-risk arm
is no longer the one raw path).

**Tests:** `replyTrueArm` probes downward to a trimmed-but-fitting budget
and asserts `didTrim: true` with the scripted answer (N4 -- the flag's
purpose finally has a passing-true test); `turnPromptDelegation` fails
instead of crashing on zero builds (N5); sanitizer bound corrected to
300 total incl. ellipsis, both payload tests assert it (N6);
`underlyingFallback` annotated as case-pinning, not sanitizer coverage
(N7); `StubTool`/`StubArgs` moved to their only call sites (N8).

**WP-28 gate additions (N4):** the chat path (`CoachChatViewModel.send()`)
still bypasses the orchestrator, so `didTrim` is emitted into the void --
migration checklist: chat adopts `respond()` and renders the
reduced-context affordance; `case .reply` arity 2→3 is compiler-caught at
migration time. Pre-existing gate (§1/§2/§4/§11) unchanged.

**Counts after round 2:** CoachKit 172 → 173 (beta) / 171 (stable).

**VERIFIED, not just written:** CoachKit matrix (beta 173 / stable 171),
full `make test` green incl. `xcodebuild TEST SUCCEEDED`.

**VERIFIED, not just written:** CoachKit matrix (beta 172 / stable 170),
full `make test` green incl. `xcodebuild TEST SUCCEEDED`.

## WP-28: off-device tiers (stacked commits on `wp-28-offdevice`)

**Foundation (no new deps):** tier-aware session cache (tier joins the
factory key -- same prompt on PCC never reuses the on-device session),
`missingCredential` pre-dispatch guard (TOCTOU-tested with a vanishing-key
double), `liveTiers` injection (the row-liveness mechanism AND the test
hook: cloud gating/cache/never-escalates/blocker-order all testable with
scripted sessions, no providers). New tests: tier-busting cache identity,
gate-then-credential sequence, cloud answers-instead-of-offers,
consent-before-key order.

**WP-28a PCC (SDK-only, no package dep):** `makeModel` builds
`PrivateCloudComputeLanguageModel`; catalog gains `pccAvailable`/`pccQuota`
seams (stable toolchain reports unavailable/ok without touching the
framework); `PCCQuota` decision table fully ungated (the framework
publishes no public `QuotaUsage` init, so the thin adapter delegates);
orchestrator quota pre-dispatch -- exhausted falls back to a fresh
on-device turn (budget reset, same snapshot linkage), near-limit sets the
reply's `quotaWarning` bit; `makeProviderSessionBuild` is the single
provider construction point (factory `init` stays private by design).
Row ships non-live by default pending the P-1.5 entitlement.

**WP-28b Claude (app-target adapter):** Anthropic's official package (0.1.4
exact) linked to the app target ONLY -- it requires macOS/iOS 27, which
CoachKit's macOS 26 floor cannot link (proven by build failure both ways).
Same constraint exempts Firebase below. `ClaudeTier` (sonnet5 default,
serverTools never configured -- pinned by test, D11), `makeBuild` via the
shared provider seam, `CoachError(claudeError:)` table (credential mirrors
the guard; attestation arms read as tier-unavailable, fixed copy).
Warnings-as-errors rescoped per first-party target (project/command-line
scope leaked `-warnings-as-errors` into SPM targets vs upstream
`-suppress-warnings`); package `swift test` runs unchanged.

**WP-28c Gemini: DEFERRED (documented):** Firebase's
`geminiLanguageModel` exists but (1) has no BYO-user-key backend -- the key
comes from the developer's `FirebaseApp` config, so usage bills/attributes
to us, contradicting the BYO posture; (2) needs `GoogleService-Info.plist`
+ `FirebaseApp.configure()` + human console setup; (3) its targets only
resolve with `GEMINI_LANGUAGE_MODEL=1` in the environment (CI wrinkle).
Needs a product decision (who pays/registers) before code. Seams are
ready: `liveTiers`, `SecretKey.geminiAPIKey`, credential guard,
never-escalates -- landing it later is purely additive.

**Live-row status:** all rows non-live by default (PCC: entitlement;
Claude: WP-29 key/consent UI; Gemini: deferred). Plan test lines all met
except live-device smoke (no device/entitlement/keys in CI -- manual per
test plan §7).

**Counts:** CoachKit 173 → 181 (beta) / 179 (stable); HealthLoomTests
67 → 70 (Claude adapter + error table) → 67 again on the deferral (work
preserved at `f40022f`, restore note above).

## WP-28 review round (reviews/wp28-review.md)

Corrections first: the review's N6/N8 "still open" verdicts were stale
(the tree it read predates the round-2 push -- impl is `prefix(limit-1)`,
`StubTool` already moved; verified by grep). N3 was genuinely missed
twice -- fixed here and verified in-file immediately after writing.

**Fixed:** N3 `@unknown default` sanitizes (F1); tier-aware framework
mapping `init(languageModelError:on:)` with `.onDevice` default, catch-site
post-adjustment deleted (F2) + cloud-overflow structural pin in the error
table; F3 decision (b): availability stays green through exhaustion (the
turn CAN run via fallback) and the reply carries `fellBackFromTier` so the
UI says so -- gating red would block the D14.3 fallback; F4 reply struct
`TurnInfo(didTrim:quotaWarning:fellBackFromTier:)` stops the arity rot
before D15's serving-tier stamp; F6 cloud deeper-ask answers (test);
F7 offline-construction pin comment.

**Confirmed intentional (F5):** no prod wiring enables PCC/Claude rows --
no `liveTiers` beyond `[.onDevice]`, no injected provider builds, no
Keychain-to-build reads. All provider code is dead in prod builds until
WP-29's key/consent UI (Claude) and the P-1.5 entitlement (PCC), by
design; defaults preserve WP-27 behavior. F8 acknowledged (double-failure
loses PCC context -- edge-of-edge, on-device-off is the actionable signal).

**Counts:** CoachKit 181 → 182 (beta) / 180 (stable).

## WP-28 review round 2 (reviews/wp28-review.md Part 4)

Verdict: mergeable, no blockers/highs. New items all low/nit.

**L1 stale, no change:** the "181/179" quote predates the fix commit --
the table already reads 182/180, matching measured beta/stable runs.

**L2 noted, not restructured:** two PCC handle constructions per turn
flagged with an inline NOTE for the on-device manual pass (test plan
§7); no speculative single-read seam -- a unit test can't price it.

**L3 filed for WP-29:** `makeBuild` wiring test lands with the
Keychain→build commit (that's where it earns its keep), alongside
before/after tests for the first prod `liveTiers` flip + Keychain read
(checklist §5). F8 stays dropped unless WP-29's error UI needs
double-failure copy.

## WP-28b Claude: deferred after CI (SDK drift)

The adapter + error table were written, tested (70 app tests), and green
locally -- then CI failed: upstream 0.1.4 references
`FoundationModels.Transcript.CustomSegment`, absent from the July-beta SDK
on CI's `xcode-27` image (local 27A5218g has it). Every upstream release
(0.1.0-0.1.4) uses the symbol, so no pin avoids it; no newer runner image
is discoverable; the fallback can't be verified without the July
toolchain. Same call as Gemini: defer, don't fork.

**Removed from the branch** (not parked uncompiled -- uncompiled code
rots while the SDK churns): the remote package, `ClaudeTier.swift`,
`ClaudeTierTests.swift`. **Restore point:** commit `f40022f` (exact
pin 0.1.4, serverTools-never pinned, 3-case error table). Restore when
CI's Xcode 27 SDK provides `Transcript.CustomSegment` (release the row
via `liveTiers` + WP-29 key UI at the same time) -- and RE-MAKE the
default-model choice against the constants table then (0.1.4 added
opus5 after the sonnet5 default was picked; do not blindly re-pin it).

**Kept:** the warnings machinery the episode produced --
`SWIFT_SUPPRESS_WARNINGS=NO` next to the errors flags (make + CI) so the
next remote dep builds warning-free-or-fail instead of conflicting, and
per-target settings for GUI builds.

## WP-28 review round 3 (findings list, no review file)

Thirteen findings, all addressed in one stacked commit.

**Real bugs fixed:** `makeModel` consults `liveTiers` first (single-predicate
invariant restored; the Claude deferral had left dead rows constructible);
provider wiring map -- unwired non-onDevice tiers throw instead of silently
answering from the default factory at a foreign budget (pinned by
`unwiredTierThrows`); quota-fallback offer loop closed (fallback turns
suppress offers; suppressed overflow throws offer-less via internal
`runTurn`, pinned by `fallbackDeeperAskAnswers` +
`suppressedOverflowThrows`); PCC seams fail closed (`{ false }` /
`.exhausted`, doc corrected); `resetDate` threads into `TurnInfo`
(`quotaResetDate`, asserted on warning + fallback replies); per-tier
single-slot session cache (toggle preserves transcripts, bounded by
construction; `resetConversation` stays the explicit close path).

**Dead code deleted:** `makeModelLiveness` (gated + 27-host-guarded =
never executes in this matrix; also stale post-guard); both provider-build
helpers (zero call sites since the deferral; restore with WP-29 wiring).

**Docs corrected:** README 70 to 67 app tests (deferral), 182 to 185 /
180 to 184 CoachKit; project.yml comment rewritten to the actual
enforcement state (both layers + known GUI gap for local packages); CI
comment drops the wrong package name; restore note re-makes (not re-pins)
the model default.

**Acknowledged, no code:** no app `CoachOrchestrator` consumer yet
(expected -- WP-29 migration checklist already covers adopting
`respond()`); double-failure context loss stays dropped.

**Counts:** CoachKit 182 to 185 (beta) / 180 to 184 (stable, 1 gated test
left); HealthLoomTests 67.

## Review fixes: sync/auth/coach hardening (15 findings)

All fifteen addressed, test-first where the seam allowed, full `make test`
green on both toolchains (beta + stable clean build).

**SyncKit**
- `SyncEngine`/`BackfillCoordinator` persist `SyncLogRedactor`-redacted
  messages to `lastError` (was raw `String(describing:)` into the store +
  UI); success-path `context.save()` failure now reports `.error` instead
  of a swallowed `.ok` (contract documented in the engine header).
- `saveWorkout` attaches distance under the activity's own bucket
  (`distanceIdentifier(for:)` single table: run/walk/hike, cycling,
  swimming, rowing; nil otherwise -- no sample, workout still saves);
  `retroactiveCleanup` sweeps every bucket the writer can emit via
  `distanceIdentifiersForCleanup` (derived from the same table).
- `WatchConflictResolver` holds per-type `RunState` (was one shared slot
  `beginRun` wiped): concurrent types no longer destroy each other's
  coverage/links/counts; drains are per-type, typeless drains fail closed.
- `BackfillCoordinator` writes `backfillStatus`/`backfillError` (new
  `SyncState` fields, additive migration) instead of contaminating the
  incremental row; `SyncStatus.rawValue` everywhere, no bare literals.
  `itemCount` stays shared cumulative by design (both pipelines import).
- Run loop is generation-guarded: a stale cancelled loop can't wipe a newer
  handle and admit a second concurrent walk.
- `sync(type:)` clears `inFlight` inside the task before waiters resume --
  no stale-outcome reuse, no clobbering newer entries.

**GoogleHealthClient**
- `completeConsent` verifies (userinfo + `hd` check) BEFORE persisting;
  userinfo failure stores nothing. Refresh-token rotation and both consent
  writes propagate storage failures as `.tokenStorageFailure` (was `try?`).
- Backoff sleep propagates cancellation as new `.cancelled` (was `try?`
  burning remaining attempts back-to-back). Typed-`throws` on this
  toolchain rejects a bare `CancellationError`, hence the case.

**App**
- `ActivitiesModels`: peek-don't-remove -- supplements for non-AppleWatch
  workouts fall through to the unlinked sweep instead of vanishing.
- `SettingsView`: failed/cancelled consent reverts the optimistic toggle.
- `TodayMetricFormatter`: delegates to CoreModel's new shared
  `MetricFormatting` (same helper CoachKit's `KnowledgeDerivation` uses) --
  negative durations clamp to "0m" on both surfaces, fixes land once.

**CoachKit**
- `GetVitalsTool.excludedMessage` routes through
  `CoachTools.excludedMessage(forTopic:)` like the other three tools.
- Quota fallback passes the on-device gate first: AI-off reports
  `.tierUnavailable`, never an opaque session-over-dead-model failure.

**Counts:** SyncKit 263 to 267; GoogleHealthClient 35 to 36; CoachKit 185
to 186 beta / 184 to 185 stable; HealthLoomTests 67 to 68. New tests:
persisted-error redaction, resolver cross-type isolation, cycling/yoga
distance buckets, userinfo-failure-stores-nothing, non-watch supplement
standalone, negative duration clamp (extended), fallback gate.

## Review fixes round 2 (15 findings)

Full `make test` green on beta, clean-build green on stable for every
touched package, simulator `TEST SUCCEEDED`.

**Correctness reversals (my round-1 fixes that were wrong):**
- Workout distance buckets are now actually authorizable: `HealthKitWriter
  .workoutShareTypes` (workout + energy + every distance bucket, derived
  from the same table) feeds a new `includingWorkoutShare` union in
  `requestShareAndRead`, passed by onboarding's single sheet. This also
  closes a pre-existing gap -- `.exercise` share was never requested
  anywhere, so workout saves could never have succeeded.
- Activities supplement is always consumed (absorbed silently for
  non-watch workouts): one entry, never vanished, never duplicated. Test
  rewritten to `entries.count == 1`.
- Access-token Keychain writes are best-effort again (`try?`) in both
  refresh and consent -- the slot is a write-only cache nothing reads
  back. Refresh-token rotation stays loud.
- `SyncEngineSaveError` namespace deleted; plain
  `HealthKitWriterError.underlying(redacted)` at the throw site.
- Typeless drains deleted from protocol, defaults, and resolver (zero
  callers left) -- stale conformers now fail to compile.

**Genuine second-order bugs:**
- `backfillStatus` carries a property-level `= "idle"` (migration reads
  property initializers, never `init`).
- Both pipelines `rollback()` before writing the error row, re-acquiring
  state after (rollback can undo a first-ever insert); backfill records
  the completed horizon only after a durable save (side store is never
  rolled back).
- `clearInFlight` is really identity-checked now (per-run UUID token;
  `Task` isn't `Equatable`).
- `stop()` awaits the loop's exit (all callers already async) + a
  cancellation probe inside `runRound` -- the generation counter alone
  only protected the handle, not the cursor.
- New `SyncStatus.cancelled` (+ `BackfillChunkOutcome.suspendedCancelled`):
  cancellation persists a message-less stop status, never an error row;
  the log mirror logs at default level, never `.error`.
- `MetricFormatting` is `nonisolated` with a per-locale cached
  `NumberFormatter` (lock-guarded lookup AND use -- formatters aren't
  thread-safe); deterministic sweep order from `allCases` (no `Set`
  round-trip).

**Counts:** SyncKit 267 to 268; rest unchanged. New tests:
cancellation-reports-stopped (engine); F6 rewrite.

## Review fixes round 3 (13 findings)

Full `make test` green on beta, clean-build green on stable for every
touched package, simulator `TEST SUCCEEDED`.

**Round-2 reversals and narrowings:**
- Bucket-less distances are preserved in workout metadata
  (`healthloom.distanceMeters`/`healthloom.energyKilocalories` on every
  workout), not dropped -- the old comment's justification was false
  (metadata carried ID/source keys only). Totals stay uncorrupted AND no
  data is lost.
- Activities trusts the resolver link over the `isAppleWatch` heuristic:
  linked supplements always attach inline (the "+ 8.0 km" row survives
  classifier divergence), and the row keeps its own source name instead
  of the supplement's. Test asserts attach + `sourceLabel == "HealthLoom"`.
- `clearTokens()` restored on the Workspace path (wipes pre-existing
  grants, not just this call's).
- Throw sites carry raw descriptions; the catch is the single D11
  redaction boundary (recorder's own re-redact stays as its log-boundary
  rule).
- `MetricFormatting.groupedCount` is one lock acquisition covering lookup
  and use.

**New machinery:**
- Settings gains an "Apple Health Sharing" section re-requesting the full
  set with `includingWorkoutShare` -- the path for installs onboarded
  before the flag shipped (HealthKit only re-prompts undetermined types).
- Data client maps `CancellationError` AND `URLError.cancelled` to
  `.cancelled`, plus a loop-top `Task.isCancelled` probe -- the backoff
  sleep was the rare window; the in-flight request is the common one.
- `stop()`/`start()` serialize through a published `retiredLoop`
  (generation-tokened clearing); `resume()` is async to match (all
  callers already awaited).
- Protocol drain defaults deleted: `IdentityConflictFilter` and the test
  double now state their (honest-empty) drains explicitly; a silent
  conformer stops compiling.
- Cancellation preserves the previous `lastError`/`backfillError`
  evidence (status alone moves to `.cancelled`).
- Resolver drains release the coverage index (per-type memory freed at
  run end, not next run's begin).
- Settings consent flips carry per-attempt tokens: a stalled attempt's
  late failure can't revert a newer success (or explicit OFF).
- Already-at-horizon records completion only after a successful save.

**Counts:** SyncKit 268 to 269 (bucketless-metadata test). Rest unchanged.

## WP-29 · Key management + consent UI

Settings → AI Models screen (`HealthLoomApp/Coach/AIModels/`): per-tier row
(status from `catalog.availability(for:)`, model picker for keyed tiers),
consent sheet per off-device tier (`TierConsentCopy` single-sources
destination / data-leaves / privacy / forget-forward, timestamp recorded in
`TierSettingsStore`), key entry (SecureField → 1-token ping via
`LiveCloudKeyValidator` → Keychain, stores only on `.valid`; delete drops
the effective state while the toggle preference survives), PCC quota line.
`CloudGateCache` bridges `MainActor` state into the catalog's `@Sendable`
closures; `AppEnvironment` wires production (live Keychain/HTTPS) vs the
`-UITestAIModels[=<scenario>]` UI-test scenario (in-memory keys, stub
validator, scrubbed preferences, PCC+Claude live).

**Review (reviews/wp-29-review.md, 3 rounds):** round 1 found 1 blocker
(F1 — four mutation paths changed zero `@Observable` state, so rows went
stale until remount) + 7 lows (F2 launch race, F3 non-live enable flows,
F4 sticky banner, F5 Gemini bare-400, F6 locale folding, F7 shared stub
state, F8 doc drift) + 2 test bugs (TMP abort, missing Delete tap). Round 3
verified F1–F8 fixed and raised F9 (Enter-key side door), closed same round:
`beginKeyEntry` is the single liveness-guarded choke point, non-live rows
hide Enter-key/picker (Delete retained for inert-key cleanup),
`ModelCatalog.isLive` + `TierAvailability` reason constants public with
tests asserting the constant. Open nits carried: N1 force-unwraps in tests,
N2 simulator-defaults pollution; residual note (chat-slot key presence reads
untracked gates) folded into WP-32 if cheap.

**Counts:** HealthLoomTests 84 → 86 (F3 non-live guard, F5 Gemini
bare-400); new `AIModelsUITests` 5/5 incl. `testKeyDeleteDisablesTier`;
CoachKit 186/186 beta, 185/185 stable (unchanged — visibility-only diff).
Full app `xcodebuild build test` green on beta with warnings-as-errors,
clean build green on stable for the touched package.

## WP-30 · Knowledge transparency UI ("You" tab)

New You tab (`HealthLoomApp/You/`, `HomeTab.you` between Coach and Data)
over the persisted `KnowledgeProfile`: per-field rows (display text,
source, as-of, AI-context toggle, Clinical / Your-correction badges),
correction sheet pinning user overrides, Forget section (derived-insight
reset + chat-history wipe, both confirmed). Durable exclusion by design:
`KnowledgeStore.refresh()` carries each key's previous `excludedFromAI`
onto the rebuilt derived field (the write-path warning's accepted gap —
absent-for-a-cycle resets — documented at mechanism and contract);
`pinCorrection(displayText:forKey:)` preserves sharing posture.
`KnowledgeStore` promoted to a stored `AppEnvironment` property with a
`youViewModel()` factory; `-UITestYouTab` seeds profile/insight/turns and
lands on the tab; `-UITestScrubChat` keeps the scripted coach transcript
hermetic. Trace expander names the serving tier (`chat.context.tier`).

**Review (reviews/wp-30-review.md, 2 rounds):** round 1 found 1 high (F1 —
wipe deleted rows but the factory's cached session kept the transcript;
fixed via `factory` in deps + `resetConversation()`) + 2 lows (F2 empty-
provider badge, F3 scrub gated on scripted) + nits (N1 notice cleared on
load; N3 shared doubles moved to `TestDoubles.swift`, not widened).

**Counts:** HealthLoomTests 86 → 93 (6 You VM + F1 session test);
`YouTabUITests` 4/4 new; `CoachUITests` 2 → 3 (trace badge);
CoachKit 186 → 189 (exclusion-durability + correction suites). Full app
`xcodebuild build test` green on beta with warnings-as-errors.

## WP-32 · In-chat tier switcher (slice 1)

Toolbar tier menu over `enabledTiers` (single source for menu, slot text,
and dispatch): `selectTier` choke point (menu + future escalation offers),
dispatch re-validation with captured `servingTier`, per-turn stamps,
untouched transcript, per-turn prompt re-resolution (suffix sweep).
Tier threaded into the session-build seam; default build serves
on-device live and every other tier fail-closed (`UnwiredTierSession`,
copy single-sourced with the orchestrator); flip checklist names routing.

**Review (reviews/wp-32-review.md, 2 rounds — SHIP IT):** round 1 high
(F1 tier-blind build stamping unserved tiers) fixed structurally +
per-tier identity test; F2 sticky select error. Round 2: 1 low (F1
unwired-error copy unpinned end-to-end — VM-level named-error +
user-turn-only test) + nits (comment reword, this paragraph).

**Counts:** HealthLoomTests 93 → 102 (7 switcher + routing + unwired
send); `CoachUITests` 3 → 4 (menu offers); CoachKit 189 → 191
(UnwiredTierSession suite). Full app `xcodebuild build test` green on
beta with warnings-as-errors (unit 102/102; UI 13/13 across
AIModels/Coach/YouTab); CoachKit 191 beta / 190 stable.

## WP-31 · Coach evals (CoachEval target)

New `CoachEval` target in `Packages/CoachKit` (no new product — target-only): 30 probes (6 grounding, 4 structure templates run 5× nightly for the 20/20 bar, 15 safety red-team, 3 prompt-injection suffix-wins) over a frozen `SeededProfile` (comma 8,432 / decimal 172.4 / 7h 30m / readiness 78 +5 4-of-4), deterministic scorers (`GroundingScorer` number-token match with trailing-zero normalization, `StructureScorer` wrapping `DailyInsight` validators, `SafetyScorer` marker + banned-pattern screen), `runAll` fan-out + `ConsistencyReport` (safety-only agreement across on-device/PCC/Claude/Gemini), and `TuningProposal` hill-climbing record (propose → human review → adopt; never auto-adopted). Framework-agnostic: no public `Evaluations` module in this beta (`import Evaluations` fails macOS + simulator), so pointing Apple's harness at these cases is a follow-up; model-in-the-loop nightly lane needs a macOS 27 host/device (`ModelLoop` seam ready, sequential documented as choice for rate limits + deterministic ordering).

**Review (2 rounds — SHIP IT):** round 1 found 2 highs (H1 safety false-pass — push-through/fasting-plan/calorie-number + marker bypasses; H2 textbook 911 replies false-fail) + 5 lows (L1 paraphrase limits, L2 25-vs-~30/set-integrity, L3 serial fan-out, L4 internal variant + unpinned rendering, L5 untested conjunction/partial) + 3 nits. Round 2 verified all closed with verbatim-pinned tests (banned 6→14, emergency/911/urgent-care/poison-control markers, 30 probes, public variant + 5 rendering pins, conjunction + partial-mismatch tests, `Screening.passed` single def). Residual L6 (new, non-gated): `could`-alternation over-broad on one ability-phrasing + `I-recommend` non-ban documented-but-unpinned — nightly-watch follow-up.

**Counts:** `CoachEvalTests` 28/28 in 7 suites (beta, warnings-as-errors clean); `CoachKitTests` 191/191 beta unchanged, 190/190 stable unchanged (218 stable total with evals); no app-target changes. Full package `swift test -warnings-as-errors` green beta + stable.
