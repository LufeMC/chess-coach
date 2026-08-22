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
        /// Reach a won result — the pawn queens safely, or the opponent is
        /// mated.
        ///
        /// Queening is the pass, and that is the point rather than a
        /// concession. `evaluate()` used to accept only checkmate, so a user who
        /// built the Lucena bridge perfectly still had to mate with queen and
        /// rook inside the same budget to be told they had done it — the drill
        /// measured a different skill from the one it taught, and reset the
        /// Lucena streak `r3.rookEndings` gates on when they ran out of moves.
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

    /// A KPK *set*. The mix is the lesson: three the user must convert and three
    /// they must hold, so they cannot pass by always pushing or always
    /// shuffling — they have to know which is which.
    ///
    /// ## Every position here has to be losable, and that is not automatic
    ///
    /// `EndgameDrillRun` grades a KPK drill by comparing the bitbase verdict
    /// after each user move against the verdict at the start. That only tests
    /// anything when the user is on the side that can *change* it:
    ///
    /// - **User attacking a won position** — a careless move throws the win
    ///   away and the drill fails. A real test.
    /// - **User defending a drawn position** — a careless move hands over the
    ///   win and the drill fails. A real test.
    /// - **User attacking a drawn position** — nothing they do can lose a draw
    ///   against correct defence, and a lone king cannot mate them, so *no*
    ///   path through `evaluate()` returns `.failed`. Shuffling passes.
    /// - **User defending a won position** — they are lost by force, so no path
    ///   returns `.passed`. There is no move that passes it.
    ///
    /// The first shipped set contained three of the third kind and one of the
    /// fourth: four of six drills graded nothing. `KPKDrillCatalogueTests` now
    /// walks the bitbase forward from every position in this catalogue and fails
    /// if any drill cannot be both passed and failed, so that class of position
    /// cannot get back in.
    ///
    /// The defending drills look unlosable for the first two plies and are not:
    /// the defender's real decision arrives at ply 3, when the attacking king
    /// steps up and the opposition starts to matter.
    static let kpkSet: [EndgameDrill] = [
        EndgameDrill(
            id: "kpk.1",
            kind: .kpk,
            title: "King in front of the pawn",
            fen: "4k3/8/4K3/4P3/8/8/8/8 w - - 0 1",
            target: .theoreticalResult
        ),
        EndgameDrill(
            id: "kpk.2",
            kind: .kpk,
            title: "Send the king first",
            fen: "2k5/8/2K5/8/2P5/8/8/8 w - - 0 1",
            target: .theoreticalResult
        ),
        EndgameDrill(
            id: "kpk.3",
            kind: .kpk,
            title: "Outside the square",
            fen: "8/8/8/8/5k2/8/1P6/1K6 w - - 0 1",
            target: .theoreticalResult
        ),
        EndgameDrill(
            id: "kpk.4",
            kind: .kpk,
            title: "Take the opposition",
            fen: "8/4k3/8/4P3/4K3/8/8/8 b - - 0 1",
            target: .theoreticalResult
        ),
        EndgameDrill(
            id: "kpk.5",
            kind: .kpk,
            title: "Hold in front of the pawn",
            fen: "8/8/8/8/8/2k5/2P5/2K5 b - - 0 1",
            target: .theoreticalResult
        ),
        EndgameDrill(
            id: "kpk.6",
            kind: .kpk,
            title: "Rook pawn: the corner draws",
            fen: "1k6/8/1K6/P7/8/8/8/8 b - - 0 1",
            target: .theoreticalResult
        )
    ]

    /// Three Lucena positions and three Philidor, not one of each.
    ///
    /// ## One position per technique is a picture, not a method
    ///
    /// `drillCleanStreakRequired` is two, so a family holding a single position
    /// asks the user to reproduce the same diagram twice — which is the
    /// memorisation failure mode `CardPolicy` spends sixty lines keeping out of
    /// the puzzle deck, arriving through the back door. Each family now varies
    /// the file, which side of the pawn the defending king stands on, and the
    /// colours, so a clean streak means the method survived a change of picture.
    ///
    /// ## Every position was checked against the engine
    ///
    /// The set the app shipped before had a "Philidor" with the defending king
    /// on b5, the defending rook on White's second rank and the pawn three ranks
    /// from the sixth: drawn, but for reasons that have nothing to do with the
    /// third-rank defence the paired lesson teaches, so twenty-five moves of
    /// anything at all passed it. These are the textbook diagrams — each Lucena
    /// is a forced win with first moves that throw it away, and each Philidor is
    /// a dead draw in which the tempting early switch to checking from behind
    /// loses. `RookEndingCatalogueTests` pins the structure so that class of
    /// position cannot come back.
    static let rookEndings: [EndgameDrill] = [
        EndgameDrill(
            id: "lucena.1",
            kind: .lucena,
            title: "Lucena: build the bridge",
            fen: "1K1k4/1P6/8/8/8/8/r7/2R5 w - - 0 1",
            target: .win
        ),
        EndgameDrill(
            id: "lucena.2",
            kind: .lucena,
            // A different file, and the defending king cut off on the *short*
            // side of the pawn rather than the long one. The bridge is still the
            // answer, but nothing about the picture matches `lucena.1`, which is
            // the point: it separates the user who learned the method from the
            // user who learned the diagram.
            title: "Lucena: defender on the short side",
            fen: "4K1k1/4P3/8/8/8/8/3r4/5R2 w - - 0 1",
            target: .win
        ),
        EndgameDrill(
            id: "lucena.3",
            kind: .lucena,
            // Colours reversed: the user runs the bridge as Black, from the
            // bottom of the board, which is where they will actually meet it
            // half the time.
            title: "Lucena: build the bridge as Black",
            fen: "2r5/R7/8/8/8/8/1p6/1k1K4 b - - 0 1",
            target: .win
        ),
        EndgameDrill(
            id: "philidor.1",
            kind: .philidor,
            title: "Philidor: third-rank defence",
            fen: "8/4k3/1r6/3KP3/8/8/8/R7 b - - 0 1",
            target: .hold
        ),
        EndgameDrill(
            id: "philidor.2",
            kind: .philidor,
            title: "Philidor: third rank against a c-pawn",
            fen: "8/2k5/6r1/1KP5/8/8/8/R7 b - - 0 1",
            target: .hold
        ),
        EndgameDrill(
            id: "philidor.3",
            kind: .philidor,
            title: "Philidor: third-rank defence as White",
            fen: "r7/8/8/8/3kp3/1R6/4K3/8 w - - 0 1",
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

    /// The move on which a KPK drill's theoretical result went, and a move that
    /// would have kept it.
    ///
    /// Both are read out of the same bitbase that grades the run, at the moment
    /// it notices. That timing is the whole reason this type exists: the
    /// position the user moved *from* is gone as soon as the engine replies, and
    /// the drill is the one flow in the app where "the move that lost it" is not
    /// an opinion — the table knows it exactly. Recording the verdict and
    /// throwing the diagnosis away left the user with "Missed" after twenty
    /// moves of a game that was decided on move three.
    struct TheoryLapse: Sendable, Hashable {
        /// The user's move number, counted the way the budget is.
        var moveNumber: Int
        /// What they played, in the notation they read on a scoresheet.
        var played: String
        /// A move that would have kept the result. Any one of them: the point is
        /// that one existed and what it looked like, not which is best.
        var keeps: String?
        /// What the position was worth before the move.
        var was: KPKOutcome
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
    /// Where the result went, when it went. `nil` while it is intact.
    private(set) var lapse: TheoryLapse?
    /// Why the game ended, when it ended in a draw.
    ///
    /// Carried because "it was a draw" is not feedback and *how* is: stalemate,
    /// a threefold repetition and the fifty-move rule are three different
    /// mistakes with three different fixes, and stalemating a won king and queen
    /// ending is the single most common way a 1200 throws one away.
    private(set) var drawReason: Board.State.DrawReason?
    /// The user's move number on which their pawn queened, for a `.win` drill.
    private(set) var queenedOnMove: Int?
    /// Set when a hold survived the budget and the board could not prove it was
    /// still a draw. The run is provisionally `.passed`; the caller is expected
    /// to put the position to the engine and hand the answer back through
    /// ``applyHoldRuling(centipawns:)`` before recording it.
    private(set) var needsHoldRuling = false
    /// Set when that ruling came back losing. The diagnosis rather than the
    /// verdict, so the banner can say what the twenty-five moves ended in
    /// instead of claiming a draw that is not on the board.
    private(set) var holdRuledLost = false
    /// The move just played, by either side.
    ///
    /// Kept so the board can mark the squares it touched. The engine answers
    /// inside 300ms and the position simply changes underneath the user, which
    /// over a sixty-ply king-and-pawn run means diffing two boards every move to
    /// work out what was played — not a chess skill, and not what the drill is
    /// there to test.
    private(set) var lastMove: Move?

    /// The theoretical KPK verdict at the start, which the user must not lose.
    let startingKPKOutcome: KPKOutcome?
    /// What the position is worth **to the user**, for a family that asks them
    /// to say so before they play it.
    ///
    /// `startingKPKOutcome` is written from the pawn's side — `.win` means the
    /// pawn's owner wins — which is the wrong frame to put in front of a user
    /// who is defending. This re-expresses it from the seat they are sitting in.
    ///
    /// `nil` means do not ask: either the family is not scored on a call, or the
    /// user is the bare king in a position that is lost by force, which
    /// `KPKDrillCatalogueTests` keeps out of the catalogue and which `.win` and
    /// `.draw` cannot honestly express.
    let startingCallForUser: KPKOutcome?
    /// The call the user made before playing, when they were asked for one.
    private(set) var recordedCall: KPKOutcome?
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
        let outcome = drill.kind == .kpk ? EndgameDrillRun.kpkOutcome(position) : nil
        self.startingKPKOutcome = outcome
        self.startingCallForUser = EndgameDrillRun.startingCall(
            for: outcome,
            kind: drill.kind,
            in: position,
            userColor: position.sideToMove
        )
    }

    /// `startingCallForUser`, resolved from the starting position.
    ///
    /// A free function of the start rather than a computed property, because the
    /// pawn on the board is not necessarily the pawn the drill began with: it
    /// can be captured or promoted, and a question asked at move zero must not
    /// change its answer at move thirty.
    private static func startingCall(
        for outcome: KPKOutcome?,
        kind: EndgameDrillKind,
        in position: Position,
        userColor: Piece.Color
    ) -> KPKOutcome? {
        guard kind.isSetScored, let outcome else { return nil }
        guard let pawn = position.pieces.first(where: { $0.kind == .pawn }) else { return nil }
        if pawn.color == userColor { return outcome }
        return outcome == .draw ? .draw : nil
    }

    var isUserToMove: Bool { board.position.sideToMove == userColor }

    var moveBudget: Int { tuning.moveBudget(for: drill.kind, curriculum: curriculumTuning) }

    // MARK: The call

    /// Records the user's read of the position before they play it.
    ///
    /// The KPK set exists to teach the one skill that decides pawn endings —
    /// telling the won ones from the drawn ones *before* you trade into them —
    /// and moves alone cannot measure it: a drawn position held for sixty moves
    /// of shuffling passes whether or not the user knew it was drawn. Asking for
    /// the verdict first is the only place that knowledge is observable.
    ///
    /// Ignored once the position is under way, so a call cannot be revised after
    /// the board has answered the question.
    mutating func recordCall(_ call: KPKOutcome) {
        guard userMoveCount == 0, result == .inProgress, recordedCall == nil else { return }
        recordedCall = call
    }

    /// Whether the user read the position correctly. `nil` when never asked.
    var callWasCorrect: Bool? {
        guard let recordedCall, let expected = startingCallForUser else { return nil }
        return recordedCall == expected
    }

    /// Whether the run was lost at the point of judging it rather than playing
    /// it. Carried so the verdict can name which of the two happened.
    var misjudgedStart: Bool { callWasCorrect == false }

    /// Plays a move for whoever is to move.
    ///
    /// - Returns: `false` when the move is not legal, in which case nothing has
    ///   changed.
    @discardableResult
    mutating func play(uci: String) -> Bool {
        guard result == .inProgress else { return false }
        let wasUser = isUserToMove
        let before = board.position
        // The move rather than a bare Bool: it carries the disambiguation and
        // check state SAN needs, and the drill has to be able to name what was
        // played back to the user.
        guard let move = PuzzleSolveMachine.move(uci: uci, on: &board) else { return false }
        lastMove = move

        if wasUser {
            userMoveCount += 1
            noteTheoryCheck(from: before, played: move)
        }

        evaluate(lastMove: move, byUser: wasUser)
        return true
    }

    /// Compares the theoretical result either side of the user's move.
    ///
    /// The check runs after the *user's* move and before the opponent's, so a
    /// slip is attributed to the person who made it — and it compares against
    /// the position they moved **from**, not against the start. Comparing
    /// against the start attributes any change to whoever moved next: a defender
    /// holding a draw the engine had already thrown away would read "the result
    /// changed on your move" on every move afterwards, forever, for a change
    /// they did not make.
    private mutating func noteTheoryCheck(from before: Position, played move: Move) {
        guard
            drill.kind == .kpk,
            let was = EndgameDrillRun.kpkOutcome(before),
            let now = EndgameDrillRun.kpkOutcome(board.position),
            now != was
        else { return }

        lostTheoreticalResult = true
        // Only the first one. A run that has already gone wrong will go wrong
        // again, and the move being taught is the one that started it.
        guard lapse == nil else { return }
        lapse = TheoryLapse(
            moveNumber: userMoveCount,
            played: move.san,
            keeps: EndgameDrillRun.moveKeeping(was, from: before),
            was: was
        )
    }

    /// Ends the run early — the user gave up, or the engine had no move.
    mutating func resign() {
        guard result == .inProgress else { return }
        result = .failed
    }

    /// Writes the verdict, and refuses to call a run clean that the user did not
    /// understand.
    ///
    /// Every terminal path goes through here so `result` and the call can never
    /// disagree. A user who was asked "win or draw for you?", answered wrong and
    /// then held the draw by shuffling has not shown the thing the KPK set
    /// exists to measure — and telling them they passed would teach them that
    /// their reading of the position was right.
    private mutating func finish(_ verdict: Result) {
        result = verdict == .passed && misjudgedStart ? .failed : verdict
    }

    private mutating func evaluate(lastMove: Move, byUser: Bool) {
        switch board.state {
        case let .checkmate(color):
            // `checkmate(color:)` names the side that *is* mated.
            guard color != userColor else {
                result = .failed
                return
            }
            finish(drill.kind == .kpk ? kpkVerdict(finished: .win) : .passed)
            return

        case let .draw(reason):
            // Kept whatever the verdict turns out to be, including on the
            // families where a draw passes: the banner is the only place the
            // user finds out whether they stalemated, repeated or ran the
            // fifty-move clock out, and those are three different lessons.
            drawReason = reason
            switch drill.kind {
            case .kpk:
                finish(kpkVerdict(finished: .draw))
            case .philidor:
                // A draw *is* the Philidor target.
                finish(.passed)
            case .kqk, .krk, .kbbk, .lucena:
                // A draw in a position winning by a piece or more is a failure
                // by definition — that is exactly what the drill tests.
                result = .failed
            }
            return

        default:
            break
        }

        // Queening is the pass for a `.win` drill. Checked after the terminal
        // states above, so promoting *into* stalemate still fails on the draw —
        // which is the point, because that is the way this ending is thrown
        // away.
        //
        // "Safely" is the whole guard, and it is deliberately the weakest one
        // that is still true: a new queen the opponent can take off the board
        // this move has won nothing, and anything more ambitious would mean
        // asserting that the resulting rook ending is won, which needs a
        // tablebase this build does not have. A queen that can be captured is
        // not scored against the user either — the run simply carries on.
        if drill.target == .win, byUser, lastMove.promotedPiece != nil,
            !sideToMoveCanCapture(on: lastMove.end)
        {
            queenedOnMove = userMoveCount
            finish(.passed)
            return
        }

        // The mirror of the above, for the side of the board a hold is played
        // from: the moment the attacker gets a new piece the defender cannot
        // take off, the hold is over. Scored here rather than at the budget
        // because a run that ended on move eight and is announced on move
        // twenty-five teaches nothing about the move that ended it — the user
        // spends seventeen moves defending a position that is already lost and
        // is then told the technique failed.
        //
        // Under-promotion is caught by the same guard: a second enemy rook wins
        // this ending as surely as a queen does, and asking after the piece kind
        // would let it through.
        if drill.target == .hold, !byUser, lastMove.promotedPiece != nil,
            !sideToMoveCanCapture(on: lastMove.end)
        {
            result = .failed
            return
        }

        guard userMoveCount >= moveBudget else { return }

        switch drill.kind {
        case .philidor:
            // Surviving the budget is the pass condition for a hold, but only
            // if the position is still one. See `holdStanding` for what the
            // board can prove by itself and what it has to hand to the engine.
            switch holdStanding {
            case .lost:
                finish(.failed)
            case .proven:
                finish(.passed)
            case .unproven:
                // Material says nothing has queened and the rook is still
                // there, which is not the same as a draw: a pawn on the seventh
                // with the rook passive and the king driven to the edge passes
                // every count on the board. The run is provisionally clean and
                // the caller is told to ask the engine before it is recorded.
                needsHoldRuling = true
                finish(.passed)
            }
        case .kpk:
            // Running out of moves without a conclusion means the drawn ones
            // were held and the won ones were not converted.
            finish(startingKPKOutcome == .draw && !lostTheoreticalResult ? .passed : .failed)
        case .kqk, .krk, .kbbk, .lucena:
            result = .failed
        }
    }

    /// What the board alone can say about a hold at the budget.
    enum HoldStanding: Sendable, Hashable {
        /// The position is drawn and the table says so.
        case proven
        /// The hold is over: the pawn queened, or the pawn ending is lost.
        case lost
        /// Nothing on the board settles it. Material is intact and no pawn has
        /// queened, which is a long way short of a draw.
        case unproven
    }

    /// Whether the defending side still has what it needs to draw.
    ///
    /// Two ways to still be holding, and the rook count only knew one of them.
    ///
    /// Trading the rooks off into king and pawn against king is a *correct* way
    /// to hold a rook ending, and it is the one a 1200 is most likely to find.
    /// Requiring a rook on the board scored that as a failed hold at the budget
    /// — the drill punished the cleanest draw available. Three men is also the
    /// one case here that is not a judgement call at all: the bitbase rules on
    /// it exactly, so it is answered from the table rather than from material.
    ///
    /// Everything else answers `.unproven` rather than "yes". The rook is still
    /// there and no pawn has queened, which is what "I am still alive" looks
    /// like from a position that is dead lost — rook passive, king on the edge,
    /// pawn on the seventh. There is no five-man tablebase in this build, so the
    /// board cannot close the question; ``applyHoldRuling(centipawns:)`` is how
    /// it gets closed.
    var holdStanding: HoldStanding {
        let pieces = board.position.pieces
        if let outcome = EndgameDrillRun.kpkOutcome(board.position),
            let pawn = pieces.first(where: { $0.kind == .pawn })
        {
            // `.win` names a win for the pawn's owner, so it only fails the hold
            // when the pawn belongs to the other side.
            return outcome == .draw || pawn.color == userColor ? .proven : .lost
        }
        let ownRooks = pieces.filter { $0.color == userColor && $0.kind == .rook }.count
        let enemy = pieces.filter { $0.color != userColor }
        // The drill starts as king, rook and pawn against king and rook, so any
        // enemy queen, bishop or knight — or a second enemy rook — can only have
        // arrived by promotion. Counting queens alone let an under-promotion to
        // a rook stand as a successful hold, which it is not: rook and rook
        // against rook wins as comfortably as queen against rook does.
        let promoted = enemy.contains { $0.kind == .queen || $0.kind == .bishop || $0.kind == .knight }
            || enemy.filter { $0.kind == .rook }.count > 1
        return ownRooks >= 1 && !promoted ? .unproven : .lost
    }

    /// How far the defender may be behind at the budget and still be credited
    /// with the hold.
    ///
    /// A held Philidor reads as a dead level score; the positions this is meant
    /// to catch — pawn on the seventh, defending king cut off — read as a clear
    /// plus for the attacker. The band sits well above the first and well below
    /// the second on purpose: a shallow search's noise must never cost a user a
    /// draw they actually held, so anything ambiguous is credited.
    static let holdDrawBand = 150

    /// Rules on a hold the board could not settle.
    ///
    /// - Parameter centipawns: the engine's score for the position on the
    ///   board, from the side to move's point of view, or `nil` for "no
    ///   opinion" — the engine was busy, the search was cut short, or there is
    ///   no engine at all. No opinion leaves the provisional pass standing,
    ///   because failing a user on a search that did not happen is the one
    ///   error this must not make.
    mutating func applyHoldRuling(centipawns: Int?) {
        guard needsHoldRuling, result == .passed else {
            needsHoldRuling = false
            return
        }
        needsHoldRuling = false
        guard let centipawns else { return }
        let forUser = board.position.sideToMove == userColor ? centipawns : -centipawns
        guard forUser < -Self.holdDrawBand else { return }
        result = .failed
        holdRuledLost = true
    }

    /// Whether the side to move can capture whatever stands on `square`.
    private func sideToMoveCanCapture(on square: Square) -> Bool {
        let mover = board.position.sideToMove
        for from in Square.allCases {
            guard let piece = board.position.piece(at: from), piece.color == mover else { continue }
            if board.canMove(pieceAt: from, to: square) { return true }
        }
        return false
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

    /// A legal move for the side to move that leaves `outcome` standing, in SAN.
    ///
    /// Asked of the bitbase and not of the engine, because the question is not
    /// "what is best" but "what still holds", and the table answers that
    /// exactly for every position this family can reach. It walks the mover's
    /// own squares rather than all sixty-four, which in a three-man ending is
    /// two of them.
    ///
    /// Promotions are skipped rather than judged. A queening move leaves KPK, so
    /// the table has no entry for the position it produces, and calling it a win
    /// without checking whether the new queen can be taken — or whether it is
    /// stalemate — would be exactly the unverified claim this file must not
    /// make. The cost is nil in the positions that matter: when the pawn can
    /// safely queen the drill is already over, and the moves that throw a KPK
    /// result away are king moves.
    static func moveKeeping(_ outcome: KPKOutcome, from position: Position) -> String? {
        let mover = position.sideToMove
        for from in Square.allCases {
            guard let piece = position.piece(at: from), piece.color == mover else { continue }
            for to in Square.allCases where to != from {
                var board = Board(position: position)
                guard board.canMove(pieceAt: from, to: to), let move = board.move(pieceAt: from, to: to) else {
                    continue
                }
                if case .promotion = board.state { continue }
                guard kpkOutcome(board.position) == outcome else { continue }
                return move.san
            }
        }
        return nil
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

    /// Scores a position the drill's own criteria could not settle.
    ///
    /// - Returns: Centipawns from the side to move's point of view, with a
    ///   forced mate folded to an extreme, or `nil` for "no opinion".
    func score(fen: String) async throws -> Int?
}

extension DrillOpponent {
    /// No opinion, so a hold the board could not disprove stands. Default so an
    /// opponent that only chooses moves — every test double, and the previews —
    /// keeps compiling and keeps grading exactly as it did.
    func score(fen: String) async throws -> Int? { nil }
}

/// A drill opponent that always resigns. Used in previews and tests.
struct NullDrillOpponent: DrillOpponent {
    func reply(fen: String) async throws -> String? { nil }
}
