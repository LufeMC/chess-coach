import Foundation

// MARK: - PuzzleTheme

/// A Lichess puzzle theme tag.
///
/// # ⚠️ WIRE FORMAT — CASES MAY ONLY EVER BE APPENDED ⚠️
///
/// The *declaration order* of these cases is the on-disk encoding of the
/// `puzzle.themes_lo` / `puzzle.themes_hi` columns. `PuzzleTheme.bit` is simply
/// the case's offset in this list, and the offline puzzle-prep tool that builds
/// `puzzles.sqlite` derives its bit assignments from this exact same ordering.
///
/// Therefore:
///
/// * **NEVER reorder cases.** Every previously built database instantly decodes
///   into the wrong themes.
/// * **NEVER remove a case.** Removing one shifts every case after it. If a
///   theme is retired upstream, keep the case and mark it deprecated.
/// * **ONLY append**, at the very end, below the `puzzleDownloadInformation`
///   marker — and only up to ``ThemeMask/bitCapacity`` total cases.
///
/// Any change here must land in the same commit as the corresponding change to
/// the offline tool, and the bundled `puzzles.sqlite` must be rebuilt.
///
/// ## Provenance
///
/// This list is the theme set agreed with the offline puzzle-prep tool. Upstream
/// Lichess (`modules/puzzle/src/main/PuzzleTheme.scala`) additionally defines
/// these themes, which are *not* yet encoded here and are the natural candidates
/// for the next append: `balestraMate`, `blindSwineMate`, `triangleMate`,
/// `collinearMove`, `cornerMate`, `discoveredCheck`, `epauletteMate`,
/// `pillsburysMate`, `morphysMate`, `operaMate`, `swallowstailMate`,
/// `checkFirst`. Eight of those twelve fit in the spare bits of the current
/// 73-bit layout; going past that needs a storage change (see ``ThemeMask``).
public enum PuzzleTheme: String, CaseIterable, Sendable, Hashable, Codable {
    // ⚠️ APPEND ONLY — see the type documentation above. ⚠️
    case advancedPawn
    case advantage
    case anastasiaMate
    case arabianMate
    case attackingF2F7
    case attraction
    case backRankMate
    case bishopEndgame
    case bodenMate
    case castling
    case capturingDefender
    case crushing
    case doubleBishopMate
    case dovetailMate
    case equality
    case kingsideAttack
    case clearance
    case defensiveMove
    case deflection
    case discoveredAttack
    case doubleCheck
    case endgame
    case enPassant
    case exposedKing
    case fork
    case hangingPiece
    case hookMate
    case interference
    case intermezzo
    case killBoxMate
    case vukovicMate
    case knightEndgame
    case long
    case master
    case masterVsMaster
    case mate
    case mateIn1
    case mateIn2
    case mateIn3
    case mateIn4
    case mateIn5
    case middlegame
    case oneMove
    case opening
    case pawnEndgame
    case pin
    case promotion
    case queenEndgame
    case queenRookEndgame
    case queensideAttack
    case quietMove
    case rookEndgame
    case sacrifice
    case short
    case skewer
    case smotheredMate
    case superGM
    case trappedPiece
    case underPromotion
    case veryLong
    case xRayAttack
    case zugzwang
    case mix
    case playerGames
    case puzzleDownloadInformation
    // ⚠️ APPEND NEW CASES BELOW THIS LINE ONLY. ⚠️

    /// The bit index this theme occupies in a ``ThemeMask``.
    ///
    /// Derived from declaration order — see the append-only contract above.
    public var bit: Int {
        // `allCases` is generated in declaration order, so the index *is* the bit.
        Self.bitByTheme[self].unsafelyUnwrapped
    }

    /// The single-theme mask for this theme.
    public var mask: ThemeMask { ThemeMask(bit: bit) }

    /// The theme occupying a given bit index, or `nil` if the bit is unassigned.
    ///
    /// Unassigned bits are not an error: a `puzzles.sqlite` built by a *newer*
    /// tool can legitimately carry bits this build does not know about yet, and
    /// those are silently ignored rather than treated as corruption.
    public static func theme(at bit: Int) -> PuzzleTheme? {
        allCases.indices.contains(bit) ? allCases[bit] : nil
    }

    /// The Lichess tag string as it appears in the puzzle CSV export.
    public var tag: String { rawValue }

    private static let bitByTheme: [PuzzleTheme: Int] = {
        var result: [PuzzleTheme: Int] = [:]
        for (index, theme) in allCases.enumerated() { result[theme] = index }
        return result
    }()
}

// MARK: - ThemeMask

/// A set of ``PuzzleTheme`` values packed into the 73-bit representation used by
/// the `puzzle` table.
///
/// SQLite has no unsigned 64-bit integer type: every `INTEGER` is a *signed*
/// `Int64`, so bit 63 of a single column cannot be used without the value going
/// negative and breaking range comparisons. The format therefore splits the mask
/// across two columns:
///
/// * `themes_lo` — bits 0...62 (63 usable bits)
/// * `themes_hi` — bits 63...72 (10 usable bits)
///
/// Both columns are consequently always non-negative, which keeps the encoding
/// legible in a SQL shell and safe to compare.
public struct ThemeMask: Sendable, Hashable {
    /// Total number of theme bits this format can represent.
    ///
    /// Widening past this requires a new column in `puzzle` plus a coordinated
    /// change to the offline tool — `puzzles.sqlite` is rebuilt from scratch each
    /// release, so it is possible, just not free.
    public static let bitCapacity = 73

