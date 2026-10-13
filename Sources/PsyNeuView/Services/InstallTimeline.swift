import Foundation

/// What a package installer spent its time on, read from its own output (#215).
///
/// "Install PsyNeuLink and Python packages" is one step on the checklist and
/// most of a first launch. Inside it, pip clones PsyNeuLink, builds its
/// metadata, resolves and downloads a dependency tree (torch is most of the
/// bytes), builds a wheel, and installs; then uv installs the backend's own
/// packages. Those are different costs with different fixes — a slow clone is
/// not a slow download — so they are told apart here, from the lines pip and
/// uv print, with a clock supplied by the caller.
///
/// Pure: lines and timestamps in, phases out. Nothing here runs anything.
enum InstallPhase: String, CaseIterable, Codable, Sendable {
    /// pip: cloning the source repository (`Cloning … to …`).
    case fetchSource
    /// pip: building the package's metadata from the clone (`Installing build
    /// dependencies`, `Getting requirements to build wheel`, `Preparing metadata`).
    case buildMetadata
    /// pip: resolving the dependency tree and downloading wheels — pip
    /// interleaves the two, so they are one phase, with the bytes counted.
    case resolveAndDownload
    /// pip: building a wheel from the source (`Building wheels for collected packages`).
    case buildWheel
    /// pip or uv: writing the packages into the environment.
    case install
    /// uv: resolving the dependency tree (`Resolved N packages in …`).
    case resolve
    /// uv: downloading and building what the resolution needs (`Prepared N packages in …`).
    case prepare

    var title: String {
        switch self {
        case .fetchSource: return "fetch the source (git clone)"
        case .buildMetadata: return "read the package metadata"
        case .resolveAndDownload: return "resolve dependencies and download wheels"
        case .buildWheel: return "build the wheel"
        case .install: return "install the packages"
        case .resolve: return "resolve dependencies"
        case .prepare: return "download and prepare packages"
        }
    }
}

/// One installer run — a pip or uv invocation — split into phases.
struct InstallTimeline: Equatable, Sendable {

    /// A wheel pip downloaded, with the size it printed.
    struct Download: Equatable, Codable, Sendable {
        var name: String
        var bytes: Int64
    }

    struct Entry: Equatable, Codable, Sendable {
        var phase: InstallPhase
        var seconds: Double
        /// Bytes downloaded during the phase, when the installer said. pip
        /// prints each wheel's size; uv prints none without a terminal.
        var bytes: Int64?
        /// Packages the phase covered, when the installer said (uv does).
        var packages: Int?
    }

    /// What this run installed, for the report: "PsyNeuLink (git+…@devel) with pip".
    let label: String
    /// A short, stable name for the run, for timing ids: "psyneulink", "backend".
    let id: String
    let startedAt: Date
    private(set) var entries: [Entry] = []
    /// The wheels pip downloaded in this run, largest first after `finish`.
    private(set) var downloads: [Download] = []
    /// Set once `finish` ran.
    private(set) var finishedAt: Date?
    /// Whether the run wrote or removed packages — uv said `Installed N
    /// packages` or `Uninstalled N packages` with N > 0 (an `Audited` run
    /// changed nothing), or pip reached `Installing collected packages`.
    /// What the fast-start preparation needs to know (#223): bytecode is
    /// recompiled only after packages changed.
    private(set) var wrotePackages = false

    private struct Current: Equatable, Sendable {
        var phase: InstallPhase
        var since: Date
    }
    private var current: Current?
    private var phaseBytes: Int64 = 0

    init(label: String, id: String, startedAt: Date) {
        self.label = label
        self.id = id
        self.startedAt = startedAt
    }

    /// The whole run, once finished.
    var totalSeconds: Double? {
        finishedAt.map { $0.timeIntervalSince(startedAt) }
    }

    var totalBytes: Int64 {
        downloads.reduce(0) { $0 + $1.bytes }
    }

