import Foundation

// MARK: - Configuration

struct Config {
    var input: String
    var output: String
    var targetCount = 120_000
    var perThemeMinimum = 1_500
    /// Arbitrary but FIXED — see `SplitMix64` for why this must not be
    /// time-seeded or drawn from the system RNG.
    var seed: UInt64 = 0x5EED_0BAD_C0FF_EE01
    var minPopularity = 85
    var minPlays = 500
    var maxRatingDeviation = 90

    /// Defaults are resolved from the source location rather than the working
    /// directory so `swift run PuzzlePrep` behaves the same from anywhere in
    /// the repo. Safe here because this tool only ever runs from its checkout.
    static func defaults() -> Config {
        // .../Tools/PuzzlePrep/Sources/PuzzlePrep/PuzzlePrep.swift
        let thisFile = URL(fileURLWithPath: #filePath)
        let toolRoot = thisFile
            .deletingLastPathComponent() // PuzzlePrep
            .deletingLastPathComponent() // Sources
            .deletingLastPathComponent() // Tools/PuzzlePrep
        let repoRoot = toolRoot
            .deletingLastPathComponent() // Tools
            .deletingLastPathComponent() // repo root
        return Config(
            input: toolRoot.appendingPathComponent("data/lichess_db_puzzle.csv.zst").path,
            output: repoRoot.appendingPathComponent("App/Resources/puzzles.sqlite").path
        )
    }

    static func parse(_ args: [String]) -> Config {
        var c = Config.defaults()
        var i = 1
        while i < args.count {
            let key = args[i]
            func value() -> String? {
                guard i + 1 < args.count else { return nil }
                i += 1
                return args[i]
            }
            switch key {
            case "--input": if let v = value() { c.input = v }
            case "--output": if let v = value() { c.output = v }
            case "--target": if let v = value(), let n = Int(v) { c.targetCount = n }
            case "--min-per-theme": if let v = value(), let n = Int(v) { c.perThemeMinimum = n }
            case "--seed": if let v = value(), let n = UInt64(v) { c.seed = n }
            case "--min-popularity": if let v = value(), let n = Int(v) { c.minPopularity = n }
            case "--min-plays": if let v = value(), let n = Int(v) { c.minPlays = n }
            case "--max-rating-dev": if let v = value(), let n = Int(v) { c.maxRatingDeviation = n }
            default: break
            }
            i += 1
        }
        return c
    }
}

// MARK: - Guaranteed themes

/// Themes the app's training modes depend on, each guaranteed a floor of
/// `perThemeMinimum` puzzles.
///
/// WHY A FLOOR AT ALL: a purely rating-balanced sample mirrors the dump's
/// natural theme distribution, which is wildly skewed — `crushing` appears in
/// millions of puzzles while `underPromotion` appears in a few thousand. A
/// "train your en passant tactics" mode backed by 40 puzzles is not a mode, so
/// the rare themes get a reserved allocation before the bulk fill runs.
///
/// The endgame family below covers the "opposition-ish endgame themes present
/// in the data": Lichess has no `opposition` tag, so this is every endgame
/// theme the dump actually carries.
let guaranteedThemeNames: [String] = [
    // Core tactical motifs
    "fork", "pin", "skewer", "discoveredAttack", "hangingPiece", "backRankMate",
    "deflection", "attraction", "interference", "intermezzo", "sacrifice",
    "quietMove", "trappedPiece", "capturingDefender", "doubleCheck",
    "promotion", "underPromotion", "enPassant", "xRayAttack", "zugzwang",
    "smotheredMate", "clearance", "defensiveMove", "exposedKing",
    // Forced mates
    "mateIn1", "mateIn2", "mateIn3",
    // Endgames
    "endgame", "pawnEndgame", "rookEndgame", "queenEndgame",
    "knightEndgame", "bishopEndgame", "queenRookEndgame",
]

// MARK: - Pass 1 output

struct ScanStats {
    var totalRows = 0
    var passedQualityFilter = 0
    var malformed = 0
    var outsideRatingBands = 0
    var unknownThemes: [String: Int] = [:]
}

// MARK: - Entry point

@main
struct PuzzlePrep {
    static func main() {
        do {
            try run()
        } catch {
            let message = (error as? PrepError)?.description ?? "\(error)"
            FileHandle.standardError.write(Data("\nERROR: \(message)\n".utf8))
            exit(1)
        }
    }

    static func log(_ s: String) {
        FileHandle.standardError.write(Data((s + "\n").utf8))
    }

