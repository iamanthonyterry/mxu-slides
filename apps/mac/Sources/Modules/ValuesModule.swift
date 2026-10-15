import AppKit
import PresenterCore
import SwiftUI
import UniformTypeIdentifiers

struct ValuesModule: View {
    let model: AppModel
    let controls: ServiceControls

    @Environment(\.runOnly) private var runOnly

    var body: some View {
        let station = controls.dynamicValues
        VStack(alignment: .leading, spacing: 6) {
            ModuleHeaderBar {

            } trailing: {
                if !runOnly {
                    Button {
                        station.add()
                    } label: {
                        Image(systemName: "plus").moduleHeaderGlyph()
                    }
                    .buttonStyle(.plain)
                    .help("Add a value — write {Name} in any text box or QR code to show it")
                }
            }
            if station.values.isEmpty {
                Text("A value is text you set once and slides read as {Name}: the offering total, the speaker, a link. Point one at a text file and it follows the file.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 2)
            }
            VStack(spacing: 4) {
                ForEach(station.values) { entry in
                    ValueRow(station: station, entry: entry, runOnly: runOnly)
                }
            }
        }
    }
}

private struct ValueRow: View {
    let station: DynamicValuesController
    let entry: DynamicValue
    let runOnly: Bool

    @State private var nameDraft = ""
    @State private var valueDraft = ""
    @FocusState private var nameFocused: Bool
    @FocusState private var valueFocused: Bool

    private var followsFile: Bool { entry.filePath?.isEmpty == false }
    private var fileUnreadable: Bool { station.unreadableFileIDs.contains(entry.id) }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                if runOnly {
                    Text(entry.name)
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                } else {
                    TextField("Name", text: $nameDraft)
                        .textFieldStyle(.plain)
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .focused($nameFocused)
                        .onSubmit(commitName)
                        .help("The name slides write in braces to read this value")
                }
                Spacer(minLength: 6)
                if !runOnly {
                    Menu {
                        Button("Copy {\(entry.name)}") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(
                                DynamicValues.token(for: entry.name), forType: .string
                            )
                        }
                        Divider()
                        Button(followsFile ? "Choose Another File…" : "Read From File…") {
                            chooseFile()
                        }
                        if followsFile {
                            Button("Stop Reading the File") { station.setFile(id: entry.id, to: nil) }
                        }
                        Divider()
                        Button("Delete", role: .destructive) { station.remove(id: entry.id) }
                    } label: {
                        Image(systemName: "ellipsis")
                            .font(.system(size: 11))
                            .foregroundStyle(.tertiary)
                            .frame(width: 20, height: 20)
                            .contentShape(Rectangle())
                    }
                    .menuStyle(.button)
                    .buttonStyle(.plain)
                    .menuIndicator(.hidden)
                    .fixedSize()
                }
            }
            if followsFile, let path = entry.filePath {
                HStack(spacing: 4) {
                    Image(systemName: fileUnreadable ? "exclamationmark.triangle.fill" : "doc.text")
                        .font(.system(size: 9))
                        .foregroundStyle(fileUnreadable ? Color.orange : .secondary)
                    Text(URL(fileURLWithPath: path).lastPathComponent)
                        .font(.caption2)
                        .foregroundStyle(fileUnreadable ? Color.orange : .secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(fileUnreadable ? "can't be read — showing the typed text" : "updates as the file changes")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
                .help(path)
            }
            if followsFile && !fileUnreadable {
                Text(station.current[entry.id] ?? "")
                    .font(.callout)
                    .foregroundStyle(.primary)
                    .lineLimit(3)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                TextField("Value", text: $valueDraft, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(.callout)
                    .lineLimit(1 ... 4)
                    .focused($valueFocused)
                    .onSubmit(commitValue)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(
            Color.primary.opacity(0.03),
            in: RoundedRectangle.standard(CornerStandard.element)
        )
        .onAppear {
            nameDraft = entry.name
            valueDraft = entry.value
        }
        .onChange(of: entry.name) { _, name in if !nameFocused { nameDraft = name } }
        .onChange(of: entry.value) { _, value in if !valueFocused { valueDraft = value } }
        .onChange(of: nameFocused) { _, focused in if !focused { commitName() } }
        .onChange(of: valueFocused) { _, focused in if !focused { commitValue() } }
        .onChange(of: valueDraft) { _, text in
            // The audience sees typing as it happens, like the offering counter
            // being updated live, so a value commits on every change.
            if valueFocused { station.setValue(id: entry.id, to: text) }
        }
    }

    private func commitName() {
        if !station.rename(id: entry.id, to: nameDraft) { nameDraft = entry.name }
    }

    private func commitValue() {
        station.setValue(id: entry.id, to: valueDraft)
    }

    private func chooseFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.plainText, .text]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.message = "Choose a text file. Its text becomes this value and updates when the file changes."
        panel.prompt = "Use File"
        if panel.runModal() == .OK, let url = panel.url {
            station.setFile(id: entry.id, to: url.path)
        }
    }
}
