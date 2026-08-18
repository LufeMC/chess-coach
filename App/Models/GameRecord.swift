import Database
import Foundation

/// A finished game, in the shape persistence needs it.
///
/// `GameSession` is `@MainActor` and full of `ChessKit` value types; the write
/// happens on an actor with no main-actor affinity. This DTO is the boundary:
/// everything crosses it as plain `Sendable` data, so the writer never has to
/// touch — or await — the session.
struct FinishedGameRecord: Sendable {

    struct Move: Sendable {
        var ply: Int
        var san: String
        var uci: String
        var byUser: Bool
        var thinkTimeMs: Int
        var clockAfterMs: Int
    }

    var id: UUID
    var startedAt: Date
    var endedAt: Date
    var mode: String
    var userColor: PlayerColor
    var opponentRating: Int
    /// `"1-0"`, `"0-1"` or `"1/2-1/2"`.
    var result: String
    var termination: String
    var pgn: String
    var moves: [Move]
    /// Everything about the opponent and the format that has no column of its
    /// own. Stored as an opaque JSON blob by design so opponent tuning can evolve
    /// without a CloudKit-visible schema migration.
    var opponentParams: OpponentParams
    /// Calibration games feed the rating estimate; the others do not.
    var isRated: Bool

    /// The JSON blob written to `games.opponentParams`.
    struct OpponentParams: Sendable, Codable, Equatable {
        var opponentRating: Int
        var baseSeconds: Int
        var incrementSeconds: Int
        var secondTryEnabled: Bool
        var guidedEnabled: Bool

        var json: String {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            guard
                let data = try? encoder.encode(self),
                let text = String(data: data, encoding: .utf8)
            else { return "{}" }
            return text
        }

        static func decode(_ json: String) -> OpponentParams? {
            guard let data = json.data(using: .utf8) else { return nil }
            return try? JSONDecoder().decode(OpponentParams.self, from: data)
        }
    }
}

extension FinishedGameRecord {

    /// The row written to `games`.
    var gameRow: GameRow {
        GameRow(
            id: id,
            startedAt: startedAt,
            endedAt: endedAt,
            mode: mode,
            userColor: userColor.rawValue,
            opponentParams: opponentParams.json,
            opponentRating: opponentRating,
            result: result,
            termination: termination,
            pgn: pgn,
            userAccuracy: nil,
            // Every finished game enters the analysis queue. `AnalysisService`
            // is what moves it out of `pending`.
            analysisState: AnalysisState.pending.rawValue,
            isRated: isRated
        )
    }

    /// The rows written to `gameMoves`, in board order.
    var moveRows: [GameMoveRow] {
        moves.map { move in
            GameMoveRow(
                gameID: id,
                ply: move.ply,
                san: move.san,
                uci: move.uci,
                classification: nil,
                winPctBefore: nil,
                winPctAfter: nil,
                thinkTimeMs: move.thinkTimeMs
            )
        }
    }
}
