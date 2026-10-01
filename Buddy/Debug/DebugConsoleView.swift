import AppKit
import SwiftUI

/// Live view of Buddy's `claude` processes: what's running, every stream-json event, stderr, exits, timeouts.
/// Open it from the menu bar panel → "Debug Console".
struct DebugConsoleView: View {
    private let log = DebugLog.shared
    @State private var showRaw = false
    @State private var autoScroll = true

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 3) {
                        if log.entries.isEmpty {
                            Text("Nothing yet. Press ⌃⌥Space and circle something.")
                                .foregroundStyle(.gray)
                        }
                        ForEach(log.entries) { entry in
                            row(entry).id(entry.id)
                        }
                    }
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
                }
                .onChange(of: log.entries.last?.id) { _, id in
                    guard autoScroll, let id else { return }
                    proxy.scrollTo(id, anchor: .bottom)
                }
            }
            .background(Color.black)
        }
        .font(.system(size: 11.5, design: .monospaced))
        .frame(minWidth: 640, minHeight: 360)
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                if log.processes.isEmpty {
                    Label("No claude process running", systemImage: "circle")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(log.processes.keys.sorted(), id: \.self) { pid in
                        let state = log.processes[pid] ?? ""
                        Label("claude pid \(pid) — \(state)", systemImage: "circle.fill")
                            .foregroundStyle(state.hasPrefix("answering") ? .orange : .green)
                    }
                }
            }
            Spacer()
            Toggle("Raw JSON", isOn: $showRaw)
            Toggle("Auto-scroll", isOn: $autoScroll)
            Button("Copy") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(log.plainText, forType: .string)
            }
            Button("Clear") { log.clear() }
        }
        .toggleStyle(.checkbox)
        .padding(10)
    }

    private func row(_ entry: DebugEntry) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(entry.date.formatted(.dateTime.hour().minute().second().secondFraction(.fractional(3))))
                    .foregroundStyle(.gray)
                Text(entry.source.rawValue.uppercased())
                    .foregroundStyle(color(entry.source))
                    .frame(width: 52, alignment: .leading)
                if let pid = entry.pid {
                    Text("\(pid)").foregroundStyle(.gray)
                }
                Text(entry.text)
                    .foregroundStyle(entry.source == .error ? .red : .white)
            }
            if showRaw, let raw = entry.raw {
                Text(raw)
                    .foregroundStyle(.gray)
                    .padding(.leading, 20)
            }
        }
    }

    private func color(_ source: DebugSource) -> Color {
        switch source {
        case .app: .green
        case .stdin: .cyan
        case .stdout: .white
        case .stderr: .orange
        case .error: .red
        }
    }
}
