//
//  CoachRequestBuilder.swift
//  ChessCoach
//

import AnalysisKit
import ChessKit
import ClaudeKit
import Database
import Foundation
import TrainingCore

// MARK: - Line notation

/// Converts engine principal variations from UCI to SAN.
///
/// The coaching contract wants both: `pvUCI` is what `CoachVerifier` checks the
/// model's quoted moves against, and `pvSAN` is what the model reads and writes,
/// because SAN is the notation chess prose is written in and asking a model to
/// discuss "g1f3" produces prose about "g1f3".
enum LineNotation {

    /// - Parameters:
    ///   - line: UCI moves from `fen`, in order.
    ///   - maxPlies: Hard cap. `CoachRequest.Caps.maxPVPlies` by default —
    ///     eight plies is as far as a claim about a line stays checkable, and
    ///     every ply beyond it is paid for on every game.
    /// - Returns: The SAN moves, truncated at the first one that will not
    ///   replay. A PV that stops early is better than a PV with a fabricated
    ///   move in it.
    static func san(
        forUCILine line: [String],
        fromFEN fen: String,
        maxPlies: Int = CoachRequest.Caps.maxPVPlies
    ) -> [String] {
        guard let position = Position(fen: fen) else { return [] }
        var board = Board(position: position)
        var result: [String] = []
        for uci in line.prefix(maxPlies) {
            guard let move = PuzzleSolveMachine.move(uci: uci, on: &board) else { break }
            result.append(move.san)
        }
        return result
    }

    /// The UCI line truncated to the same length the SAN conversion managed, so
    /// the two arrays stay index-aligned. `CoachResponse.MoveRef` carries both
    /// and the verifier compares them positionally.
    static func alignedUCI(_ line: [String], toSANCount count: Int) -> [String] {
        Array(line.prefix(count))
    }

    /// Splits a stored space-separated PV.
    static func plies(_ pv: String) -> [String] {
        pv.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
    }
}

// MARK: - Builder

/// Assembles a ``CoachRequest`` from stored rows.
///
/// Pure and synchronous: every input is passed in, so the whole shape of what
/// gets sent to the model — including the caps — is testable from fixtures with
/// no database, no engine and no network.
enum CoachRequestBuilder {

    /// Everything one coaching call needs.
    struct Inputs: Sendable {
        var game: Database.Game
        var moves: [GameMove]
        var evals: [PlyEval]
        /// Already ranked; only the top ``CoachRequest/Caps/maxMoments`` are
        /// sent.
        var moments: [Database.Moment]
        var settings: AppSettings
        var rung: Rung
        var focus: WeeklyFocus?
        var microGoal: MicroGoalState?
        var leaks: [Leak]

        init(
            game: Database.Game,
            moves: [GameMove] = [],
            evals: [PlyEval] = [],
            moments: [Database.Moment] = [],
            settings: AppSettings = AppSettings(),
            rung: Rung,
            focus: WeeklyFocus? = nil,
            microGoal: MicroGoalState? = nil,
            leaks: [Leak] = []
        ) {
            self.game = game
            self.moves = moves
            self.evals = evals
            self.moments = moments
            self.settings = settings
            self.rung = rung
            self.focus = focus
            self.microGoal = microGoal
            self.leaks = leaks
        }
    }

    /// Builds the request, already capped.
    ///
    /// `capped()` is applied here rather than relying on `CoachService` doing it
    /// so that what the tests inspect is what goes on the wire.
    static func build(_ inputs: Inputs) -> CoachRequest {
        CoachRequest(
            profile: profile(inputs),
            game: gameSummary(inputs),
            moments: inputs.moments
                .sorted { $0.score > $1.score }
                .prefix(CoachRequest.Caps.maxMoments)
                .compactMap { moment(from: $0, inputs: inputs) }
        )
        .capped()
    }

    // MARK: Profile

