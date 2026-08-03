import Foundation

enum ProcessDetailSortOrder: String, CaseIterable, Identifiable {
    case cpu
    case priority
    case name
    case descriptor
    case fileKind
    case port
    case rights
    case references
    case address
    case size

    var id: Self { self }

    // rawValue is the @AppStorage key, so it stays fixed; the label is what
    // the menu shows and is translated.
    var label: String {
        switch self {
        case .cpu: String(localized: "CPU Usage")
        case .priority: String(localized: "Priority")
        case .name: String(localized: "Name")
        case .descriptor: String(localized: "File Descriptor")
        case .fileKind: String(localized: "Kind")
        case .port: String(localized: "Port Name")
        case .rights: String(localized: "Rights")
        case .references: String(localized: "References")
        case .address: String(localized: "Address")
        case .size: String(localized: "Size")
        }
    }

    // First entry is the kind's default order — the one load() used to apply.
    static func options(for kind: ProcessDetailKind) -> [ProcessDetailSortOrder] {
        switch kind {
        case .summary: []
        case .threads: [.cpu, .name, .priority]
        case .files: [.descriptor, .fileKind, .name]
        case .ports: [.port, .rights, .references]
        case .modules: [.address, .name, .size]
        }
    }

    static func `default`(for kind: ProcessDetailKind) -> ProcessDetailSortOrder {
        options(for: kind).first ?? .name
    }
}

// The records a detail screen actually shows: filtered by the search field and
// sorted by the menu's order. Only the screen's own kind is ever populated.
struct ProcessDetailRecords {
    var threads: [ThreadRecord] = []
    var files: [FileDescriptorRecord] = []
    var ports: [MachPortRecord] = []
    var modules: [ModuleRecord] = []

    var count: Int { threads.count + files.count + ports.count + modules.count }
    var isEmpty: Bool { count == 0 }

    static func total(in detail: ProcessDetailSnapshot, kind: ProcessDetailKind) -> Int {
        switch kind {
        case .summary: 0
        case .threads: detail.threads.count
        case .files: detail.files.count
        case .ports: detail.ports.count
        case .modules: detail.modules.count
        }
    }

    // Sorts are total orders with a stable final key: Swift's sort is not
    // stable, so equal-keyed records would otherwise shuffle on every rebuild.
    static func visible(
        in detail: ProcessDetailSnapshot,
        kind: ProcessDetailKind,
        order: ProcessDetailSortOrder,
        query: String
    ) -> ProcessDetailRecords {
        let query = query.trimmingCharacters(in: .whitespaces)
        var records = ProcessDetailRecords()
        switch kind {
        case .summary:
            break
        case .threads:
            records.threads = detail.threads
                .filter { matches(thread: $0, query: query) }
                .sorted { areInOrder(threads: $0, $1, order: order) }
        case .files:
            records.files = detail.files
                .filter { matches(file: $0, query: query) }
                .sorted { areInOrder(files: $0, $1, order: order) }
        case .ports:
            records.ports = detail.ports
                .filter { matches(port: $0, query: query) }
                .sorted { areInOrder(ports: $0, $1, order: order) }
        case .modules:
            records.modules = detail.modules
                .filter { matches(module: $0, query: query) }
                .sorted { areInOrder(modules: $0, $1, order: order) }
        }
        return records
    }

    private static func matches(thread: ThreadRecord, query: String) -> Bool {
        guard !query.isEmpty else { return true }
        return contains(query, in: [
            thread.name,
            InspectorFormat.hex(thread.id),
            InspectorFormat.threadState(thread.runState),
        ])
    }

    private static func matches(file: FileDescriptorRecord, query: String) -> Bool {
        guard !query.isEmpty else { return true }
        return contains(query, in: [
            String(file.descriptor),
            file.path,
            file.detail,
            file.localAddress,
            file.remoteAddress,
            InspectorFormat.fileKind(file.kind),
        ])
    }

    private static func matches(port: MachPortRecord, query: String) -> Bool {
        guard !query.isEmpty else { return true }
        return contains(query, in: [
            String(port.name),
            InspectorFormat.hex(UInt64(port.name)),
            InspectorFormat.portRights(port.rights),
        ])
    }

    private static func matches(module: ModuleRecord, query: String) -> Bool {
        guard !query.isEmpty else { return true }
        return contains(query, in: [
            module.path,
            module.identifier,
            InspectorFormat.hex(module.address),
        ])
    }

    private static func contains(_ query: String, in fields: [String]) -> Bool {
        fields.contains { !$0.isEmpty && $0.localizedCaseInsensitiveContains(query) }
    }

    private static func areInOrder(
        threads lhs: ThreadRecord,
        _ rhs: ThreadRecord,
        order: ProcessDetailSortOrder
    ) -> Bool {
        switch order {
        case .name:
            switch lhs.name.localizedCaseInsensitiveCompare(rhs.name) {
            case .orderedAscending: return true
            case .orderedDescending: return false
            case .orderedSame: return lhs.id < rhs.id
            }
        case .priority:
            if lhs.currentPriority != rhs.currentPriority {
                return lhs.currentPriority > rhs.currentPriority
            }
            return lhs.id < rhs.id
        default:
            if lhs.cpuUsage != rhs.cpuUsage { return lhs.cpuUsage > rhs.cpuUsage }
            return lhs.id < rhs.id
        }
    }

