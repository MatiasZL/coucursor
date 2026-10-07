#if !APPSTORE
import Foundation
import AppKit

// MARK: - LyricsService
// Fetches plain / synced lyrics from LRCLIB when the user opens Coucursor
// while Spotify or Apple Music is playing. No API key; identify via Lrclib-Client.

@MainActor
final class LyricsService: ObservableObject {
    static let shared = LyricsService()

    struct Line: Identifiable, Equatable {
        let id: Int
        let time: TimeInterval?   // nil = unsynced plain line
        let text: String
    }

    @Published private(set) var lines: [Line] = []
    @Published private(set) var title: String = ""
    @Published private(set) var artist: String = ""
    @Published private(set) var accentHex: String = "#1DB954"
    @Published private(set) var loading: Bool = false
    @Published private(set) var error: String? = nil
    @Published private(set) var currentIndex: Int = 0
    @Published private(set) var instrumental: Bool = false

    private var trackKey: String = ""
    private var positionTimer: Timer?
    private var fetchGeneration: Int = 0
    private let session: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = 12
        c.httpAdditionalHeaders = [
            "Lrclib-Client": "Coucursor/1.0 (https://github.com/MatiasZL/coucursor)",
            "Accept": "application/json",
        ]
        return URLSession(configuration: c)
    }()

    private init() {}

    /// Resolve now-playing track, fetch lyrics, expand the lyrics view.
    func openForNowPlaying() {
        guard let now = currentTrack() else {
            NotificationCenter.default.post(name: .hookExpand, object: IslandView.overview)
            return
        }
        title = now.title
        artist = now.artist
        accentHex = now.accentHex
        NotificationCenter.default.post(name: .hookExpand, object: IslandView.lyrics)
        loadIfNeeded(title: now.title, artist: now.artist, album: now.album)
        startPositionPolling()
    }

    /// Called when the lyrics view appears / track may have changed.
    func refreshForVisibleView() {
        guard let now = currentTrack() else { return }
        title = now.title
        artist = now.artist
        accentHex = now.accentHex
        loadIfNeeded(title: now.title, artist: now.artist, album: now.album)
        startPositionPolling()
    }

    func stopPositionPolling() {
        positionTimer?.invalidate()
        positionTimer = nil
    }

    // MARK: - Now playing

    private struct NowPlaying {
        let title: String
        let artist: String
        let album: String?
        let accentHex: String
        let source: Source
        enum Source { case spotify, music }
    }

    private func currentTrack() -> NowPlaying? {
        let state = AppState.shared
        if state.spotifyPlaying,
           state.activeIntegrations.contains("integration_spotify"),
           let t = SpotifyController.shared.trackTitle, !t.isEmpty {
            return NowPlaying(
                title: t,
                artist: SpotifyController.shared.artist ?? "",
                album: SpotifyController.shared.album,
                accentHex: "#1DB954",
                source: .spotify
            )
        }
        if state.musicPlaying,
           state.activeIntegrations.contains("integration_music"),
           let t = MusicController.shared.trackTitle, !t.isEmpty {
            return NowPlaying(
                title: t,
                artist: MusicController.shared.artist ?? "",
                album: MusicController.shared.album,
                accentHex: "#FA2D48",
                source: .music
            )
        }
        return nil
    }

    // MARK: - Fetch

    private func loadIfNeeded(title: String, artist: String, album: String?) {
        let key = "\(title.lowercased())|\(artist.lowercased())"
        if key == trackKey, (!lines.isEmpty || instrumental || error != nil), !loading {
            return
        }
        trackKey = key
        fetchGeneration += 1
        let gen = fetchGeneration
        loading = true
        error = nil
        lines = []
        currentIndex = 0
        instrumental = false

        Task {
            let result = await Self.fetchLyrics(
                session: session,
                title: title,
                artist: artist,
                album: album
            )
            guard gen == fetchGeneration else { return }
            loading = false
            switch result {
            case .instrumental:
                instrumental = true
                lines = []
            case .ok(let parsed):
                lines = parsed
                if parsed.isEmpty { error = "No lyrics found" }
            case .missing:
                error = "No lyrics found"
            case .failed:
                error = "Couldn’t load lyrics"
            }
        }
    }

    private enum FetchResult {
        case ok([Line])
        case instrumental
        case missing
        case failed
    }

    private nonisolated static func fetchLyrics(
        session: URLSession,
        title: String,
        artist: String,
        album: String?
    ) async -> FetchResult {
        // Prefer structured search (tolerant); fall back to q=.
        if let hit = await search(session: session, title: title, artist: artist, album: album) {
            return decodeRecord(hit)
        }
        var comps = URLComponents(string: "https://lrclib.net/api/search")!
        comps.queryItems = [URLQueryItem(name: "q", value: "\(title) \(artist)".trimmingCharacters(in: .whitespaces))]
        guard let url = comps.url else { return .failed }
        var req = URLRequest(url: url)
        req.setValue("Coucursor/1.0 (https://github.com/MatiasZL/coucursor)", forHTTPHeaderField: "User-Agent")
        do {
            let (data, resp) = try await session.data(for: req)
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            guard code == 200,
                  let list = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]],
                  let hit = pickBest(list, title: title, artist: artist) else {
                return code == 404 ? .missing : .failed
            }
            return decodeRecord(hit)
        } catch {
            return .failed
        }
    }

    private nonisolated static func search(
        session: URLSession,
        title: String,
        artist: String,
        album: String?
    ) async -> [String: Any]? {
        var comps = URLComponents(string: "https://lrclib.net/api/search")!
        var items = [
            URLQueryItem(name: "track_name", value: title),
        ]
        if !artist.isEmpty {
            items.append(URLQueryItem(name: "artist_name", value: artist))
        }
        if let album, !album.isEmpty {
            items.append(URLQueryItem(name: "album_name", value: album))
        }
        comps.queryItems = items
        guard let url = comps.url else { return nil }
        var req = URLRequest(url: url)
        req.setValue("Coucursor/1.0 (https://github.com/MatiasZL/coucursor)", forHTTPHeaderField: "User-Agent")
        do {
            let (data, resp) = try await session.data(for: req)
            guard (resp as? HTTPURLResponse)?.statusCode == 200,
                  let list = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
                return nil
            }
            return pickBest(list, title: title, artist: artist)
        } catch {
            return nil
        }
    }

    private nonisolated static func pickBest(
        _ list: [[String: Any]],
        title: String,
        artist: String
    ) -> [String: Any]? {
        guard !list.isEmpty else { return nil }
        let t = title.lowercased()
        let a = artist.lowercased()
        let scored: [(Int, [String: Any])] = list.map { row in
            var score = 0
            let name = ((row["trackName"] as? String) ?? (row["name"] as? String) ?? "").lowercased()
            let art = ((row["artistName"] as? String) ?? "").lowercased()
            if name == t { score += 5 }
            else if name.contains(t) || t.contains(name) { score += 2 }
            if !a.isEmpty {
                if art == a { score += 4 }
                else if art.contains(a) || a.contains(art) { score += 2 }
            }
            if row["instrumental"] as? Bool == true { score -= 3 }
            if row["syncedLyrics"] as? String != nil { score += 2 }
            else if row["plainLyrics"] as? String != nil { score += 1 }
            return (score, row)
        }
        return scored.max(by: { $0.0 < $1.0 })?.1
    }

    private nonisolated static func decodeRecord(_ row: [String: Any]) -> FetchResult {
        if row["instrumental"] as? Bool == true { return .instrumental }
        if let synced = row["syncedLyrics"] as? String, !synced.isEmpty {
            let parsed = parseLRC(synced)
            if !parsed.isEmpty { return .ok(parsed) }
        }
        if let plain = row["plainLyrics"] as? String, !plain.isEmpty {
            let parsed = plain
                .components(separatedBy: .newlines)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
                .enumerated()
                .map { Line(id: $0.offset, time: nil, text: $0.element) }
            return parsed.isEmpty ? .missing : .ok(parsed)
        }
        return .missing
    }

    private nonisolated static func parseLRC(_ raw: String) -> [Line] {
        // [mm:ss.xx] text   or   [mm:ss] text
        let pattern = #"^\[(\d{1,2}):(\d{2})(?:\.(\d{1,3}))?\]\s*(.*)$"#
        guard let re = try? NSRegularExpression(pattern: pattern) else { return [] }
        var out: [Line] = []
        for (idx, line) in raw.components(separatedBy: .newlines).enumerated() {
            let s = line.trimmingCharacters(in: .whitespaces)
            guard !s.isEmpty else { continue }
            let range = NSRange(s.startIndex..<s.endIndex, in: s)
            guard let m = re.firstMatch(in: s, range: range),
                  let minR = Range(m.range(at: 1), in: s),
                  let secR = Range(m.range(at: 2), in: s) else { continue }
            let minutes = Double(s[minR]) ?? 0
            let seconds = Double(s[secR]) ?? 0
            var frac = 0.0
            if m.range(at: 3).location != NSNotFound, let fR = Range(m.range(at: 3), in: s) {
                let digits = String(s[fR])
                let padded = digits.count >= 3 ? digits : digits + String(repeating: "0", count: 3 - digits.count)
                frac = (Double(padded.prefix(3)) ?? 0) / 1000
            }
            let text: String = {
                guard m.range(at: 4).location != NSNotFound, let tR = Range(m.range(at: 4), in: s) else { return "" }
                return String(s[tR]).trimmingCharacters(in: .whitespaces)
            }()
            guard !text.isEmpty else { continue }
            out.append(Line(id: idx, time: minutes * 60 + seconds + frac, text: text))
        }
        return out
    }

    // MARK: - Position → highlight

    private func startPositionPolling() {
        stopPositionPolling()
        guard lines.contains(where: { $0.time != nil }) else { return }
        let timer = Timer.scheduledTimer(withTimeInterval: 0.45, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tickPosition() }
        }
        RunLoop.main.add(timer, forMode: .common)
        positionTimer = timer
        tickPosition()
    }

    private func tickPosition() {
        guard AppState.shared.view == .lyrics else {
            stopPositionPolling()
            return
        }
        guard let now = currentTrack() else { return }
        // Track changed while the panel is open → reload.
        let key = "\(now.title.lowercased())|\(now.artist.lowercased())"
        if key != trackKey {
            title = now.title
            artist = now.artist
            accentHex = now.accentHex
            loadIfNeeded(title: now.title, artist: now.artist, album: now.album)
            return
        }
        Task {
            let pos = await playerPosition(for: now.source)
            guard let pos else { return }
            applyPosition(pos)
        }
    }

    private func applyPosition(_ pos: TimeInterval) {
        let timed = lines.compactMap { line -> (Int, TimeInterval)? in
            guard let t = line.time else { return nil }
            return (line.id, t)
        }
        guard !timed.isEmpty else { return }
        var idx = 0
        for (i, t) in timed {
            if t <= pos + 0.05 { idx = i } else { break }
        }
        if idx != currentIndex { currentIndex = idx }
    }

    private func playerPosition(for source: NowPlaying.Source) async -> TimeInterval? {
        let script: String
        switch source {
        case .spotify:
            script = #"tell application id "com.spotify.client" to get player position as string"#
        case .music:
            script = #"tell application id "com.apple.Music" to get player position as string"#
        }
        return await runPositionScript(script)
    }

    private func runPositionScript(_ source: String) async -> TimeInterval? {
        await withCheckedContinuation { cont in
            DispatchQueue.global(qos: .utility).async {
                let script = NSAppleScript(source: source)!
                var err: NSDictionary?
                let desc = script.executeAndReturnError(&err)
                if err != nil {
                    cont.resume(returning: nil)
                    return
                }
                let raw = desc.stringValue ?? ""
                cont.resume(returning: TimeInterval(raw))
            }
        }
    }
}
#endif
