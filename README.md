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

Shipped (P0 + P1 — the sync pipeline — plus WP-33's Today view, pulled forward from P4):

- **Google Health OAuth (PKCE)** — `ASWebAuthenticationSession` consent flow, Keychain-backed token storage, single-flight refresh on 401
- **Typed Google Health v4 client** — `reconcile`/`dailyRollup` REST calls against `health.googleapis.com`, paged, with exponential backoff + jitter on 429/5xx
- **Full type mapping** — steps, heart rate, sleep, weight, SpO₂, HRV, blood glucose, hydration, body fat, nutrition, and ~13 exercise types mapped to their HealthKit equivalents, with unit conversion and rejection rules pinned by golden-file tests
- **Idempotent HealthKit writes** — every sample stamped with `HKMetadataKeyExternalUUID`; re-sync is diffed in batches, never one query per sample
- **High-water-mark + lookback sync cursor** — a fixed lookback window (72 h; 7 d for sleep) so late-arriving device data is never silently dropped
- **Historical backfill** — chunked, checkpointed, resumable walk-back (30 d / 90 d / 1 y / all) independent of incremental sync
- **Background sync** — `BGAppRefreshTask`-driven, with a diagnostics log and manual sync from Settings
- **Non-writable types surfaced in-app** — ECG, Active Zone Minutes, Irregular Rhythm Notifications stored locally and badged "not in Apple Health"
- **Apple Watch-priority conflict resolution (D13)** — session- and stream-level dedupe against watch workout coverage windows, retroactive cleanup on ordering hazards, consolidated **Activities view**, and a "Prefer Apple Watch during workouts" Settings toggle
- **Onboarding + dashboard** — welcome → Google consent → HealthKit permission → first sync, then a per-type sync status dashboard
- **Today view (Yacht club design)** — readiness tick-scale hero, reorderable metric rows, sync-status header; the readiness score and coach panel render explicit pending states until WP-23/34 land
- **KnowledgeStore (P2, WP-19)** — derives a human-readable `KnowledgeProfile` from HealthKit + `LocalSample` (steps, resting HR/HRV trend, sleep duration/stage split, workouts merged with linked Fitbit supplements, Active Zone Minutes, presence-only clinical fields), with user-correction pinning and tool-facing summary text — gated tool answers behind `CoachTools`, per-turn context behind the Coach tab
- **ContextAssembler (P2, WP-20, hardened in WP-21/22 review)** — builds the exact `HealthContext` for one coach turn from the `KnowledgeProfile` only (`excludedFromAI` filtering incl. clinical default-out, UTF-8-bytes/4 token-budget trimming with user corrections first then vitals > sleep > activity > history, system-prompt tokens reserved out of the budget, every assembly persisted as a `ContextSnapshot` with a hard 200-row retention cap (evicted rows null linked turns first, so no trace link dangles) for the "What did the coach see?" trace) — consumed by WP-23 insights and the WP-25 Coach tab expander
- **PromptManager + SafetyLayer (P2, WP-21)** — user-editable base prompt + immutable safety suffix (non-medical disclaimer, no-diagnosis/no-ECG-AFib rule with clinician redirect — ⚠️ wording needs human review, see progress.md), append-only version history with value-snapshot returns — the effective prompt drives WP-25 chat instructions (editor UI is WP-26)
- **AvailabilityGate + CoachSession (P2, WP-22)** — on-device availability states with user copy + fallback, `CoachSession` seam over `LanguageModelSession` (incremental-delta streaming, cancellation-safe, observable busy flag), single purpose-driven session factory (cached conversation, fresh one-shots) — drives WP-25 chat

Architected, not yet built (see [Status & Roadmap](#status--roadmap) below):

- The rest of the on-device AI coach — model tiers, prompt editor, and the rest of the surfaces below
- Private Cloud Compute / Claude / Gemini model tiers, prompt editor, chat UI polish (WP-30 full context view)

## Technology Stack

| Layer | Framework |
| --- | --- |
| UI | SwiftUI (`@Observable`, Approachable Concurrency, default `@MainActor`) |
| Data | SwiftData (`SyncState`, `LocalSample`, chat/knowledge models) |
| Health | HealthKit (reads for de-dup, writes for synced samples/workouts) |
| Device sync source | Google Health API (`health.googleapis.com/v4`) via OAuth 2.0 + PKCE |
| Secrets | Keychain (`kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`) |
| Background work | BGTaskScheduler (`BGAppRefreshTask`) |
| On-device AI | Foundation Models framework (`LanguageModelSession`, `SystemLanguageModel`), planned |
| Apple cloud AI | `PrivateCloudComputeLanguageModel` — free server model on Private Cloud Compute (Small Business Program), planned |
| BYO-key cloud AI | Claude via Anthropic's official `ClaudeForFoundationModels` package, Gemini via Firebase — both through the iOS 27 `LanguageModel` protocol, opt-in, planned |
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
HealthLoomUITests/        XCUITest — onboarding, dashboard, activities, today, coach chat, and prompt editor flows
Design/                  Yacht club design system reference (HTML + SwiftUI mockups)
```

## Testing

CI runs a per-package `swift test -Xswiftc -warnings-as-errors` matrix, then generates
the Xcode project via `xcodegen` and runs `xcodebuild build test` for the `HealthLoom`
scheme on an iOS Simulator — warnings fail the build in both stages. `make test` runs
the same package-by-package `swift test` + build locally; `make xcode` regenerates and
opens the project.

```bash
xcodegen generate                                     # regenerate HealthLoom.xcodeproj from project.yml
swift test --package-path Packages/SyncKit            # run a single package's tests
xcodebuild test -project HealthLoom.xcodeproj \
  -scheme HealthLoom -destination 'platform=iOS Simulator,name=iPhone 17'
```

| Package | Tests | Coverage |
| --- | --- | --- |
| CoreModel | 22 | SwiftData model relationships, defaults, Codable value types, shared exercise-payload decoding, health-context data framing + shared prompt composer |
| Secrets | 14 | Keychain read/write/delete round-trip, accessibility attribute, missing-item handling |
| GoogleHealthClient | 35 | OAuth PKCE flow, token refresh, `reconcile`/`dailyRollup` decoding against real-shaped fixtures, retry/backoff |
| SyncKit | 260 | `TypeMapper` golden files per data type + rejection rules, `SyncEngine` idempotency/cursor/lookback, `HealthKitWriter` batched existence diff, backfill chunking/checkpointing, background scheduling, sync log redaction, `WatchCoverageIndex`/`ConflictResolver` (D13) |
| CoachKit | 173 | `KnowledgeStore` derivation math (steps/HR/HRV/sleep/workouts), correction pinning, clinical-field exclusion, HealthKit read-store adapter, refresh throttle, reentrancy, tool-facing summary window clamping, `ContextAssembler` trimming/snapshot retention, `PromptManager` history + suffix ordering, `AvailabilityGate` mapping, session lifecycle identities, cumulative-to-delta streaming, `ReadinessEngine` golden vectors + monotonicity, `DailyInsight` prompt/generator seam, coach tools wiring + clamping + exclusion gating, `ModelCatalog` gating truth table + tier budgets, `CoachError` normalization + sanitizer, orchestrator suffix/snapshot/escalation/`didTrim` (173 beta / 171 stable — 2 tests need the 27 SDK) |
| HealthLoomTests | 67 | App-target unit tests — Today metrics/formatting, Activities consolidation, watch-priority preferences, coach chat view-model + launch matrix, prompt editor + diff engine + review rounds |
| **HealthLoomUITests** | **8 (1 self-skipped)** | **XCUITest: onboarding (skips on this runner's HealthKit-sheet limitation), dashboard sync states, consolidated activities, Today edit mode, coach chat stream + persistence + unavailable state, prompt edit + preview + reset + restore** |

Verified 2026-09-01 (most recently, after the round-2 code review fixes below): full
`make test` (all package suites + `xcodebuild build test`) passes on both this repo's
toolchains (Xcode 27 beta and, for the package matrix, Xcode 26.4.1) with zero warnings
and zero failures.

## Requirements

- iOS 27 or later
- Xcode 27 beta or later, on an Apple Silicon Mac (to build from source). In CI, the
  app-scheme job runs on GitHub's `xcode-27` preview runner image (Xcode 27 beta,
  iOS 27 simulators); the package `swift test` jobs run on `macos-26` with Xcode 26.x
  (the manifests deliberately stay at `swift-tools-version: 6.2`) — see the Toolchain
  note in [implementation-plan.md](implementation-plan.md)
- [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`) — `project.yml` is the source of truth; the `.xcodeproj` is not committed
- A Google Cloud OAuth client for the Google Health API (see [google-health-healthkit-base-knowledge.md](google-health-healthkit-base-knowledge.md))

## Status & Roadmap

P0 (foundations + first vertical slice), P1 (full sync, including WP-12b's watch-priority
conflict resolution), and WP-33 (Today view, pulled forward from P4) are implemented —
see [progress.md](progress.md) for the per-work-package build log. Remaining phases, in
order, per [implementation-plan.md](implementation-plan.md):

- **P2** — on-device AI coach: `KnowledgeStore` (WP-19), `ContextAssembler` (WP-20), `PromptManager`/`SafetyLayer` (WP-21), `AvailabilityGate`/`CoachSession` (WP-22), and `ReadinessEngine`/`DailyInsight` (WP-23), and coach tools (WP-24) are implemented; the chat UI (WP-25) is implemented
- **P3** — off-device model tiers (Private Cloud Compute / Claude / Gemini), consent +
  key management, coach evals on Apple's Evaluations framework
- **P4 remainder** — scheduled insights/notifications, export/deletion, optional
  Siri/Spotlight App Intents, accessibility & localization pass, launch checklist

**Outstanding human prerequisites (implementation-plan.md Phase P-1), not yet done:**
a real Google Cloud OAuth client (P-1.3) — every sync-pipeline test so far runs against
fixtures only, never a real account — plus the Google OAuth verification process (P-1.4)
and the Private Cloud Compute entitlement application (P-1.5), both called out in the
plan as launch long poles to start on day one.

## License

This project is licensed under the [MIT License](LICENSE).
