//
//  PuzzleExplanationCorpusTests.swift
//  ChessCoachTests
//

import ChessKit
import Database
import Foundation
import Testing
import TrainingCore

@testable import ChessCoach

/// Runs the result-banner sentence over the real puzzle corpus and checks the
/// claims it makes.
///
/// ## Why a corpus sweep rather than more fixtures
///
/// Every bug found in this sentence so far was found by a person reading one
/// banner and noticing it was wrong — a winning king march called "a defensive
/// move", an explanation cut off mid-clause. Fixtures cannot find those: they
/// test the shapes somebody already thought of. The corpus has 120,000 real
/// positions and every one of them produces a sentence, so the honest way to ask
/// "is this copy correct" is to generate all of them and assert invariants over
/// the lot.
///
/// The checks are deliberately about *claims*, not taste:
/// - it must not speak in engine units;
/// - it must not assert material the line does not actually win;
/// - it must fit the space the banner has;
/// - it must not degenerate into naming a square;
/// - it must be a well-formed sentence.
///
/// ## Sample size
///
/// The committed run uses a few thousand puzzles, deterministically chosen, so
/// the suite keeps its ~3 second budget. Set `PUZZLE_CORPUS_SAMPLE` to a larger
/// number (or `all`) to sweep the whole database when hunting; set
/// `PUZZLE_CORPUS_REPORT` to a path to have the failures written out.
@Suite("Puzzle explanation corpus")
struct PuzzleExplanationCorpusTests {

    // MARK: Harness

    struct Violation {
        var puzzleID: String
        var rule: String
        var message: String
        var detail: String
    }

    /// One puzzle, reduced to what the banner builder needs.
    struct Case {
        var id: String
        var theme: ThemeTag
        /// Position the solver is looking at, i.e. after the setup move.
        var position: Position
        var answer: String
        var continuation: [String]
        var rating: Int
    }

    static var sampleSize: Int? {
        guard let raw = ProcessInfo.processInfo.environment["PUZZLE_CORPUS_SAMPLE"] else { return 4_000 }
        if raw.lowercased() == "all" { return nil }
        return Int(raw) ?? 4_000
    }

