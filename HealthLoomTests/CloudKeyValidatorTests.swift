// CloudKeyValidatorTests.swift
//
// WP-29 (implementation-plan.md): the 1-token ping mapping -- 2xx valid,
// provider rejection invalid, any other answer refused with its reason and
// the provider's message, no answer a transport error; never "invalid key"
// unless the provider said so. Stubbed at the `URLProtocol` layer so no
// test touches the network.

import CoachKit
import Foundation
import Testing

@testable import HealthLoom

// WP-29 F7: serialized — `StubTransport.next`/`nextBody` are shared
// mutable statics and Swift Testing runs cases in parallel by default.
@Suite(.serialized)
struct CloudKeyValidatorTests {
    /// One canned response (or throw) for every request.
    private final nonisolated class StubTransport: URLProtocol, @unchecked Sendable {
        nonisolated(unsafe) static var next: Result<HTTPURLResponse, Error>?
        /// Canned body for the next response (WP-29 F5: Gemini 400s only
        /// count as invalid-key when the body names `API_KEY_INVALID`).
        nonisolated(unsafe) static var nextBody: Data = Data()
        /// Outgoing request body of the last intercepted call (third-party
        /// F10: lets the wire-format test decode what was actually sent).
        nonisolated(unsafe) static var lastRequestBody: Data?

        nonisolated override class func canInit(with request: URLRequest) -> Bool { true }
        nonisolated override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

        nonisolated override func startLoading() {
            // URLSession may relocate a Data body onto httpBodyStream by
            // the time a protocol sees it — capture both forms.
            if let body = request.httpBody {
                Self.lastRequestBody = body
            } else if let stream = request.httpBodyStream {
                stream.open()
                defer { stream.close() }
                var data = Data()
                var buffer = [UInt8](repeating: 0, count: 4096)
                while stream.hasBytesAvailable {
                    let count = stream.read(&buffer, maxLength: buffer.count)
                    if count <= 0 { break }
                    data.append(buffer, count: count)
                }
                Self.lastRequestBody = data
            } else {
                Self.lastRequestBody = nil
            }
            guard let next = Self.next else {
                client?.urlProtocol(self, didFailWithError: URLError(.unknown))
                return
            }
            switch next {
            case .success(let response):
                client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
                client?.urlProtocol(self, didLoad: Self.nextBody)
                client?.urlProtocolDidFinishLoading(self)
            case .failure(let error):
                client?.urlProtocol(self, didFailWithError: error)
            }
        }

        nonisolated override func stopLoading() {}
    }

