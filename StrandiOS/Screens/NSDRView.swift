import SwiftUI
import WebKit
import AVFoundation
import StrandDesign
import StrandAnalytics
import WhoopStore

// NSDRView.swift — "Perform and Log NSDR": a guided Huberman NSDR played through YouTube's own embedded
// player, logged as a restorative session when it ends.
//
// NOOP ships no audio. The recordings are © Scicomm Media LLC, so they are only ever streamed from
// YouTube's official iframe player inside a WKWebView, and the screen offers "Open in YouTube" when the
// player refuses to embed or YouTube can't be reached. Played time comes from the player's own clock
// (`NSDRListenTracker`), so a paused player or a seek earns nothing. The rest credit is `NSDRCredit`'s; this screen only reports it.

/// Drives one NSDR screen: which recording is loaded, what the player reports, and the session clock.
@MainActor
final class NSDRPlayerModel: ObservableObject {
    /// What the embedded player last reported.
    enum PlayerState: Equatable {
        case loading, ready, playing, paused, buffering, ended
        /// A YouTube player error code (101/150 = embedding disabled, 152/153 = player configuration), or
        /// `unreachableCode` when the player never loaded at all.
        case failed(Int)
    }

    /// Not a YouTube code: the iframe API never reported in (offline, or youtube.com blocked).
    static let unreachableCode = -1
    /// How long the page may stay silent (no `ready`, no `error`) before the player counts as unreachable.
    static let loadTimeoutNanoseconds: UInt64 = 10_000_000_000

    /// A session that just ended, ready to be logged.
    struct FinishedSession {
        let recording: NSDRRecording
        let startedAt: Date
        let endedAt: Date
        let listenedSeconds: Double
        let nominalSeconds: Double
    }

    @Published private(set) var recording: NSDRRecording
    @Published private(set) var state: PlayerState = .loading
    @Published private(set) var listenedSeconds: Double = 0
    /// Bumped for every new recording so the web view reloads; `autoplay` says whether it should start.
    @Published private(set) var loadToken = 0
    private(set) var autoplay = false
    /// Bumped to ask the web view to pause (an ended session must not keep playing into a new one).
    @Published private(set) var pauseToken = 0

    private var tracker = NSDRListenTracker()
    private var sessionStart: Date?
    /// The length the player reports, which wins over the catalog's when it is known.
    private var playerDuration: Double?
    private var loadWatchdog: Task<Void, Never>?

    init() {
        recording = NSDRCatalog.randomPick()
        armLoadWatchdog()
    }

    var nominalSeconds: Double {
        if let d = playerDuration, d > 0 { return d }
        return recording.nominalSeconds
    }

    var isEmbedError: Bool {
        if case .failed = state { return true }
        return false
    }

    var isUnreachable: Bool { state == .failed(Self.unreachableCode) }

    /// One message from the page's script.
    func handle(_ body: [String: Any]) {
        let type = body["type"] as? String
        if let d = (body["duration"] as? NSNumber)?.doubleValue, d > 0 { playerDuration = d }
        switch type {
        case "ready":
            // A slow network can bring the player up after the watchdog gave up on it; take it back.
            if state == .loading || isUnreachable { state = .ready }
        case "error":
            state = .failed((body["code"] as? NSNumber)?.intValue ?? 0)
        case "unreachable":
            if state == .loading { state = .failed(Self.unreachableCode) }
        case "state", "tick":
            let code = (body["state"] as? NSNumber)?.intValue ?? -1
            let position = (body["position"] as? NSNumber)?.doubleValue ?? 0
            observe(code: code, position: position)
        default:
            break
        }
    }

    /// YT.PlayerState: -1 unstarted, 0 ended, 1 playing, 2 paused, 3 buffering, 5 cued.
    private func observe(code: Int, position: Double) {
        if case .failed = state, !isUnreachable { return }
        let playing = code == 1
        if playing, sessionStart == nil { sessionStart = Date() }
        tracker.observe(position: position, isPlaying: playing)
        listenedSeconds = tracker.listenedSeconds
        switch code {
        case 0: state = .ended
        case 1: state = .playing
        case 2: state = .paused
        case 3: state = .buffering
        default: if state == .loading { state = .ready }
        }
    }

