//
//  EndgameDrills.swift
//  ChessCoach
//

import AnalysisKit
import ChessKit
import Foundation
import TrainingCore

/// The endgame drill families the curriculum gates on.
///
/// Skill `r1.basicMates` needs K+Q vs K and K+R vs K, `r2.kpk` needs king and
/// pawn, `r3.rookEndings` needs Lucena and Philidor. K+B+B vs K is not gated but
/// ships alongside the other basic mates because a user who can mate with queen
/// and rook and *not* with two bishops has a hole they will fall into exactly
/// once, in a game they were winning.
enum EndgameDrillKind: String, Sendable, Hashable, CaseIterable, Codable {
    case kqk
    case krk
    case kbbk
    case kpk
    case lucena
    case philidor

    /// The metric this family's clean streak is stored under.
    ///
    /// KPK is the odd one out: its gate counts clean *sets* rather than clean
    /// runs, because one KPK position proves nothing — the whole point of the
    /// family is telling the won ones from the drawn ones.
    var streakMetricKey: MetricKey {
        switch self {
        case .kqk: return .kqkDrillCleanStreak
        case .krk: return .krkDrillCleanStreak
        case .kpk: return .kpkDrillCleanSetStreak
        case .lucena: return .lucenaDrillCleanStreak
        case .philidor: return .philidorDrillCleanStreak
        case .kbbk: return MetricKey("drill.kbbk.cleanStreak")
        }
    }

    var isSetScored: Bool { self == .kpk }
}

/// Constants the drills need that `DomainTuning` does not carry.
///
/// `DomainTuning.Curriculum` owns the KQK and KRK move budgets because the
/// curriculum's skill *titles* quote them. These are the ones only the drill
/// runner cares about, and they live here rather than being open-coded at the
/// three places that check them.
struct EndgameDrillTuning: Sendable, Hashable {
    /// Two bishops mate from the worst case in 19 moves with perfect play; 30
    /// leaves room for a human who knows the method but not the shortest path.
    var kbbkMaxMoves: Int = 30
    /// A KPK drill is played to a natural conclusion; this only stops a runaway.
    var kpkMaxMoves: Int = 60
    /// Lucena is a win in well under twenty moves once the bridge is built.
    var lucenaMaxMoves: Int = 25
    /// Philidor is a *hold*: the defender has to survive, not achieve anything,
    /// so the budget is the length of the test rather than a deadline.
    var philidorHoldMoves: Int = 25

    static let `default` = EndgameDrillTuning()

    func moveBudget(for kind: EndgameDrillKind, curriculum: DomainTuning.Curriculum) -> Int {
        switch kind {
        case .kqk: return curriculum.kqkMaxMoves
        case .krk: return curriculum.krkMaxMoves
        case .kbbk: return kbbkMaxMoves
        case .kpk: return kpkMaxMoves
        case .lucena: return lucenaMaxMoves
        case .philidor: return philidorHoldMoves
        }
    }
}

/// One drill position.
struct EndgameDrill: Sendable, Hashable, Identifiable {
    var id: String
    var kind: EndgameDrillKind
    var title: String
    /// Position the drill starts from. The user is always the side to move.
    var fen: String
    /// What the user has to achieve.
    var target: Target

    enum Target: String, Sendable, Hashable, Codable {
        /// Deliver checkmate inside the move budget.
        case mate
        /// Reach a won result — the pawn promotes or the opponent is mated.
        case win
        /// Survive the budget without losing.
        case hold
        /// Achieve whatever the tablebase says the position is worth.
        case theoreticalResult
    }

    var userColor: Piece.Color? {
        Position(fen: fen)?.sideToMove
    }
}

// MARK: - Catalogue

extension EndgameDrill {

    /// The shipping drill set.
    ///
    /// Positions are chosen to be *methodical* rather than tricky: each is the
    /// standard textbook starting point for its technique, because the drill is
    /// testing whether the user knows a method, not whether they can find a
    /// one-off resource.
    static let catalogue: [EndgameDrill] = basicMates + kpkSet + rookEndings

    static let basicMates: [EndgameDrill] = [
        EndgameDrill(
            id: "kqk.1",
            kind: .kqk,
            title: "Queen against king",
            fen: "8/8/8/4k3/8/8/8/K6Q w - - 0 1",
            target: .mate
        ),
        EndgameDrill(
            id: "kqk.2",
            kind: .kqk,
            title: "Queen against king, king in the corner",
            fen: "7k/8/8/3Q4/8/8/8/4K3 w - - 0 1",
            target: .mate
        ),
        EndgameDrill(
            id: "krk.1",
            kind: .krk,
            title: "Rook against king",
            fen: "8/8/8/4k3/8/8/8/K6R w - - 0 1",
            target: .mate
        ),
        EndgameDrill(
            id: "krk.2",
            kind: .krk,
            title: "Rook against king, defender centralised",
            fen: "8/8/3k4/8/8/8/R7/4K3 w - - 0 1",
            target: .mate
        ),
        EndgameDrill(
            id: "kbbk.1",
            kind: .kbbk,
            title: "Two bishops against king",
            fen: "8/8/8/4k3/8/8/8/KBB5 w - - 0 1",
            target: .mate
        )
    ]