    private func validator(statusCode: Int, body: Data = Data()) -> LiveCloudKeyValidator {
        StubTransport.nextBody = body
        StubTransport.next = .success(HTTPURLResponse(
            url: URL(string: "https://example.com")!,
            statusCode: statusCode,
            httpVersion: nil,
            headerFields: nil
        )!)
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubTransport.self]
        return LiveCloudKeyValidator(session: URLSession(configuration: config))
    }

    private func failingValidator() -> LiveCloudKeyValidator {
        StubTransport.nextBody = Data()
        StubTransport.next = .failure(URLError(.notConnectedToInternet))
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubTransport.self]
        return LiveCloudKeyValidator(session: URLSession(configuration: config))
    }

    @Test("200 validates for both providers")
    func valid() async {
        #expect(await validator(statusCode: 200).validate(key: "k", for: .claude) == .valid)
        #expect(await validator(statusCode: 200).validate(key: "k", for: .gemini) == .valid)
    }

    @Test("provider rejections map to invalidKey (401 Anthropic, 400 Gemini)")
    func invalidKey() async {
        #expect(await validator(statusCode: 401).validate(key: "k", for: .claude) == .invalidKey)
        // WP-29 F5: a Gemini 400 only rejects when the body names the key.
        let apiKeyInvalid = Data(#"{"error": {"code": 400, "status": "INVALID_ARGUMENT", "details": [{"reason": "API_KEY_INVALID"}]}}"#.utf8)
        #expect(await validator(statusCode: 400, body: apiKeyInvalid).validate(key: "k", for: .gemini) == .invalidKey)
    }

    /// The refusal a response produced, or nil (recorded) for any other result.
    private func refusal(_ result: CloudKeyValidation) -> KeyCheckRefusal? {
        guard case .refused(let refusal) = result else {
            Issue.record("expected .refused, got \(result)")
            return nil
        }
        return refusal
    }

    private func anthropicError(type: String, message: String) -> Data {
        let body: [String: Any] = ["type": "error", "error": ["type": type, "message": message]]
        return (try? JSONSerialization.data(withJSONObject: body)) ?? Data()
    }

    @Test("a Gemini 400 without API_KEY_INVALID is refused with Google's message, not invalidKey")
    func geminiBareBadRequestIsRefused() async {
        let disabledAPI = Data(#"{"error": {"code": 400, "message": "API disabled"}}"#.utf8)
        let result = await validator(statusCode: 400, body: disabledAPI).validate(key: "k", for: .gemini)
        guard let refused = refusal(result) else { return }
        #expect(refused.reason == .other)
        #expect(refused.detail == "API disabled")
        let emptyResult = await validator(statusCode: 400).validate(key: "k", for: .gemini)
        #expect(refusal(emptyResult)?.detail == nil)
    }

    @Test("an Anthropic 400 for an empty credit balance is a billing refusal, not a transport error")
    func anthropicLowCreditIsBilling() async {
        let message = "Your credit balance is too low to access the Anthropic API."
        let body = anthropicError(type: "invalid_request_error", message: message)
        let result = await validator(statusCode: 400, body: body).validate(key: "k", for: .claude)
        guard let refused = refusal(result) else { return }
        #expect(refused.reason == .billing)
        #expect(refused.statusCode == 400)
        #expect(refused.detail == message)
    }

    @Test("status codes and error types map to their refusal reasons", arguments: [
        (402, "billing_error", KeyCheckRefusal.Reason.billing),
        (403, "permission_error", .permission),
        (404, "not_found_error", .modelUnavailable),
        (429, "rate_limit_error", .rateLimited),
        (500, "api_error", .providerOutage),
        (529, "overloaded_error", .providerOutage),
        (400, "invalid_request_error", .other),
    ])
    func reasonByStatus(statusCode: Int, type: String, reason: KeyCheckRefusal.Reason) async {
        let body = anthropicError(type: type, message: "m")
        let result = await validator(statusCode: statusCode, body: body).validate(key: "k", for: .claude)
        #expect(refusal(result)?.reason == reason)
    }

    @Test("a 429/500 is never an invalid-key verdict")
    func serverErrorIsNotInvalidKey() async {
        let claude = await validator(statusCode: 429).validate(key: "k", for: .claude)
        #expect(refusal(claude)?.reason == .rateLimited)
        let gemini = await validator(statusCode: 500).validate(key: "k", for: .gemini)
        #expect(refusal(gemini)?.reason == .providerOutage)
    }

    @Test("the provider message is one bounded line; a body without one gives no detail")
    func detailIsSanitized() {
        let long = "first line\n\n  second\tline " + String(repeating: "x", count: 500)
        let refusal = KeyCheckRefusal(statusCode: 400, body: anthropicError(type: "invalid_request_error", message: long))
        let detail = refusal.detail ?? ""
        #expect(detail.hasPrefix("first line second line x"))
        let hasNewline = detail.contains { $0.isNewline }
        #expect(!hasNewline)
        #expect(detail.count == KeyCheckRefusal.maxDetailLength)
        #expect(detail.hasSuffix("…"))
        #expect(KeyCheckRefusal(statusCode: 502, body: Data("<html>Bad gateway</html>".utf8)).detail == nil)
        #expect(KeyCheckRefusal(statusCode: 400, body: anthropicError(type: "invalid_request_error", message: " \n ")).detail == nil)
    }

    @Test("Claude ping body admits no tools key (structural, third-party F10)")
    func claudePingBodyHasNoToolsKey() async throws {
        // Direct pin: the type itself encodes (distinguishes a broken
        // Encodable from transport body relocation below).
        let encoded = try JSONEncoder().encode(ClaudeMessageRequest.ping)
        #expect(!encoded.isEmpty)
        #expect(await validator(statusCode: 200).validate(key: "k", for: .claude) == .valid)
        let sent = try #require(StubTransport.lastRequestBody, "ping sent no body")
        let dict = try #require(try JSONSerialization.jsonObject(with: sent) as? [String: Any])
        // Exact key set: any added field (notably "tools") fails here.
        #expect(Set(dict.keys) == ["model", "max_tokens", "messages"])
        #expect(dict["model"] as? String == ClaudeTier.keyCheckModel.id)
        #expect(dict["max_tokens"] as? Int == 1)
        let messages = try #require(dict["messages"] as? [[String: String]])
        #expect(messages == [["role": "user", "content": "ok"]])
    }

    @Test("an offline transport maps to transportError")
    func offlineIsTransport() async {
        let result = await failingValidator().validate(key: "k", for: .claude)
        if case .transportError = result {
        } else {
            Issue.record("expected transportError, got \(result)")
        }
    }
}
