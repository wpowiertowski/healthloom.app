// SyncEngine+BackfillBusyProbe.swift
//
// WP-15 (implementation-plan.md) step 2. Zero-code conformance -- mirrors
// `GoogleHealthClient+SyncEngine.swift`'s own "the real type already matches
// the protocol shape exactly" pattern (WP-09's own precedent for this exact
// situation). `SyncEngine.claimForBackfill(_:)` / `releaseBackfillClaim(_:)`
// (SyncEngine.swift; a read-only `isBusy` probe until WP-58) already
// satisfy `BackfillBusyProbe` (BackfillTypes.swift) verbatim.
//
// Lives in `Backfill/`, not `SyncEngine/`, so this WP's footprint inside the
// concurrently-edited `SyncEngine/` folder stays limited to the one method
// added directly to `SyncEngine.swift` -- everything else new lives here,
// in this WP's own folder.
//
// Guarded identically to `SyncEngine.swift` itself: `SyncEngine` only exists
// under `#if canImport(HealthKit)`.
#if canImport(HealthKit)
extension SyncEngine: BackfillBusyProbe {}
#endif
