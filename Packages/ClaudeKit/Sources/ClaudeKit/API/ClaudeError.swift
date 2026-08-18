//
//  ClaudeError.swift
//  ClaudeKit
//

import Foundation

/// Every way a Messages API call can fail, typed so callers can branch on the
/// ones that matter (a missing key needs a settings prompt, a 429 needs a
/// backoff banner, a refusal needs a different UI entirely).
public enum ClaudeError: Error, Sendable, Equatable {

    /// No API key in the keychain. The user has to add one.
    case missingAPIKey

    /// 401 — the key is wrong or revoked.
    case unauthorized(APIErrorPayload?)

    /// 403 — the key is valid but not permitted to do this.
    case permissionDenied(APIErrorPayload?)

    /// 404 — usually a model id that doesn't exist for this account.
    case notFound(APIErrorPayload?)

    /// 413 — request body too large. For us that means too many moments or
    /// PVs that weren't truncated; retrying unchanged cannot help.
    case requestTooLarge(APIErrorPayload?)

    /// 429 — rate limited. `retryAfter` is the `retry-after` header in seconds
    /// when the server sent one.
    case rateLimited(retryAfter: TimeInterval?, payload: APIErrorPayload?)

    /// 5xx — server side, retryable.
    case serverError(status: Int, payload: APIErrorPayload?)

    /// Any other non-2xx status.
    case httpError(status: Int, payload: APIErrorPayload?)

    /// The body didn't match what we model. The associated value is a
    /// description rather than the underlying error so this stays `Equatable`
    /// and `Sendable`.
    case decodingFailed(String)

    /// `stop_reason == "refusal"`. Deliberately not a "response with empty
    /// content" — the caller must not render a refusal as coaching.
    case refusal(MessageResponse?)

    /// An `error` event arrived mid-stream.
    case streamError(APIErrorPayload)

    /// The connection ended without `message_stop`. The partial text is
    /// unusable for structured output.
    case streamTruncated

    /// URLSession failed before we got a response.
    case transportFailure(String)

    /// Whether a retry could plausibly succeed. 4xx other than 429 never can.
    public var isRetryable: Bool {
        switch self {
        case .rateLimited, .serverError, .transportFailure:
            return true
        case .missingAPIKey, .unauthorized, .permissionDenied, .notFound,
             .requestTooLarge, .httpError, .decodingFailed, .refusal,
             .streamError, .streamTruncated:
            return false
        }
    }

    /// The `retry-after` hint, when the server gave one.
    public var retryAfter: TimeInterval? {
        if case let .rateLimited(retryAfter, _) = self { return retryAfter }
        return nil
    }

    /// Maps an HTTP status and body to the right case. Non-2xx only.
    static func fromHTTP(status: Int, headers: [String: String], body: Data) -> ClaudeError {
        let payload = try? JSONDecoder().decode(APIErrorPayload.self, from: body)

        switch status {
        case 401: return .unauthorized(payload)
        case 403: return .permissionDenied(payload)
        case 404: return .notFound(payload)
        case 413: return .requestTooLarge(payload)
        case 429: return .rateLimited(retryAfter: retryAfterSeconds(from: headers), payload: payload)
        case 500...599: return .serverError(status: status, payload: payload)
        default: return .httpError(status: status, payload: payload)
        }
    }

    /// Reads `retry-after` as delta-seconds.
    ///
    /// The HTTP spec also allows an absolute date; the Anthropic API sends
    /// seconds, and a date we failed to parse is better reported as "no hint"
    /// than as a wrong delay.
    static func retryAfterSeconds(from headers: [String: String]) -> TimeInterval? {
        // Header names are case-insensitive and URLSession does not normalise
        // them, so match rather than subscript.
        guard let value = headers.first(where: { $0.key.caseInsensitiveCompare("retry-after") == .orderedSame })?.value
        else { return nil }

        return TimeInterval(value.trimmingCharacters(in: .whitespaces))
    }

}

// MARK: - Messages

extension ClaudeError: LocalizedError {

    public var errorDescription: String? {
        switch self {
        case .missingAPIKey:
            return "No Anthropic API key is stored on this device."
        case let .unauthorized(payload):
            return "Anthropic rejected the API key (401).\(Self.suffix(payload))"
        case let .permissionDenied(payload):
            return "This API key is not permitted to make that request (403).\(Self.suffix(payload))"
        case let .notFound(payload):
            return "Endpoint or model not found (404).\(Self.suffix(payload))"
        case let .requestTooLarge(payload):
            return "The request body was too large (413).\(Self.suffix(payload))"
        case let .rateLimited(retryAfter, payload):
            let wait = retryAfter.map { " Retry after \(Int($0))s." } ?? ""
            return "Rate limited (429).\(wait)\(Self.suffix(payload))"
        case let .serverError(status, payload):
            return "Anthropic server error (\(status)).\(Self.suffix(payload))"
        case let .httpError(status, payload):
            return "Unexpected HTTP status \(status).\(Self.suffix(payload))"
        case let .decodingFailed(detail):
            return "Could not decode the response: \(detail)"
        case .refusal:
            return "The model declined to answer this request."
        case let .streamError(payload):
            return "The stream failed: \(payload.error.message)"
        case .streamTruncated:
            return "The stream ended before the message was complete."
        case let .transportFailure(detail):
            return "Network request failed: \(detail)"
        }
    }

    private static func suffix(_ payload: APIErrorPayload?) -> String {
        guard let payload else { return "" }
        return " \(payload.error.message)"
    }

}
