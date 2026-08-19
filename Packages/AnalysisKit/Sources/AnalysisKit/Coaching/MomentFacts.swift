//
//  MomentFacts.swift
//  AnalysisKit
//

import ChessKit
import EngineKit

/// Everything a coaching sentence is allowed to name, in one value.
///
/// Assembled once per moment so the clause builders stay declarative and, more
/// importantly, so every clause is drawing on the same reading of the position.
/// A "what happened" clause built from the finding and a "proof" clause built by
/// re-deriving the position from the FEN is how a note ends up naming two
/// different pieces.
struct MomentFacts: Sendable {

    let context: MoveContext
    let diagnosis: Mistake
    let kind: MomentKind
    /// The finding the diagnosis was built from.
    let evidence: MomentEvidence?
    /// Chooses between the alternate wordings. Stable for a given position.
    let seed: UInt64

    init(context: MoveContext, diagnosis: Mistake, kind: MomentKind, evidence: MomentEvidence?) {
        self.context = context
        self.diagnosis = diagnosis
        self.kind = kind
        self.evidence = evidence
        // The moment's row UUID is minted at persistence time, so seeding from it
        // would give a moment a different note every time a game were re-analysed
        // — and re-analysis producing the same note is the whole claim of a
        // deterministic explainer. The position and the move that was played in
        // it identify the moment just as well and never change.
        self.seed = MomentFacts.hash("\(context.ply)|\(context.positionBefore.fen)|\(context.playedUCI)")
    }

    // MARK: Moves

    var playedSAN: String { context.playedMove.san }
    /// Falls back to a description rather than an empty string: a sentence with a
    /// hole in it reads as a bug, and the engine always had *some* preference.
    var bestSAN: String { context.bestMove?.san ?? "the engine's choice" }
    var refutationSAN: String { context.refutationMove?.san ?? "their reply" }
    var hasRefutation: Bool { context.refutationMove != nil }

    var mover: Piece.Color { context.mover }
    var opponent: Piece.Color { context.opponent }

    // MARK: Squares

    /// The square the finding is about: the hanging piece, the threatened
    /// square, the square the exchange happened on.
    var targetSquare: Square? { evidence?.squares.first }
    var targetSquareName: String { targetSquare?.notation ?? context.playedMove.end.notation }

    /// The piece the finding is about, named for prose ("rook", not "Rook").
    var targetPiece: String {
        guard let square = targetSquare else { return pieceName(context.playedMove.piece.kind) }
        if let piece = occupancyAfter[square] { return pieceName(piece.kind) }
        if let piece = occupancyBefore[square] { return pieceName(piece.kind) }
        return "piece"
    }

    var occupancyBefore: Occupancy { Occupancy(context.positionBefore) }
    var occupancyAfter: Occupancy { Occupancy(context.positionAfter) }

    /// The position the primary finding's theme squares live in.
    ///
    /// A missed tactic is classified from the position *before* the move (the
    /// player could have played it); an allowed one from the position after it.
    /// Looking a fork target up in the wrong one of those names the wrong piece.
    var themePosition: Position {
        evidence?.detector == .allowedTactic ? context.positionAfter : context.positionBefore
    }

    func pieceName(at square: Square, in position: Position) -> String {
        Occupancy(position)[square].map { pieceName($0.kind) } ?? "piece"
    }

    func pieceName(_ kind: Piece.Kind) -> String { kind.description.lowercased() }

    // MARK: Numbers

    /// "no", "one", "two"… — a note reads as English, not as a table.
    func count(_ n: Int) -> String {
        switch n {
        case 0: "no"
        case 1: "one"
        case 2: "two"
        case 3: "three"
        case 4: "four"
        default: "\(n)"
        }
    }

    func plural(_ n: Int, _ singular: String) -> String {
        "\(count(n)) \(singular)\(n == 1 ? "" : "s")"
    }

    func points(_ value: Double) -> String { String(format: "%.2f", value) }

    // MARK: Variation

    /// FNV-1a, because `Hasher` is seeded per process and would give the same
    /// moment a different sentence on every launch.
    static func hash(_ text: String) -> UInt64 {
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in text.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 1_099_511_628_211
        }
        return hash
    }

    /// Picks one of `count` alternates. `salt` keeps two clauses in the same note
    /// from moving together, which would leave the note with two "styles" rather
    /// than genuinely varied wording.
    func variant(_ salt: String, of count: Int) -> Int {
        guard count > 1 else { return 0 }
        return Int((MomentFacts.hash(salt) &+ seed) % UInt64(count))
    }

    func choose(_ options: [String], salt: String) -> String {
        options.isEmpty ? "" : options[variant(salt, of: options.count)]
    }
}
