import AVKit
import SwiftUI

/// Shows what was on screen, following the playhead.
///
/// Keyframes are a lookup rather than a scrub: the frame shown is the last one
/// captured at or before the current time, so the picture always matches what
/// was being said.
struct ScreenPlaybackView: View, Equatable {
    let directory: URL
    let keyframes: [ScreenCapture.Keyframe]
    let hasVideo: Bool
    /// The keyframe matching the playhead, resolved by the caller.
    ///
    /// Deliberately not the raw playback time: that ticks 20x a second, and
    /// taking it here re-rendered the whole pane — including a JPEG decode per
    /// visible thumbnail — at that rate.
    let currentFile: String?
    /// Supplied by the session transport, not created here — the video follows
    /// the same play/pause/seek as the audio.
    let videoPlayer: AVPlayer?
    /// The line being spoken, shown over the picture as a subtitle.
    ///
    /// Resolved by the caller, so this view does not re-render on every
    /// playback tick — only when the line actually changes.
    var subtitle: String?
    var onSeek: ((TimeInterval) -> Void)?

    /// Ignores the closure, which is recreated on every parent render and would
    /// otherwise make the view look changed even when nothing is.
    /// Every input that changes what is drawn has to be here.
    ///
    /// `.equatable()` makes this the whole truth: a field left out is a field
    /// SwiftUI never sees change. `subtitle` was missing, so the caption was
    /// whatever line happened to be playing when the pane first appeared and
    /// never moved again.
    static func == (lhs: ScreenPlaybackView, rhs: ScreenPlaybackView) -> Bool {
        lhs.currentFile == rhs.currentFile
            && lhs.subtitle == rhs.subtitle
            && lhs.hasVideo == rhs.hasVideo
            && lhs.directory == rhs.directory
            && lhs.keyframes.count == rhs.keyframes.count
            && lhs.videoPlayer === rhs.videoPlayer
    }

    var body: some View {
        Group {
            if hasVideo {
                videoPane
            } else if !keyframes.isEmpty {
                keyframePane
            } else {
                empty
            }
        }
        .overlay(alignment: .bottom) { subtitleOverlay }
    }

    /// What is being said over what is being shown.
    ///
    /// Deliberately a caption rather than a transcript: one line, centred,
    /// legible over any picture. Reading along happens in the transcript pane;
    /// this is for watching.
    @ViewBuilder
    private var subtitleOverlay: some View {
        if let subtitle, !subtitle.isEmpty, hasVideo || !keyframes.isEmpty {
            Text(subtitle)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(.white)
                .multilineTextAlignment(.center)
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
                .background {
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        // Dark rather than the app's surfaces: a subtitle sits
                        // on whatever the screen happened to be showing, and
                        // only a dark plate stays readable over all of it.
                        .fill(Color.black.opacity(0.72))
                }
                .frame(maxWidth: 620)
                .padding(.bottom, 18)
                .padding(.horizontal, 20)
                .transition(.opacity)
                .animation(.smooth(duration: 0.18), value: subtitle)
                .allowsHitTesting(false)
        }
    }

    // MARK: - Video