    private static func areInOrder(
        files lhs: FileDescriptorRecord,
        _ rhs: FileDescriptorRecord,
        order: ProcessDetailSortOrder
    ) -> Bool {
        switch order {
        case .fileKind:
            if lhs.kind != rhs.kind { return lhs.kind.rawValue < rhs.kind.rawValue }
            return lhs.descriptor < rhs.descriptor
        case .name:
            switch fileName(lhs).localizedCaseInsensitiveCompare(fileName(rhs)) {
            case .orderedAscending: return true
            case .orderedDescending: return false
            case .orderedSame: return lhs.descriptor < rhs.descriptor
            }
        default:
            return lhs.descriptor < rhs.descriptor
        }
    }

    private static func areInOrder(
        ports lhs: MachPortRecord,
        _ rhs: MachPortRecord,
        order: ProcessDetailSortOrder
    ) -> Bool {
        switch order {
        case .rights:
            if lhs.rights != rhs.rights { return lhs.rights < rhs.rights }
            return lhs.name < rhs.name
        case .references:
            if lhs.userReferences != rhs.userReferences {
                return lhs.userReferences > rhs.userReferences
            }
            return lhs.name < rhs.name
        default:
            return lhs.name < rhs.name
        }
    }

    private static func areInOrder(
        modules lhs: ModuleRecord,
        _ rhs: ModuleRecord,
        order: ProcessDetailSortOrder
    ) -> Bool {
        switch order {
        case .name:
            switch moduleName(lhs).localizedCaseInsensitiveCompare(moduleName(rhs)) {
            case .orderedAscending: return true
            case .orderedDescending: return false
            case .orderedSame: return lhs.address < rhs.address
            }
        case .size:
            if lhs.size != rhs.size { return lhs.size > rhs.size }
            return lhs.address < rhs.address
        default:
            return lhs.address < rhs.address
        }
    }

    static func fileName(_ file: FileDescriptorRecord) -> String {
        if !file.path.isEmpty { return file.path }
        if !file.localAddress.isEmpty {
            return file.remoteAddress.isEmpty
                ? file.localAddress
                : "\(file.localAddress) → \(file.remoteAddress)"
        }
        return ""
    }

    static func moduleName(_ module: ModuleRecord) -> String {
        if !module.path.isEmpty {
            let component = (module.path as NSString).lastPathComponent
            if !component.isEmpty { return component }
        }
        return module.identifier.isEmpty
            ? InspectorFormat.hex(module.address)
            : module.identifier
    }
}

// Plain-text export of exactly what the screen shows — same records, same
// order — so a shared listing matches the one the user is looking at.
enum ProcessDetailExport {
    static func text(
        title: String,
        process: String,
        records: ProcessDetailRecords
    ) -> String {
        var lines = ["\(title) — \(process)", String(localized: "\(records.count) in total"), ""]
        lines += records.threads.map(line(thread:))
        lines += records.files.map(line(file:))
        lines += records.ports.map(line(port:))
        lines += records.modules.map(line(module:))
        return lines.joined(separator: "\n")
    }

    private static func line(thread: ThreadRecord) -> String {
        var parts = [InspectorFormat.hex(thread.id)]
        if !thread.name.isEmpty { parts.append(thread.name) }
        parts.append(InspectorFormat.threadState(thread.runState))
        parts.append("priority \(thread.currentPriority)")
        parts.append(String(format: "%.1f%%", Double(thread.cpuUsage) / 10))
        return parts.joined(separator: " · ")
    }

    private static func line(file: FileDescriptorRecord) -> String {
        var parts = ["fd \(file.descriptor)"]
        parts.append(file.detail.isEmpty ? InspectorFormat.fileKind(file.kind) : file.detail)
        let name = ProcessDetailRecords.fileName(file)
        if !name.isEmpty { parts.append(name) }
        return parts.joined(separator: " · ")
    }

    private static func line(port: MachPortRecord) -> String {
        var parts = [
            InspectorFormat.hex(UInt64(port.name)),
            InspectorFormat.portRights(port.rights),
        ]
        if port.objectType != 0 {
            parts.append("kobject \(port.objectType)")
        }
        parts.append("refs \(port.userReferences)")
        return parts.joined(separator: " · ")
    }

    private static func line(module: ModuleRecord) -> String {
        var parts = [
            ProcessDetailRecords.moduleName(module),
            InspectorFormat.hex(module.address),
        ]
        if module.size > 0 { parts.append(InspectorFormat.bytes(module.size)) }
        if !module.path.isEmpty { parts.append(module.path) }
        return parts.joined(separator: " · ")
    }
}
