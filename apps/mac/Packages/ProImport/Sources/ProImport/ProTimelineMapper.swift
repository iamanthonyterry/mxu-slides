import Foundation
import PresenterCore

/// Maps a ProPresenter 7 presentation timeline (slide cues on a clock, optionally
/// chased by incoming SMPTE timecode) onto `PresentationTimeline`.
///
/// Pro7 stores cue times in seconds from the start of the timeline, and the
/// timecode offset in seconds of timecode (01:00:00:00 → 3600). A cue either names
/// a slide (`cue_id`, which is the slide's id after import) or carries an action;
/// action cues have no slide to fire, so they are dropped with a warning.
public enum ProTimelineMapper {

    public static func map(
        _ doc: RVData_Presentation, slideIDs: Set<String>
    ) -> (timeline: PresentationTimeline?, warnings: [String]) {
        guard doc.hasTimeline else { return (nil, []) }
        let source = doc.timeline
        let rawCues = source.cuesV2.isEmpty ? source.cues : source.cuesV2
        var warnings: [String] = []
        var cues: [TimelineCue] = []
        var actionCues = 0
        var missing = 0
        for cue in rawCues {
            guard case .cueID(let uuid)? = cue.triggerInfo else {
                actionCues += 1
                continue
            }
            let slideID = uuid.string.lowercased()
            guard slideIDs.contains(slideID) else {
                missing += 1
                continue
            }
            guard cue.triggerTime.isFinite, cue.triggerTime >= 0 else { continue }
            cues.append(TimelineCue(
                slideId: slideID, timeSeconds: cue.triggerTime,
                name: cue.name.isEmpty ? nil : cue.name))
        }
        if actionCues > 0 {
            warnings.append("timeline: \(actionCues) action cue(s) not imported (only slide cues are supported)")
        }
        if missing > 0 {
            warnings.append("timeline: \(missing) cue(s) pointed at slides that are not in the presentation")
        }
        guard !cues.isEmpty || source.timecodeEnable else { return (nil, warnings) }
        cues.sort { $0.timeSeconds < $1.timeSeconds }
        let offset = source.timecodeOffset.isFinite ? max(0, source.timecodeOffset) : 0
        let duration = source.duration.isFinite && source.duration > 0 ? source.duration : nil
        return (
            PresentationTimeline(
                timecodeEnabled: source.timecodeEnable,
                offsetSeconds: offset,
                cues: cues,
                durationSeconds: duration),
            warnings
        )
    }
}