    // MARK: Reading the output

    /// One line of installer output, as it arrived.
    mutating func observe(_ raw: String, at now: Date) {
        let line = raw.trimmingCharacters(in: .whitespaces)
        guard !line.isEmpty else { return }

        // uv reports each phase after the fact, with its own duration. Those
        // numbers are better than any clock out here, so they are taken as is.
        if let uv = Self.uvPhase(line) {
            entries.append(Entry(phase: uv.phase, seconds: uv.seconds, bytes: nil, packages: uv.packages))
            if uv.packages > 0, line.hasPrefix("Installed ") || line.hasPrefix("Uninstalled ") {
                wrotePackages = true
            }
            return
        }

        // pip announces each phase as it starts; the clock measures it.
        if line.hasPrefix("Cloning ") {
            transition(to: .fetchSource, at: now)
        } else if line.hasPrefix("Resolved ") && line.contains(" to commit ") {
            transition(to: .fetchSource, at: now)
        } else if line.hasPrefix("Installing build dependencies")
                    || line.hasPrefix("Getting requirements to build")
                    || line.hasPrefix("Preparing metadata")
                    || line.hasPrefix("Checking if build backend") {
            transition(to: .buildMetadata, at: now)
        } else if (line.hasPrefix("Collecting ") && !line.contains("git+"))
                    || line.hasPrefix("Downloading ")
                    || line.hasPrefix("Using cached ")
                    || line.hasPrefix("Requirement already satisfied") {
            transition(to: .resolveAndDownload, at: now)
            if line.hasPrefix("Downloading "), !line.contains(".metadata "),
               let download = Self.download(fromPipLine: line) {
                downloads.append(download)
                phaseBytes += download.bytes
            }
        } else if line.hasPrefix("Building wheels for collected packages")
                    || line.hasPrefix("Building wheel for")
                    || line.hasPrefix("Created wheel for")
                    || line.hasPrefix("Successfully built") {
            transition(to: .buildWheel, at: now)
        } else if line.hasPrefix("Installing collected packages") {
            transition(to: .install, at: now)
            wrotePackages = true
        }
    }

    /// The run ended. Closes the phase in progress.
    mutating func finish(at now: Date) {
        guard finishedAt == nil else { return }
        close(at: now)
        finishedAt = now
        downloads.sort { $0.bytes > $1.bytes }
    }

    private mutating func transition(to phase: InstallPhase, at now: Date) {
        if current?.phase == phase { return }
        close(at: now)
        // Time before the first announcement — pip starting up — belongs to
        // the first phase rather than to nobody.
        let since = entries.isEmpty && current == nil ? startedAt : now
        current = Current(phase: phase, since: since)
        phaseBytes = 0
    }

    private mutating func close(at now: Date) {
        guard let open = current else { return }
        entries.append(Entry(
            phase: open.phase,
            seconds: now.timeIntervalSince(open.since),
            bytes: open.phase == .resolveAndDownload && phaseBytes > 0 ? phaseBytes : nil,
            packages: nil))
        current = nil
        phaseBytes = 0
    }

    // MARK: Parsing

    /// `Downloading torch-2.8.0-cp314-none-macosx_11_0_arm64.whl (73.9 MB)`
    /// → the file and its size in bytes. pip's units are decimal (1 MB =
    /// 1,000,000 bytes).
    static func download(fromPipLine line: String) -> Download? {
        guard line.hasPrefix("Downloading ") else { return nil }
        let rest = line.dropFirst("Downloading ".count)
        guard let open = rest.lastIndex(of: "("), rest.hasSuffix(")") else { return nil }
        let name = rest[..<open].trimmingCharacters(in: .whitespaces)
        let size = rest[rest.index(after: open)...].dropLast()
        guard let bytes = bytes(fromSize: String(size)) else { return nil }
        return Download(name: name, bytes: bytes)
    }

