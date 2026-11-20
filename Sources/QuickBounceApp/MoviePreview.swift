@preconcurrency import AVKit
import SwiftUI

struct MoviePreview<OpenActions: View>: View {
    @AppStorage(AppLanguage.preferenceKey) private var interfaceLanguage = "en"
    let name: String
    let player: AVPlayer
    let item: AVPlayerItem
    @ViewBuilder let openActions: () -> OpenActions
    @State private var fullScreen = MovieFullScreenControl()
    @State private var playbackFailed = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(name)
                    .font(.callout.weight(.semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                Menu(content: openActions) {
                    Label(L("Open With"), systemImage: "arrow.up.forward.app")
                }
                .fixedSize()
                Button(action: fullScreen.enter) {
                    Label(L("Enter Full Screen"), systemImage: "arrow.up.left.and.arrow.down.right")
                        .labelStyle(.iconOnly)
                }
                .functionTip("Enter Full Screen")
                .disabled(playbackFailed)
            }
            ZStack {
                Color.black
                if playbackFailed {
                    ContentUnavailableView(
                        L("Video Preview Unavailable"),
                        systemImage: "exclamationmark.triangle",
                        description: Text(L("Try opening the file in your default video player."))
                    )
                    .environment(\.colorScheme, .dark)
                } else {
                    InlineMoviePlayer(player: player, fullScreen: fullScreen, exitTitle: L("Exit Full Screen"))
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 10))
        }
        .onReceive(item.publisher(for: \.status).receive(on: DispatchQueue.main)) { status in
            playbackFailed = status == .failed
        }
    }
}

@MainActor
private final class MovieFullScreenControl {
    weak var view: MoviePlaybackView?

    func enter() { view?.enterVideoFullScreen() }
}

private struct InlineMoviePlayer: NSViewRepresentable {
    let player: AVPlayer
    let fullScreen: MovieFullScreenControl
    let exitTitle: String

    func makeCoordinator() -> MoviePlaybackView {
        MoviePlaybackView(player: player, exitTitle: exitTitle)
    }

    func makeNSView(context: Context) -> NSView {
        // Keep the SwiftUI-owned view in place while AppKit moves its child
        // into the full-screen window.
        let container = NSView()
        let playback = context.coordinator
        playback.frame = container.bounds
        playback.autoresizingMask = [.width, .height]
        container.addSubview(playback)
        fullScreen.view = playback
        return container
    }

    func updateNSView(_ view: NSView, context: Context) {
        context.coordinator.update(player: player, exitTitle: exitTitle)
    }

    static func dismantleNSView(_ view: NSView, coordinator: MoviePlaybackView) {
        coordinator.exitVideoFullScreen()
        coordinator.playerView.player = nil
    }
}

@MainActor
private final class MoviePlaybackView: NSView {
    let playerView = AVPlayerView()
    private let exitButton = NSButton()

    init(player: AVPlayer, exitTitle: String) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor

        playerView.controlsStyle = .inline
        playerView.videoGravity = .resizeAspect
        playerView.player = player
        playerView.frame = bounds
        playerView.autoresizingMask = [.width, .height]
        addSubview(playerView)

        exitButton.title = exitTitle
        exitButton.image = NSImage(systemSymbolName: "arrow.down.right.and.arrow.up.left", accessibilityDescription: nil)
        exitButton.imagePosition = .imageLeading
        exitButton.bezelStyle = .rounded
        exitButton.appearance = NSAppearance(named: .darkAqua)
        exitButton.target = self
        exitButton.action = #selector(exitVideoFullScreen)
        exitButton.keyEquivalent = "\u{1b}"
        exitButton.keyEquivalentModifierMask = []
        exitButton.isHidden = true
        exitButton.translatesAutoresizingMaskIntoConstraints = false
        addSubview(exitButton)
        NSLayoutConstraint.activate([
            exitButton.topAnchor.constraint(equalTo: safeAreaLayoutGuide.topAnchor, constant: 16),
            exitButton.trailingAnchor.constraint(equalTo: safeAreaLayoutGuide.trailingAnchor, constant: -16)
        ])
    }

    required init?(coder: NSCoder) { nil }

    func update(player: AVPlayer, exitTitle: String) {
        if playerView.player !== player { playerView.player = player }
        exitButton.title = exitTitle
    }

    func enterVideoFullScreen() {
        guard !isInFullScreenMode, let screen = window?.screen else { return }
        let presentation: NSApplication.PresentationOptions = [.autoHideMenuBar, .autoHideDock]
        guard enterFullScreenMode(screen, withOptions: [
            .fullScreenModeAllScreens: false,
            .fullScreenModeApplicationPresentationOptions: presentation.rawValue
        ]) else { return }
        exitButton.isHidden = false
        window?.makeFirstResponder(playerView)
    }

    @objc func exitVideoFullScreen() {
        guard isInFullScreenMode else { return }
        exitButton.isHidden = true
        exitFullScreenMode()
    }
}