    static func run() throws {
        let config = Config.parse(CommandLine.arguments)

        guard FileManager.default.fileExists(atPath: config.input) else {
            throw PrepError.inputMissing(config.input)
        }
        guard let zstd = ZstdLineStream.locateZstd() else { throw PrepError.zstdNotFound }

        let stream = ZstdLineStream(
            executable: zstd,
            input: URL(fileURLWithPath: config.input)
        )

        log("PuzzlePrep")
        log("  input       : \(config.input)")
        log("  output      : \(config.output)")
        log("  zstd        : \(zstd.path)")
        log("  filter      : popularity >= \(config.minPopularity), plays >= \(config.minPlays), ratingDev <= \(config.maxRatingDeviation)")
        log("  target      : \(config.targetCount) puzzles, >= \(config.perThemeMinimum) per guaranteed theme")
        log("  seed        : \(config.seed) (fixed — reruns are reproducible)")
        log("")

        let clock = Date()

        // ---- Pass 1 ------------------------------------------------------
        log("Pass 1/2: scanning dump, filtering for quality...")
        let (candidates, stats) = try scan(stream: stream, config: config)
        log(String(
            format: "  read %d rows, %d passed quality (%.1f%%), %d usable in bands 600-2399  [%.1fs]",
            stats.totalRows, stats.passedQualityFilter,
            stats.totalRows > 0 ? Double(stats.passedQualityFilter) / Double(stats.totalRows) * 100 : 0,
            candidates.count, Date().timeIntervalSince(clock)
        ))

        // ---- Curate ------------------------------------------------------
        log("Curating balanced subset...")
        let guaranteedBits = guaranteedThemeNames.compactMap { ThemeTable.bitIndex[$0] }
        let curator = Curator(
            targetCount: config.targetCount,
            perThemeMinimum: config.perThemeMinimum,
            seed: config.seed,
            guaranteedThemeBits: guaranteedBits
        )
        let result = curator.curate(candidates)
        log("  selected \(result.selectedRowIndices.count) puzzles")

        // ---- Pass 2 ------------------------------------------------------
        // The selected rows are re-read from the dump rather than cached in
        // memory during pass 1: a second decompress is cheaper in wall-clock
        // than holding ~2.26M FEN/move/URL strings resident.
        log("Pass 2/2: re-reading selected rows and writing SQLite...")
        let writer = try SQLiteWriter(path: config.output)
        let written = try emit(stream: stream, config: config, selected: result.selectedRowIndices, writer: writer)

        let builtAt = ISO8601DateFormatter().string(from: Date())
        try writer.writeMeta([
            ("schema_version", "1"),
            ("source_dump", (config.input as NSString).lastPathComponent),
            ("built_at", builtAt),
            ("puzzle_count", "\(written)"),
            ("theme_ordering_version", "\(ThemeTable.themeOrderingVersion)"),
        ])
        log("  VACUUM...")
        try writer.finish()

        let attrs = try? FileManager.default.attributesOfItem(atPath: config.output)
        let size = (attrs?[.size] as? NSNumber)?.intValue ?? 0
        report(
            config: config, stats: stats, result: result,
            written: written, fileSize: size,
            elapsed: Date().timeIntervalSince(clock)
        )
    }

    // MARK: Pass 1 — scan and filter

