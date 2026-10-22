import Foundation
import Combine
import AVFoundation
import CoreGraphics

/// One active preview. Invalidation precedes cancellation so late results can never revive a closed player.
@MainActor public final class PreviewSession: ObservableObject {
    public enum Phase: Equatable { case preparing, ready, failed, closed }
    @Published public private(set) var phase: Phase = .closed
    @Published public private(set) var name = ""
    @Published public private(set) var kind: FilePreviewKind?
    @Published public private(set) var image: CGImage?
    @Published public private(set) var text: TextPreview?
    @Published public private(set) var media: MediaPreviewDetails?
    @Published public private(set) var player: AVPlayer?
    @Published public private(set) var message = ""
    @Published public private(set) var preparingFile = false
    @Published public private(set) var position: Double = 0
    @Published public private(set) var isPlaying = false
    @Published public var volume: Double = 1 { didSet { player?.volume = Float(max(0, min(1, volume))) } }
    public private(set) var requestID: UUID?
    private var task: Task<Void, Never>?
    private var timeoutTask: Task<Void, Never>?
    private var asset: AVURLAsset?
    private var statusObservation: NSKeyValueObservation?
    private var failedNotification: NSObjectProtocol?
    private var playbackObservation: NSKeyValueObservation?
    private var timeObserver: Any?
    private var temporaryRoot: URL?

    public init() {}
    @discardableResult public func begin(name: String, kind: FilePreviewKind) -> UUID {
        close()
        let id = UUID(); requestID = id
        self.name = name; self.kind = kind; phase = .preparing; preparingFile = true
        return id
    }

    /// Takes ownership of a directory created exclusively for this preview, after extraction and CRC succeed.
    public func load(_ url: URL, ownedRoot: URL, requestID id: UUID) {
        guard requestID == id else { try? FileManager.default.removeItem(at: ownedRoot); return }
        temporaryRoot = ownedRoot; preparingFile = false
        let kind = kind
        timeoutTask = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: 20_000_000_000) } catch { return }
            guard let self, self.requestID == id, self.phase == .preparing else { return }
            self.fail("Preview loading timed out. Extract the file to inspect it separately.", requestID: id)
        }
        task = Task { [weak self] in
            do {
                let content = Task.detached(priority: .userInitiated) { () throws -> (CGImage?, TextPreview?, AVURLAsset?) in
                    try PreviewSafety.validate(url, inside: ownedRoot)
                    try Task.checkCancellation()
                    switch kind {
                    case .image: return (try FilePreviewContent.image(url), nil, nil)
                    case .text: return (nil, try FilePreviewContent.text(url), nil)
                    case .audio, .video: return (nil, nil, try NativeMediaPreview.asset(url))
                    case nil: throw CancellationError()
                    }
                }
                let result = try await withTaskCancellationHandler(operation: { try await content.value }, onCancel: { content.cancel() })
                try Task.checkCancellation()
                guard let self, self.requestID == id else { return }
                self.image = result.0; self.text = result.1
                if let asset = result.2 {
                    self.asset = asset
                    let details = try await withTaskCancellationHandler(operation: { try await NativeMediaPreview.inspect(asset) }, onCancel: { asset.cancelLoading() })
                    try Task.checkCancellation()
                    guard self.requestID == id else { return }
                    self.media = details; self.image = details.artwork
                    let item = AVPlayerItem(asset: asset)
                    item.preferredForwardBufferDuration = 3
                    item.preferredMaximumResolution = CGSize(width: 2560, height: 1440)
                    let player = AVPlayer(playerItem: item)
                    player.allowsExternalPlayback = false
                    // Explicit user action starts playback; never autoplay when browsing archives.
                    self.player = player
                    player.volume = Float(self.volume)
                    self.playbackObservation = player.observe(\.timeControlStatus, options: [.initial, .new]) { [weak self] player, _ in
                        let playing = player.timeControlStatus == .playing
                        Task { @MainActor in
                            guard let self, self.requestID == id else { return }
                            self.isPlaying = playing
                        }
                    }
                    self.timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.25, preferredTimescale: 600), queue: .main) { [weak self] time in
                        let seconds = CMTimeGetSeconds(time)
                        Task { @MainActor in
                            guard let self, self.requestID == id, seconds.isFinite else { return }
                            self.position = max(0, seconds)
                        }
                    }
                    self.statusObservation = item.observe(\.status, options: [.initial, .new]) { [weak self] item, _ in
                        if item.status == .failed {
                            Task { @MainActor in self?.fail("This media format or codec is not supported by the macOS player. Extract it to use another player.", requestID: id) }
                        }
                    }
                    self.failedNotification = NotificationCenter.default.addObserver(forName: .AVPlayerItemFailedToPlayToEndTime, object: item, queue: .main) { [weak self] _ in
                        Task { @MainActor in self?.fail("Playback stopped because the media could not be decoded. The archive itself was extracted successfully.", requestID: id) }
                    }
                }
                guard self.requestID == id else { return }
                self.timeoutTask?.cancel(); self.timeoutTask = nil
                self.phase = .ready
            } catch is CancellationError { /* close/switch invalidates this request */ }
            catch {
                guard let self, self.requestID == id, self.phase == .preparing else { return }
                let key = (error as? ArchiveError)?.errorDescription ?? "Preview could not be loaded. Extract the file to inspect it separately."
                self.fail(key, requestID: id)
            }
        }
    }

    public func fail(_ message: String, requestID id: UUID) {
        guard requestID == id else { return }
        task?.cancel(); task = nil
        releaseResources()
        self.message = message; preparingFile = false; phase = .failed
    }

    public func close() {
        requestID = nil
        task?.cancel(); task = nil
        releaseResources()
        preparingFile = false; name = ""; kind = nil; message = ""; phase = .closed
    }

    public func togglePlayback() {
        guard phase == .ready, let player else { return }
        if player.rate != 0 { player.pause() }
        else {
            if let duration = media?.duration, duration > 0, position >= duration - 0.05 { seek(to: 0) }
            player.play()
        }
    }

    public func seek(to seconds: Double) {
        guard phase == .ready, let duration = media?.duration, duration > 0, seconds.isFinite else { return }
        player?.currentItem?.cancelPendingSeeks()
        player?.seek(to: CMTime(seconds: min(duration, max(0, seconds)), preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
    }

    private func releaseResources() {
        timeoutTask?.cancel(); timeoutTask = nil
        statusObservation?.invalidate(); statusObservation = nil
        playbackObservation?.invalidate(); playbackObservation = nil
        if let timeObserver { player?.removeTimeObserver(timeObserver) }; timeObserver = nil
        if let failedNotification { NotificationCenter.default.removeObserver(failedNotification) }
        failedNotification = nil
        player?.pause(); player?.replaceCurrentItem(with: nil); player = nil
        asset?.cancelLoading(); asset = nil
        image = nil; text = nil; media = nil
        position = 0; isPlaying = false
        if let temporaryRoot { try? FileManager.default.removeItem(at: temporaryRoot) }
        temporaryRoot = nil
    }
}
