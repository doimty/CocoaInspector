import SwiftUI

struct ProcessDetailListView: View {
    let kind: ProcessDetailKind
    let identity: ProcessIdentity

    @Environment(ProcessListModel.self) private var model
    @State private var detail: ProcessDetailSnapshot?
    // Filtering and sorting run once per load, query, or order change — never
    // in a view body, which re-runs far more often than the data changes.
    @State private var visible = ProcessDetailRecords()
    @State private var failure: String?
    @State private var searchText = ""
    @AppStorage private var sortOrder: ProcessDetailSortOrder

    init(kind: ProcessDetailKind, identity: ProcessIdentity) {
        self.kind = kind
        self.identity = identity
        // One stored order per kind: "sort by size" means nothing to threads.
        _sortOrder = AppStorage(
            wrappedValue: .default(for: kind),
            "processDetail.sortOrder.\(kind.rawValue)"
        )
    }

    private var title: String {
        switch kind {
        case .summary: String(localized: "Overview")
        case .threads: String(localized: "Threads")
        case .files: String(localized: "Open Files")
        case .ports: String(localized: "Mach Ports")
        case .modules: String(localized: "Loaded Modules")
        }
    }

    private var searchPrompt: String {
        switch kind {
        case .summary: String(localized: "Search")
        case .threads: String(localized: "Search by name or thread ID")
        case .files: String(localized: "Search by path or descriptor")
        case .ports: String(localized: "Search by port name or rights")
        case .modules: String(localized: "Search by name or path")
        }
    }

    private var processName: String {
        model.row(for: identity)?.displayName ?? "pid \(identity.pid)"
    }

    var body: some View {
        List {
            if let detail {
                content(for: detail)
            }
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $searchText, prompt: searchPrompt)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) { optionsMenu }
        }
        .overlay { overlayContent }
        .task { await load() }
        .refreshable { await load() }
        .onChange(of: searchText) { rebuildVisible() }
        .onChange(of: sortOrder) { rebuildVisible() }
    }

    @ViewBuilder private var optionsMenu: some View {
        Menu {
            if detail != nil {
                ShareLink(
                    item: ProcessDetailExport.text(
                        title: title,
                        process: processName,
                        records: visible
                    ),
                    subject: Text("\(title) — \(processName)")
                ) {
                    Label("Share", systemImage: "square.and.arrow.up")
                }
                .disabled(visible.isEmpty)
                Picker("Sort By", systemImage: "arrow.up.arrow.down", selection: $sortOrder) {
                    ForEach(ProcessDetailSortOrder.options(for: kind)) { order in
                        Text(order.label).tag(order)
                    }
                }
                .pickerStyle(.menu)
            }
        } label: {
            Image(systemName: "ellipsis.circle")
        }
        .disabled(detail == nil)
    }

    @ViewBuilder private func content(for detail: ProcessDetailSnapshot) -> some View {
        Section {
            switch kind {
            case .summary:
                EmptyView()
            case .threads:
                ForEach(visible.threads, id: \.id) { thread in
                    ThreadRowView(thread: thread)
                }
            case .files:
                ForEach(visible.files, id: \.descriptor) { file in
                    FileRowView(file: file)
                }
            case .ports:
                ForEach(visible.ports, id: \.name) { port in
                    PortRowView(port: port)
                }
            case .modules:
                ForEach(visible.modules, id: \.address) { module in
                    ModuleRowView(module: module)
                }
            }
        } header: {
            if let header = header(for: detail) {
                Text(header)
            }
        } footer: {
            if detail.status == .partial {
                Text("Some of this couldn’t be read (error \(detail.errorCode)).")
            }
        }
    }

    private func header(for detail: ProcessDetailSnapshot) -> String? {
        let total = ProcessDetailRecords.total(in: detail, kind: kind)
        guard total > 0 else { return nil }
        return visible.count == total
            ? String(localized: "\(total) in total")
            : String(localized: "\(visible.count) of \(total) shown")
    }

    @ViewBuilder private var overlayContent: some View {
        if let failure {
            ContentUnavailableView {
                Label("Couldn’t Load This", systemImage: "exclamationmark.triangle")
            } description: {
                Text(failure)
            } actions: {
                Button("Try Again") { Task { await load() } }
            }
        } else if let detail {
            if ProcessDetailRecords.total(in: detail, kind: kind) == 0 {
                ContentUnavailableView("Nothing Here Yet", systemImage: "tray")
            } else if visible.isEmpty {
                ContentUnavailableView.search(text: searchText)
            }
        } else {
            ProgressView()
        }
    }

    private func rebuildVisible() {
        guard let detail else {
            visible = ProcessDetailRecords()
            return
        }
        visible = ProcessDetailRecords.visible(
            in: detail,
            kind: kind,
            order: sortOrder,
            query: searchText
        )
    }

    private func load() async {
        failure = nil
        do {
            let result = try await model.details(kind, for: identity)
            switch result.status {
            case .available, .partial:
                detail = result
                rebuildVisible()
            case .processExited:
                failure = String(localized: "This process has ended.")
            case .permissionDenied:
                failure = String(
                    localized: "This app isn’t allowed to read that (error \(Int(result.errorCode)))."
                )
            case .unsupported:
                failure = String(localized: "This isn’t available on this device.")
            case .failed:
                failure = String(
                    localized: "Couldn’t read this data (error \(Int(result.errorCode)))."
                )
            }
        } catch {
            failure = InspectorErrorText.describe(error)
        }
    }
}

private struct ThreadRowView: View {
    let thread: ThreadRecord

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(
                    thread.name.isEmpty
                        ? String(localized: "Thread \(InspectorFormat.hex(thread.id))")
                        : thread.name
                )
                .lineLimit(1)
                Text("\(InspectorFormat.threadState(thread.runState)) · priority \(thread.currentPriority)")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Text(String(format: "%.1f%%", Double(thread.cpuUsage) / 10))
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
    }
}

private struct FileRowView: View {
    let file: FileDescriptorRecord

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("fd \(file.descriptor) · \(file.detail.isEmpty ? InspectorFormat.fileKind(file.kind) : file.detail)")
            if !subtitle.isEmpty {
                Text(subtitle)
                    .font(.footnote.monospaced())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
        }
    }

    private var subtitle: String { ProcessDetailRecords.fileName(file) }
}

private struct PortRowView: View {
    let port: MachPortRecord

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(InspectorFormat.hex(UInt64(port.name)))
                    .monospaced()
                Text(subtitle)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if port.userReferences > 1 {
                Text("refs \(port.userReferences)")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var subtitle: String {
        var parts = [InspectorFormat.portRights(port.rights)]
        if port.objectType != 0 {
            parts.append(String(localized: "kobject \(Int(port.objectType))"))
        }
        if !port.setMembers.isEmpty {
            parts.append(String(localized: "\(port.setMembers.count) members"))
        }
        return parts.joined(separator: " · ")
    }
}

private struct ModuleRowView: View {
    let module: ModuleRecord

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(name)
                    .lineLimit(1)
                Spacer()
                if module.size > 0 {
                    Text(InspectorFormat.bytes(module.size))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }
            if !module.path.isEmpty {
                Text(module.path)
                    .font(.footnote.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .textSelection(.enabled)
            }
        }
    }

    private var name: String { ProcessDetailRecords.moduleName(module) }
}
