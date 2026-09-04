// TokenEstimation.swift
//
// Shared byte-to-token estimator (WP-27 review R4): `PromptManager` and
// `ContextAssembler` shared the UTF-8-bytes/4-rounded-up rule but each
// carried its own `+3)/4` copy, with both comments claiming to be the
// canonical one. One function; the two call-shape wrappers
// (`estimatedTokens(for:)` per type) keep their exact formulas -- only the
// rounding step is shared, so no token math changes in this move.

/// Rounds a UTF-8 byte count up to whole tokens at ~4 bytes/token.
/// Internal: callers use the `estimatedTokens(for:)` wrappers per type.
func bytesToTokens(_ bytes: Int) -> Int {
    (bytes + 3) / 4
}
