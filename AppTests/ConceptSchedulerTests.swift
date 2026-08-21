//
//  ConceptSchedulerTests.swift
//  ChessCoachTests
//

import Foundation
import ChessKit
import Testing
import TrainingCore

@testable import ChessCoach

/// The set has one concept slot and the app fills it. These are the rules that
/// decide what a user is taught and when.
@Suite("Concept scheduling")
struct ConceptSchedulerTests {

    private func states(_ pairs: [(String, ConceptScheduler.State)]) -> [String: ConceptScheduler.State] {
        Dictionary(uniqueKeysWithValues: pairs)
    }

    @Test("A concept never seen is taught before it is tested")
    func teachesBeforeTesting() throws {
        let selection = try #require(ConceptScheduler.next(rating: 1000, states: [:]))
        #expect(selection.teachFirst)
    }

    /// The whole point of the rating tier: Philidor taught at 900 is Philidor
    /// forgotten by the time a rook ending ever appears.
    @Test("Concepts above the user's rating are not served yet")
    func respectsRatingTiers() {
        let early = TrainingConcept.available(atRating: 900).map(\.id)
        #expect(early.contains("opening.london"))
        #expect(early.contains("endgame.kqk"))
        #expect(early.contains("endgame.philidor") == false)
        #expect(early.contains("positional.outpost") == false)

        let later = TrainingConcept.available(atRating: 1500).map(\.id)
        #expect(later.contains("endgame.philidor"))
        #expect(later.contains("positional.outpost"))
    }

