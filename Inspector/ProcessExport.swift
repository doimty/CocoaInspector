import Foundation

// A machine-readable dump of everything the daemon can say about one process,
// written as an XML property list so plutil and analysis scripts can read it
// back. Every collector reports its own status: a partial export is still
// useful, but a reader has to be able to tell what's missing.
struct ProcessExportDocument: Codable {
    struct SectionStatus: Codable {
        var status: String
        var errorCode: Int32 = 0
        var failure: String?
    }

    var formatVersion = 1
    var exportedAt: Date
    var pid: Int32
    var startTime: UInt64
    var process: ProcessRecord?
    var bundle: BundleMetadata?
    var threads: [ThreadRecord] = []
    var files: [FileDescriptorRecord] = []
    var ports: [MachPortRecord] = []
    var modules: [ModuleRecord] = []
    var collectors: [String: SectionStatus] = [:]
}

enum ProcessExport {
    @MainActor
    static func document(
        for identity: ProcessIdentity,
        using model: ProcessListModel
    ) async -> ProcessExportDocument {
        var document = ProcessExportDocument(
            exportedAt: Date(),
            pid: identity.pid,
            startTime: identity.startTime
        )
        // Sequential on purpose: the daemon serves one request at a time, and
        // the model funnels them through a single operation chain anyway.
        for kind in ProcessDetailKind.allCases {
            do {
                let snapshot = try await model.details(kind, for: identity)
                document.collectors[key(for: kind)] = ProcessExportDocument.SectionStatus(
                    status: snapshot.status.rawValue,
                    errorCode: snapshot.errorCode
                )
                switch kind {
                case .summary:
                    document.process = snapshot.process
                    document.bundle = snapshot.bundle
                case .threads: document.threads = snapshot.threads
                case .files: document.files = snapshot.files
                case .ports: document.ports = snapshot.ports
                case .modules: document.modules = snapshot.modules
                }
            } catch {
                document.collectors[key(for: kind)] = ProcessExportDocument.SectionStatus(
                    status: "failed",
                    failure: InspectorErrorText.describe(error)
                )
            }
        }
        return document
    }

    // Each export gets its own directory so repeated exports of one process
    // keep the same readable file name instead of collecting numeric suffixes.
    static func write(_ document: ProcessExportDocument, named name: String) throws -> URL {
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .xml
        let data = try encoder.encode(document)
        let directory = exportsDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("\(fileName(name)).plist")
        try data.write(to: url, options: .atomic)
        return url
    }

    static func removeExports() {
        try? FileManager.default.removeItem(at: exportsDirectory)
    }

    private static var exportsDirectory: URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("Exports", isDirectory: true)
    }

    private static func fileName(_ name: String) -> String {
        let sanitized = String(
            name.map { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" ? $0 : "-" }
        )
        return sanitized.isEmpty ? "process" : sanitized
    }

    private static func key(for kind: ProcessDetailKind) -> String {
        switch kind {
        case .summary: "summary"
        case .threads: "threads"
        case .files: "files"
        case .ports: "ports"
        case .modules: "modules"
        }
    }
}
