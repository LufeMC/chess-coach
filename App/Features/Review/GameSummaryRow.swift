import Database
import Foundation
import SwiftUI

// MARK: - Row model

/// Everything one row shows, derived from a stored game.
///
/// Pure and separate from the view so the derivations that are easy to get wrong
/// — result from the *user's* side, not White's; accuracy that may be missing —
/// can be tested without a database.
struct GameSummaryRow: Identifiable, Sendable, Equatable {
    var id: UUID
    var opponent: String
    var subtitle: String
    var resultSymbol: String
    var result: GameResult?
    var accuracyText: String
    var analysisState: AnalysisState

    struct Indicator: Sendable, Equatable {
        var symbol: String
        var title: String
    }

    /// Nil once analysis is complete — see `GameLibraryRow`.
    var analysisIndicator: Indicator? {
        switch analysisState {
        case .complete: nil
        case .pending: Indicator(symbol: "clock", title: "Analysis pending")
        case .running: Indicator(symbol: "arrow.triangle.2.circlepath", title: "Analysing")
        case .failed: Indicator(symbol: "exclamationmark.triangle", title: "Analysis failed")
        }
    }

    var resultTint: Color {
        guard let result, let color = userColor else { return .secondary }
        if result == .draw { return .secondary }
        return result.isWin(for: color) ? .accentColor : .orange
    }

    /// Kept so `resultTint` can answer "did *you* win", which is the only reading
    /// of a result that matters in a personal history.
    var userColor: PlayerColor?

    static func make(game: Database.Game, opponentName: String, calendar: Calendar = .current) -> GameSummaryRow {
        let result = game.result.flatMap(GameResult.init(rawValue:))
        let color = game.color

        let symbol: String
        switch (result, color) {
        case (.some(.draw), _): symbol = "="
        case (.some(let value), .some(let side)): symbol = value.isWin(for: side) ? "W" : "L"
        default: symbol = "·"
        }

        var parts: [String] = [game.startedAt.formatted(date: .abbreviated, time: .omitted)]
        if let mode = game.gameMode { parts.append(mode.rawValue.capitalized) }
        parts.append("\(game.opponentRating)")

        return GameSummaryRow(
            id: game.id,
            opponent: opponentName,
            subtitle: parts.joined(separator: " · "),
            resultSymbol: symbol,
            result: result,
            // Rounded to a whole percent: the decimal places of an accuracy
            // estimate are noise, and printing them implies a precision the
            // Lichess curve does not have.
            accuracyText: game.userAccuracy.map { "\(Int($0.rounded()))%" } ?? "—",
            analysisState: game.analysis ?? .pending,
            userColor: color
        )
    }
}
