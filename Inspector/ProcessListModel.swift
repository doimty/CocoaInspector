import SwiftUI

struct ProcessRow: Identifiable, Equatable {
    let record: ProcessRecord
    let cpuFraction: Double

    var id: ProcessIdentity { record.identity }
    var displayName: String { record.name.isEmpty ? "pid \(record.pid)" : record.name }
    // App executables run from an .app bundle in one of two install locations:
    // user apps in a bundle container (/var/containers/Bundle/Application/<UUID>/,
    // or /var/mobile/Containers/Bundle/Application/ before iOS 9.3) and system
    // apps in /Applications. The ".app/" requirement keeps jbroot daemons
    // (installed under a .jbroot-* bundle container) out.
    var isApp: Bool {
        record.executablePath.contains(".app/")
            && (record.executablePath.contains("/Bundle/Application/")
                || record.executablePath.hasPrefix("/Applications/"))
    }
}

enum ProcessSortOrder: String, CaseIterable, Identifiable {
    case cpu = "CPU"
    case memory = "Memory"
    case pid = "PID"
    case name = "Name"

    var id: Self { self }

    // rawValue is the @AppStorage key, so it stays fixed; the label is what
    // the menu shows and is translated.
    var label: String {
        switch self {
        case .cpu: InspectorLocalization.text("CPU Usage")
        case .memory: InspectorLocalization.text("Memory Used")
        case .pid: InspectorLocalization.text("PID")
        case .name: InspectorLocalization.text("Name")
        }
    }

    // Total order with pid as the final tiebreaker: Swift's sort is not
    // stable, so without it equal-keyed rows (idle processes, same-named
    // helpers) shuffle randomly on every one-second resort.
    func areInOrder(_ lhs: ProcessRow, _ rhs: ProcessRow) -> Bool {
        switch self {
        case .cpu:
            if lhs.cpuFraction != rhs.cpuFraction {
                return lhs.cpuFraction > rhs.cpuFraction
            }
            if lhs.record.physicalFootprint != rhs.record.physicalFootprint {
                return lhs.record.physicalFootprint > rhs.record.physicalFootprint
            }
            return lhs.record.pid < rhs.record.pid
        case .memory:
            if lhs.record.physicalFootprint != rhs.record.physicalFootprint {
                return lhs.record.physicalFootprint > rhs.record.physicalFootprint
            }
            return lhs.record.pid < rhs.record.pid
        case .pid:
            return lhs.record.pid < rhs.record.pid
        case .name:
            switch lhs.record.name.localizedCaseInsensitiveCompare(rhs.record.name) {
            case .orderedAscending: return true
            case .orderedDescending: return false
            case .orderedSame: return lhs.record.pid < rhs.record.pid
            }
        }
    }
}

enum ProcessScopeFilter: String, CaseIterable, Identifiable {
    case all
    case root
    case mobile
    case apps

    var id: Self { self }

    var label: String {
        switch self {
        case .all: InspectorLocalization.text("Everything")
        case .root: InspectorLocalization.text("System (root)")
        case .mobile: InspectorLocalization.text("User (mobile)")
        case .apps: InspectorLocalization.text("Apps")
        }
    }

    func matches(_ row: ProcessRow) -> Bool {
        switch self {
        case .all: true
        case .root: row.record.userID == 0
        case .mobile: row.record.userID == 501
        case .apps: row.isApp
        }
    }
}

// Everything derived from a sample is computed off the main actor (in the
// serial operation chain) so the main thread only assigns stored properties.
struct PreparedSample: Sendable {
    let rows: [ProcessRow]
    let rowsByIdentity: [ProcessIdentity: ProcessRow]
    let visibleRows: [ProcessRow]
    let totalCPUFraction: Double
    let system: SystemRecord
    let uptimeNanoseconds: UInt64
    let machTimebaseNumerator: UInt32
    let machTimebaseDenominator: UInt32

    init(
        update: ProcessSnapshotUpdate,
        scope: ProcessScopeFilter,
        order: ProcessSortOrder,
        query: String
    ) {
        let cpuByIdentity = Dictionary(
            update.intervals.map { ($0.process.identity, $0.cpuCoreFraction) },
            uniquingKeysWith: { first, _ in first }
        )
        rows = update.snapshot.processes.map {
            ProcessRow(record: $0, cpuFraction: cpuByIdentity[$0.identity] ?? 0)
        }
        rowsByIdentity = Dictionary(
            rows.map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        visibleRows = ProcessListModel.visibleRows(in: rows, scope: scope, order: order, query: query)
        totalCPUFraction = update.intervals.reduce(0) { $0 + $1.cpuCoreFraction }
        system = update.snapshot.system
        uptimeNanoseconds = update.snapshot.sampleUptimeNanoseconds
        machTimebaseNumerator = update.snapshot.machTimebaseNumerator
        machTimebaseDenominator = update.snapshot.machTimebaseDenominator
    }
}

@MainActor
final class ProcessListModel: ObservableObject {
    enum Phase: Equatable {
        case idle
        case connecting
        case active
        case failed(String)
    }

    private enum DefaultsKey {
        static let sortOrder = "processList.sortOrder"
        static let scopeFilter = "processList.scopeFilter"
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var rows: [ProcessRow] = []
    // Filtering and sorting happen once per sample or query change, never in a
    // view body — bodies re-run every second and must stay O(visible rows).
    @Published private(set) var visibleRows: [ProcessRow] = []
    @Published private(set) var system = SystemRecord()
    @Published private(set) var totalCPUFraction: Double = 0
    @Published private(set) var uptimeNanoseconds: UInt64 = 0
    @Published private(set) var machTimebaseNumerator: UInt32 = 1
    @Published private(set) var machTimebaseDenominator: UInt32 = 1