    /// End the current session (if anything was played) and hand it back for logging. Resets the clock;
    /// the recording stays loaded.
    func finishSession() -> FinishedSession? {
        defer {
            tracker = NSDRListenTracker()
            listenedSeconds = 0
            sessionStart = nil
        }
        guard let start = sessionStart, tracker.listenedSeconds > 0 else { return nil }
        return FinishedSession(recording: recording, startedAt: start, endedAt: Date(),
                               listenedSeconds: tracker.listenedSeconds, nominalSeconds: nominalSeconds)
    }

    /// Pause playback (End session), so the next session starts only when the user presses play.
    func pause() { pauseToken += 1 }

    /// Switch to a different recording (never the current one) and start it.
    func next() {
        recording = NSDRCatalog.randomPick(excluding: recording.id)
        reload(autoplay: true)
    }

    /// Reload the current recording (after an error, or for a fresh session).
    func reload(autoplay: Bool) {
        self.autoplay = autoplay
        state = .loading
        playerDuration = nil
        loadToken += 1
        armLoadWatchdog()
    }

    /// A page that never reports in would otherwise sit as a black box forever. If this load is still
    /// `.loading` after `loadTimeoutNanoseconds`, show the unreachable state (a newer load re-arms it).
    private func armLoadWatchdog() {
        loadWatchdog?.cancel()
        let token = loadToken
        loadWatchdog = Task { [weak self] in
            try? await Task.sleep(nanoseconds: Self.loadTimeoutNanoseconds)
            guard !Task.isCancelled, let self, self.loadToken == token, self.state == .loading else { return }
            self.state = .failed(Self.unreachableCode)
        }
    }
}

struct NSDRView: View {
    @EnvironmentObject private var repo: Repository
    @StateObject private var player = NSDRPlayerModel()
    @Environment(\.openURL) private var openURL
    @Environment(\.scenePhase) private var scenePhase

    @State private var history: [NSDRSessionRow] = []
    /// The note under the controls after a session is ended ("Logged …" / "Too short to log").
    @State private var lastResult: String?

    var body: some View {
        ScreenScaffold(title: "Non-Sleep Deep Rest",
                       subtitle: "Guided NSDR by Dr. Andrew Huberman, streamed from YouTube",
                       topBackground: liquidScaffoldSky()) {
            playerCard
            creditCard
            historyCard
        }
        .task { await reloadHistory() }
        .onChange(of: player.state) { _, state in
            // NSDR is done with eyes closed, so auto-lock would cut it short: hold the screen on while
            // the recording plays, and let go as soon as it pauses, ends or fails.
            ScreenIdle.keepAwake(state == .playing || state == .buffering)
            // A recording that plays to the end finishes the session by itself.
            if state == .ended { endSession() }
        }
        // Going to the background (Home, the lock button, a call) ends the session as End does: the
        // app has no background audio mode, because YouTube's terms forbid background playback of
        // embeds, so iOS stops the player there anyway. The clock resets, so coming back can't log
        // the same time twice.
        .onChange(of: scenePhase) { _, phase in
            guard phase == .background else { return }
            player.pause()
            ScreenIdle.keepAwake(false)
            endSession()
        }
        .onAppear { NSDRAudioSession.activate() }
        .onDisappear {
            ScreenIdle.keepAwake(false)
            NSDRAudioSession.deactivate()
            // Leaving the screen ends the session; the repository outlives the view, so the write lands.
            if let done = player.finishSession() {
                let repo = repo
                Task { await Self.log(done, repo: repo) }
            }
        }
    }

    // MARK: - Player