    /// Opens the corpus the app ships with.
    static func corpus() throws -> PuzzleRepository {
        let url = try #require(
            Bundle.main.url(forResource: "puzzles", withExtension: "sqlite"),
            "the bundled puzzle corpus is missing from this build"
        )
        let database = try PuzzleDatabase.open(at: url, excludeFromBackup: false)
        return PuzzleRepository(reader: database.reader)
    }

    /// Builds the solver-facing case for a puzzle, or nil when the row cannot be
    /// replayed at all (which is itself reported).
    static func makeCase(_ puzzle: Puzzle) -> Case? {
        guard let start = Position(fen: puzzle.fen),
            let setup = puzzle.setupMove,
            let (_, afterSetup) = LineReplayShim.apply(uci: setup, to: start),
            let answer = puzzle.solution.first
        else { return nil }
        return Case(
            id: puzzle.id,
            theme: TrainingVocabulary.primaryTheme(of: puzzle),
            position: afterSetup,
            answer: answer,
            continuation: Array(puzzle.solution.dropFirst()),
            rating: puzzle.rating
        )
    }

    // MARK: Invariants

    static let jargon: [(String, String)] = [
        ("centipawns", #"(?i)centipawns?"#),
        ("cp figure", #"\d+\s?cp\b"#),
        ("expected points", #"(?i)expected points"#),
        ("plies", #"(?i)\bpl(y|ies)\b"#),
        ("multipv", #"(?i)multipv"#),
        ("engine depth", #"(?i)\bdepth \d"#),
        ("bare decimal", #"(?<![\d.])\d+\.\d+(?![\d.])"#),
    ]

    /// Material the sentence claims, as a piece kind.
    static func claimedWin(in message: String) -> Piece.Kind? {
        for (kind, noun) in [
            (Piece.Kind.queen, "queen"), (.rook, "rook"), (.bishop, "bishop"),
            (.knight, "knight"), (.pawn, "pawn"),
        ] where message.contains("you win the \(noun)") {
            return kind
        }
        return nil
    }

    static func value(of kind: Piece.Kind) -> Int {
        switch kind {
        case .pawn: 1
        case .knight, .bishop: 3
        case .rook: 5
        case .queen: 9
        case .king: 0
        }
    }

    /// Net material the solver actually gains over the whole stored line.
    ///
    /// Counts every capture by both sides from the answer onward, which is the
    /// only claim the sentence is entitled to make: "you win the rook" after a
    /// line where the rook is recaptured is exactly the assertion the house rule
    /// forbids.
    static func netMaterial(for item: Case) -> Int {
        var position = item.position
        let solver = position.sideToMove
        var net = 0
        for (index, uci) in ([item.answer] + item.continuation).enumerated() {
            guard let (move, next) = LineReplayShim.apply(uci: uci, to: position) else { break }
            if case .capture(let taken) = move.result {
                let isSolvers = index % 2 == 0
                net += (isSolvers ? 1 : -1) * value(of: taken.kind)
            }
            _ = solver
            position = next
        }
        return net
    }

    static func check(_ item: Case, message: String, solved: Bool) -> [Violation] {
        var out: [Violation] = []
        func flag(_ rule: String, _ detail: String) {
            out.append(Violation(puzzleID: item.id, rule: rule, message: message, detail: detail))
        }

        for (name, pattern) in jargon
        where message.range(of: pattern, options: .regularExpression) != nil {
            flag("engine jargon: \(name)", "the banner is read by a ~1200 player")
        }

        if message.count > ResultBanner.messageBudget {
            flag("over the banner budget", "\(message.count) characters against \(ResultBanner.messageBudget)")
        }

        // Well-formedness. A sentence assembled from clauses is exactly where
        // doubled punctuation and stray articles come from.
        for (name, pattern) in [
            ("double space", #"  "#),
            ("space before punctuation", #"\s[,.;:]"#),
            ("doubled period", #"\.\."#),
            ("doubled word", #"(?i)\b(\w+) \1\b"#),
            ("empty clause", #"(?i)(—|:|,)\s*(\.|$)"#),
        ] where message.range(of: pattern, options: .regularExpression) != nil {
            flag("malformed: \(name)", "")
        }

        if !message.hasSuffix(".") && !message.hasSuffix("!") {
            flag("unterminated sentence", "")
        }

        // The claim check that matters: material asserted must be material won.
        if let claimed = claimedWin(in: message) {
            let net = netMaterial(for: item)
            if net < value(of: claimed) {
                flag(
                    "asserts material the line does not win",
                    "claims the \(claimed), line nets \(net)"
                )
            }
        }

        return out
    }

    // MARK: The sweep

    @Test("Every banner the corpus can produce is honest, readable and fits")
    func sweep() throws {
        let repository = try Self.corpus()
        let bounds = try #require(try repository.ratingBounds(), "empty corpus")
        let all = try repository.puzzles(
            ratingRange: bounds,
            themes: .empty,
            limit: Self.sampleSize ?? Int.max
        )
        #expect(!all.isEmpty, "no puzzles were read from the corpus")

        var violations: [Violation] = []
        var unreplayable: [String] = []
        var themeFallbacks = 0
        var squareFallbacks = 0
        var examined = 0

        for puzzle in all {
            guard let item = Self.makeCase(puzzle) else {
                unreplayable.append(puzzle.id)
                continue
            }
            examined += 1

            for solved in [true, false] {
                let message = PuzzleConcept.verdictMessage(
                    solved: solved,
                    theme: item.theme,
                    answer: item.answer,
                    position: item.position,
                    continuation: item.continuation
                )
                violations.append(contentsOf: Self.check(item, message: message, solved: solved))
                if solved { continue }
                if message.contains("This puzzle was about") { themeFallbacks += 1 }
                if message.range(of: #"the move was to [a-h][1-8]\.$"#, options: .regularExpression) != nil {
                    squareFallbacks += 1
                }
            }
        }

        Self.writeReport(
            examined: examined,
            violations: violations,
            unreplayable: unreplayable,
            themeFallbacks: themeFallbacks,
            squareFallbacks: squareFallbacks
        )

        let byRule = Dictionary(grouping: violations, by: \.rule)
            .mapValues(\.count)
            .sorted { $0.value > $1.value }
        let summary = byRule.map { "\($0.key): \($0.value)" }.joined(separator: "; ")

        #expect(
            violations.isEmpty,
            """
            \(violations.count) banner violations over \(examined) puzzles — \(summary).
            First few: \(violations.prefix(5).map { "\($0.puzzleID) [\($0.rule)] \($0.message)" }.joined(separator: " | "))
            """
        )
        #expect(unreplayable.isEmpty, "\(unreplayable.count) corpus rows could not be replayed")
    }

    static func writeReport(
        examined: Int,
        violations: [Violation],
        unreplayable: [String],
        themeFallbacks: Int,
        squareFallbacks: Int
    ) {
        guard let path = ProcessInfo.processInfo.environment["PUZZLE_CORPUS_REPORT"] else { return }
        var text = "examined \(examined) puzzles\n"
        text += "unreplayable rows: \(unreplayable.count)\n"
        text += "theme-noun fallbacks (no board-derived clause): \(themeFallbacks)"
        text += String(format: "  (%.1f%%)\n", examined > 0 ? Double(themeFallbacks) / Double(examined) * 100 : 0)
        text += "bare-square fallbacks: \(squareFallbacks)"
        text += String(format: "  (%.1f%%)\n", examined > 0 ? Double(squareFallbacks) / Double(examined) * 100 : 0)
        text += "violations: \(violations.count)\n\n"

        let grouped = Dictionary(grouping: violations, by: \.rule).sorted { $0.value.count > $1.value.count }
        for (rule, items) in grouped {
            text += "== \(rule) — \(items.count)\n"
            for item in items.prefix(12) {
                text += "   \(item.puzzleID): \(item.message)\n"
                if !item.detail.isEmpty { text += "      \(item.detail)\n" }
            }
            text += "\n"
        }
        try? text.write(toFile: path, atomically: true, encoding: .utf8)
    }
}

/// `LineReplay` lives in AnalysisKit, which the app target links but this test
/// does not import directly; this keeps the corpus harness free of that
/// dependency and of any behaviour difference from it.
enum LineReplayShim {
    static func apply(uci: String, to position: Position) -> (move: Move, position: Position)? {
        guard uci.count >= 4 else { return nil }
        let characters = Array(uci)
        let start = Square(String(characters[0...1]))
        let end = Square(String(characters[2...3]))
        var board = Board(position: position)
        guard var move = board.move(pieceAt: start, to: end) else { return nil }
        if characters.count == 5 {
            let kind: Piece.Kind =
                switch characters[4] {
                case "n": .knight
                case "b": .bishop
                case "r": .rook
                default: .queen
                }
            move = board.completePromotion(of: move, to: kind)
        } else if case .promotion(let pending) = board.state, pending.end == end {
            move = board.completePromotion(of: move, to: .queen)
        }
        return (move, board.position)
    }
}