    static func scan(stream: ZstdLineStream, config: Config) throws -> ([Candidate], ScanStats) {
        var stats = ScanStats()
        var candidates: [Candidate] = []
        candidates.reserveCapacity(2_400_000)

        var fields = CSVFields()
        var columns: [String: Int] = [:]
        var isHeader = true
        var rowIndex: UInt32 = 0

        // Column indices, resolved by NAME from the header — the dump has
        // gained columns over time (`DailyDate` is the most recent), so
        // positional parsing would rot on the next refresh.
        var cId = -1, cRating = -1
        var cDev = -1, cPop = -1, cPlays = -1, cThemes = -1

        var lastLog = Date()

        try stream.forEachLine { line in
            guard line.count > 0 else { return }
            splitCSVLine(line, into: &fields)

            if isHeader {
                isHeader = false
                for i in 0..<fields.count {
                    let name = makeString(line, fields.starts[i], fields.ends[i], quoted: fields.quoted[i])
                    columns[name] = i
                }
                func need(_ n: String) throws -> Int {
                    guard let i = columns[n] else { throw PrepError.missingColumn(n) }
                    return i
                }
                cId = try need("PuzzleId")
                cRating = try need("Rating")
                cDev = try need("RatingDeviation")
                cPop = try need("Popularity")
                cPlays = try need("NbPlays")
                cThemes = try need("Themes")
                // Not read in pass 1, but validated here so a missing column
                // fails before a 2-minute scan rather than after it.
                _ = try need("FEN")
                _ = try need("Moves")
                return
            }

            stats.totalRows += 1
            if stats.totalRows % 500_000 == 0 {
                let now = Date()
                log(String(
                    format: "    %6.1fM rows  |  %d kept  |  %.0f k rows/s",
                    Double(stats.totalRows) / 1_000_000,
                    stats.passedQualityFilter,
                    500.0 / max(now.timeIntervalSince(lastLog), 0.001)
                ))
                lastLog = now
            }

            let idx = rowIndex
            rowIndex += 1

            guard fields.count > max(cThemes, max(cPlays, cId)) else {
                stats.malformed += 1
                return
            }
            guard
                let rating = parseInt(line, fields.starts[cRating], fields.ends[cRating]),
                let dev = parseInt(line, fields.starts[cDev], fields.ends[cDev]),
                let pop = parseInt(line, fields.starts[cPop], fields.ends[cPop]),
                let plays = parseInt(line, fields.starts[cPlays], fields.ends[cPlays])
            else {
                stats.malformed += 1
                return
            }

            // Themes are tokenised for EVERY row, not just survivors, so the
            // unknown-theme census covers the whole dump — that census is how
            // we learn Lichess shipped a new tag.
            var mask = ThemeMask()
            forEachToken(line, fields.starts[cThemes], fields.ends[cThemes]) { s, e in
                let name = makeString(line, s, e, quoted: false)
                if let bit = ThemeTable.bitIndex[name] {
                    mask.set(bit)
                } else {
                    stats.unknownThemes[name, default: 0] += 1
                }
            }

            guard pop >= config.minPopularity, plays >= config.minPlays, dev <= config.maxRatingDeviation else {
                return
            }
            stats.passedQualityFilter += 1

            guard let band = Bands.index(forRating: rating) else {
                stats.outsideRatingBands += 1
                return
            }

            candidates.append(Candidate(
                rowIndex: idx,
                rating: UInt16(clamping: rating),
                band: UInt8(band),
                maskLo: mask.lo,
                maskHi: mask.hi
            ))
        }

        guard !isHeader else { throw PrepError.emptyInput }
        return (candidates, stats)
    }

    // MARK: Pass 2 — materialise selected rows

    static func emit(
        stream: ZstdLineStream, config: Config,
        selected: [UInt32], writer: SQLiteWriter
    ) throws -> Int {
        try writer.createSchema()

        var fields = CSVFields()
        var isHeader = true
        var rowIndex: UInt32 = 0
        // Single forward cursor over the ascending selection — O(1) per row,
        // no per-row hashing.
        var cursor = 0
        var written = 0

        var cId = -1, cFen = -1, cMoves = -1, cRating = -1
        var cDev = -1, cPop = -1, cPlays = -1, cThemes = -1, cURL = -1

        try stream.forEachLine { line in
            guard line.count > 0 else { return }
            if isHeader {
                isHeader = false
                splitCSVLine(line, into: &fields)
                var columns: [String: Int] = [:]
                for i in 0..<fields.count {
                    columns[makeString(line, fields.starts[i], fields.ends[i], quoted: fields.quoted[i])] = i
                }
                func need(_ n: String) throws -> Int {
                    guard let i = columns[n] else { throw PrepError.missingColumn(n) }
                    return i
                }
                cId = try need("PuzzleId")
                cFen = try need("FEN")
                cMoves = try need("Moves")
                cRating = try need("Rating")
                cDev = try need("RatingDeviation")
                cPop = try need("Popularity")
                cPlays = try need("NbPlays")
                cThemes = try need("Themes")
                cURL = columns["GameUrl"] ?? -1
                return
            }

            let idx = rowIndex
            rowIndex += 1
            guard cursor < selected.count, selected[cursor] == idx else { return }
            cursor += 1

            splitCSVLine(line, into: &fields)
            guard
                let rating = parseInt(line, fields.starts[cRating], fields.ends[cRating]),
                let dev = parseInt(line, fields.starts[cDev], fields.ends[cDev]),
                let pop = parseInt(line, fields.starts[cPop], fields.ends[cPop]),
                let plays = parseInt(line, fields.starts[cPlays], fields.ends[cPlays])
            else { return }

            var mask = ThemeMask()
            forEachToken(line, fields.starts[cThemes], fields.ends[cThemes]) { s, e in
                if let bit = ThemeTable.bitIndex[makeString(line, s, e, quoted: false)] {
                    mask.set(bit)
                }
            }

            try writer.insert(
                id: makeString(line, fields.starts[cId], fields.ends[cId], quoted: fields.quoted[cId]),
                fen: makeString(line, fields.starts[cFen], fields.ends[cFen], quoted: fields.quoted[cFen]),
                moves: makeString(line, fields.starts[cMoves], fields.ends[cMoves], quoted: fields.quoted[cMoves]),
                rating: rating, ratingDev: dev, popularity: pop, nbPlays: plays,
                mask: mask,
                gameURL: cURL >= 0 && cURL < fields.count
                    ? makeString(line, fields.starts[cURL], fields.ends[cURL], quoted: fields.quoted[cURL])
                    : ""
            )
            written += 1
            if written % 25_000 == 0 { log("    wrote \(written) / \(selected.count)") }
        }
        return written
    }