    private var playerCard: some View {
        NoopCard(tint: StrandPalette.restColor) {
            VStack(alignment: .leading, spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("NOW PLAYING")
                        .font(StrandFont.overline)
                        .tracking(1.4)
                        .foregroundStyle(StrandPalette.textTertiary)
                    Text(player.recording.title)
                        .font(StrandFont.headline)
                        .foregroundStyle(StrandPalette.textPrimary)
                    Text(player.recording.channel)
                        .font(StrandFont.caption)
                        .foregroundStyle(StrandPalette.textSecondary)
                }

                ZStack {
                    NSDRYouTubePlayer(model: player)
                    if player.isEmbedError { embedErrorOverlay }
                }
                .aspectRatio(16.0 / 9.0, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

                HStack(spacing: 10) {
                    NoopButton("Next", systemImage: "forward.fill", kind: .secondary, fullWidth: true) {
                        endSession()
                        player.next()
                    }
                    NoopButton("End session", systemImage: "stop.fill", kind: .primary, fullWidth: true) {
                        player.pause()
                        ScreenIdle.keepAwake(false)
                        endSession()
                    }
                    .disabled(player.listenedSeconds <= 0)
                }

                Button {
                    openURL(player.recording.watchURL)
                } label: {
                    Label("Open in YouTube", systemImage: "arrow.up.right.square")
                        .font(StrandFont.footnote)
                }
                .foregroundStyle(StrandPalette.accent)

                if let lastResult {
                    Text(lastResult)
                        .font(StrandFont.footnote)
                        .foregroundStyle(StrandPalette.textSecondary)
                }
            }
        }
    }

    private var embedErrorOverlay: some View {
        ZStack {
            StrandPalette.surfaceInset
            VStack(spacing: 10) {
                Image(systemName: player.isUnreachable ? "wifi.slash" : "play.slash")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(StrandPalette.textSecondary)
                Text(player.isUnreachable
                     ? String(localized: "Can't reach YouTube. Check your connection and try again.")
                     : String(localized: "YouTube won't play this recording here."))
                    .font(StrandFont.footnote)
                    .foregroundStyle(StrandPalette.textSecondary)
                    .multilineTextAlignment(.center)
                HStack(spacing: 10) {
                    NoopButton("Open in YouTube", systemImage: "arrow.up.right.square", kind: .primary) {
                        openURL(player.recording.watchURL)
                    }
                    // Offline, another recording fails the same way; retry this one instead.
                    if player.isUnreachable {
                        NoopButton("Try again", kind: .secondary) { player.reload(autoplay: false) }
                    } else {
                        NoopButton("Try another", kind: .secondary) { player.next() }
                    }
                }
            }
            .padding(12)
        }
    }

    // MARK: - Credit

