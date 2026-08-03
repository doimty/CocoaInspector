import Foundation

struct ProcessAvailability: OptionSet, Codable, Sendable {
    let rawValue: UInt64

    init(rawValue: UInt64) {
        self.rawValue = rawValue
    }

    init(from decoder: Decoder) throws {
        rawValue = try decoder.singleValueContainer().decode(UInt64.self)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    static let bsd = ProcessAvailability(rawValue: 1 << 0)
    static let task = ProcessAvailability(rawValue: 1 << 1)
    static let resourceUsage = ProcessAvailability(rawValue: 1 << 2)
    static let fileDescriptors = ProcessAvailability(rawValue: 1 << 3)
    static let executablePath = ProcessAvailability(rawValue: 1 << 4)
    static let commandLine = ProcessAvailability(rawValue: 1 << 5)
    static let ports = ProcessAvailability(rawValue: 1 << 6)
    static let sandbox = ProcessAvailability(rawValue: 1 << 7)
    static let network = ProcessAvailability(rawValue: 1 << 8)
    static let taskMetadata = ProcessAvailability(rawValue: 1 << 9)
}

enum ProcessSandboxStatus: Int8, Codable, Sendable {
    case unavailable = -1
    case unrestricted = 0
    case sandboxed = 1
}

struct SystemRecord: Codable, Equatable, Sendable {
    var physicalMemory: UInt64 = 0
    var freeMemory: UInt64 = 0
    var activeProcessorCount: UInt32 = 0
    var totalThreadCount: UInt64 = 0
    var totalUserTime: UInt64 = 0
    var totalSystemTime: UInt64 = 0
    var networkStatus: CollectorStatus = .unsupported
    var networkErrorCode: Int32 = 0
}

struct ProcessIdentity: Codable, Hashable, Sendable {
    let pid: Int32
    let startTime: UInt64
}

struct ProcessRecord: Codable, Equatable, Sendable {
    var pid: Int32
    var parentPID: Int32 = 0
    var userID: UInt32 = 0
    var groupID: UInt32 = 0
    var status: UInt32 = 0
    var flags: UInt32 = 0
    var nice: Int32 = 0
    var threadCount: UInt32 = 0
    var runningThreadCount: UInt32 = 0
    var priority: Int32 = 0
    var basePriority: Int32 = 0
    var terminalDevice: UInt32 = 0
    var taskRole: UInt32 = 0
    var fileDescriptorCount: UInt32 = 0
    var socketCount: UInt32 = 0
    var portCount: UInt32 = 0
    var availability: ProcessAvailability = []
    var sandboxStatus: ProcessSandboxStatus = .unavailable

    var startTime: UInt64 = 0
    var userTime: UInt64 = 0
    var systemTime: UInt64 = 0
    var packageIdleWakeups: UInt64 = 0
    var interruptWakeups: UInt64 = 0
    var timerWakeups: UInt64 = 0
    var pageIns: UInt64 = 0
    var wiredSize: UInt64 = 0
    var residentSize: UInt64 = 0
    var physicalFootprint: UInt64 = 0
    var maximumResidentSize: UInt64 = 0
    var virtualSize: UInt64 = 0
    var diskBytesRead: UInt64 = 0
    var diskBytesWritten: UInt64 = 0
    var faults: UInt64 = 0
    var copyOnWriteFaults: UInt64 = 0
    var messagesSent: UInt64 = 0
    var messagesReceived: UInt64 = 0
    var machSystemCalls: UInt64 = 0
    var unixSystemCalls: UInt64 = 0
    var contextSwitches: UInt64 = 0
    var networkBytesReceived: UInt64 = 0
    var networkBytesSent: UInt64 = 0
    var networkPacketsReceived: UInt64 = 0
    var networkPacketsSent: UInt64 = 0

    var name = ""
    var executablePath = ""
    var arguments: [String] = []

    var identity: ProcessIdentity {
        ProcessIdentity(pid: pid, startTime: startTime)
    }

    var totalCPUTime: UInt64 {
        userTime.addingReportingOverflow(systemTime).overflow
            ? UInt64.max
            : userTime + systemTime
    }
}

struct ProcessSnapshot: Codable, Equatable, Sendable {
    let generation: UInt64
    let sampleUptimeNanoseconds: UInt64
    let machTimebaseNumerator: UInt32
    let machTimebaseDenominator: UInt32
    let processes: [ProcessRecord]
    var system = SystemRecord()
}

struct ProcessInterval: Equatable, Sendable {
    let process: ProcessRecord
    let elapsedNanoseconds: UInt64
    let cpuTimeNanoseconds: UInt64
    let diskBytesRead: UInt64
    let diskBytesWritten: UInt64
    let packageIdleWakeups: UInt64
    let interruptWakeups: UInt64
    let timerWakeups: UInt64
    let faults: UInt64
    let copyOnWriteFaults: UInt64
    let messagesSent: UInt64
    let messagesReceived: UInt64
    let machSystemCalls: UInt64
    let unixSystemCalls: UInt64
    let contextSwitches: UInt64
    let networkBytesReceived: UInt64
    let networkBytesSent: UInt64
    let networkPacketsReceived: UInt64
    let networkPacketsSent: UInt64

