import Foundation
import Observation
import PresenterCore
import SlideScene

/// The workspace's dynamic values: named text that slides read with `{Name}`,
/// typed by hand or followed from a text file another tool keeps current.
@MainActor
@Observable
final class DynamicValuesController {
    private(set) var values: [DynamicValue] = []

    /// What each value currently reads as, by value id.
    private(set) var current: [String: String] = [:]

    /// Ids of file-backed values whose file is missing or empty right now.
    private(set) var unreadableFileIDs: Set<String> = []

    private let render: RenderContext

    /// Called after slides' table of values changes, so live output redraws.
    @ObservationIgnored var onChange: (() -> Void)?

    @ObservationIgnored private var watcher: Task<Void, Never>?

    private static let defaultsKey = "serviceControls.dynamicValues"

    /// How often file-backed values are read again.
    private static let pollInterval: Duration = .seconds(1)

    init(render: RenderContext) {
        self.render = render
        restore()
        refresh()
        updateWatcher()
    }

    func value(id: String) -> DynamicValue? {
        values.first { $0.id == id }
    }

    /// Whether `name` could be given to the value with `id` (or to a new one
    /// when `id` is nil).
    func canUse(name: String, for id: String? = nil) -> Bool {
        guard DynamicValues.isValidName(name) else { return false }
        let key = DynamicValues.key(name)
        return !values.contains { $0.id != id && DynamicValues.key($0.name) == key }
    }

    @discardableResult
    func add(name: String = "Value", value: String = "", filePath: String? = nil) -> String {
        let entry = DynamicValue(
            name: DynamicValues.uniqueName(
                DynamicValues.isValidName(name) ? name.trimmingCharacters(in: .whitespacesAndNewlines) : "Value",
                among: values
            ),
            value: value, filePath: filePath
        )
        values.append(entry)
        changed()
        return entry.id
    }

    /// Renames a value. Returns false, changing nothing, when the name is
    /// empty, holds braces, or another value already uses it.
    @discardableResult
    func rename(id: String, to name: String) -> Bool {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard canUse(name: trimmed, for: id),
              let index = values.firstIndex(where: { $0.id == id })
        else { return false }
        guard values[index].name != trimmed else { return true }
        values[index].name = trimmed
        changed()
        return true
    }

    func setValue(id: String, to text: String) {
        guard let index = values.firstIndex(where: { $0.id == id }),
              values[index].value != text else { return }
        values[index].value = text
        changed()
    }

    func setFile(id: String, to path: String?) {
        guard let index = values.firstIndex(where: { $0.id == id }) else { return }
        let path = path.flatMap { $0.isEmpty ? nil : $0 }
        guard values[index].filePath != path else { return }
        values[index].filePath = path
        changed()
    }

    func remove(id: String) {
        guard values.contains(where: { $0.id == id }) else { return }
        values.removeAll { $0.id == id }
        changed()
    }

    // MARK: -

    private func changed() {
        refresh()
        updateWatcher()
        save()
    }

    /// Reads every value, and hands slides the table only when it differs.
    private func refresh() {
        var table: [String: String] = [:]
        var unreadable: Set<String> = []
        var seen: Set<String> = []
        var currentByID: [String: String] = [:]
        for entry in values {
            var text = entry.value
            if let path = entry.filePath, !path.isEmpty {
                if let fromFile = DynamicValues.contents(ofFileAt: path) {
                    text = fromFile
                } else {
                    unreadable.insert(entry.id)
                }
            }
            currentByID[entry.id] = text
            guard DynamicValues.isValidName(entry.name) else { continue }
            let key = DynamicValues.key(entry.name)
            if seen.insert(key).inserted { table[key] = text }
        }
        if current != currentByID { current = currentByID }
        if unreadableFileIDs != unreadable { unreadableFileIDs = unreadable }
        if render.confidenceInfo.values != table {
            var info = render.confidenceInfo
            info.values = table
            render.confidenceInfo = info
            onChange?()
        }
    }

    private func updateWatcher() {
        let wantsWatcher = values.contains { $0.filePath?.isEmpty == false }
        if !wantsWatcher {
            watcher?.cancel()
            watcher = nil
            return
        }
        guard watcher == nil else { return }
        watcher = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.pollInterval)
                guard let self, !Task.isCancelled else { return }
                self.refresh()
            }
        }
    }

    private func save() {
        if let data = try? JSONEncoder().encode(values) {
            UserDefaults.standard.set(data, forKey: Self.defaultsKey)
        }
    }

    private func restore() {
        guard let data = UserDefaults.standard.data(forKey: Self.defaultsKey),
              let saved = try? JSONDecoder().decode([DynamicValue].self, from: data)
        else { return }
        values = saved
    }
}
