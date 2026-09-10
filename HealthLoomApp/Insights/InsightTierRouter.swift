// InsightTierRouter.swift
//
// WP-34 tier routing for unattended insights (pure). The plan's rule:
// on-device by default; PCC only when the user enabled that tier *and*
// separately opted into "insights via Apple cloud"; BYO-key tiers
// (Claude/Gemini) are chat-only for insights.
//
// The BYO exclusion is structural, not a branch: this function takes no
// BYO-key input at all, so no caller can route an unattended insight to
// a third party — there is no parameter to get wrong (AGENTS.md §2:
// make invalid states unrepresentable; tier-blind code is the bug until
// proven otherwise). The returned tier rides into generation explicitly.

import CoachKit
import Foundation

enum InsightTierRouter {
    /// - Parameters:
    ///   - pccRowOn: the AI-Models row toggle for PCC
    ///     (`TierSettingsStore.isTurnedOn` — rule §15-19). Round-7 item
    ///     2: the catalog input alone served PCC overnight after the
    ///     user switched the row off — every other consumer (chat send)
    ///     ANDs the toggle, and so does this.
    ///   - pccTierEnabled: `catalog.isEnabled(.privateCloudCompute)`
    ///     (consent + availability + live, per the WP-29 gates).
    ///   - viaCloudOptIn: the plan's separate `insightsViaCloud` toggle.
    ///   - onDeviceAvailable: live on-device availability.
    /// - Returns: the serving tier, or nil when nothing may serve.
    static func route(
        pccRowOn: Bool,
        pccTierEnabled: Bool,
        viaCloudOptIn: Bool,
        onDeviceAvailable: Bool
    ) -> ModelTier? {
        if pccRowOn && pccTierEnabled && viaCloudOptIn {
            return .privateCloudCompute
        }
        if onDeviceAvailable {
            return .onDevice
        }
        return nil
    }
}