    private var creditCard: some View {
        let fraction = NSDRCredit.sessionFraction(.init(listenedSeconds: player.listenedSeconds,
                                                        nominalSeconds: player.nominalSeconds))
        let points = NSDRCredit.perSessionPoints * fraction
        return NoopCard {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("This session")
                        .font(StrandFont.headline)
                        .foregroundStyle(StrandPalette.textPrimary)
                    Spacer()
                    Text("\(Self.clock(player.listenedSeconds)) of \(Self.clock(player.nominalSeconds))")
                        .font(StrandFont.subhead)
                        .monospacedDigit()
                        .foregroundStyle(StrandPalette.textSecondary)
                }
                ProgressView(value: min(player.listenedSeconds / max(player.nominalSeconds, 1), 1))
                    .tint(StrandPalette.restColor)
                Text(points > 0
                     ? String(localized: "Rest credit so far: +\(Self.points(points))")
                     : String(localized: "Rest credit starts halfway through the recording and is full from 80 percent (+\(Self.points(NSDRCredit.perSessionPoints)))."))
                    .font(StrandFont.footnote)
                    .foregroundStyle(StrandPalette.textSecondary)
                Text("NSDR restores energy and supports recovery, but it doesn't replace sleep. Up to two sessions a day add a small amount to that day's Rest; NSDR never counts as sleep time.")
                    .font(StrandFont.caption)
                    .foregroundStyle(StrandPalette.textTertiary)
            }
        }
    }

    // MARK: - History

    private var historyCard: some View {
        NoopCard {
            VStack(alignment: .leading, spacing: 10) {
                SectionHeader("Recent sessions", overline: "NSDR log")
                if history.isEmpty {
                    Text("No sessions yet. Finished sessions are logged here and added to that day's Rest.")
                        .font(StrandFont.footnote)
                        .foregroundStyle(StrandPalette.textSecondary)
                } else {
                    ForEach(history, id: \.startTs) { row in
                        historyRow(row)
                    }
                }
            }
        }
    }

    private func historyRow(_ row: NSDRSessionRow) -> some View {
        let points = NSDRCredit.sessionPoints(.init(listenedSeconds: row.listenedS, nominalSeconds: row.nominalS))
        let title = NSDRCatalog.recordingById(row.recordingId)?.title ?? row.recordingId
        return HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(StrandFont.subhead)
                    .foregroundStyle(StrandPalette.textPrimary)
                    .lineLimit(1)
                Text(Self.sessionTimeFormatter.string(from: Date(timeIntervalSince1970: TimeInterval(row.startTs))))
                    .font(StrandFont.caption)
                    .foregroundStyle(StrandPalette.textTertiary)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text(Self.clock(row.listenedS))
                    .font(StrandFont.subhead)
                    .monospacedDigit()
                    .foregroundStyle(StrandPalette.textSecondary)
                Text(points > 0 ? String(localized: "+\(Self.points(points)) Rest") : String(localized: "No credit"))
                    .font(StrandFont.caption)
                    .foregroundStyle(points > 0 ? StrandPalette.restColor : StrandPalette.textTertiary)
            }
        }
    }

    // MARK: - Session

    private func endSession() {
        guard let done = player.finishSession() else { return }
        Task {
            let row = await Self.log(done, repo: repo)
            if let row {
                let points = NSDRCredit.sessionPoints(.init(listenedSeconds: row.listenedS, nominalSeconds: row.nominalS))
                let logged = String(localized: "Logged \(Self.clock(row.listenedS)) of NSDR")
                let credit = points > 0 ? String(localized: "+\(Self.points(points)) Rest") : String(localized: "No credit")
                lastResult = "\(logged) · \(credit)"
            } else {
                lastResult = String(localized: "Not logged: sessions under 30 seconds aren't saved.")
            }
            await reloadHistory()
        }
    }

    /// Writes the session under a background-task assertion, so a session ended by going to the
    /// background is stored before iOS suspends the app.
    @discardableResult
    private static func log(_ done: NSDRPlayerModel.FinishedSession, repo: Repository) async -> NSDRSessionRow? {
        let application = UIApplication.shared
        var taskID: UIBackgroundTaskIdentifier = .invalid
        taskID = application.beginBackgroundTask(withName: "nsdr-log-session") {
            application.endBackgroundTask(taskID)
            taskID = .invalid
        }
        defer {
            if taskID != .invalid {
                application.endBackgroundTask(taskID)
                taskID = .invalid
            }
        }
        return await repo.logNSDRSession(startedAt: done.startedAt, endedAt: done.endedAt,
                                         recordingId: done.recording.id,
                                         listenedSeconds: done.listenedSeconds, nominalSeconds: done.nominalSeconds)
    }

    private func reloadHistory() async {
        history = await repo.recentNSDRSessions(limit: 10)
    }

    /// Rest points as shown everywhere on this screen: one decimal, the reader's locale.
    private static func points(_ p: Double) -> String {
        String(format: "%.1f", locale: AppLanguage.activeLocale, p)
    }

    private static func clock(_ seconds: Double) -> String {
        let s = max(Int(seconds.rounded()), 0)
        return String(format: "%d:%02d", s / 60, s % 60)
    }

    private static let sessionTimeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f
    }()
}

/// Plays NSDR audio with the ringer switch on silent, and hands audio back to other apps on exit.
private enum NSDRAudioSession {
    static func activate() {
        let s = AVAudioSession.sharedInstance()
        try? s.setCategory(.playback, mode: .spokenAudio)
        try? s.setActive(true)
    }

    static func deactivate() {
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
}

// MARK: - YouTube iframe player

/// YouTube's official iframe player in a WKWebView, inline (`playsinline=1`). The page is loaded with an
/// https base URL derived from the bundle id, which YouTube's embed rules require of a native app (an
/// embed with no referrer/origin fails with error 152/153). Player state, position and errors are posted
/// back to `NSDRPlayerModel` through a script message handler.
private struct NSDRYouTubePlayer: UIViewRepresentable {
    @ObservedObject var model: NSDRPlayerModel

