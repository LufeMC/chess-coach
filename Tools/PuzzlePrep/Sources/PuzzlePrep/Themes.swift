import Foundation

// MARK: - Theme ordering: shared wire-format contract
//
// ############################################################################
// # DO NOT REORDER, INSERT INTO, OR REMOVE FROM `ThemeTable.ordering`.        #
// ############################################################################
//
// WHY THIS IS DELICATE:
// The position of a theme in this list IS its bit index in the `themes_lo` /
// `themes_hi` columns of the generated SQLite file. Nothing in the database
// records theme *names* — a puzzle's themes exist only as set bits. The reader
// side (`Packages/Database`, `enum PuzzleTheme`) reconstructs names purely from
// case order, so the two lists are a wire format shared across two modules that
// never import each other.
//
// Consequences of getting this wrong are silent, not loud: shifting one entry
// does not crash anything, it just makes every puzzle in the shipped database
// claim the wrong tactics. A user asking to train forks would be served pins.
//
// SAFE CHANGE: append new themes to the END of the list, and bump
// `themeOrderingVersion`. Appending is safe because existing bit indices are
// untouched; readers built against an older ordering simply do not know the new
// trailing bits. There is deliberate headroom for this — see the bit layout
// below, which reserves room for 8 more themes past the current 65.
//
// UNSAFE CHANGE: anything else. Reordering, alphabetising, inserting in the
// middle, or deleting a retired theme all renumber later bits and invalidate
// every previously built database.
//
// This list is intentionally hardcoded rather than imported from
// `Packages/Database`. The duplication is the point: this tool must build from
// a bare checkout without the app's package graph, and a copy that is loudly
// documented as a contract is safer than a dependency edge that quietly
// couples a build tool to app code. The two lists are kept in sync by hand,
// and `themeOrderingVersion` in the `meta` table lets a reader detect a
// mismatch instead of misinterpreting bits.

enum ThemeTable {
    /// Bumped whenever `ordering` changes. Written to `meta.theme_ordering_version`
    /// so a reader can refuse a database built against a different ordering
    /// rather than silently mis-decoding every theme bit.
    static let themeOrderingVersion = 1

    /// Bit index of a theme == its position in this array, starting at 0.
    static let ordering: [String] = [
        "advancedPawn",              // 0
        "advantage",                 // 1
        "anastasiaMate",             // 2
        "arabianMate",               // 3
        "attackingF2F7",             // 4
        "attraction",                // 5
        "backRankMate",              // 6
        "bishopEndgame",             // 7
        "bodenMate",                 // 8
        "castling",                  // 9
        "capturingDefender",         // 10
        "crushing",                  // 11
        "doubleBishopMate",          // 12
        "dovetailMate",              // 13
        "equality",                  // 14
        "kingsideAttack",            // 15
        "clearance",                 // 16
        "defensiveMove",             // 17
        "deflection",                // 18
        "discoveredAttack",          // 19
        "doubleCheck",               // 20
        "endgame",                   // 21
        "enPassant",                 // 22
        "exposedKing",               // 23
        "fork",                      // 24
        "hangingPiece",              // 25
        "hookMate",                  // 26
        "interference",              // 27
        "intermezzo",                // 28
        "killBoxMate",               // 29
        "vukovicMate",               // 30
        "knightEndgame",             // 31
        "long",                      // 32
        "master",                    // 33
        "masterVsMaster",            // 34
        "mate",                      // 35
        "mateIn1",                   // 36
        "mateIn2",                   // 37
        "mateIn3",                   // 38
        "mateIn4",                   // 39
        "mateIn5",                   // 40
        "middlegame",                // 41
        "oneMove",                   // 42
        "opening",                   // 43
        "pawnEndgame",               // 44
        "pin",                       // 45
        "promotion",                 // 46
        "queenEndgame",              // 47
        "queenRookEndgame",          // 48
        "queensideAttack",           // 49
        "quietMove",                 // 50
        "rookEndgame",               // 51
        "sacrifice",                 // 52
        "short",                     // 53
        "skewer",                    // 54
        "smotheredMate",             // 55
        "superGM",                   // 56
        "trappedPiece",              // 57
        "underPromotion",            // 58
        "veryLong",                  // 59
        "xRayAttack",                // 60
        "zugzwang",                  // 61
        "mix",                       // 62
        "playerGames",               // 63
        "puzzleDownloadInformation", // 64
    ]

    /// Name -> bit index, built once from `ordering`.
    static let bitIndex: [String: Int] = {
        var map = [String: Int](minimumCapacity: ordering.count * 2)
        for (i, name) in ordering.enumerated() { map[name] = i }
        return map
    }()
}

// MARK: - Theme bit mask

/// A 73-bit theme set, split across the two Int64 columns the schema exposes.
///
/// BIT LAYOUT (the other half of the wire-format contract):
///   `themes_lo` holds bit indices 0...62  (63 bits)
///   `themes_hi` holds bit indices 63...72 (10 bits, stored right-shifted by 63,
///                                          so global bit 63 is hi bit 0)
///
/// WHY 63 AND NOT 64 IN THE LOW WORD: SQLite integers are *signed* 64-bit. If
/// `themes_lo` used bit 63 it would round-trip as a negative number, and any
/// reader doing arithmetic (or a plain `WHERE themes_lo & mask` in SQL) would
/// have to reason about sign extension. Capping the low word at 63 bits keeps
/// both columns non-negative in every language that reads this file.
///
/// WHY 73 BITS FOR 65 THEMES: the 8 unused high bits are deliberate headroom.
/// Lichess adds themes over time, and appending to `ThemeTable.ordering` must
/// not require a schema migration.
struct ThemeMask: Sendable, Equatable {
    /// Global bits 0...62.
    private(set) var lo: UInt64 = 0
    /// Global bits 63...72, stored shifted down by 63.
    private(set) var hi: UInt64 = 0

    /// Number of bits stored in the low word. See the type doc for why it is 63.
    static let lowWordBits = 63
    /// Total addressable bits across both columns.
    static let totalBits = 73

    init() {}

    mutating func set(_ bit: Int) {
        precondition(bit >= 0 && bit < Self.totalBits, "theme bit \(bit) outside the 73-bit mask")
        if bit < Self.lowWordBits {
            lo |= (1 << UInt64(bit))
        } else {
            hi |= (1 << UInt64(bit - Self.lowWordBits))
        }
    }

    func contains(_ bit: Int) -> Bool {
        if bit < Self.lowWordBits {
            return lo & (1 << UInt64(bit)) != 0
        } else {
            return hi & (1 << UInt64(bit - Self.lowWordBits)) != 0
        }
    }

    /// Both accessors are safe casts, never negative: `lo` only ever uses 63
    /// bits and `hi` only ever uses 10.
    var loColumnValue: Int64 { Int64(bitPattern: lo) }
    var hiColumnValue: Int64 { Int64(bitPattern: hi) }
}
