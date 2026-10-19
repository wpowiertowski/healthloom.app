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
//     200 = valid; 401 = invalid key; any other status = refused (the
//     provider answered, but not about the key -- a 429/500 or an empty
//     credit balance must not tell the user their key is wrong).
//   - Gemini: GET /v1beta/models?key= (no body, no spend). 200 = valid;
//     400 with API_KEY_INVALID = invalid key; any other status = refused,
//     same rule as above.
// A refusal carries the reason and the provider's own message
// (`KeyCheckRefusal`), so the sheet can say what to fix instead of a bare
// status code. No answer at all (offline, timeout) is a transport error.
// Timeout 15s: validation is user-initiated and foreground, but a hanging
// socket must still lose to the spinner eventually.

import CoachKit
import Foundation

/// Outcome of a key check. Not Bool: "the provider rejected the key", "the
/// provider answered but refused the check for another reason" and "no
/// answer" each need their own copy. Only `.valid` stores.
enum CloudKeyValidation: Sendable, Equatable {
    case valid
    case invalidKey
    /// The provider answered with an error that isn't a verdict on the key
    /// (billing, permissions, rate limit, outage, …).
    case refused(KeyCheckRefusal)
    /// No HTTP answer: offline, timeout, TLS failure, cancellation.
    case transportError(String)
}

/// Why a provider refused a key check it did answer, built from the status
/// code and the error body. Classification and sanitizing happen here, at
/// construction (AGENTS.md §2), so no caller can show a raw multi-line or
/// unbounded provider body.
nonisolated struct KeyCheckRefusal: Sendable, Equatable {
    enum Reason: Sendable, Equatable {
        /// 402 `billing_error`, or Anthropic's 400 "Your credit balance is
        /// too low…" (an `invalid_request_error`, so only its message can
        /// tell it apart).
        case billing
        /// 403: the key's organization or workspace isn't allowed.
        case permission
        /// 404: the check's model isn't available to the key's organization.
        case modelUnavailable
        /// 429.
        case rateLimited
        /// 5xx, including Anthropic's 529 overloaded.
        case providerOutage
        /// Anything else; the provider's message is the only hint.
        case other
    }

    /// Longest provider message shown; longer ones are cut with "…".
    static let maxDetailLength = 200

    let reason: Reason
    let statusCode: Int
    /// The provider's `error.message`, collapsed to one line and capped at
    /// `maxDetailLength`; nil when the body carried none.
    let detail: String?

    init(statusCode: Int, body: Data) {
        // Both providers nest the message as `error.message`; Anthropic
        // adds `error.type`. A body that doesn't decode leaves both nil.
        let error = (try? JSONDecoder().decode(ErrorEnvelope.self, from: body))?.error
        self.statusCode = statusCode
        self.detail = error?.message.flatMap(Self.sanitized)
        self.reason = Self.classify(statusCode: statusCode, type: error?.type, message: error?.message)
    }

    private struct ErrorEnvelope: Decodable {
        struct Body: Decodable {
            var type: String?
            var message: String?
        }

        var error: Body
    }

    private static func classify(statusCode: Int, type: String?, message: String?) -> Reason {
        if type == "billing_error" || message?.localizedCaseInsensitiveContains("credit balance") == true {
            return .billing
        }
        switch statusCode {
        case 402: return .billing
        case 403: return .permission
        case 404: return .modelUnavailable
        case 429: return .rateLimited
        case 500...599: return .providerOutage
        default: return .other
        }
    }

    private static func sanitized(_ message: String) -> String? {
        let oneLine = message.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard !oneLine.isEmpty else { return nil }
        guard oneLine.count > maxDetailLength else { return oneLine }
        return String(oneLine.prefix(maxDetailLength - 1)) + "…"
    }
}

protocol CloudKeyValidating: Sendable {
    func validate(key: String, for tier: ModelTier) async -> CloudKeyValidation
}

/// Model options for the key-gated rows ("model picker where applicable",
/// WP-29). Fixed lists (not free discovery): the picker must render without
/// a valid key, so it can't ask the provider. The stored value is the full
/// provider model ID. Claude's list is the package's model table
/// (`ClaudeTier.models`, WP-85), the same one dispatch resolves against.
enum CloudModelOptions {
    static let claudeDefault = ClaudeTier.defaultModel.id
    static let claudeOptions = ClaudeTier.models.map(\.id)

    static let geminiDefault = "gemini-2.5-flash"
    static let geminiOptions = [
        "gemini-2.5-flash",
        "gemini-2.5-pro",
        "gemini-2.0-flash",
    ]

    /// The model a row shows and a turn dispatches to: the stored override
    /// when the tier still offers it, else the default. A stale override
    /// (a Claude 4.x pick from before WP-85) reads as the default instead of
    /// a value the picker can't select.
    static func resolvedModelID(stored: String?, for tier: ModelTier) -> String? {
        if let stored, options(for: tier).contains(stored) {
            return stored
        }
        return defaultModelID(for: tier)
    }

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

    /// The 1-token ping: cheapest authenticated call, fixed shape, on the
    /// cheapest model (any model proves the key).
    static let ping = ClaudeMessageRequest(
        model: ClaudeTier.keyCheckModel.id,
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
    /// malformed request) with a *valid* key is a refusal, not a verdict.
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
    /// WP-29 F5: any other 400 is not "invalid key"); any other status =
    /// refused, with the body's reason; a throw (offline, timeout,
    /// cancellation) = transport error. Cancellation is never "invalid":
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
            let markerFound = invalidBodyMarker.map {
                (String(data: data, encoding: .utf8) ?? "").contains($0)
            } ?? true
            if markerFound {
                return .invalidKey
            }
        }
        return .refused(KeyCheckRefusal(statusCode: http.statusCode, body: data))
    }
}