    @Published var sortOrder: ProcessSortOrder {
        didSet {
            UserDefaults.standard.set(sortOrder.rawValue, forKey: DefaultsKey.sortOrder)
            rebuildVisibleRows()
        }
    }
    @Published var scopeFilter: ProcessScopeFilter {
        didSet {
            UserDefaults.standard.set(scopeFilter.rawValue, forKey: DefaultsKey.scopeFilter)
            rebuildVisibleRows()
        }
    }
    @Published var searchText = "" {
        didSet { rebuildVisibleRows() }
    }
    // Pausing keeps the last snapshot on screen but releases the daemon (the
    // sampling loop deactivates on exit, so the foreground lease lapses).
    @Published var isPaused = false {
        didSet {
            if isPaused {
                samplingTask?.cancel()
            } else {
                ensureSampling()
            }
        }
    }

    private let session = ProcessDataSession()
    // Publishing the identity map keeps detail views live as samples arrive.
    @Published private var rowsByIdentity: [ProcessIdentity: ProcessRow] = [:]
    private var shouldRun = false
    private var samplingTask: Task<Void, Never>?
    private var operationChain: Task<Void, Never> = Task {}

    init() {
        let defaults = UserDefaults.standard
        sortOrder = defaults.string(forKey: DefaultsKey.sortOrder)
            .flatMap { ProcessSortOrder(rawValue: $0) } ?? .cpu
        scopeFilter = defaults.string(forKey: DefaultsKey.scopeFilter)
            .flatMap { ProcessScopeFilter(rawValue: $0) } ?? .all
    }

    func row(for identity: ProcessIdentity) -> ProcessRow? {
        rowsByIdentity[identity]
    }

    func start() {
        shouldRun = true
        ensureSampling()
    }

    func stop() {
        shouldRun = false
        samplingTask?.cancel()
    }

    func details(
        _ kind: ProcessDetailKind,
        for identity: ProcessIdentity
    ) async throws -> ProcessDetailSnapshot {
        try await enqueue { [session] in
            try await session.activateIfNeeded()
            try await session.renewForegroundLease()
            return try await session.details(kind, for: identity)
        }
    }

    func sendSignal(_ signal: InspectorSignal, to identity: ProcessIdentity) async throws {
        try await enqueue { [session] in
            try await session.activateIfNeeded()
            try await session.renewForegroundLease()
            let ticket = try await session.prepareSignal(signal, for: identity)
            try await session.commitSignal(ticket: ticket)
        }
    }

    private func ensureSampling() {
        guard shouldRun, !isPaused, samplingTask == nil else { return }
        samplingTask = Task { await runSampling() }
    }

    private func runSampling() async {
        phase = .connecting
        do {
            try await enqueue { [session] in try await session.activate() }
            phase = .active
            while !Task.isCancelled {
                let scope = scopeFilter
                let order = sortOrder
                let query = searchText
                let prepared = try await enqueue { [session] in
                    try await session.renewForegroundLease()
                    // Executable paths ride along with every sample: the Apps
                    // filter and row subtitles need them, and .standard omits them.
                    let update = try await session.sample(
                        collectors: [.taskCounters, .executablePaths]
                    )
                    return PreparedSample(update: update, scope: scope, order: order, query: query)
                }
                apply(prepared)
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
        } catch {
            if !Task.isCancelled {
                shouldRun = false
                clearRows()
                phase = .failed(InspectorErrorText.describe(error))
            }
        }
        try? await enqueue { [session] in await session.deactivate() }
        if phase == .active || phase == .connecting { phase = .idle }
        samplingTask = nil
        ensureSampling()
    }

    private func apply(_ prepared: PreparedSample) {
        rows = prepared.rows
        rowsByIdentity = prepared.rowsByIdentity
        visibleRows = prepared.visibleRows
        totalCPUFraction = prepared.totalCPUFraction
        system = prepared.system
        uptimeNanoseconds = prepared.uptimeNanoseconds
        machTimebaseNumerator = prepared.machTimebaseNumerator
        machTimebaseDenominator = prepared.machTimebaseDenominator
    }

    private func clearRows() {
        rows = []
        rowsByIdentity = [:]
        visibleRows = []
        totalCPUFraction = 0
    }

    // Interactive changes (search, sort, filter) rebuild on the main actor from
    // the current rows and animate. Per-second samples apply unanimated (in
    // apply(_:)): animating every sample kept the 400-row list in continuous
    // batch-update animations, which let taps land on rows mid-move and held
    // extra cells alive for the duration of each move.
    private func rebuildVisibleRows() {
        withAnimation(.easeInOut(duration: 0.2)) {
            visibleRows = Self.visibleRows(in: rows, scope: scopeFilter, order: sortOrder, query: searchText)
        }
    }

    nonisolated static func visibleRows(
        in rows: [ProcessRow],
        scope: ProcessScopeFilter,
        order: ProcessSortOrder,
        query: String
    ) -> [ProcessRow] {
        let query = query.trimmingCharacters(in: .whitespaces)
        let pidQuery = Int32(query)
        var result = rows.filter { row in
            scope.matches(row)
                && (query.isEmpty
                    || row.record.name.localizedCaseInsensitiveContains(query)
                    || row.record.pid == pidQuery)
        }
        result.sort(by: order.areInOrder)
        return result
    }

    private func enqueue<T: Sendable>(
        _ body: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        let previous = operationChain
        let task = Task { () throws -> T in
            await previous.value
            return try await body()
        }
        operationChain = Task { _ = try? await task.value }
        return try await task.value
    }
}
