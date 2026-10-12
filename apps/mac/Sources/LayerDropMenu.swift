import PresenterCore
import SwiftUI

enum LayerDropChoice: Equatable {
    case slide
    case layer(String)
}

struct PendingLayerDrop: Identifiable, Equatable {
    let id = UUID()
    var mediaID: String
    var slideID: String
    var scenePoint: CGPoint = .zero
}

struct LayerDropChooser: View {
    let model: AppModel
    let mediaID: String
    let slideTitle: String
    let layersTitle: String
    var replacing: [String: String] = [:]
    let pick: (LayerDropChoice) -> Void
    let cancel: () -> Void

    var body: some View {
        let stack = model.layerStack
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Color.black
                    .overlay { PosterImage(model: model, mediaId: mediaID) }
                    .clipped()
                    .frame(width: 48, height: 27)
                    .clipShape(RoundedRectangle.standard(3))
                Text("Place \u{201C}\(model.media(mediaID)?.name ?? "Media")\u{201D}")
                    .font(.caption.weight(.semibold))
                    .lineLimit(2)
                Spacer(minLength: 0)
            }
            .padding(.bottom, 2)
            row(title: slideTitle, note: nil, tint: nil) { pick(.slide) }
            Divider()
            Text(layersTitle.uppercased())
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
                .tracking(0.6)
            ForEach(stack.topDown, id: \.id) { layer in
                row(
                    title: layer.name,
                    note: replacing[layer.id].map { "replaces \u{201C}\($0)\u{201D}" },
                    tint: LayerTint.color(stack.tintHex(ofLayer: layer.id))
                ) { pick(.layer(layer.id)) }
            }
            Divider()
            HStack {
                Spacer()
                Button("Cancel", role: .cancel, action: cancel)
                    .keyboardShortcut(.cancelAction)
                    .controlSize(.small)
            }
        }
        .padding(12)
        .frame(width: 280)
    }

    private func row(title: String, note: String?, tint: Color?, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                if let tint {
                    Circle().fill(tint).frame(width: 8, height: 8)
                } else {
                    Image(systemName: "photo")
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                        .frame(width: 8)
                }
                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .font(.caption)
                        .lineLimit(1)
                    if let note {
                        Text(note)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .frame(maxWidth: .infinity, minHeight: 26, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(Color.primary.opacity(0.05), in: RoundedRectangle.standard(CornerStandard.element))
    }
}