    @Test("The family rotates rather than repeating yesterday's subject")
    func rotatesFamilies() throws {
        let selection = try #require(
            ConceptScheduler.next(rating: 1500, states: [:], lastFamily: .opening)
        )
        #expect(selection.concept.family != .opening)
    }

    /// Rotation is a preference, not a rule: serving nothing is worse than
    /// serving the same family twice.
    @Test("Rotation gives way rather than leaving the slot empty")
    func rotationNeverStarvesTheSlot() throws {
        // At rating 0 only openings and the three basic endgames exist; ask for
        // something that is not an endgame or an opening and it must still pick.
        let openingsOnly = TrainingConcept.available(atRating: 0)
            .filter { $0.family == .opening }
        #expect(openingsOnly.isEmpty == false)

        let selection = try #require(
            ConceptScheduler.next(rating: 0, states: [:], lastFamily: .positional)
        )
        #expect(selection.concept.fromRating <= 0)
    }

    @Test("Once everything is taught, the least practised comes back")
    func returnsToTheLeastPractised() throws {
        let all = TrainingConcept.available(atRating: 1500)
        var seen = states(
            all.map {
                ($0.id, ConceptScheduler.State(id: $0.id, isIntroduced: true, timesSeen: 5,
                                               lastSeenAt: Date(timeIntervalSince1970: 10_000)))
            }
        )
        let neglected = try #require(all.first { $0.family == .positional })
        seen[neglected.id] = ConceptScheduler.State(
            id: neglected.id, isIntroduced: true, timesSeen: 1,
            lastSeenAt: Date(timeIntervalSince1970: 20)
        )

        let selection = try #require(ConceptScheduler.next(rating: 1500, states: seen))
        #expect(selection.concept.id == neglected.id)
        #expect(selection.teachFirst == false, "it has been taught; this is an exercise")
    }

    /// A concept shown but never exercised is more overdue than one practised
    /// last week, not less.
    @Test("Taught but never practised sorts before recently practised")
    func neverPractisedIsMostOverdue() throws {
        let all = TrainingConcept.available(atRating: 1500)
        var seen = states(
            all.map {
                ($0.id, ConceptScheduler.State(id: $0.id, isIntroduced: true, timesSeen: 3,
                                               lastSeenAt: Date(timeIntervalSince1970: 5_000)))
            }
        )
        let untouched = try #require(all.first { $0.family == .endgame })
        seen[untouched.id] = ConceptScheduler.State(id: untouched.id, isIntroduced: true, timesSeen: 0)

        let selection = try #require(ConceptScheduler.next(rating: 1500, states: seen))
        #expect(selection.concept.id == untouched.id)
    }

    /// Every taught line is replayed move by move against a real board.
    ///
    /// The lines are checked against Stockfish by hand when they are written,
    /// but nothing stopped a typo in a UCI string from shipping a line that
    /// simply stops halfway — and it would fail silently, as a lesson whose
    /// exercise ends early rather than as a crash. This is the guard for the
    /// next opening somebody adds.
    @Test("Every opening line in the catalogue is legal from start to finish")
    func openingLinesAreLegal() throws {
        for concept in TrainingConcept.catalogue {
            guard case let .line(fen, moves, opponentMovesFirst) = concept.exercise else { continue }

            let start = try #require(Position(fen: fen), "\(concept.id): unparseable FEN")
            var board = Board(position: start)

            for (index, uci) in moves.enumerated() {
                #expect(
                    PuzzleSolveMachine.move(uci: uci, on: &board) != nil,
                    "\(concept.id): move \(index) (\(uci)) is not legal"
                )
            }

            // The solver has to have the last word, or the exercise ends on the
            // opponent's move and the user is left holding a finished board.
            let solverPlaysEvenIndices = !opponentMovesFirst
            let lastIsSolvers = (moves.count - 1) % 2 == (solverPlaysEvenIndices ? 0 : 1)
            #expect(lastIsSolvers, "\(concept.id): the line ends on the opponent's move")
        }
    }

    /// The banner shows four lines and cuts anything past them. A measured
    /// sample put the full `lookFor` at a median of 128 characters — longer
    /// than the whole banner — so the concept verdict uses only its first
    /// sentence. This holds that sentence to a length the banner can show.
    @Test("Every concept's banner cue fits the result banner")
    func cuesFitTheBanner() {
        // Four lines at roughly 29 characters, less the longest realistic
        // "Missed — the bishop takes the knight." opening.
        let budget = 116 - 40

        for concept in TrainingConcept.catalogue {
            let cue = concept.teaching.cue
            #expect(!cue.isEmpty, "\(concept.id): empty cue")
            #expect(cue.hasSuffix("."), "\(concept.id): cue is not a whole sentence")
            #expect(
                cue.count <= budget,
                "\(concept.id): cue is \(cue.count) characters, over the \(budget) the banner can show"
            )
        }
    }

    @Test("Every concept in the catalogue carries a real lesson")
    func everyConceptTeaches() {
        for concept in TrainingConcept.catalogue {
            #expect(concept.teaching.idea.isEmpty == false, "\(concept.id) has no idea")
            #expect(concept.teaching.why.isEmpty == false, "\(concept.id) has no why")
            #expect(concept.teaching.lookFor.isEmpty == false, "\(concept.id) has no cue")
            #expect(concept.title.isEmpty == false)
        }
        #expect(Set(TrainingConcept.catalogue.map(\.id)).count == TrainingConcept.catalogue.count)
    }
}

/// The set's shape: the concept opens it, the puzzles follow.
///
/// It used to close the set, and almost nobody reached it — getting there meant
/// finishing all ten puzzles in one sitting, so a set abandoned partway taught
/// nothing at all.
@Suite("Set composition")
@MainActor
struct SetCompositionTests {

    private var aDrill: TrainingConcept {
        TrainingConcept.catalogue.first {
            if case .drill = $0.exercise { return true }
            return false
        } ?? TrainingConcept.catalogue[0]
    }

    @Test("The set opens on the concept, not on a puzzle")
    func conceptOpensTheSet() async {
        let model = PuzzleSessionModel(
            driver: SetShapeDriver(),
            database: nil,
            concept: .init(concept: aDrill, teachFirst: true)
        )
        await model.start()

        #expect(model.teachingConcept?.id == aDrill.id, "the lesson has to come first")
    }

