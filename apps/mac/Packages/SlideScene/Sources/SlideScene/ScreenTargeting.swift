import Foundation
import PresenterCore

/// Limiting a media cue to some screens. A cue with no screens, or an empty
/// list, shows everywhere.
public enum ScreenTargeting {

    /// Nil for "every screen", so an empty choice is stored as nothing.
    public static func normalized(_ ids: [String]?) -> [String]? {
        guard let ids else { return nil }
        let cleaned = ids.filter { !$0.isEmpty }
        return cleaned.isEmpty ? nil : cleaned
    }

    /// The selection after switching one screen on or off. Stays in a stable
    /// order so the same choice always compares equal.
    public static func toggling(_ id: String, in selected: [String]?) -> [String]? {
        var ids = selected ?? []
        if let index = ids.firstIndex(of: id) {
            ids.remove(at: index)
        } else {
            ids.append(id)
        }
        return normalized(ids.sorted())
    }

    /// Short words for a chip: "All Screens", one screen's name, or a count.
    public static func summary(
        _ selected: [String]?, name: (String) -> String?
    ) -> String {
        guard let ids = normalized(selected) else { return "All Screens" }
        if ids.count == 1 { return name(ids[0]) ?? "1 Screen" }
        return "\(ids.count) Screens"
    }
}

extension CueMedia {

    /// True when the cue is limited to particular screens.
    public var isScreenTargeted: Bool {
        ScreenTargeting.normalized(screenIds) != nil
    }

    /// Whether the cue belongs in the scene for `screen`. The program feed
    /// and previews have no screen and show every cue.
    public func shows(onScreen screen: String?) -> Bool {
        guard let screen, let ids = ScreenTargeting.normalized(screenIds) else { return true }
        return ids.contains(screen)
    }
}