    static func profile(_ inputs: Inputs) -> CoachRequest.Profile {
        let habit = inputs.focus?.habit ?? .blunderCheck
        return CoachRequest.Profile(
            ratingEstimate: Int(inputs.settings.userRating.rounded()),
            // The playing ladder is plain Elo and carries no deviation, so the
            // puzzle rating's RD stands in. It is the only uncertainty the app
            // actually measures, and it moves for the same reason the ladder's
            // would: how recently and how much the user has been observed.
            ratingUncertainty: Int(inputs.settings.puzzleRD.rounded()),
            rung: CoachRequest.Rung(id: "r\(inputs.rung.id)", title: inputs.rung.title),
            weeklyFocus: CoachRequest.WeeklyFocus(
                habitID: CoachVocabularyBridge.habitID(for: habit),
                stepTag: CoachVocabularyBridge.stepTag(for: habit),
                microGoal: CoachRequest.MicroGoal(
                    metricID: CoachVocabularyBridge.metricID(for: habit),
                    target: inputs.microGoal?.target ?? 0,
                    current: inputs.microGoal?.current ?? 0
                )
            ),
            leakTop3: inputs.leaks.prefix(3).map { leak in
                CoachRequest.Leak(
                    causeTag: leak.causeTag.rawValue,
                    epLostPerGame: leak.epLostPerGame,
                    trend: CoachVocabularyBridge.trend(forDelta: leak.deltaVsPreviousWeek)
                )
            }
        )
    }

    // MARK: Game

    static func gameSummary(_ inputs: Inputs) -> CoachRequest.Game {
        let userIsWhite = inputs.game.color != .black
        let accuracies = phaseAccuracies(inputs)

        return CoachRequest.Game(
            result: result(of: inputs.game),
            userColor: userIsWhite ? .white : .black,
            accuracyUser: inputs.game.userAccuracy ?? accuracies.overallUser,
            accuracyOpponent: accuracies.overallOpponent,
            timeControl: timeControl(from: inputs.game.opponentParams),
            moveCount: (inputs.moves.count + 1) / 2,
            opening: openingLine(inputs.moves),
            phaseAccuracy: CoachRequest.PhaseAccuracy(
                opening: accuracies.opening,
                middlegame: accuracies.middlegame,
                endgame: accuracies.endgame
            )
        )
    }

    static func result(of game: Database.Game) -> CoachRequest.Game.Result {
        guard let stored = game.result.flatMap(GameResult.init(rawValue:)) else { return .draw }
        guard stored != .draw else { return .draw }
        let color: PlayerColor = game.color ?? .white
        return stored.isWin(for: color) ? .win : .loss
    }

    /// The opening, named by its actual moves.
    ///
    /// The app does not carry an ECO book, and inventing an opening name the
    /// model would then repeat back to the student is worse than telling it what
    /// was played. Six plies is enough to identify almost any opening and costs
    /// nothing.
    static func openingLine(_ moves: [GameMove], plies: Int = 6) -> String {
        let ordered = moves.sorted { $0.ply < $1.ply }.prefix(plies)
        guard !ordered.isEmpty else { return "unknown" }
        var text = ""
        for move in ordered {
            if move.ply % 2 == 1 { text += "\(move.ply / 2 + 1)." }
            text += "\(move.san) "
        }
        return text.trimmingCharacters(in: .whitespaces)
    }

    /// Reads a time control out of the opaque opponent-parameters blob.
    ///
    /// The blob is deliberately opaque to the database package, so this is a
    /// best-effort read of two well-known keys. "unknown" is an honest answer;
    /// a fabricated "10+0" is not.
    static func timeControl(from opponentParams: String) -> String {
        guard
            let data = opponentParams.data(using: .utf8),
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return "unknown" }