    /// Number of bits carried by the `themes_lo` column.
    public static let lowBitCount = 63

    /// Bits 0...62, as stored in `puzzle.themes_lo`.
    public private(set) var low: UInt64
    /// Bits 63...72, as stored in `puzzle.themes_hi`.
    public private(set) var high: UInt64

    public static let empty = ThemeMask(low: 0, high: 0)

    // No defaulted parameters here: with `ExpressibleByArrayLiteral` also
    // providing a zero-argument form, defaults would make `ThemeMask()`
    // ambiguous. Use `.empty` for the empty mask.
    public init(low: UInt64, high: UInt64) {
        self.low = low & Self.lowFieldMask
        self.high = high & Self.highFieldMask
    }

    /// Rebuilds a mask from the two `Int64` column values read out of SQLite.
    public init(storedLow: Int64, storedHigh: Int64) {
        // Negative values can only come from a corrupt or foreign encoding; the
        // masking below discards the sign bit rather than trapping, so a bad row
        // degrades to "fewer themes" instead of crashing puzzle selection.
        self.init(low: UInt64(bitPattern: storedLow), high: UInt64(bitPattern: storedHigh))
    }

    public init(bit: Int) {
        self = .empty
        insert(bit: bit)
    }

    public init(_ themes: some Sequence<PuzzleTheme>) {
        self = .empty
        for theme in themes { insert(theme) }
    }

    /// The value for the `themes_lo` column. Always >= 0.
    public var storedLow: Int64 { Int64(bitPattern: low) }
    /// The value for the `themes_hi` column. Always >= 0.
    public var storedHigh: Int64 { Int64(bitPattern: high) }

    public var isEmpty: Bool { low == 0 && high == 0 }

    public mutating func insert(_ theme: PuzzleTheme) { insert(bit: theme.bit) }

    public mutating func remove(_ theme: PuzzleTheme) { remove(bit: theme.bit) }

    public func contains(_ theme: PuzzleTheme) -> Bool { contains(bit: theme.bit) }

    /// The themes this build knows about. Bits set by a newer encoder are skipped.
    public var themes: [PuzzleTheme] {
        PuzzleTheme.allCases.filter { contains($0) }
    }

    /// True if the two masks share at least one bit — the "any of these themes"
    /// test used by puzzle selection.
    public func intersects(_ other: ThemeMask) -> Bool {
        (low & other.low) != 0 || (high & other.high) != 0
    }

    public func union(_ other: ThemeMask) -> ThemeMask {
        ThemeMask(low: low | other.low, high: high | other.high)
    }

    public func intersection(_ other: ThemeMask) -> ThemeMask {
        ThemeMask(low: low & other.low, high: high & other.high)
    }

    // MARK: Bit-level access

    public mutating func insert(bit: Int) {
        precondition(
            (0..<Self.bitCapacity).contains(bit),
            "Theme bit \(bit) is outside the \(Self.bitCapacity)-bit mask format"
        )
        if bit < Self.lowBitCount {
            low |= 1 << UInt64(bit)
        } else {
            high |= 1 << UInt64(bit - Self.lowBitCount)
        }
    }

    public mutating func remove(bit: Int) {
        guard (0..<Self.bitCapacity).contains(bit) else { return }
        if bit < Self.lowBitCount {
            low &= ~(1 << UInt64(bit))
        } else {
            high &= ~(1 << UInt64(bit - Self.lowBitCount))
        }
    }

    public func contains(bit: Int) -> Bool {
        guard (0..<Self.bitCapacity).contains(bit) else { return false }
        return bit < Self.lowBitCount
            ? (low & (1 << UInt64(bit))) != 0
            : (high & (1 << UInt64(bit - Self.lowBitCount))) != 0
    }

    private static let lowFieldMask: UInt64 = (1 << UInt64(lowBitCount)) - 1
    private static let highFieldMask: UInt64 = (1 << UInt64(bitCapacity - lowBitCount)) - 1
}

extension ThemeMask: ExpressibleByArrayLiteral {
    public init(arrayLiteral elements: PuzzleTheme...) { self.init(elements) }
}

extension ThemeMask: CustomStringConvertible {
    public var description: String {
        isEmpty ? "ThemeMask([])" : "ThemeMask([\(themes.map(\.rawValue).joined(separator: ", "))])"
    }
}

// MARK: - Encoding helpers

extension PuzzleTheme {
    /// Packs Lichess tag strings (the space-separated `themes` CSV column) into a
    /// mask. Unrecognised tags are reported so the caller can decide whether an
    /// unknown upstream theme is worth appending to the enum.
    public static func encode(
        tags: some Sequence<String>
    ) -> (mask: ThemeMask, unknown: [String]) {
        var mask = ThemeMask.empty
        var unknown: [String] = []
        for tag in tags {
            guard !tag.isEmpty else { continue }
            if let theme = PuzzleTheme(rawValue: tag) {
                mask.insert(theme)
            } else {
                unknown.append(tag)
            }
        }
        return (mask, unknown)
    }

    /// Splits and packs a raw Lichess `themes` field (`"mateIn2 fork short"`).
    public static func encode(
        tagList: String
    ) -> (mask: ThemeMask, unknown: [String]) {
        encode(tags: tagList.split(separator: " ").map(String.init))
    }
}