    /// A drill cannot run inside the session — it needs its own screen — so it
    /// is handed to the Train tab and the puzzles carry on immediately. The bug
    /// this guards is the set ending right there, before a single puzzle.
    @Test("After the concept the puzzles still run")
    func puzzlesFollowTheConcept() async {
        let model = PuzzleSessionModel(
            driver: SetShapeDriver(),
            database: nil,
            concept: .init(concept: aDrill, teachFirst: true)
        )
        await model.start()
        model.beginConceptExercise()

        #expect(model.pendingDrill != nil, "the drill should be handed to the Train tab")
        #expect(model.stage == .solving, "the puzzles have to follow the concept")
    }
}

/// A driver with one puzzle queued, which is all these tests need.
@MainActor
private final class SetShapeDriver: PuzzleSessionDriver {
    var queueCount: Int { 1 }
    var currentIndex: Int { 0 }
    var itemOnScreen: SessionItemPlan? { plan }
    var solveMachine: PuzzleSolveMachine? { machine }
    var isSessionFinished: Bool { false }
    var loadFailure: String? { nil }
    var puzzleRating: Double { 1200 }

    private let plan: SessionItemPlan
    private var machine: PuzzleSolveMachine?

    init() {
        let item = SolvableItem(
            backing: .corpusPuzzle(id: UUID().uuidString),
            fen: "rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1",
            line: ["e2e4", "e7e5"],
            opponentMovesFirst: true,
            rating: 1200,
            primaryTheme: .fork
        )
        plan = SessionItemPlan(kind: .fresh, presented: PresentedPuzzle(item: item, preferring: .identity))
    }

    func startSession(focus: WeeklyFocus?) async {
        machine = plan.presented.machine(retryPolicy: plan.retryPolicy)
        machine?.start()
    }
    func offer(uci: String) async -> PuzzleSolveMachine.MoveResult { .illegal }
    func revealHint() -> String? { nil }
    func skipCurrent() async {}
}

/// The lesson draws the position its exercise reaches, so the card and the
/// practice cannot describe different things.
@Suite("Concept previews")
struct ConceptPreviewTests {

    @Test("Every opening and endgame lesson has a board to show")
    func teachableConceptsDraw() {
        for concept in TrainingConcept.catalogue {
            switch concept.exercise {
            case .line, .drill:
                #expect(concept.preview != nil, "\(concept.id): nothing to draw")
                #expect(concept.previewCaption != nil, "\(concept.id): drawn with no caption")
            case .corpusFeature:
                // Searched for at run time, so there is no fixed position.
                #expect(concept.preview == nil)
            }
        }
    }

    /// The London card named d4, Bf4 and e3; the exercise then asked for Nf3
    /// and Nbd2. The drawn position is the end of the line, so the knights are
    /// on the board whether or not anybody wrote them into the prose.
    @Test("The drawn position is where the moves actually end")
    func previewIsTheFinishedSetup() throws {
        let london = try #require(TrainingConcept.catalogue.first { $0.id == "opening.london" })
        let preview = try #require(london.preview)

        // Nf3 and Nbd2 — the two moves the lesson never mentioned.
        #expect(preview.position.piece(at: .f3)?.kind == .knight)
        #expect(preview.position.piece(at: .d2)?.kind == .knight)
        // And the bishop the lesson is actually about.
        #expect(preview.position.piece(at: .f4)?.kind == .bishop)
        #expect(preview.orientation == .white, "shown from the side doing the learning")
    }

    @Test("A lesson for the side moving second is drawn from their side")
    func orientationFollowsTheSolver() throws {
        let italian = try #require(TrainingConcept.catalogue.first { $0.id == "opening.italian" })
        #expect(try #require(italian.preview).orientation == .black)
    }
}