    /// A KPK *set*. The mix is the lesson: three wins and three draws, so the
    /// user cannot pass by always pushing or always shuffling — they have to
    /// know which is which.
    static let kpkSet: [EndgameDrill] = [
        EndgameDrill(
            id: "kpk.1",
            kind: .kpk,
            title: "Opposition, pawn on the fifth",
            fen: "8/8/8/3k4/3P4/3K4/8/8 w - - 0 1",
            target: .theoreticalResult
        ),
        EndgameDrill(
            id: "kpk.2",
            kind: .kpk,
            title: "King in front of the pawn",
            fen: "8/8/3k4/8/3P4/3K4/8/8 w - - 0 1",
            target: .theoreticalResult
        ),
        EndgameDrill(
            id: "kpk.3",
            kind: .kpk,
            title: "Rook pawn",
            fen: "8/8/8/8/k7/P7/K7/8 w - - 0 1",
            target: .theoreticalResult
        ),
        EndgameDrill(
            id: "kpk.4",
            kind: .kpk,
            title: "Defending with the opposition",
            fen: "8/8/8/2k5/8/2K5/2P5/8 b - - 0 1",
            target: .theoreticalResult
        ),
        EndgameDrill(
            id: "kpk.5",
            kind: .kpk,
            title: "Outside the square",
            fen: "8/8/8/8/5k2/8/1P6/1K6 w - - 0 1",
            target: .theoreticalResult
        ),
        EndgameDrill(
            id: "kpk.6",
            kind: .kpk,
            title: "Holding the draw in front of the pawn",
            fen: "8/8/8/8/8/2k5/2P5/2K5 b - - 0 1",
            target: .theoreticalResult
        )
    ]

    static let rookEndings: [EndgameDrill] = [
        EndgameDrill(
            id: "lucena.1",
            kind: .lucena,
            title: "Lucena: build the bridge",
            fen: "1K1k4/1P6/8/8/8/8/r7/2R5 w - - 0 1",
            target: .win
        ),
        EndgameDrill(
            id: "philidor.1",
            kind: .philidor,
            title: "Philidor: third-rank defence",
            fen: "8/8/8/1k6/8/1K1P4/5r2/6R1 b - - 0 1",
            target: .hold
        )
    ]

    static func drills(kind: EndgameDrillKind) -> [EndgameDrill] {
        catalogue.filter { $0.kind == kind }
    }
}

// MARK: - Run

/// One attempt at a drill, played out against an engine opponent.
///
/// The run is a pure state machine over moves, like ``PuzzleSolveMachine``: the
/// engine is the caller's problem, so the pass criteria can be tested by feeding
/// a move list.
struct EndgameDrillRun: Sendable {

    enum Result: String, Sendable, Hashable, Codable {
        case inProgress
        case passed
        case failed
    }

    let drill: EndgameDrill
    let tuning: EndgameDrillTuning
    let curriculumTuning: DomainTuning.Curriculum

    private(set) var board: Board
    /// Moves played by the user, counted in *full* moves — the unit the
    /// curriculum's budgets are written in.
    private(set) var userMoveCount = 0
    private(set) var result: Result = .inProgress
    /// Set when a KPK drill's theoretical result was thrown away. Recorded
    /// separately from `result` because it is the diagnosis, not the verdict.
    private(set) var lostTheoreticalResult = false

    /// The theoretical KPK verdict at the start, which the user must not lose.
    private let startingKPKOutcome: KPKOutcome?
    private let userColor: Piece.Color

    init?(
        drill: EndgameDrill,
        tuning: EndgameDrillTuning = .default,
        curriculumTuning: DomainTuning.Curriculum = DomainTuning.default.curriculum
    ) {
        guard let position = Position(fen: drill.fen) else { return nil }
        self.drill = drill
        self.tuning = tuning
        self.curriculumTuning = curriculumTuning
        self.board = Board(position: position)
        self.userColor = position.sideToMove
        self.startingKPKOutcome = drill.kind == .kpk ? EndgameDrillRun.kpkOutcome(position) : nil
    }

    var isUserToMove: Bool { board.position.sideToMove == userColor }

    var moveBudget: Int { tuning.moveBudget(for: drill.kind, curriculum: curriculumTuning) }