    @ViewBuilder
    private var videoPane: some View {
        if let videoPlayer {
            PlayerView(player: videoPlayer)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            VStack(spacing: 8) {
                Image(systemName: "video.slash")
                    .font(.system(size: 24, weight: .light))
                    .foregroundStyle(.tertiary)
                Text("Screen recording could not be opened")
                    .font(Theme.Font.body)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    // MARK: - Keyframes

    private var current: ScreenCapture.Keyframe? {
        keyframes.first { $0.file == currentFile } ?? keyframes.first
    }

    private var keyframePane: some View {
        VStack(spacing: 0) {
            ZStack {
                if let current, let image = load(current) {
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                        .overlay {
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .stroke(Color.primary.opacity(0.12), lineWidth: 1)
                        }
                        .id(current.file)
                        .transition(.opacity)
                } else {
                    Text("Frame unavailable")
                        .font(Theme.Font.body)
                        .foregroundStyle(.tertiary)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(16)
            .animation(.smooth(duration: 0.2), value: current?.file)

            filmstrip
        }
    }

    private var filmstrip: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 8) {
                    ForEach(keyframes, id: \.file) { frame in
                        thumbnail(frame)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
            }
            .background(.regularMaterial)
            .onChange(of: current?.file) { _, file in
                guard let file else { return }
                withAnimation(.smooth(duration: 0.3)) {
                    proxy.scrollTo(file, anchor: .center)
                }
            }
        }
    }

    @ViewBuilder
    private func thumbnail(_ frame: ScreenCapture.Keyframe) -> some View {
        let isCurrent = frame.file == current?.file

        Button {
            onSeek?(frame.time)
        } label: {
            VStack(spacing: 3) {
                thumbnailImage(frame)
                    .overlay {
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .stroke(isCurrent ? Theme.system : Color.clear, lineWidth: 2)
                    }
                Text(frame.time.clockString)
                    .font(Theme.Font.caption)
                    .foregroundStyle(isCurrent ? AnyShapeStyle(Theme.system) : AnyShapeStyle(.tertiary))
            }
        }
        .buttonStyle(.plain)
        .id(frame.file)
        .help("Play from \(frame.time.clockString)")
    }

    @ViewBuilder
    private func thumbnailImage(_ frame: ScreenCapture.Keyframe) -> some View {
        if let image = load(frame) {
            Image(nsImage: image)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: 104, height: 62)
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        } else {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color.primary.opacity(0.08))
                .frame(width: 104, height: 62)
        }
    }

    private func load(_ frame: ScreenCapture.Keyframe) -> NSImage? {
        KeyframeCache.image(directory: directory, file: frame.file)
    }

    private var empty: some View {
        EmptyState(
            systemImage: "rectangle.slash",
            title: "No screen capture",
            detail: "This recording was made without capturing the screen."
        )
    }
}


/// AppKit's `AVPlayerView`, not SwiftUI's `VideoPlayer`.
///
/// `VideoPlayer` comes from the `_AVKit_SwiftUI` overlay, and in this SwiftPM
/// executable instantiating its generic metadata aborts inside
/// `getSuperclassMetadata`. The crash happens whenever the enclosing view's type
/// is realised — not only when the video branch actually runs — so merely having
/// a `VideoPlayer` in the body was enough to kill the Screen tab for sessions
/// that contain no video at all. The AppKit view has no such problem.
private struct PlayerView: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.player = player
        // No controls: the session transport owns play, pause, and seek. A second
        // set of controls would let the video drift off the audio clock that the
        // transcript timestamps are tied to.
        view.controlsStyle = .none
        view.videoGravity = .resizeAspect
        return view
    }

    func updateNSView(_ nsView: AVPlayerView, context: Context) {
        if nsView.player !== player {
            nsView.player = player
        }
    }
}


/// Decoded keyframes, kept in memory.
///
/// Decoding was previously done inline in `body`, which meant a JPEG read off
/// disk for every visible thumbnail on every render — and the pane re-rendered
/// with the playhead. A session with dozens of frames turned that into a
/// continuous stream of disk reads and image decodes, which is what made the
/// screen panel feel heavy.
///
/// `NSCache` evicts under memory pressure on its own, so this cannot grow
/// unbounded across long sessions.
/// Shared: the timeline transcript loads frames too, and decoding the same PNG
/// twice for two views on the same screen is pure waste.
enum KeyframeCache {
    private static let cache: NSCache<NSString, NSImage> = {
        let cache = NSCache<NSString, NSImage>()
        cache.countLimit = 400
        return cache
    }()

    static func image(directory: URL, file: String) -> NSImage? {
        let key = "\(directory.path)/\(file)" as NSString
        if let cached = cache.object(forKey: key) { return cached }

        let url = directory.appendingPathComponent("frames").appendingPathComponent(file)
        guard let image = NSImage(contentsOf: url) else { return nil }
        cache.setObject(image, forKey: key)
        return image
    }
}
