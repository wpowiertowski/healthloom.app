// CloudKeyValidator.swift
//
// WP-29 (implementation-plan.md): "validate with a 1-token ping" -- a key
// is only written to the Keychain after the provider accepted it, so a
// pasted-wrong key surfaces as "invalid key" at entry time instead of a
// red sync row on every later turn.
//
// `CloudKeyValidating` is the seam: the view model talks to the protocol,
// tests inject a stub deciding per key, and the app wires `LiveCloudKeyValidator`
// (real HTTPS, injectable `URLSession` so its own tests stub the transport
// via `URLProtocol`). Both pings are the cheapest authenticated call each
// provider offers:
//   - Anthropic: POST /v1/messages with `max_tokens: 1` (one output token).
//     200 = valid; 401 = invalid key; anything else = inconclusive
//     (treated as a transport error, NOT "invalid" -- a 429/500 must not
//     tell the user their key is wrong).
//   - Gemini: GET /v1beta/models?key= (no body, no spend). 200 = valid;
//     400 with API_KEY_INVALID = invalid key; anything else = transport
//     error, same rule as above.
// Timeout 15s: validation is user-initiated and foreground, but a hanging
// socket must still lose to the spinner eventually.

import CoachKit
import Foundation

/// Outcome of a key check. Three cases (not Bool): "the provider rejected
/// the key" and "the network failed" need different copy AND different
/// behavior (only `.invalidKey` is a reason to refuse storing).
enum CloudKeyValidation: Sendable, Equatable {
    case valid
    case invalidKey
    case transportError(String)
}

protocol CloudKeyValidating: Sendable {
    func validate(key: String, for tier: ModelTier) async -> CloudKeyValidation
}

/// Model options for the key-gated rows ("model picker where applicable",
/// WP-29). Fixed lists (not free discovery): the picker must render without
/// a valid key, so it can't ask the provider. The stored value is the full
/// provider model ID -- the ping and (later) dispatch use it verbatim.
enum CloudModelOptions {
    static let claudeDefault = "claude-haiku-4-5-20251001"
    static let claudeOptions = [
        "claude-haiku-4-5-20251001",
        "claude-sonnet-4-5-20250929",
        "claude-opus-4-1-20250805",
    ]

    static let geminiDefault = "gemini-2.5-flash"
    static let geminiOptions = [
        "gemini-2.5-flash",
        "gemini-2.5-pro",
        "gemini-2.0-flash",
    ]

    /// Default when no override is stored. Non-key-gated tiers have no
    /// selectable model (their rows render no picker).
    static func defaultModelID(for tier: ModelTier) -> String? {
        switch tier {
        case .claude: claudeDefault
        case .gemini: geminiDefault
        case .onDevice, .privateCloudCompute: nil
        }
    }

    static func options(for tier: ModelTier) -> [String] {
        switch tier {
        case .claude: claudeOptions
        case .gemini: geminiOptions
        case .onDevice, .privateCloudCompute: []
        }
    }
}

/// Deterministic validator for tests: unit tests inject per-case
/// results through `AIModelsViewModel` (valid/invalid/transport), and the
/// AI Models UI-test scenario returns one fixed result for every key so
/// the save/delete flows run without network.
struct StubCloudKeyValidator: CloudKeyValidating {
    var result: CloudKeyValidation

    func validate(key: String, for tier: ModelTier) async -> CloudKeyValidation {
        result
    }
}

/// The Claude key-validation ping body as a type, not a dictionary
/// (third-party F10, structural rule): the ping is chat-only with no tool
/// use, and a `[String: Any]` body would admit a `"tools"` entry without
/// the compiler noticing. With this struct the server-side tool wire
/// types (`web_search_20250305`, `code_execution_*`, …) are
/// unrepresentable — there is no field for them to live in, and the
/// wire-format test below fails on any extra key.
struct ClaudeMessageRequest: Encodable, Sendable {
    struct Message: Encodable, Sendable {
        var role: String
        var content: String
    }

    var model: String
    var messages: [Message]
    var maxTokens: Int

    enum CodingKeys: String, CodingKey {
        case model
        case messages
        case maxTokens = "max_tokens"
    }

    /// The 1-token ping: cheapest authenticated call, fixed shape.
    static let ping = ClaudeMessageRequest(
        model: CloudModelOptions.claudeDefault,
        messages: [Message(role: "user", content: "ok")],
        maxTokens: 1
    )
}

struct LiveCloudKeyValidator: CloudKeyValidating {
    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    func validate(key: String, for tier: ModelTier) async -> CloudKeyValidation {
        switch tier {
        case .claude:
            await validateClaude(key: key)
        case .gemini:
            await validateGemini(key: key)
        case .onDevice, .privateCloudCompute:
            // No key exists for these tiers; validating is a programming
            // error, and failing loudly beats storing nothing silently.
            preconditionFailure("No API key to validate for \(tier).")
        }
    }

    /// Body snippet that must accompany a 400 for it to count as a key
    /// rejection on Gemini (WP-29 F5). A bare 400 (disabled API,
    /// malformed request) with a *valid* key is a transport error.
    private static let geminiInvalidKeyMarker = "API_KEY_INVALID"

    private func validateClaude(key: String) async -> CloudKeyValidation {
        var request = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
        request.httpMethod = "POST"
        request.setValue(key, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.timeoutInterval = 15
        request.httpBody = try? JSONEncoder().encode(ClaudeMessageRequest.ping)
        return await perform(request, invalidStatusCodes: [401], invalidBodyMarker: nil)
    }

    private func validateGemini(key: String) async -> CloudKeyValidation {
        var components = URLComponents(string: "https://generativelanguage.googleapis.com/v1beta/models")!
        components.queryItems = [URLQueryItem(name: "key", value: key)]
        var request = URLRequest(url: components.url!)
        request.httpMethod = "GET"
        request.timeoutInterval = 15
        return await perform(
            request,
            invalidStatusCodes: [400],
            invalidBodyMarker: Self.geminiInvalidKeyMarker
        )
    }

    /// 2xx = valid; listed status = the provider rejected the credential
    /// (when `invalidBodyMarker` is set, the body must also contain it —
    /// WP-29 F5: any other 400 is inconclusive, not "invalid key");
    /// anything else (5xx, 429, transport throw, cancellation) =
    /// inconclusive. Cancellation maps to transport-error (not invalid):
    /// the sheet's Task is cancelled on dismiss, and a dismiss must never
    /// rewrite the key field's error to "invalid key".
    private func perform(
        _ request: URLRequest,
        invalidStatusCodes: Set<Int>,
        invalidBodyMarker: String?
    ) async -> CloudKeyValidation {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            return .transportError(error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else {
            return .transportError("Non-HTTP response.")
        }
        if (200..<300).contains(http.statusCode) {
            return .valid
        }
        if invalidStatusCodes.contains(http.statusCode) {
            if let marker = invalidBodyMarker {
                let body = String(data: data, encoding: .utf8) ?? ""
                guard body.contains(marker) else {
                    return .transportError("HTTP \(http.statusCode).")
                }
            }
            return .invalidKey
        }
        return .transportError("HTTP \(http.statusCode).")
    }
}