    var cpuCoreFraction: Double {
        guard elapsedNanoseconds > 0 else { return 0 }
        return Double(cpuTimeNanoseconds) / Double(elapsedNanoseconds)
    }
}

struct ProcessSnapshotUpdate: Equatable, Sendable {
    let snapshot: ProcessSnapshot
    let intervals: [ProcessInterval]
    let started: [ProcessIdentity]
    let exited: [ProcessIdentity]
}

struct ProcessSnapshotReducer: Sendable {
    private var previous: ProcessSnapshot?

    mutating func reset() {
        previous = nil
    }

    mutating func consume(_ snapshot: ProcessSnapshot) -> ProcessSnapshotUpdate {
        defer { previous = snapshot }

        guard let previous else {
            return ProcessSnapshotUpdate(
                snapshot: snapshot,
                intervals: [],
                started: snapshot.processes.map(\.identity),
                exited: []
            )
        }

        let elapsed = delta(snapshot.sampleUptimeNanoseconds, previous.sampleUptimeNanoseconds)
        let previousByIdentity = Dictionary(
            previous.processes.map { ($0.identity, $0) },
            uniquingKeysWith: { _, latest in latest }
        )
        let currentIdentities = Set(snapshot.processes.map(\.identity))
        var intervals = [ProcessInterval]()
        var started = [ProcessIdentity]()
        intervals.reserveCapacity(snapshot.processes.count)

        for process in snapshot.processes {
            guard let old = previousByIdentity[process.identity] else {
                started.append(process.identity)
                continue
            }

            let cpuTicks = delta(process.totalCPUTime, old.totalCPUTime)
            intervals.append(ProcessInterval(
                process: process,
                elapsedNanoseconds: elapsed,
                cpuTimeNanoseconds: machTicksToNanoseconds(
                    cpuTicks,
                    numerator: snapshot.machTimebaseNumerator,
                    denominator: snapshot.machTimebaseDenominator
                ),
                diskBytesRead: delta(process.diskBytesRead, old.diskBytesRead),
                diskBytesWritten: delta(process.diskBytesWritten, old.diskBytesWritten),
                packageIdleWakeups: delta(process.packageIdleWakeups, old.packageIdleWakeups),
                interruptWakeups: delta(process.interruptWakeups, old.interruptWakeups),
                timerWakeups: delta(process.timerWakeups, old.timerWakeups),
                faults: delta(process.faults, old.faults),
                copyOnWriteFaults: delta(process.copyOnWriteFaults, old.copyOnWriteFaults),
                messagesSent: delta(process.messagesSent, old.messagesSent),
                messagesReceived: delta(process.messagesReceived, old.messagesReceived),
                machSystemCalls: delta(process.machSystemCalls, old.machSystemCalls),
                unixSystemCalls: delta(process.unixSystemCalls, old.unixSystemCalls),
                contextSwitches: delta(process.contextSwitches, old.contextSwitches),
                networkBytesReceived: delta(process.networkBytesReceived, old.networkBytesReceived),
                networkBytesSent: delta(process.networkBytesSent, old.networkBytesSent),
                networkPacketsReceived: delta(process.networkPacketsReceived, old.networkPacketsReceived),
                networkPacketsSent: delta(process.networkPacketsSent, old.networkPacketsSent)
            ))
        }

        let exited = previous.processes
            .map(\.identity)
            .filter { !currentIdentities.contains($0) }

        return ProcessSnapshotUpdate(
            snapshot: snapshot,
            intervals: intervals,
            started: started,
            exited: exited
        )
    }

    private func delta(_ current: UInt64, _ previous: UInt64) -> UInt64 {
        current >= previous ? current - previous : 0
    }

    private func machTicksToNanoseconds(
        _ ticks: UInt64,
        numerator: UInt32,
        denominator: UInt32
    ) -> UInt64 {
        guard denominator != 0 else { return 0 }

        let divisor = UInt64(denominator)
        let multiplier = UInt64(numerator)
        let quotient = ticks / divisor
        let remainder = ticks % divisor
        let (whole, wholeOverflow) = quotient.multipliedReportingOverflow(by: multiplier)
        let (partialProduct, partialOverflow) = remainder.multipliedReportingOverflow(by: multiplier)
        guard !wholeOverflow, !partialOverflow else { return UInt64.max }
        let partial = partialProduct / divisor
        let (result, resultOverflow) = whole.addingReportingOverflow(partial)
        return resultOverflow ? UInt64.max : result
    }
}
