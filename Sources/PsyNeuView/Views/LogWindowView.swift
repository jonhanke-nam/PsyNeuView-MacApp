import SwiftUI

struct LogWindowView: View {
    let appState: AppState
    /// Report a Problem (#202) lives in this window: it must work when
    /// PsyNeuView can't start (PsyNeuView-archive#1279).
    var report: ProblemReportModel? = nil
    /// Opens the report screen the same way Help ▸ Report a Problem… does.
    var onReportProblem: (() -> Void)? = nil
    @State private var filter: LogSource? = nil
    @State private var searchText = ""
    @State private var autoScroll = true

    private var filteredLogs: [LogEntry] {
        var logs = appState.logs
        if let filter {
            logs = logs.filter { $0.source == filter }
        }
        if !searchText.isEmpty {
            logs = logs.filter { $0.text.localizedCaseInsensitiveContains(searchText) }
        }
        return logs
    }

    var body: some View {
        if let report, report.isOpen {
            ReportProblemView(model: report)
                .frame(minWidth: 700, minHeight: 400)
        } else {
            logs
        }
    }

    private var logs: some View {
        VStack(spacing: 0) {
            // Toolbar
            HStack {
                // Filter picker
                Picker("Filter", selection: $filter) {
                    Text("All").tag(LogSource?.none)
                    ForEach(LogSource.allCases, id: \.self) { source in
                        Text(source.rawValue).tag(LogSource?.some(source))
                    }
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 300)

                Spacer()

                TextField("Search...", text: $searchText)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 200)

                Toggle("Auto-scroll", isOn: $autoScroll)
                    .toggleStyle(.checkbox)

                Button("Clear") {
                    appState.clearLogs()
                }
            }
            .padding(8)

            Divider()

            // Log content
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 1) {
                        ForEach(filteredLogs) { entry in
                            LogLineView(entry: entry)
                                .id(entry.id)
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                }
                .onChange(of: appState.logs.count) { _, _ in
                    if autoScroll, let last = filteredLogs.last {
                        proxy.scrollTo(last.id, anchor: .bottom)
                    }
                }
            }

            Divider()

            // Status bar
            HStack {
                Text("\(filteredLogs.count) lines")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Copy All") {
                    let text = filteredLogs.map { entry in
                        "[\(entry.formattedTimestamp)] [\(entry.source.rawValue)] \(entry.text)"
                    }.joined(separator: "\n")
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                }
                .buttonStyle(.borderless)
                .font(.caption)
                if let onReportProblem {
                    Button("Report a Problem…", action: onReportProblem)
                        .font(.caption)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
        }
        .frame(minWidth: 700, minHeight: 400)
    }
}

struct LogLineView: View {
    let entry: LogEntry

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            Text(entry.formattedTimestamp)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 85, alignment: .leading)

            Text(entry.source.rawValue)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(sourceColor)
                .frame(width: 65, alignment: .leading)

            Text(entry.text)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(entry.isError ? .red : .primary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 1)
    }

    private var sourceColor: Color {
        switch entry.source {
        case .backend:  return .blue
        case .frontend: return .green
        case .system:   return .orange
        }
    }
}
