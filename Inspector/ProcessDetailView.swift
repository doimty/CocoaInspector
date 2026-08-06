import SwiftUI
import UIKit

struct ProcessDetailView: View {
    let row: ProcessRow

    @EnvironmentObject private var model: ProcessListModel
    @Environment(\.dismiss) private var dismiss
    @State private var summary: ProcessDetailSnapshot?
    @State private var summaryFailure: String?
    @State private var pendingSignal: InspectorSignal?
    @State private var isConfirmingSignal = false
    @State private var signalFailure: String?
    @State private var isShowingSignalFailure = false
    @State private var isSendingSignal = false
    @State private var isExporting = false
    @State private var exportFile: ExportFile?
    @State private var exportFailure: String?

    private var identity: ProcessIdentity { row.record.identity }
    private var liveRow: ProcessRow? { model.row(for: identity) }
    // Summary carries fields the periodic sample doesn't collect (paths, fd/port
    // counts); the live sample keeps the dynamic numbers moving between refreshes.
    private var record: ProcessRecord { summary?.process ?? row.record }
    private var stats: ProcessRecord { liveRow?.record ?? record }
    private var hasExited: Bool {
        model.phase == .active && !model.rows.isEmpty && liveRow == nil
    }

    var body: some View {
        List {
            // The drill-downs sit right under the overview: they are what this
            // screen is for, and scrolling past every stat to reach them is not.
            overviewSection
            detailLinksSection
            resourceSection
            executableSection
            bundleSection
        }
        .navigationTitle(row.displayName)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) { optionsMenu }
        }
        .task { await loadSummary() }
        .refreshable { await loadSummary() }
        .sheet(item: $exportFile, onDismiss: cleanUpExport) { file in
            ExportShareSheet(url: file.url)
        }
        .alert(
            "Couldn’t Export the Details",
            isPresented: Binding(
                get: { exportFailure != nil },
                set: { if !$0 { exportFailure = nil } }
            )
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(exportFailure ?? InspectorLocalization.text("Something unexpected went wrong."))
        }
        .confirmationDialog(
            InspectorLocalization.format("Stop %@?", row.displayName),
            isPresented: $isConfirmingSignal,
            titleVisibility: .visible,
            presenting: pendingSignal
        ) { signal in
            Button(
                signal == .forceKill ? "Force Quit (SIGKILL)" : "Ask It to Quit (SIGTERM)",
                role: .destructive
            ) {
                Task { await send(signal) }
            }
        } message: { signal in
            if signal == .forceKill {
                Text("This ends the process immediately. Unsaved work can be lost.")
            } else {
                Text("This asks the process to shut down on its own.")
            }
        }
        .alert("Couldn’t Send the Signal", isPresented: $isShowingSignalFailure) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(signalFailure ?? InspectorLocalization.text("Something unexpected went wrong."))
        }
    }

    private var optionsMenu: some View {
        Menu {
            Button {
                Task { await exportDetails() }
            } label: {
                Label("Export as Property List", systemImage: "square.and.arrow.up")
            }
            .disabled(isExporting)
            if record.pid > 1, !hasExited {
                Section {
                    Button(role: .destructive) {
                        pendingSignal = .terminate
                        isConfirmingSignal = true
                    } label: {
                        Label("Ask It to Quit", systemImage: "stop.circle")
                    }
                    Button(role: .destructive) {
                        pendingSignal = .forceKill
                        isConfirmingSignal = true
                    } label: {
                        Label("Force Quit", systemImage: "xmark.octagon")
                    }
                }
                .disabled(isSendingSignal)
            }
        } label: {
            if isExporting {
                ProgressView()
            } else {
                Image(systemName: "ellipsis.circle")
            }
        }
    }

    private var overviewSection: some View {
        Section {
            InspectorLabeledContent("PID", value: String(record.pid))
            InspectorLabeledContent("Started By (PPID)", value: String(record.parentPID))
            InspectorLabeledContent("Running As", value: InspectorFormat.user(record.userID))
            InspectorLabeledContent(
                "Threads",
                value: InspectorLocalization.format(
                    "%lld (%lld running)",
                    Int64(stats.threadCount),
                    Int64(stats.runningThreadCount)
                )
            )
            InspectorLabeledContent(
                "Priority",
                value: InspectorLocalization.format(
                    "%lld (base %lld)",
                    Int64(record.priority),
                    Int64(record.basePriority)
                )
            )
            InspectorLabeledContent("Nice Value", value: String(record.nice))
            InspectorLabeledContent("Sandbox", value: InspectorFormat.sandbox(record.sandboxStatus))
            if record.availability.contains(.fileDescriptors) {
                InspectorLabeledContent(
                    "Open Files",
                    value: InspectorLocalization.format(
                        "%lld (%lld sockets)",
                        Int64(record.fileDescriptorCount),
                        Int64(record.socketCount)
                    )
                )
            }
            if record.availability.contains(.ports) {
                InspectorLabeledContent("Mach Ports", value: String(record.portCount))
            }
        } header: {
            Text("Overview")
        } footer: {
            if hasExited {
                Text("This process is no longer running.")
            } else if let summaryFailure {
                Text("Couldn’t refresh the details: \(summaryFailure)")
            }
        }
    }

    private var resourceSection: some View {
        Section("Resource Use") {
            InspectorLabeledContent("CPU", value: InspectorFormat.percent(liveRow?.cpuFraction ?? 0))
            InspectorLabeledContent(
                "Total CPU Time",
                value: InspectorFormat.cpuTime(
                    stats.totalCPUTime,
                    numerator: model.machTimebaseNumerator,
                    denominator: model.machTimebaseDenominator
                )
            )
            InspectorLabeledContent("Memory Footprint", value: InspectorFormat.bytes(stats.physicalFootprint))
            InspectorLabeledContent("Resident Memory", value: InspectorFormat.bytes(stats.residentSize))
            InspectorLabeledContent("Virtual Memory", value: InspectorFormat.bytes(stats.virtualSize))
            InspectorLabeledContent("Read from Disk", value: InspectorFormat.bytes(stats.diskBytesRead))
            InspectorLabeledContent("Written to Disk", value: InspectorFormat.bytes(stats.diskBytesWritten))
            if record.availability.contains(.network) {
                InspectorLabeledContent("Downloaded", value: InspectorFormat.bytes(record.networkBytesReceived))
                InspectorLabeledContent("Uploaded", value: InspectorFormat.bytes(record.networkBytesSent))
            }
        }
    }

    @ViewBuilder private var executableSection: some View {
        if !record.executablePath.isEmpty || !record.arguments.isEmpty {
            Section("Executable") {
                if !record.executablePath.isEmpty {
                    Text(record.executablePath)
                        .font(.footnote.monospaced())
                        .textSelection(.enabled)
                }
                if !record.arguments.isEmpty {
                    Text(record.arguments.joined(separator: " "))
                        .font(.footnote.monospaced())
                        .textSelection(.enabled)
                }
            }
        }
    }

    @ViewBuilder private var bundleSection: some View {
        if let bundle = summary?.bundle {
            Section("App Bundle") {
                InspectorLabeledContent("Bundle ID", value: bundle.identifier)
                if !bundle.displayName.isEmpty {
                    InspectorLabeledContent("Display Name", value: bundle.displayName)
                }
                if !bundle.version.isEmpty {
                    InspectorLabeledContent("Version", value: bundle.version)
                }
                if !bundle.minimumOSVersion.isEmpty {
                    InspectorLabeledContent("Requires iOS", value: bundle.minimumOSVersion)
                }
                if !bundle.SDKName.isEmpty {
                    InspectorLabeledContent("SDK", value: bundle.SDKName)
                }
            }
        }
    }

    private var detailLinksSection: some View {
        Section("More Details") {
            NavigationLink("Threads") {
                ProcessDetailListView(kind: .threads, identity: identity)
            }
            NavigationLink("Open Files") {
                ProcessDetailListView(kind: .files, identity: identity)
            }
            NavigationLink("Mach Ports") {
                ProcessDetailListView(kind: .ports, identity: identity)
            }
            NavigationLink("Loaded Modules") {
                ProcessDetailListView(kind: .modules, identity: identity)
            }
        }
    }

    private func loadSummary() async {
        summaryFailure = nil
        do {
            let result = try await model.details(.summary, for: identity)
            if result.status == .available || result.status == .partial {
                summary = result
            } else {
                summaryFailure = InspectorLocalization.format(
                    "error %lld",
                    Int64(result.errorCode)
                )
            }
        } catch {
            summaryFailure = InspectorErrorText.describe(error)
        }
    }

    // Gathers every collector, not just what's on screen: the file is meant to
    // be read back later, when the process may well be gone.
    private func exportDetails() async {
        isExporting = true
        defer { isExporting = false }
        let document = await ProcessExport.document(for: identity, using: model)
        do {
            let url = try ProcessExport.write(
                document,
                named: "\(row.displayName)-\(record.pid)"
            )
            exportFile = ExportFile(url: url)
        } catch {
            exportFailure = error.localizedDescription
        }
    }

    // The plist lives in a temporary directory only until the share sheet is
    // done with it; nothing is left lying around afterwards.
    private func cleanUpExport() {
        ProcessExport.removeExports()
    }

    private func send(_ signal: InspectorSignal) async {
        isSendingSignal = true
        defer { isSendingSignal = false }
        do {
            try await model.sendSignal(signal, to: identity)
            dismiss()
        } catch {
            signalFailure = InspectorErrorText.describe(error)
            isShowingSignalFailure = true
        }
    }
}

private struct ExportFile: Identifiable {
    let url: URL
    var id: URL { url }
}

// ShareLink needs its item up front; the export is only ready after a round of
// daemon calls, so the share sheet is presented directly once the file exists.
private struct ExportShareSheet: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: [url], applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
