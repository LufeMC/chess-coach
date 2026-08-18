//
//  Violation.swift
//  ClaudeKit
//

import Foundation

/// The outcome of verifying a model response.
public enum VerificationResult: Sendable, Equatable {
    case valid
    case invalid([Violation])

    public var isValid: Bool {
        if case .valid = self { return true }
        return false
    }

    public var violations: [Violation] {
        if case let .invalid(violations) = self { return violations }
        return []
    }

    /// Builds a result from a list, collapsing "empty" to `.valid` so callers
    /// can't accidentally treat `.invalid([])` as a failure.
    static func from(_ violations: [Violation]) -> VerificationResult {
        violations.isEmpty ? .valid : .invalid(violations)
    }
}

/// One thing wrong with a model response.
///
/// Every violation names the moment it belongs to (when it has one) so the
/// fallback can discard exactly that note and keep the rest, and carries a
/// message precise enough to hand straight back to the model on the repair
/// attempt — "diverges from PV 0 at ply 2: model wrote e2e4, PV has d2d4" is
/// actionable in a way that "invalid line" is not.
public struct Violation: Sendable, Equatable, Codable {

    public enum Kind: String, Sendable, Equatable, Codable {
        /// The response is structurally wrong: missing note, unknown or
        /// duplicated momentID, empty required field.
        case shape
        /// `sourcePVIndex` doesn't name a line this moment provides.
        case pvIndexOutOfRange
        /// The quoted line is not a root-anchored prefix of the named PV.
        case lineDivergence
        /// The quoted line runs past the end of the PV.
        case lineTooLong
        /// `plyFromRoot` doesn't match the move's position in the line.
        case plyIndexMismatch
        /// The UCI matches but the SAN written next to it does not describe it.
        case sanMismatch
        /// A quoted move isn't legal in the position it claims to occur in.
        case illegalMove
        /// A `question` field names a move.
        case notationInQuestion
        /// `habitID` or `suggestedTag` outside the allowed vocabulary.
        case unknownVocabulary
        /// A field exceeded its character limit.
        case characterLimit
        /// The moment's `fenBefore` could not be parsed, so nothing rooted at
        /// it can be verified. A data problem, but it fails closed.
        case unverifiablePosition
    }

    /// The moment this violation belongs to, or `nil` for response-level
    /// problems (game note, weekly focus suggestion).
    public var momentID: String?

    /// Key path into the response, e.g. `momentNotes[0].keyLine.moves[2].uci`.
    public var field: String

    public var kind: Kind

    /// Human-readable and model-readable. Names the expected and actual value
    /// wherever both exist.
    public var message: String

    public init(momentID: String?, field: String, kind: Kind, message: String) {
        self.momentID = momentID
        self.field = field
        self.kind = kind
        self.message = message
    }

}

extension Violation: CustomStringConvertible {
    public var description: String {
        let moment = momentID.map { "[\($0)] " } ?? ""
        return "\(moment)\(field): \(message)"
    }
}