    // MARK: Report

    static func report(
        config: Config, stats: ScanStats, result: CurationResult,
        written: Int, fileSize: Int, elapsed: TimeInterval
    ) {
        func hr() { print(String(repeating: "-", count: 64)) }
        func fmt(_ n: Int) -> String {
            let f = NumberFormatter()
            f.numberStyle = .decimal
            return f.string(from: NSNumber(value: n)) ?? "\(n)"
        }

        print("")
        hr()
        print("PuzzlePrep — build report")
        hr()
        print("Source dump        : \((config.input as NSString).lastPathComponent)")
        print("Rows read          : \(fmt(stats.totalRows))")
        print("Passed quality     : \(fmt(stats.passedQualityFilter))  (popularity >= \(config.minPopularity), plays >= \(config.minPlays), dev <= \(config.maxRatingDeviation))")
        print("  outside 600-2399 : \(fmt(stats.outsideRatingBands))  (excluded from curation)")
        print("  malformed rows   : \(fmt(stats.malformed))")
        print("Curation pool      : \(fmt(result.candidatesInBandRange))")
        print("Selected           : \(fmt(written))")
        print("Output             : \(config.output)")
        print(String(format: "Output size        : %.1f MB (%@ bytes)", Double(fileSize) / 1_048_576, fmt(fileSize)))
        print(String(format: "Elapsed            : %.1fs", elapsed))

        hr()
        print("Rating band distribution")
        hr()
        let maxBand = result.perBandCount.max() ?? 1
        for b in 0..<Bands.count {
            let n = result.perBandCount[b]
            let barWidth = maxBand > 0 ? Int((Double(n) / Double(maxBand)) * 30) : 0
            print(String(
                format: "  %-10@ %8@  %@",
                Bands.label(b) as NSString,
                fmt(n) as NSString,
                String(repeating: "#", count: barWidth) as NSString
            ))
        }

        hr()
        print("Theme distribution in selection (descending)")
        hr()
        let guaranteed = Set(guaranteedThemeNames)
        let rows = result.perThemeCount.enumerated()
            .map { (ThemeTable.ordering[$0.offset], $0.element, result.perThemeAvailable[$0.offset]) }
            .sorted { $0.1 > $1.1 }
        for (name, count, available) in rows where count > 0 || guaranteed.contains(name) {
            let flag = guaranteed.contains(name) ? " *" : "  "
            print(String(
                format: "  %-26@%@ %8@   (pool: %@)",
                name as NSString, flag as NSString,
                fmt(count) as NSString, fmt(available) as NSString
            ))
        }
        print("  * = theme with a guaranteed minimum of \(fmt(config.perThemeMinimum))")

        if !result.themeShortfalls.isEmpty {
            hr()
            print("Theme minimums NOT met (pool too small — took everything available)")
            hr()
            for s in result.themeShortfalls {
                print("  \(s.theme): \(fmt(s.got)) of \(fmt(s.wanted)) requested; only \(fmt(s.available)) exist after filtering")
            }
        }

        hr()
        if stats.unknownThemes.isEmpty {
            print("Unknown theme tags : none — ThemeTable.ordering covers the whole dump")
        } else {
            print("UNKNOWN theme tags (present in dump, absent from ThemeTable.ordering)")
            print("Append these to ThemeTable.ordering AND to PuzzleTheme in Packages/Database,")
            print("then bump themeOrderingVersion. Never insert them mid-list.")
            hr()
            for (name, count) in stats.unknownThemes.sorted(by: { $0.value > $1.value }) {
                print("  \(name): \(fmt(count))")
            }
        }
        hr()
    }
}