    /// `73.9 MB`, `62 kB`, `1.2 GB`, `512 bytes` → bytes.
    static func bytes(fromSize text: String) -> Int64? {
        let parts = text.trimmingCharacters(in: .whitespaces).split(separator: " ")
        guard parts.count == 2, let number = Double(parts[0]) else { return nil }
        let multiplier: Double
        switch parts[1].lowercased() {
        case "bytes", "b": multiplier = 1
        case "kb": multiplier = 1_000
        case "mb": multiplier = 1_000_000
        case "gb": multiplier = 1_000_000_000
        default: return nil
        }
        return Int64((number * multiplier).rounded())
    }

    /// `Resolved 87 packages in 1.21s` / `Prepared 3 packages in 2m 03s` /
    /// `Installed 87 packages in 310ms` / `Audited 1 package in 2ms`.
    static func uvPhase(_ line: String) -> (phase: InstallPhase, packages: Int, seconds: Double)? {
        let words = line.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        guard words.count >= 5, words[2].hasPrefix("package"), words[3] == "in",
              let count = Int(words[1]) else { return nil }
        let phase: InstallPhase
        switch words[0] {
        case "Resolved": phase = .resolve
        case "Prepared": phase = .prepare
        case "Installed", "Audited", "Uninstalled": phase = .install
        default: return nil
        }
        guard let seconds = seconds(fromUvDuration: words[4...].joined(separator: " ")) else { return nil }
        return (phase, count, seconds)
    }

    /// `1.21s`, `310ms`, `2m 03s`, `1h 2m 3s` → seconds.
    static func seconds(fromUvDuration text: String) -> Double? {
        var total = 0.0
        var any = false
        for token in text.split(separator: " ") {
            let t = String(token)
            if t.hasSuffix("ms"), let v = Double(t.dropLast(2)) {
                total += v / 1_000; any = true
            } else if t.hasSuffix("h"), let v = Double(t.dropLast()) {
                total += v * 3_600; any = true
            } else if t.hasSuffix("m"), let v = Double(t.dropLast()) {
                total += v * 60; any = true
            } else if t.hasSuffix("s"), let v = Double(t.dropLast()) {
                total += v; any = true
            } else {
                return nil
            }
        }
        return any ? total : nil
    }

    // MARK: For the checklist and the report

    /// The phases as checklist details, plus the run's total, in order.
    func details() -> [InstallProgress.Detail] {
        var out: [InstallProgress.Detail] = []
        for entry in entries {
            out.append(InstallProgress.Detail(
                id: "\(id)/\(entry.phase.rawValue)",
                title: "\(label): \(entry.phase.title)",
                seconds: entry.seconds,
                bytes: entry.bytes))
        }
        if let total = totalSeconds {
            out.append(InstallProgress.Detail(
                id: "\(id)/total",
                title: "\(label): total",
                seconds: total,
                bytes: totalBytes > 0 ? totalBytes : nil))
        }
        return out
    }

    /// The biggest wheels, for the log: "torch 73.9 MB, numpy 5.0 MB".
    func largestDownloads(_ count: Int = 5) -> String {
        downloads.prefix(count).map { "\(Self.packageName($0.name)) \(Self.format(bytes: $0.bytes))" }
            .joined(separator: ", ")
    }

    /// `torch-2.8.0-cp314-none-macosx_11_0_arm64.whl` → `torch`.
    static func packageName(_ wheel: String) -> String {
        String(wheel.split(separator: "-").first ?? Substring(wheel))
    }

    /// `73900000` → `73.9 MB`.
    static func format(bytes: Int64) -> String {
        let b = Double(bytes)
        if b >= 1_000_000_000 { return String(format: "%.1f GB", b / 1_000_000_000) }
        if b >= 1_000_000 { return String(format: "%.1f MB", b / 1_000_000) }
        if b >= 1_000 { return String(format: "%.0f kB", b / 1_000) }
        return "\(bytes) bytes"
    }
}
