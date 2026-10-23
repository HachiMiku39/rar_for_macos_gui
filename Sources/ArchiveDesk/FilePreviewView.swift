import SwiftUI
import AppKit
import AVKit
#if canImport(ArchiveCore)
import ArchiveCore
#endif

@MainActor final class FilePreviewWindowController: NSObject, NSWindowDelegate {
    private weak var model: Model?
    private var window: NSWindow?
    init(model: Model) { self.model = model }
    func show() {
        guard let model else { return }
        if window == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 650), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
            window.identifier = NSUserInterfaceItemIdentifier("ArchiveDesk.FilePreview")
            window.isReleasedWhenClosed = false
            window.minSize = NSSize(width: 640, height: 480)
            window.delegate = self
            window.contentView = NSHostingView(rootView: FilePreviewView(session: model.filePreview)
                .environmentObject(model).environmentObject(model.language))
            window.center(); self.window = window
        }
        window?.title = model.language.text("Preview") + " — " + model.filePreview.name
        window?.makeKeyAndOrderFront(nil)
    }
    func hide() { window?.orderOut(nil) }
    func windowWillClose(_ notification: Notification) { model?.closePreview() }
}

/// AppKit's player supplies keyboard-accessible play, pause, scrubbing, volume and full-screen controls.
private struct NativePlayerView: NSViewRepresentable {
    let player: AVPlayer
    let video: Bool
    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.controlsStyle = .inline
        view.showsFullScreenToggleButton = video
        view.allowsPictureInPicturePlayback = false
        view.videoGravity = .resizeAspect
        view.player = player
        return view
    }
    func updateNSView(_ view: AVPlayerView, context: Context) {
        view.player = player; view.showsFullScreenToggleButton = video
    }
    static func dismantleNSView(_ view: AVPlayerView, coordinator: ()) { view.player = nil }
}

struct FilePreviewView: View {
    @ObservedObject var session: PreviewSession
    @EnvironmentObject var model: Model
    @EnvironmentObject var language: AppLanguage
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Label(language.text("Preview"), systemImage: "eye")
                Text(session.name).lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                Spacer()
                Button(language.text("Close")) { model.closePreview() }.keyboardShortcut(.cancelAction)
            }.padding(12).background(.bar)
            if session.hasTextData {
                HStack {
                    Picker(language.text("Text encoding"), selection: Binding(get: { session.textEncoding }, set: { session.setTextEncoding($0) })) {
                        ForEach(PreviewTextEncoding.allCases, id: \.self) { encoding in
                            Text(encoding.rawValue).tag(encoding)
                        }
                    }.frame(maxWidth: 310)
                    Text(language.text("Independent of ZIP filename encoding."))
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                }.padding(.horizontal, 16).padding(.vertical, 8)
            }
            Group {
                switch session.phase {
                case .preparing:
                    VStack(spacing: 16) {
                        ProgressView()
                        Text(language.text(session.preparingFile ? "Extracting and verifying preview…" : "Loading preview…"))
                        if session.preparingFile, let progress = model.progress { ProgressView(value: progress).frame(width: 280) }
                        Button(language.text("Cancel")) { model.closePreview() }
                    }.frame(maxWidth: .infinity, maxHeight: .infinity)
                case .failed:
                    ContentUnavailableView {
                        Label(language.text("Preview unavailable"), systemImage: "exclamationmark.triangle")
                    } description: {
                        Text(language.text(session.message))
                    } actions: {
                        Text(language.text("Close this window to extract the file, use Quick Look, or open a trusted copy in another app."))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                case .ready: previewContent
                case .closed: Color.clear
                }
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            Text(language.text("Read-only preview · Temporary copies are removed when this preview closes. No changes are saved to the archive."))
                .font(.caption).foregroundStyle(.secondary).padding(10)
        }.archiveTheme(miku: model.usesMikuTheme).preferredColorScheme(model.colorScheme).environment(\.locale, language.locale)
    }

    @ViewBuilder private var previewContent: some View {
        if let text = session.text {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(text.encoding).font(.caption).foregroundStyle(.secondary)
                    if text.inferred {
                        Text(language.text("Detected encoding; choose another if the text looks incorrect."))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    if text.truncated { Text(language.text("Showing the first 256 KiB only.")).font(.caption).foregroundStyle(.orange) }
                    Spacer()
                    Button(language.text("Copy preview text")) {
                        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text.text, forType: .string)
                    }
                }
                ScrollView([.horizontal, .vertical]) {
                    Text(verbatim: text.text).font(.system(.body, design: .monospaced)).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                }
            }.padding(16)
        } else if let player = session.player, let details = session.media {
            if details.hasVideo {
                NativePlayerView(player: player, video: true)
            } else {
                HSplitView {
                    VStack(spacing: 12) {
                        artwork.frame(maxWidth: .infinity, maxHeight: .infinity)
                        if details.artworkUnavailable {
                            Text(language.text("Album artwork is damaged or exceeds preview limits. Audio playback is still available."))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        AudioPreviewControls(session: session)
                    }.padding(16).frame(minWidth: 290)
                    ScrollView {
                        VStack(alignment: .leading, spacing: 16) {
                            Text(language.text("Music information")).font(.headline)
                            if details.tags.isEmpty { Text(language.text("No readable music tags.")).foregroundStyle(.secondary) }
                            ForEach(details.tags) { tag in
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(language.text(tag.label)).font(.caption).foregroundStyle(.secondary)
                                    Text(verbatim: tag.value).textSelection(.enabled)
                                }
                            }
                            if details.tagsLimited { Text(language.text("Some metadata was omitted to keep the preview bounded.")).font(.caption).foregroundStyle(.secondary) }
                        }.padding(18).frame(maxWidth: .infinity, alignment: .leading)
                    }.frame(minWidth: 220, idealWidth: 280, maxWidth: 350)
                }
            }
        } else if let image = session.image {
            VStack(spacing: 8) {
                Image(decorative: image, scale: 1).resizable().scaledToFit().padding(16)
                Text(language.text("Fit-to-window image preview · Animated images show the first frame."))
                    .font(.caption).foregroundStyle(.secondary).padding(.bottom, 10)
            }
        }
    }
    @ViewBuilder private var artwork: some View {
        if let image = session.image { Image(decorative: image, scale: 1).resizable().scaledToFit().clipShape(RoundedRectangle(cornerRadius: 12)) }
        else { Image(systemName: "music.note").font(.system(size: 96)).foregroundStyle(.secondary).accessibilityLabel(language.text("No album artwork")) }
    }
}

