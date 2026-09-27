# Base Knowledge: Google Health API ↔ Apple HealthKit

> Reference document for building an iOS app that syncs Fitbit/Pixel data (via Google Health API) into Apple HealthKit.
> Last verified: June 2026. Both platforms are evolving — re-verify the data-types tables before a production build.

---

## 1. Platform landscape (read this first)

There are **two separate "Google health" surfaces**, and only one is reachable from iOS:

| Platform | What it is | Reachable from iOS? |
|---|---|---|
| **Health Connect** | Google's on-device health datastore. Android-only API. | ❌ No |
| **Google Health API** (`health.googleapis.com/v4/`) | Cloud REST API; successor to the Fitbit Web API. Exposes Fitbit / Pixel Watch / Fitbit Air data via Google OAuth 2.0. | ✅ Yes (any platform) |
| **Google Fit REST API** (legacy) | Deprecated. Supported only until **end of 2026**. | (don't build on it) |

**Key dates**
- Fitbit Web API sunsets **September 2026**. OAuth tokens do **not** carry over — every user must re-consent via Google OAuth.
- Google Fit (incl. REST API) sunset **end of 2026**.
- The Fitbit app was rebranded to **Google Health** (May 19, 2026). The **Fitbit Air** (screenless tracker, launched May 2026; tracks HR, HRV, SpO₂, AFib, resting HR, sleep stages) is iOS-compatible and syncs into this ecosystem.

**Critical scope note:** All Google Health API scopes are **Restricted** → require a Google privacy/security review and OAuth app verification (verified domain, live homepage, per-scope written justification) before production.

---

## 2. Google Health API essentials

- **Base URL:** `https://health.googleapis.com/v4/`
- **Auth:** Google OAuth 2.0. Scopes are HTTP URLs of the form
  `https://www.googleapis.com/auth/googlehealth.{scope}` — e.g.
  `…/googlehealth.activity_and_fitness.writeonly`.
  Read and write are **separate** scopes (`.readonly` / `.writeonly`).
- **Protocols:** REST + gRPC. Client libraries published under the Google APIs GitHub project.
- **Resource pattern:** `users/me/dataTypes/{dataType}/dataPoints`
- **Identifier casing:** kebab-case in endpoints (`body-fat`), snake_case in filters (`body_fat`).

### Endpoint methods (per data type)
- `list` — raw data points
- `get` — single point
- `reconcile` — **merged, de-duplicated** stream across multiple sources (e.g. Pixel Watch + Fitbit Air). Use this before writing to HealthKit to avoid double-counting.
- `rollup` / `dailyRollup` — aggregated; `dailyRollup` stitches days correctly across DST/time-zone travel.
- `create` / `update` / `batchDelete` — write operations (only on writable types).

### Data behavior gotchas
- **Not real-time.** Fitbit devices sync only through the Fitbit/Google Health app — typically every ~15 min while the app is open. The API reflects data only after that sync.
- **No common schema with old Fitbit API** — zero overlapping field paths. Each point is a typed union member named for its data type (see *Wire format* below), with `dataSource` on listed points only.
- **Odd base units** — e.g. distances in **millimeters** for precision. Normalize on ingest.
- **Intraday / high-frequency** data was still rolling out mid-2026; some metrics may only be available as daily rollups initially.

### Wire format (verified 2026-09-27 against the published v4 reference)

HealthLoom's first real sync returned 404 for every type because the client was built on
an assumed flat shape. The published reference
(developers.google.com/health/reference/rest/v4) says:

- **Reads are `GET` with an empty body.**
  - Reconcile: `GET v4/users/me/dataTypes/{kebab-type}/dataPoints:reconcile`.
  - List: the same path without `:reconcile`.
  - Query parameters: `filter`, `pageSize`, `pageToken`, and optionally `dataSourceFamily`.
- **`filter` is AIP-160** with a snake_case type prefix. Its field depends on how the type
  records time:
  - interval types: `steps.interval.start_time`;
  - instant samples: `weight.sample_time.physical_time`;
  - daily summaries: `daily_resting_heart_rate.date` (`YYYY-MM-DD`);
  - sessions: `exercise.interval.civil_start_time`;
  - sleep: filtered on `sleep.interval.end_time`;
  - ECG: only `electrocardiogram.interval.start_time >=`.

  Example: `steps.interval.start_time >= "2026-07-01T00:00:00Z" AND steps.interval.start_time < "2026-07-02T00:00:00Z"`.
- **Response:** `{ "dataPoints": [...], "nextPageToken": "..." }`. Each point is
  `{ "dataPointName": "...", "<camelType>": {...} }`, for example
  `"heartRate": { "sampleTime": { "physicalTime": ... }, "beatsPerMinute": "72" }`.
  - **Reconciled points have no `dataSource`.**
  - **`dataPointName` is empty for most types**, so derive a stable ID.
  - Listed points carry `name` and `dataSource`.
- **Whole numbers arrive as strings** (`"count": "482"`). Units live in field names:
  `weightGrams`, `millimeters`, `heightMillimeters`, `kcal`, `temperatureCelsius`,
  `bloodGlucoseMilligramsPerDeciliter`, `amountConsumed.milliliters`.
- **Page size:** at most 25 for exercise and sleep, and 10,000 for everything else.
- **Not every type can be reconciled.** ECG, irregular-rhythm notifications and food are
  list-only. Total calories and calories-in-heart-rate-zone exist only as roll-ups, and
  `food` is a catalogue entry, not a time series.
- Sleep stages are `stages[{startTime, endTime, type}]`, with `type` one of AWAKE, LIGHT,
  DEEP, REM, ASLEEP or RESTLESS. Exercise carries `exerciseType` (180+ enum values),
  `displayName` and `metricsSummary` (`distanceMillimeters`, `caloriesKcal`, …).

`Packages/GoogleHealthClient/.../GoogleDataTypeSchema.swift` holds the per-type table.

---

## 3. Google Health API data types (full table)

`I` = Interval, `S` = Sample, `D` = Daily, `Se` = Session, `F` = Food.
"Write" = supports `create`/`update`/`batchDelete`.

| Data type | Record | Read ops | Write? | Scope |
|---|---|---|---|---|
| Active Energy Burned | I | list, reconcile, rollup, dailyRollup | — | activity_and_fitness |
| Active Minutes | I | list, reconcile, rollup, dailyRollup | — | activity_and_fitness |
| Active Zone Minutes | I | list, reconcile, rollup, dailyRollup | — | activity_and_fitness |
| Activity Level | I | list, reconcile | — | activity_and_fitness |
| Altitude | I | list, reconcile, rollup, dailyRollup | — | activity_and_fitness |
| Blood Glucose | S | list, get, reconcile, rollup, dailyRollup | — | health_metrics_and_measurements |
| **Body Fat** | S | list, get, reconcile, rollup, dailyRollup | ✅ | health_metrics_and_measurements |
| Calories In Heart Rate Zone | I | rollup, dailyRollup | — | activity_and_fitness |
| Core Body Temperature | S | list, get, reconcile, rollup, dailyRollup | — | health_metrics_and_measurements |
| Daily Heart Rate Variability | D | list, reconcile | — | health_metrics_and_measurements |
| Daily Heart Rate Zones | D | list, reconcile | — | health_metrics_and_measurements |
| Daily Oxygen Saturation | D | list, reconcile | — | health_metrics_and_measurements |
| Daily Respiratory Rate | D | list, reconcile | — | health_metrics_and_measurements |
| Daily Resting Heart Rate | D | list, reconcile | — | health_metrics_and_measurements |
| Daily Sleep Temperature Derivations | D | list, reconcile | — | health_metrics_and_measurements |
| Daily VO2 Max | D | list, reconcile | — | activity_and_fitness |
| Distance | I | list, reconcile, rollup, dailyRollup | — | activity_and_fitness |
| Electrocardiogram (ECG) | Se | list | — | ecg |
| **Exercise** | Se | list, get, reconcile | ✅ | activity_and_fitness |
| Floors | I | reconcile, rollup, dailyRollup | — | activity_and_fitness |
| Food | F | list, get | — | nutrition |
| Food Measurement Unit | F | list, get | — | nutrition |
| Heart Rate | S | list, reconcile, rollup, dailyRollup | — | health_metrics_and_measurements |
| Heart Rate Variability | S | list, reconcile | — | health_metrics_and_measurements |
| **Height** | S | list, get, reconcile | ✅ | health_metrics_and_measurements |
| **Hydration Log** | Se | list, get, reconcile, rollup, dailyRollup | ✅ | nutrition |
| Irregular Rhythm Notification | Se | list | — | irn |
| **Nutrition Log** | S | list, get, reconcile, rollup, dailyRollup | ✅ | nutrition |
| Oxygen Saturation | S | list, reconcile | — | health_metrics_and_measurements |
| Respiratory Rate Sleep Summary | S | list, reconcile | — | health_metrics_and_measurements |
| Run VO2 Max | S | list, reconcile, rollup, dailyRollup | — | activity_and_fitness |
| Sedentary Period | I | list, reconcile, rollup, dailyRollup | — | activity_and_fitness |
| **Sleep** | Se | list, get, reconcile | ✅ | sleep |
| Steps | I | list, reconcile, rollup, dailyRollup | — | activity_and_fitness |
| Swim Lengths Data | I | list, reconcile, rollup, dailyRollup | — | activity_and_fitness |
| Time in Heart Rate Zone | I | list, reconcile, rollup, dailyRollup | — | activity_and_fitness |
| Total Calories | I | rollup, dailyRollup | — | activity_and_fitness |
| VO2 Max | S | list, reconcile | — | activity_and_fitness |
| **Weight** | S | list, get, reconcile, rollup, dailyRollup | ✅ | health_metrics_and_measurements |

> For a sync-to-HealthKit app, **read** coverage is what matters — and every type supports a read op. Google-side write ops are only relevant if you also push data back into the user's Fitbit/Google account.

---

## 4. Apple HealthKit essentials

- **Framework:** HealthKit. Central object: `HKHealthStore`. On-device only.
- **Permissions:** Per-type, and **read/write are independent**. The app cannot tell whether the user denied read access (privacy design) — code defensively.
- **Sample model:** `HKQuantitySample`, `HKCategorySample`, `HKCorrelation`, `HKWorkout`. Samples are **immutable**.
- **Provenance:** Anything you write is attributed to **your app** as the source, not the original Fitbit device. Tag samples with `HKMetadataKey…` (e.g. a custom `sourceDevice` / external UUID) so you can dedupe and delete-by-source later.
- **Background delivery:** `HKObserverQuery` + `enableBackgroundDelivery` for reacting to new HealthKit data; not needed for the inbound Google→HealthKit direction but useful for the AI layer.

### Read-only in HealthKit (cannot write)
- **ECG** (`HKElectrocardiogram`) — raw ECG cannot be written via the public API.
- **Apple Exercise Time / Stand Time** — system-computed, read-only.
- Various clinical record types.

---

## 5. Mapping: Google Health API → HealthKit write targets

Binding constraint = whether HealthKit accepts a **write** for the matching type (all Google types read fine).

| Google Health type | HealthKit identifier | Works? | Notes |
|---|---|---|---|
| Steps | `stepCount` | ✅ | |
| Distance | `distanceWalkingRunning` | ✅ | Convert mm → m |
| Floors | `flightsClimbed` | ✅ | |
| Active Energy Burned / Total Calories | `activeEnergyBurned` / `basalEnergyBurned` | ✅ | Google gives single total; split if needed |
| Heart Rate | `heartRate` | ✅ | |
| Daily Resting Heart Rate | `restingHeartRate` | ✅ | |
| Heart Rate Variability | `heartRateVariabilitySDNN` | ✅ | |
| Oxygen Saturation (SpO₂) | `oxygenSaturation` | ✅ | |
| Respiratory Rate | `respiratoryRate` | ✅ | |
| VO₂ Max / Run VO₂ Max | `vo2Max` | ✅ | |
| Weight | `bodyMass` | ✅ | |
| Height | `height` | ✅ | |
| Body Fat | `bodyFatPercentage` | ✅ | |
| Blood Glucose | `bloodGlucose` | ✅ | |
| Core Body Temperature | `bodyTemperature` | ✅ | |
| Sleep | `sleepAnalysis` (category) | ✅ | Map Google sleep stages → HK stages |
| Exercise | `HKWorkout` | ✅ | Map Google exercise type → `HKWorkoutActivityType` (~13 Google types are coarse) |
| Hydration Log | `dietaryWater` | ✅ | |
| Food / Nutrition Log | `dietaryEnergyConsumed`, protein, carbs, fat… | ✅ | Build `HKCorrelation` per meal |
| Active Minutes / Active Zone Minutes | `appleExerciseTime` (**read-only**) | ⚠️ | No writable target; store as workout/metadata or app-local only |
| Electrocardiogram (ECG) | `HKElectrocardiogram` (**read-only**) | ❌ | Cannot reconstruct in Apple Health |
| Irregular Rhythm Notification | event-only | ⚠️ | Limited; keep app-local |

### Sync rules of thumb
1. Pull from Google using **`reconcile`** (already de-duplicated across Pixel Watch + Fitbit Air).
2. Normalize units (mm→m, etc.).
3. Stamp each HealthKit sample with the Google data-point UUID in metadata for idempotent re-sync.
4. Skip ❌ types; surface ⚠️ types in-app only with a clear "not written to Apple Health" label.
5. HealthKit samples are immutable → to "update," delete-by-metadata then re-insert.