    /// Plays a move for whoever is to move.
    ///
    /// - Returns: `false` when the move is not legal, in which case nothing has
    ///   changed.
    @discardableResult
    mutating func play(uci: String) -> Bool {
        guard result == .inProgress else { return false }
        let wasUser = isUserToMove
        guard PuzzleSolveMachine.apply(uci: uci, to: &board) else { return false }

        if wasUser {
            userMoveCount += 1
            // The theory check runs after the *user's* move and before the
            // opponent's, so a slip is attributed to the person who made it.
            if drill.kind == .kpk, let starting = startingKPKOutcome {
                if let now = EndgameDrillRun.kpkOutcome(board.position), now != starting {
                    lostTheoreticalResult = true
                }
            }
        }

        evaluate()
        return true
    }

    /// Ends the run early — the user gave up, or the engine had no move.
    mutating func resign() {
        guard result == .inProgress else { return }
        result = .failed
    }

    private mutating func evaluate() {
        switch board.state {
        case let .checkmate(color):
            // `checkmate(color:)` names the side that *is* mated.
            guard color != userColor else {
                result = .failed
                return
            }
            result = drill.kind == .kpk ? kpkVerdict(finished: .win) : .passed
            return

        case .draw:
            switch drill.kind {
            case .kpk:
                result = kpkVerdict(finished: .draw)
            case .philidor:
                // A draw *is* the Philidor target.
                result = .passed
            case .kqk, .krk, .kbbk, .lucena:
                // A draw in a position winning by a piece or more is a failure
                // by definition — that is exactly what the drill tests.
                result = .failed
            }
            return

        default:
            break
        }

        guard userMoveCount >= moveBudget else { return }

        switch drill.kind {
        case .philidor:
            // Surviving the budget is the pass condition for a hold — with the
            // rook still on the board and no enemy queen, because "I am still
            // alive" is not a hold if the pawn has already promoted.
            //
            // This is deliberately weaker than the other criteria: without a
            // 5-man tablebase there is no way to prove a rook ending is still
            // drawn, and asserting one would be worse than admitting the limit.
            result = defenderStillHolding ? .passed : .failed
        case .kpk:
            // Running out of moves without a conclusion means the drawn ones
            // were held and the won ones were not converted.
            result = startingKPKOutcome == .draw && !lostTheoreticalResult ? .passed : .failed
        case .kqk, .krk, .kbbk, .lucena:
            result = .failed
        }
    }

    /// Whether the defending side still has what it needs to draw.
    private var defenderStillHolding: Bool {
        let pieces = board.position.pieces
        let ownRooks = pieces.filter { $0.color == userColor && $0.kind == .rook }.count
        let enemyQueens = pieces.filter { $0.color != userColor && $0.kind == .queen }.count
        return ownRooks >= 1 && enemyQueens == 0
    }

    private func kpkVerdict(finished actual: KPKOutcome) -> Result {
        guard let expected = startingKPKOutcome else { return .failed }
        return actual == expected && !lostTheoreticalResult ? .passed : .failed
    }

    /// Whether the run counts as clean for the streak metric.
    var isClean: Bool { result == .passed }

    // MARK: KPK probe

    /// The tablebase verdict for a three-piece K+P vs K position.
    ///
    /// Returns `nil` for anything that is not KPK — a promotion has happened, or
    /// the caller handed us the wrong drill — so the checks above degrade to
    /// "no opinion" rather than to a wrong verdict.
    static func kpkOutcome(_ position: Position) -> KPKOutcome? {
        let pieces = position.pieces
        guard pieces.count == 3, let pawn = pieces.first(where: { $0.kind == .pawn }) else { return nil }
        let kings = pieces.filter { $0.kind == .king }
        guard
            kings.count == 2,
            let strongKing = kings.first(where: { $0.color == pawn.color }),
            let weakKing = kings.first(where: { $0.color != pawn.color })
        else { return nil }

        return KPKBitbase.probe(
            strongSide: pawn.color,
            strongKing: strongKing.square,
            pawn: pawn.square,
            weakKing: weakKing.square,
            sideToMove: position.sideToMove
        )
    }
}

// MARK: - Opponent

/// The engine side of a drill.
///
/// Behind a protocol so drills can be exercised without an engine — the pass
/// criteria are the part worth testing, and they do not care who chose the
/// replies.
protocol DrillOpponent: Sendable {
    /// - Returns: A UCI move, or `nil` when the position is terminal.
    func reply(fen: String) async throws -> String?
}

/// A drill opponent that always resigns. Used in previews and tests.
struct NullDrillOpponent: DrillOpponent {
    func reply(fen: String) async throws -> String? { nil }
}