    func makeCoordinator() -> Coordinator { Coordinator(model: model) }

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.allowsInlineMediaPlayback = true
        config.mediaTypesRequiringUserActionForPlayback = []
        config.userContentController.add(WeakScriptHandler(context.coordinator), name: "nsdr")
        let web = WKWebView(frame: .zero, configuration: config)
        web.isOpaque = false
        web.backgroundColor = .black
        web.scrollView.isScrollEnabled = false
        context.coordinator.load(into: web)
        return web
    }

    func updateUIView(_ web: WKWebView, context: Context) {
        context.coordinator.model = model
        if context.coordinator.loadedToken != model.loadToken {
            context.coordinator.load(into: web)
        } else if context.coordinator.pausedToken != model.pauseToken {
            context.coordinator.pausedToken = model.pauseToken
            web.evaluateJavaScript("if (player && player.pauseVideo) { player.pauseVideo(); }")
        }
    }

    static func dismantleUIView(_ web: WKWebView, coordinator: Coordinator) {
        web.configuration.userContentController.removeScriptMessageHandler(forName: "nsdr")
        web.loadHTMLString("", baseURL: nil)
    }

    @MainActor
    final class Coordinator: NSObject, WKScriptMessageHandler {
        var model: NSDRPlayerModel
        var loadedToken = -1
        var pausedToken = 0

        init(model: NSDRPlayerModel) { self.model = model }

        func load(into web: WKWebView) {
            loadedToken = model.loadToken
            pausedToken = model.pauseToken
            let origin = NSDRYouTubePlayer.embedOrigin
            web.loadHTMLString(NSDRYouTubePlayer.html(videoId: model.recording.id, origin: origin.absoluteString,
                                                      autoplay: model.autoplay),
                               baseURL: origin)
        }

        func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
            guard let body = message.body as? [String: Any] else { return }
            model.handle(body)
        }
    }

    /// `https://<bundle id>`, the app identity YouTube asks embedded players in native apps to send.
    static var embedOrigin: URL {
        let id = (Bundle.main.bundleIdentifier ?? "app.noop").lowercased()
        return URL(string: "https://\(id)") ?? URL(string: "https://app.noop")!
    }

    /// The page: the iframe API, one player, and a once-a-second position tick while it exists. A script
    /// that fails to load posts `unreachable` at once; one that hangs is caught by the model's watchdog.
    /// The video id comes from `NSDRCatalog` (11 url-safe characters), never from user input.
    static func html(videoId: String, origin: String, autoplay: Bool) -> String {
        """
        <!DOCTYPE html>
        <html><head>
        <meta name="viewport" content="width=device-width, initial-scale=1, maximum-scale=1">
        <meta name="referrer" content="strict-origin-when-cross-origin">
        <style>html,body{margin:0;padding:0;height:100%;background:#000;overflow:hidden}
        #player{position:absolute;inset:0;width:100%;height:100%}</style>
        </head><body>
        <div id="player"></div>
        <script>
        function post(m){try{window.webkit.messageHandlers.nsdr.postMessage(m);}catch(e){}}
        var player;
        function onYouTubeIframeAPIReady(){
          player = new YT.Player('player', {
            videoId: '\(videoId)',
            playerVars: {playsinline: 1, rel: 0, autoplay: \(autoplay ? 1 : 0), origin: '\(origin)'},
            events: {
              onReady: function(){ post({type:'ready', duration: player.getDuration()}); },
              onStateChange: function(e){ post({type:'state', state:e.data, position:player.getCurrentTime(), duration:player.getDuration()}); },
              onError: function(e){ post({type:'error', code:e.data}); }
            }
          });
          setInterval(function(){
            if (player && player.getPlayerState) {
              post({type:'tick', state:player.getPlayerState(), position:player.getCurrentTime(), duration:player.getDuration()});
            }
          }, 1000);
        }
        </script>
        <script src="https://www.youtube.com/iframe_api" onerror="post({type:'unreachable'})"></script>
        </body></html>
        """
    }
}

/// Breaks the WKUserContentController → handler retain cycle.
private final class WeakScriptHandler: NSObject, WKScriptMessageHandler {
    weak var target: WKScriptMessageHandler?
    init(_ target: WKScriptMessageHandler) { self.target = target }
    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        target?.userContentController(controller, didReceive: message)
    }
}