private struct AudioPreviewControls: View {
    @ObservedObject var session: PreviewSession
    @EnvironmentObject var language: AppLanguage
    @State private var editing = false
    @State private var scrub: Double = 0
    private var duration: Double { session.media?.duration ?? 0 }
    private func time(_ value: Double) -> String {
        let seconds = Int(max(0, min(value.isFinite ? value : 0, 359999)))
        return seconds >= 3600 ? String(format: "%d:%02d:%02d", seconds / 3600, seconds / 60 % 60, seconds % 60) : String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
    var body: some View {
        VStack(spacing: 10) {
            HStack(spacing: 14) {
                Button { session.seek(to: session.position - 15) } label: { Image(systemName: "gobackward.15") }
                    .help(language.text("Back 15 seconds")).disabled(duration <= 0)
                Button { session.togglePlayback() } label: { Image(systemName: session.isPlaying ? "pause.fill" : "play.fill").frame(width: 20) }
                    .help(language.text(session.isPlaying ? "Pause" : "Play")).keyboardShortcut(.space, modifiers: [])
                Button { session.seek(to: session.position + 15) } label: { Image(systemName: "goforward.15") }
                    .help(language.text("Forward 15 seconds")).disabled(duration <= 0)
                Spacer()
                Image(systemName: "speaker.wave.2")
                Slider(value: $session.volume, in: 0...1).frame(width: 90).accessibilityLabel(language.text("Volume"))
            }.buttonStyle(.borderless).font(.title3)
            Slider(value: Binding(get: { min(max(0, editing ? scrub : session.position), max(1, duration)) }, set: { scrub = $0 }), in: 0...max(1, duration)) { changed in
                if changed { scrub = session.position; editing = true }
                else { editing = false; session.seek(to: scrub) }
            }.disabled(duration <= 0).accessibilityLabel(language.text("Playback position"))
            HStack {
                Text(time(editing ? scrub : session.position)); Spacer(); Text(duration > 0 ? time(duration) : "—")
            }.font(.caption.monospacedDigit()).foregroundStyle(.secondary)
        }.padding(14).archiveGlass()
    }
}