        let base = (object["baseSeconds"] as? Double) ?? (object["baseSeconds"] as? Int).map(Double.init)
        let increment = (object["incrementSeconds"] as? Double) ?? (object["incrementSeconds"] as? Int).map(Double.init)
        guard let base else { return "unknown" }
        return "\(Int(base / 60))+\(Int(increment ?? 0))"
    }

    struct PhaseAccuracies: Sendable {
        var opening = 0.0
        var middlegame = 0.0
        var endgame = 0.0
        var overallUser = 0.0
        var overallOpponent = 0.0
    }

    /// Per-phase accuracy, replayed from the stored evaluations.
    ///
    /// Derived from `PlyEval` rather than from `GameMove.winPctBefore/After`
    /// because `PlyEval` is unambiguous: an engine score is always relative to
    /// the side to move, so the expected points at ply *p* belong to whoever is
    /// moving at ply *p*, and the same value at *p+1* seen from the mover's side
    /// is its complement. Reading the stored win percentages instead would
    /// depend on a perspective convention that is not written down anywhere.
    static func phaseAccuracies(_ inputs: Inputs) -> PhaseAccuracies {
        var epByPly: [Int: Double] = [:]
        for eval in inputs.evals {
            if let mate = eval.pv1Mate {
                epByPly[eval.ply] = mate > 0 ? 1 : 0
            } else if let cp = eval.pv1Cp {
                epByPly[eval.ply] = EvalMath.expectedPoints(EvalMath.winPercent(cp: cp))
            }
        }

        let userIsWhite = inputs.game.color != .black
        var board = Board(position: .standard)
        var sums: [AnalysisKit.Phase: (total: Double, count: Int)] = [:]
        var user: (total: Double, count: Int) = (0, 0)
        var opponent: (total: Double, count: Int) = (0, 0)

        for move in inputs.moves.sorted(by: { $0.ply < $1.ply }) {
            let ply = move.ply
            let phase = AnalysisKit.Phase.classify(position: board.position, ply: ply)
            let isUser = (ply % 2 == 1) == userIsWhite

            if let before = epByPly[ply], let next = epByPly[ply + 1] {
                let accuracy = EvalMath.accuracy(winPctBefore: before * 100, winPctAfter: (1 - next) * 100)
                if isUser {
                    user.total += accuracy
                    user.count += 1
                    var bucket = sums[phase] ?? (0, 0)
                    bucket.total += accuracy
                    bucket.count += 1
                    sums[phase] = bucket
                } else {
                    opponent.total += accuracy
                    opponent.count += 1
                }
            }

            guard PuzzleSolveMachine.apply(uci: move.uci, to: &board) else { break }
        }

        func mean(_ bucket: (total: Double, count: Int)?) -> Double {
            guard let bucket, bucket.count > 0 else { return 0 }
            return (bucket.total / Double(bucket.count) * 10).rounded() / 10
        }

        return PhaseAccuracies(
            opening: mean(sums[.opening]),
            middlegame: mean(sums[.middlegame]),
            endgame: mean(sums[.endgame]),
            overallUser: mean(user),
            overallOpponent: mean(opponent)
        )
    }

    // MARK: Moments

    static func moment(from stored: Database.Moment, inputs: Inputs) -> CoachRequest.Moment? {
        guard let position = Position(fen: stored.fen) else { return nil }

        let eval = inputs.evals.first { $0.ply == stored.ply }
        let move = inputs.moves.first { $0.ply == stored.ply }

        return CoachRequest.Moment(
            momentID: stored.id.uuidString,
            ply: stored.ply,
            fenBefore: stored.fen,
            phase: phase(AnalysisKit.Phase.classify(position: position, ply: stored.ply)),
            playedSAN: stored.playedSAN,
            playedUCI: stored.playedUCI,
            bestSAN: stored.bestSAN,
            bestUCI: stored.bestUCI,
            deltaEP: stored.deltaEP,
            judgment: judgment(for: stored, eval: eval),
            causeTag: stored.causeTag,
            stepTag: stored.stepTag,
            modifiers: stored.modifierList,
            thinkTimeMs: move?.thinkTimeMs ?? 0,
            criticalityGap: criticalityGap(eval),
            engineLines: engineLines(for: stored, eval: eval)
        )
    }

    static func phase(_ phase: AnalysisKit.Phase) -> CoachRequest.Moment.Phase {
        switch phase {
        case .opening: return .opening
        case .middlegame: return .middlegame
        case .endgame: return .endgame
        }
    }

    /// The contract's four-way judgment.
    ///
    /// `missedWin` is not an expected-points band, it is a *situation*: the
    /// engine had a forced mate and the move played did not take it. That is
    /// worth telling apart from an ordinary blunder because the coaching is
    /// different — "you had mate in three" is a calculation lesson, not a safety
    /// one. Everything else falls back to the standard EP bands.
    static func judgment(for stored: Database.Moment, eval: PlyEval?) -> CoachRequest.Moment.Judgment {
        if let mate = eval?.pv1Mate, mate > 0, stored.deltaEP >= EvalMath.mistakeThreshold {
            return .missedWin
        }
        switch EvalMath.judgment(deltaEP: stored.deltaEP) {
        case .blunder: return .blunder
        case .mistake: return .mistake
        case .inaccuracy, .ok: return .inaccuracy
        }
    }

    static func criticalityGap(_ eval: PlyEval?) -> Double {
        guard let eval else { return 0 }
        func expectedPoints(cp: Int?, mate: Int?) -> Double? {
            if let mate { return mate > 0 ? 1 : 0 }
            if let cp { return EvalMath.expectedPoints(EvalMath.winPercent(cp: cp)) }
            return nil
        }
        guard
            let best = expectedPoints(cp: eval.pv1Cp, mate: eval.pv1Mate),
            let second = expectedPoints(cp: eval.pv2Cp, mate: eval.pv2Mate)
        else { return 0 }
        return max(0, best - second)
    }

    /// The engine lines the model is allowed to quote.
    ///
    /// `CoachVerifier` checks every quoted move against these and nothing else,
    /// so anything missing here is a line the model cannot legally mention. Both
    /// lines are rooted at the moment's `fenBefore`, which is what makes the
    /// verifier's ply indices meaningful.
    static func engineLines(for stored: Database.Moment, eval: PlyEval?) -> [CoachRequest.EngineLine] {
        guard let eval else {
            // With no stored evaluation the only line we can vouch for is the
            // single best move the moment itself records.
            let uci = stored.bestUCI.isEmpty ? [] : [stored.bestUCI]
            return [
                CoachRequest.EngineLine(
                    label: .best,
                    evalCp: 0,
                    pvSAN: stored.bestSAN.isEmpty ? [] : [stored.bestSAN],
                    pvUCI: uci
                )
            ]
        }

        var lines: [CoachRequest.EngineLine] = []

        func line(label: CoachRequest.EngineLine.Label, pv: String, cp: Int?, mate: Int?) {
            let uci = LineNotation.plies(pv)
            guard !uci.isEmpty else { return }
            let san = LineNotation.san(forUCILine: uci, fromFEN: stored.fen)
            guard !san.isEmpty else { return }
            lines.append(
                CoachRequest.EngineLine(
                    label: label,
                    // A mate is reported as a large centipawn value so the field
                    // stays a single number, matching how the schema types it.
                    evalCp: mate.map { $0 > 0 ? 10_000 : -10_000 } ?? (cp ?? 0),
                    pvSAN: san,
                    pvUCI: LineNotation.alignedUCI(uci, toSANCount: san.count)
                )
            )
        }

        line(label: .best, pv: eval.pv1, cp: eval.pv1Cp, mate: eval.pv1Mate)
        line(label: .alt, pv: eval.pv2, cp: eval.pv2Cp, mate: eval.pv2Mate)

        if lines.isEmpty, !stored.bestUCI.isEmpty {
            lines.append(
                CoachRequest.EngineLine(
                    label: .best,
                    evalCp: 0,
                    pvSAN: [stored.bestSAN],
                    pvUCI: [stored.bestUCI]
                )
            )
        }
        return lines
    }
}
