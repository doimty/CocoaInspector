//
//  ProcessDetailListView.swift
//  Inspector
//
//  Created by qaq on 3/8/2026.
//

import SwiftUI
import UIKit

struct ProcessDetailListView: View {
    let kind: ProcessDetailKind
    let identity: ProcessIdentity

    @EnvironmentObject private var model: ProcessListModel
    @State private var detail: ProcessDetailSnapshot?
    @State private var visible = ProcessDetailRecords()
    @State private var failure: String?
    @State private var searchText = ""
    @State private var inspected: DetailRowInspection?
    @AppStorage private var sortOrder: ProcessDetailSortOrder
    @AppStorage private var sortAscending: Bool
    @State private var sharePayload: InspectorSharePayload?

    private let columns: [DetailColumn]

    init(kind: ProcessDetailKind, identity: ProcessIdentity) {
        self.kind = kind
        self.identity = identity
        columns = ProcessDetailTable.columns(for: kind)
        let fallback = ProcessDetailSort.default(for: kind)
        _sortOrder = AppStorage(
            wrappedValue: fallback.order,
            "processDetail.sortOrder.\(kind.rawValue)"
        )
        _sortAscending = AppStorage(
            wrappedValue: fallback.ascending,
            "processDetail.sortAscending.\(kind.rawValue)"
        )
    }

    private var sort: ProcessDetailSort {
        ProcessDetailSort(order: sortOrder, ascending: sortAscending)
    }

    private var sortBinding: Binding<ProcessDetailSort> {
        Binding(
            get: { sort },
            set: { sortOrder = $0.order; sortAscending = $0.ascending }
        )
    }

    private var title: String {
        switch kind {
        case .summary: InspectorLocalization.text("Overview")
        case .threads: InspectorLocalization.text("Threads")
        case .files: InspectorLocalization.text("Open Files")
        case .ports: InspectorLocalization.text("Mach Ports")
        case .modules: InspectorLocalization.text("Loaded Modules")
        }
    }

    private var searchPrompt: String {
        switch kind {
        case .summary: InspectorLocalization.text("Search")
        case .threads: InspectorLocalization.text("Search by name or thread ID")
        case .files: InspectorLocalization.text("Search by path or descriptor")
        case .ports: InspectorLocalization.text("Search by port name or rights")
        case .modules: InspectorLocalization.text("Search by name or path")
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
        .listStyle(.plain)
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $searchText, prompt: searchPrompt)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) { optionsMenu }
        }
        .overlay { overlayContent }
        .sheet(item: $inspected) { RowInspectionSheet(inspection: $0) }
        .sheet(item: $sharePayload) { payload in
            InspectorActivityView(items: payload.items)
        }
        .task { await load() }
        .refreshable { await load() }
        .onChange(of: searchText) { _ in rebuildVisible() }
        .onChange(of: sort) { _ in rebuildVisible() }
    }

    @ViewBuilder private var optionsMenu: some View {
        Menu {
            if detail != nil {
                Button {
                    let text = ProcessDetailExport.text(
                        title: title,
                        process: processName,
                        records: visible
                    )
                    sharePayload = InspectorSharePayload(items: [text])
                } label: {
                    Label("Share", systemImage: "square.and.arrow.up")
                }
                .disabled(visible.isEmpty)
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
                    row(
                        cells: ProcessDetailTable.cells(thread: thread),
                        inspection: DetailRowInspection(thread: thread)
                    )
                }
            case .files:
                ForEach(visible.files, id: \.descriptor) { file in
                    row(
                        cells: ProcessDetailTable.cells(file: file),
                        inspection: DetailRowInspection(file: file)
                    )
                }
            case .ports:
                ForEach(visible.ports, id: \.name) { port in
                    row(
                        cells: ProcessDetailTable.cells(port: port),
                        inspection: DetailRowInspection(port: port)
                    )
                }
            case .modules:
                ForEach(visible.modules, id: \.address) { module in
                    row(
                        cells: ProcessDetailTable.cells(module: module),
                        inspection: DetailRowInspection(module: module)
                    )
                }
            }
        } header: {
            if !columns.isEmpty {
                DetailTableHeader(columns: columns, sort: sortBinding)
            }
        } footer: {
            footer(for: detail)
        }
    }

    private func row(cells: [String], inspection: DetailRowInspection) -> some View {
        Button {
            inspected = inspection
        } label: {
            DetailTableRow(columns: columns, cells: cells)
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder private func footer(for detail: ProcessDetailSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            if let count = countSummary(for: detail) {
                Text(count)
            }
            if detail.status == .partial {
                Text(InspectorLocalization.format(
                    "Some of this couldn’t be read (error %lld).",
                    Int64(detail.errorCode)
                ))
            }
        }
        .padding(.top, 4)
    }

    private func countSummary(for detail: ProcessDetailSnapshot) -> String? {
        let total = ProcessDetailRecords.total(in: detail, kind: kind)
        guard total > 0 else { return nil }
        return visible.count == total
            ? InspectorLocalization.format("%lld in total", Int64(total))
            : InspectorLocalization.format(
                "%lld of %lld shown",
                Int64(visible.count),
                Int64(total)
            )
    }

    @ViewBuilder private var overlayContent: some View {
        if let failure {
            InspectorUnavailableView(
                title: "Couldn’t Load This",
                systemImage: "exclamationmark.triangle",
                message: failure,
                actionTitle: "Try Again",
                action: { Task { await load() } }
            )
        } else if let detail {
            if ProcessDetailRecords.total(in: detail, kind: kind) == 0 {
                InspectorUnavailableView(
                    title: "Nothing Here Yet",
                    systemImage: "tray"
                )
            } else if visible.isEmpty {
                InspectorUnavailableView(
                    title: "Nothing to Show",
                    systemImage: "magnifyingglass",
                    message: searchText
                )
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
            sort: sort,
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
                failure = InspectorLocalization.text("This process has ended.")
            case .permissionDenied:
                failure = InspectorLocalization.format(
                    "This app isn’t allowed to read that (error %lld).",
                    Int64(result.errorCode)
                )
            case .unsupported:
                failure = InspectorLocalization.text("This isn’t available on this device.")
            case .failed:
                failure = InspectorLocalization.format(
                    "Couldn’t read this data (error %lld).",
                    Int64(result.errorCode)
                )
            }
        } catch {
            failure = InspectorErrorText.describe(error)
        }
    }
}

private struct RowInspectionSheet: View {
    let inspection: DetailRowInspection

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationView {
            List {
                ForEach(inspection.fields) { field in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(field.label)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(field.value)
                            .font(field.isMonospaced ? .callout.monospaced() : .callout)
                            .textSelection(.enabled)
                    }
                }
            }
            .navigationTitle(inspection.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button {
                        UIPasteboard.general.string = inspection.text
                    } label: {
                        Image(systemName: "doc.on.doc")
                    }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .navigationViewStyle(StackNavigationViewStyle())
    }
}