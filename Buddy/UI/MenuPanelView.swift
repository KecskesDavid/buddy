import SwiftUI

/// The panel that drops down from Buddy's menu bar icon: how to draw, model, quit.
struct MenuPanelView: View {
    let model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 6) {
                Image(systemName: "cursorarrow.rays")
                Text("Buddy").font(.headline)
            }

            Divider()

            VStack(alignment: .leading, spacing: 6) {
                sectionTitle("How to draw")
                step("1", "Press \(Text("⌃⌥Space").font(.callout.monospaced().weight(.semibold)))")
                step("2", "Circle something on screen")
                step("3", "Release — the answer appears next to the cursor")
                Text("Esc or any click closes it.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Divider()

            VStack(alignment: .leading, spacing: 6) {
                sectionTitle("Model")
                Picker("Model", selection: Binding(get: { model.model }, set: { model.setModel($0) })) {
                    ForEach(ClaudeModel.allCases) { option in
                        Text(option.label).tag(option)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                Text(model.model.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Divider()

            HStack {
                Button("Debug Console") {
                    NSApp.activate()
                    openWindow(id: "debug-console")
                }
                Spacer()
                Button("Quit Buddy") { NSApplication.shared.terminate(nil) }
                    .keyboardShortcut("q")
            }
        }
        .padding(14)
        .frame(width: 280)
    }

    private func sectionTitle(_ title: String) -> some View {
        Text(title)
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.secondary)
    }

    private func step(_ number: String, _ text: LocalizedStringKey) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(number)
                .font(.caption.weight(.bold))
                .frame(width: 16, height: 16)
                .background(Circle().fill(Color.accentColor.opacity(0.2)))
            Text(text).font(.callout)
        }
    }
}
