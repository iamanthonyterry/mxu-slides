import AudioEngine
import SwiftUI
import TimecodeKit

/// Device and channel pickers for the LTC input.
struct TimecodeInputPicker: View {
    @Bindable var timecode: TimecodeController

    var body: some View {
        let devices = timecode.inputDevices
        let selected = devices.first { $0.uid == timecode.deviceUID }
        HStack(spacing: 8) {
            Picker("", selection: $timecode.deviceUID) {
                Text("None").tag("")
                if selected == nil, !timecode.deviceUID.isEmpty {
                    Text("Unavailable device").tag(timecode.deviceUID)
                }
                ForEach(devices) { device in
                    Text(device.name).tag(device.uid)
                }
            }
            .labelsHidden()
            .frame(maxWidth: 200)

            Picker("", selection: $timecode.channel) {
                ForEach(0..<max(selected?.channelCount ?? 2, timecode.channel + 1), id: \.self) { index in
                    Text("Ch \(index + 1)").tag(index)
                }
            }
            .labelsHidden()
            .fixedSize()
            .disabled(selected == nil)
        }
    }
}

/// Live readout: state, incoming timecode, rate, signal level, and which song is live.
struct TimecodeStatusView: View {
    let timecode: TimecodeController

    var body: some View {
        VStack(alignment: .trailing, spacing: 4) {
            HStack(spacing: 8) {
                Circle()
                    .fill(color)
                    .frame(width: 8, height: 8)
                Text(timecode.status.label)
                    .font(.callout)
                Text(timecode.timecode?.description ?? "--:--:--:--")
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(timecode.status == .running ? .primary : .secondary)
            }
            HStack(spacing: 8) {
                ProgressView(value: Double(min(timecode.inputPeak, 1)))
                    .frame(width: 80)
                    .controlSize(.small)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
    }

    private var color: Color {
        switch timecode.status {
        case .running: .green
        case .waiting, .stopped: .yellow
        case .failed, .noInput: .red
        case .off: .gray
        }
    }

    private var detail: String {
        var parts: [String] = []
        if let rate = timecode.rate { parts.append(rate.label) }
        if let song = timecode.activeSongName {
            parts.append(song)
        } else if timecode.serviceName == nil, timecode.enabled {
            parts.append("No service selected")
        } else if timecode.enabled {
            parts.append("\(timecode.followedSongCount) song\(timecode.followedSongCount == 1 ? "" : "s") on timecode")
        }
        return parts.joined(separator: " · ")
    }
}
