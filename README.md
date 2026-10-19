[![Build](https://github.com/wpowiertowski/healthloom.app/actions/workflows/ci.yml/badge.svg?branch=main)](https://github.com/wpowiertowski/healthloom.app/actions?query=branch%3Amain)
[![License](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)
[![Swift 6.4](https://img.shields.io/badge/swift-6.4-F05138.svg)](https://swift.org)
[![iOS 27](https://img.shields.io/badge/iOS-27-000000.svg)](https://developer.apple.com/ios/)
[![SwiftUI](https://img.shields.io/badge/SwiftUI-blue.svg)](https://developer.apple.com/swiftui/)
[![SwiftData](https://img.shields.io/badge/SwiftData-blue.svg)](https://developer.apple.com/swiftdata/)
[![HealthKit](https://img.shields.io/badge/HealthKit-blue.svg)](https://developer.apple.com/healthkit/)

# HealthLoom

Fitbit (and Fitbit Air) data, synced into Apple Health — with an AI coach you control.

---

## Overview

HealthLoom is a native iOS app that syncs Fitbit / Fitbit Air / Pixel Watch data from the
**Google Health API** into **Apple HealthKit**, so your health data lives in one place
even if your wearable isn't from Apple. It's built for the dual-wear user: a Fitbit worn
24/7 for baseline data (sleep, overnight HRV/SpO₂, resting HR, all-day steps) and an Apple
Watch worn for dedicated activities — HealthLoom consolidates the two instead of double
counting.

On top of that data, HealthLoom layers a **user-controlled AI coach**, built entirely on
the iOS 27 Foundation Models framework: the on-device Apple model by default, Apple's
Private Cloud Compute server model as a free bigger-model tier, and Claude / Gemini as
opt-in bring-your-own-key providers — all behind the framework's `LanguageModel`
protocol, so one session API serves every tier. You write the system prompt; a
non-editable safety suffix keeps clinical topics pointed at an actual clinician.

## Features

Shipped (P0–P5, then WP-52–WP-82 from real-device use; per-package build log in
[progress.md](progress.md)):

**Sync: Google Health → Apple Health**

- **Google Health OAuth (PKCE)** — `ASWebAuthenticationSession` consent flow, Keychain-backed token storage, single-flight refresh on 401, incremental consent per scope
- **Typed Google Health v4 client** — `reconcile`/`dailyRollup` calls against `health.googleapis.com` in the real wire format (WP-51), paged, with exponential backoff + jitter on 429/5xx
- **Full type mapping** — steps, heart rate, sleep, weight, SpO₂, HRV (written as RMSSD or SDNN, as a nightly 8 pm–6 am average), blood glucose, hydration, body fat, nutrition, and ~13 exercise types mapped to HealthKit, with unit conversion and rejection rules pinned by golden-file tests
- **Idempotent HealthKit writes** — every sample stamped with `HKMetadataKeyExternalUUID`; re-syncs are diffed in batches, and in-app samples upsert in batches that leave unchanged rows alone
- **Incremental sync with lookback** — each run reaches back 72 h (24 h for heart rate, 7 d for sleep) so late device uploads still land; three types sync at once
- **Historical backfill** — chunked, checkpointed, resumable walk-back (30 d / 90 d / 1 y / all)
- **Background sync** — `BGAppRefreshTask`-driven; Sync Now holds background time and retries a dropped connection once; Sync Log with per-type diagnostics
- **Non-writable types surfaced in-app** — ECG, Active Zone Minutes, Irregular Rhythm Notifications stored locally and badged "not in Apple Health"
- **Conflict resolution (D13)** — workouts other apps saved to Apple Health, Apple Watch included, win the session; Fitbit stream samples inside them are deferred; sleep source preference (Fitbit by default)

**Screens**

- **Today** — readiness score with its named signals, HRV beside last night's average, reorderable metric rows, morning insight panel
- **Activities** — consolidated Apple Watch / Apple Health / Google Health entries (duplicate Google sessions folded into one), each opening to a summary, route map, and a plot of every measurement
- **Data** — per-type sync status with 7-day averages, opening on the last known values
- **You** — every profile field the coach can see, with per-field AI toggles, corrections, goals/injuries/preferences, and forget controls
- **Settings** — sync preferences, units per measurement (weight, distance, pool, energy, stride), AI models with per-tier consent, morning insights, export, and disconnect & wipe
- **Concrete Glass design system** (D16), floating tab bar, VoiceOver / Dynamic Type / Reduce Motion pass, iCloud sync of settings, insight preferences and coach history through the private CloudKit database (D17, schema as code)

**AI coach**

- **Knowledge + context** — `KnowledgeStore` derives a readable profile from HealthKit + local samples; `ContextAssembler` builds each turn's context from it alone (clinical fields excluded by default, token-budget trimming), and every assembly is kept as a snapshot for the "What did the coach see?" trace
- **Prompt + safety** — user-editable base prompt with version history and editor; immutable safety suffix (non-medical disclaimer, no-diagnosis / no-ECG-AFib rule), wording approved by the owner 2026-09-03
- **Chat** — streaming replies, typing indicator naming the running tool, in-chat tier menu, per-turn tier badge
- **Tools** — gated answers for sleep, vitals, steps, and every workout in full (splits, per-device measurements)
- **Morning insights** — `ReadinessEngine` + `@Generable DailyInsight`, generated after the overnight sync, local notification with headline only by default
- **Evals** — `CoachEval` target: grounding, structure, safety red-team, and prompt-injection probes, with the deterministic half in CI
- **Claude tier (WP-85)** — opt-in, with your own Anthropic API key: Anthropic's official `ClaudeForFoundationModels` package behind the same session seam as on-device, Opus 5.5 by default (Sonnet 5.5 and Haiku 5.5 in the picker), consent required, key checked before it's stored and read from the Keychain only when a turn needs it, chat only (morning insights never leave Apple), no Anthropic-hosted tools

Built but not live (see [Status & Roadmap](#status--roadmap)):

- **Private Cloud Compute tier** — catalog, quota and consent are in place; turns route to a fail-closed session until the PCC entitlement is granted
- **Gemini tier** — deferred pending a product decision on who pays for and registers the Firebase backend

## Technology Stack

| Layer | Framework |
| --- | --- |
| UI | SwiftUI (`@Observable`, Approachable Concurrency, default `@MainActor`) |
| Data | SwiftData (`SyncState`, `LocalSample`, chat/knowledge models) |
| Health | HealthKit (reads for de-dup, writes for synced samples/workouts) |
| Device sync source | Google Health API (`health.googleapis.com/v4`) via OAuth 2.0 + PKCE |
| Secrets | Keychain (`kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`) |
| Background work | BGTaskScheduler (`BGAppRefreshTask`) |
| On-device AI | Foundation Models framework (`LanguageModelSession`, `SystemLanguageModel`) |
| Apple cloud AI | `PrivateCloudComputeLanguageModel` — free server model on Private Cloud Compute (Small Business Program) — built, live once the entitlement is granted |
| BYO-key cloud AI | Claude via Anthropic's official `ClaudeForFoundationModels` package, Gemini via Firebase — both through the iOS 27 `LanguageModel` protocol, opt-in; Claude live since WP-85, Gemini deferred |
| Concurrency | Swift 6.4 strict concurrency (actors, `async`/`await`, `@concurrent`) |

## Architecture

```text
┌─────────────┐  BLE   ┌───────────────────┐  ~15 min   ┌───────────────────────┐
│ Fitbit Air  │ ─────▶ │ Google Health app │ ─────────▶ │ Google Health API     │
│ Pixel Watch │        │ (user's phone)    │    sync    │ health.googleapis…/v4 │
└─────────────┘        └───────────────────┘            └───────────┬───────────┘
                                                                    │ OAuth 2.0 + PKCE, reconcile reads
                                                                    ▼
                                                    ┌───────────────────────────────┐
                                                    │ HealthLoom (this app)         │
                                                    │ SyncEngine → TypeMapper       │
                                                    │ → ConflictResolver            │
                                                    │ → HealthKitWriter             │
                                                    └──┬──────────────────┬─────────┘
                                                       ▼                  ▼
                   Apple Watch ── native recording ──▶ Apple HealthKit    AI Coach
                   (workouts: GPS, dense HR)           (writable types)   (profile-only context)
```

Full write-up, including the twelve numbered design decisions (sync cursor semantics,
idempotency, watch-priority conflict resolution, privacy posture, AI context boundaries)
lives in [architecture.md](architecture.md).

## Project Structure

```text
HealthLoomApp/           SwiftUI app target — screens, DI wiring, BGTask registration
├── Onboarding/          Welcome → Google consent → HealthKit permission → first sync
├── Today/               Yacht club Today view — readiness hero, reorderable metric rows
├── Activities/          Consolidated watch/Fitbit activity view (D13)
├── Dashboard/           Per-type sync status
├── Backfill/            Historical backfill range picker + per-type progress
├── Settings/            Sync preferences, incremental consent scopes, watch-priority toggle
├── Diagnostics/         Sync log viewer
├── DI/                  App-wide dependency wiring
└── Shared/              Shared chrome/theme used across screens
Packages/                Local Swift packages, dependency-ordered (architecture.md §2)
├── CoreModel/            SwiftData models + shared value types — no I/O
├── Secrets/              Keychain wrapper (actor KeychainStore)
├── GoogleHealthClient/   OAuth (PKCE) + typed v4 REST client
├── SyncKit/              Pull → map → resolve conflicts → write pipeline + scheduling
└── CoachKit/              On-device coach: knowledge/context/prompt/readiness/session/tool layers
HealthLoomTests/          Unit tests hosted in the app target (@testable import HealthLoom)
HealthLoomUITests/        XCUITest — onboarding, dashboard, activities, Today, coach chat, prompt editor, AI models, insights, settings, You tab, wipe, sync stress
Design/                  Yacht club design system reference (HTML + SwiftUI mockups)
```

## Testing

CI runs a per-package `swift test -Xswiftc -warnings-as-errors` matrix, then runs
`xcodebuild build test` for the `HealthLoom` scheme on an iOS Simulator against the
committed `HealthLoom.xcodeproj` — the same project Xcode Cloud archives — with warnings
failing the build in both stages. A separate *XcodeGen Drift* job regenerates the project
with the pinned XcodeGen and fails if the commit is stale. `make test` runs the same
package-by-package `swift test` + build locally; `make xcode` regenerates (after checking
the XcodeGen version against the pin) and opens the project.

```bash
make xcode                                            # regenerate HealthLoom.xcodeproj (pinned XcodeGen) and open it
swift test --package-path Packages/SyncKit            # run a single package's tests
xcodebuild test -project HealthLoom.xcodeproj \
  -scheme HealthLoom -destination 'platform=iOS Simulator,name=iPhone 17'
```

| Package | Tests | Coverage |
| --- | --- | --- |
| CoreModel | 25 | SwiftData model relationships, defaults, Codable value types, shared exercise-payload decoding, health-context data framing + shared prompt composer |
| Secrets | 14 | Keychain read/write/delete round-trip, accessibility attribute, missing-item handling |
| GoogleHealthClient | 62 | OAuth PKCE flow, token refresh, consent verify-before-store, cancellable backoff, `reconcile`/`dailyRollup` decoding against real-shaped fixtures, retry/backoff |
| SyncKit | 368 | `TypeMapper` golden files per data type + rejection rules, `SyncEngine` idempotency/cursor/lookback, `HealthKitWriter` batched existence diff, backfill chunking/checkpointing, background scheduling, sync log redaction, persisted-error redaction, per-activity distance buckets, per-type resolver runs, backfill status fencing + loop generation, `WatchCoverageIndex`/`ConflictResolver` (D13) |
| CoachKit | 232 | `KnowledgeStore` derivation math (steps/HR/HRV/sleep/workouts), correction pinning, clinical-field exclusion, HealthKit read-store adapter, refresh throttle, reentrancy, tool-facing summary window clamping, `ContextAssembler` trimming/snapshot retention, `PromptManager` history + suffix ordering, `AvailabilityGate` mapping, session lifecycle identities, cumulative-to-delta streaming, `ReadinessEngine` golden vectors + monotonicity, `DailyInsight` prompt/generator seam, coach tools wiring + clamping + exclusion gating, `ModelCatalog` gating truth table + tier budgets, `CoachError` normalization + sanitizer, orchestrator suffix/snapshot/escalation/`didTrim`/`TurnInfo`, tier-aware cache + credential guard + quota fallback |
| HealthLoomTests | 403 | App-target unit tests — Today metrics/formatting, readiness inputs, Activities consolidation + detail series, units, Data tab values, coach chat view-model + workout reader, prompt editor, insights, wipe/export, iCloud sync, pixel snapshots |
| **HealthLoomUITests** | **30 (2 skipped)** | **XCUITest: onboarding, dashboard, activities, Today, coach chat, prompt editor, AI models, insights, settings, You tab, wipe. Skipped: the HealthKit-sheet onboarding test (runner limitation) and the on-demand sync stress test (`make stress`)** |

Counts are from CI run 227 on main (2fd618c, 2026-10-02): packages on Xcode 26.4.1, app
and UI tests on Xcode 27.0, zero failures. That run's log also held 24 UI-test compiler
warnings, fixed in WP-83, which moves the package jobs to Xcode 27 and fails any build
whose log holds a warning.

## Requirements

- iOS 27 or later
- Xcode 27 or later, on an Apple Silicon Mac (to build from source). In CI, the
  package `swift test` jobs and the app-scheme job all run on GitHub's `xcode-27`
  runner image (Xcode 27.0, iOS 27 simulators), the only one that carries Xcode 27
  so far; the manifests are at `swift-tools-version: 6.4`. See the Toolchain note in
  [implementation-plan.md](implementation-plan.md)
- [XcodeGen](https://github.com/yonaskolb/XcodeGen) at the version pinned in `.github/workflows/ci.yml` (`XCODEGEN_VERSION`) — `project.yml` is the source of truth, and the generated `HealthLoom.xcodeproj` is **committed** (Xcode Cloud builds from it and has no XcodeGen step). Regenerate with `make xcode` after any structural change and commit the result; CI's drift job rejects a stale project
- A Google Cloud OAuth client for the Google Health API (see [google-health-healthkit-base-knowledge.md](google-health-healthkit-base-knowledge.md))

## Status & Roadmap

Phases P0–P5 of [implementation-plan.md](implementation-plan.md) are implemented, plus
WP-52–WP-82 from real-device use; [progress.md](progress.md) has the per-package log.
What remains:

- **Off-device tiers** — PCC goes live with its entitlement (P-1.5), together with session routing and before/after serving-model tests (WP-38). Gemini needs the product decision above. Claude shipped in WP-85; a real-key check on a device is the remaining manual step (test plan §7).
- **Toolchain** — move CI back to the regular macOS image once it carries Xcode 27, and re-test the self-skipped HealthKit-sheet UI test on the 27.0 runtime.
- **Launch checklist (WP-38)** — Google OAuth verification for the Restricted scopes (P-1.4), App Review prep and privacy label, graceful-degradation matrix, and a real dual-wear verification day.
- **Optional** — webhook push freshness (WP-36), Siri & Spotlight via App Intents (WP-39).

## License

This project is licensed under the [MIT License](LICENSE).
