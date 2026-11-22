// Narrator — reads narration aloud into sound files for videos.
// Two kinds of voice:
// • Pare Voice: cloned voices (yours, or voice artists you have permission for) made with Chatterbox,
//   using the voices saved by the Pare Voice app in ~/Documents/Pare Voice/Voices.
//   Pare Guide runs a small helper (Resources/pare_voice_engine.py) with the Chatterbox install at ~/chatterbox.
// • The Mac's built-in voices (no setup).
// Everything runs on this Mac.

import AppKit
import AVFoundation

enum NarratorKind: String, CaseIterable, Identifiable {
    case pareVoice = "Pare Voice (cloned voices)"
    case mac = "Mac voice"
    var id: String { rawValue }
}

enum PareVoiceMode: String, CaseIterable, Identifiable {
    case turbo = "Fast (Turbo)"
    case standard = "Expressive (Standard)"
    var id: String { rawValue }
    var engineName: String { self == .turbo ? "turbo" : "standard" }
}

enum Narrator {
    static var kind: NarratorKind {
        get { NarratorKind(rawValue: UserDefaults.standard.string(forKey: "narratorKind") ?? "") ?? (PareVoice.isInstalled ? .pareVoice : .mac) }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "narratorKind") }
    }

    /// Which narrator will actually be used (falls back to the Mac voice if Pare Voice isn't set up).
    static var effectiveKind: NarratorKind {
        kind == .pareVoice && PareVoice.isInstalled && PareVoice.selectedVoice != nil ? .pareVoice : .mac
    }

    /// Reads `text` into a sound file in `folder` and returns the file and its length in seconds.
    static func record(_ text: String, name: String, in folder: URL) async throws -> (URL, Double)? {
        let t = text.plain.trimmed
        guard !t.isEmpty else { return nil }
        if effectiveKind == .pareVoice, let voice = PareVoice.selectedVoice {
            let url = folder.appendingPathComponent(name + ".wav")
            let secs = try await PareVoice.say(t, voice: voice, to: url)
            return (url, secs)
        }
        let url = folder.appendingPathComponent(name + ".caf")
        let secs = try await Speech.write(t, to: url)
        return secs > 0 ? (url, secs) : nil
    }

    static var summary: String {
        switch effectiveKind {
        case .pareVoice: return "Pare Voice: \(PareVoice.selectedVoice ?? "")"
        case .mac: return "Mac voice"
        }
    }
}

// MARK: - Pare Voice engine

enum PareVoice {
    static let port = 7866
    private static let lock = NSLock()
    private static var process: Process?

    static var home: URL { FileManager.default.homeDirectoryForCurrentUser }
    static var python: URL { home.appendingPathComponent("chatterbox/bin/python") }
    static var voicesFolder: URL { home.appendingPathComponent("Documents/Pare Voice/Voices", isDirectory: true) }
    static var script: URL? { Bundle.main.url(forResource: "pare_voice_engine", withExtension: "py") }

    /// Chatterbox is installed (the same setup Pare Voice uses).
    static var isInstalled: Bool { FileManager.default.isExecutableFile(atPath: python.path) && script != nil }

    static var voices: [String] {
        let files = (try? FileManager.default.contentsOfDirectory(at: voicesFolder, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension.lowercased() == "wav" && !$0.lastPathComponent.hasPrefix(".") }
            .map { $0.deletingPathExtension().lastPathComponent }
            .sorted()
    }

    static var selectedVoice: String? {
        let all = voices
        if let v = UserDefaults.standard.string(forKey: "pareVoiceName"), all.contains(v) { return v }
        return all.contains("Rakesh") ? "Rakesh" : all.first
    }

    static var mode: PareVoiceMode {
        PareVoiceMode(rawValue: UserDefaults.standard.string(forKey: "pareVoiceMode") ?? "") ?? .turbo
    }

    static var exaggeration: Double { UserDefaults.standard.object(forKey: "pareVoiceExpressiveness") as? Double ?? 0.45 }
    static var cfg: Double { UserDefaults.standard.object(forKey: "pareVoicePace") as? Double ?? 0.5 }

    private static var base: URL { URL(string: "http://127.0.0.1:\(port)")! }

    private static func healthy() async -> Bool {
        var req = URLRequest(url: base.appendingPathComponent("health"))
        req.timeoutInterval = 2
        guard let (_, resp) = try? await URLSession.shared.data(for: req) else { return false }
        return (resp as? HTTPURLResponse)?.statusCode == 200
    }

    /// Starts the helper if it isn't already running.
    static func start() async throws {
        if await healthy() { return }
        guard isInstalled, let script else {
            throw PGError("Pare Voice isn't set up on this Mac (Chatterbox should be at ~/chatterbox).")
        }
        let p = Process()
        p.executableURL = python
        p.arguments = [script.path, String(port)]
        var env = ProcessInfo.processInfo.environment
        env["PYTHONUNBUFFERED"] = "1"
        env["PATH"] = [home.appendingPathComponent("chatterbox/bin").path, "/usr/bin", "/bin", "/usr/sbin", "/sbin",
                       env["PATH"] ?? ""].joined(separator: ":")
        p.environment = env
        let log = home.appendingPathComponent("Library/Logs/Pare Guide voice.log")
        FileManager.default.createFile(atPath: log.path, contents: nil)
        if let h = try? FileHandle(forWritingTo: log) { p.standardOutput = h; p.standardError = h }
        try p.run()
        lock.withLock { process = p }
        for _ in 0..<60 {
            try await Task.sleep(nanoseconds: 500_000_000)
            if await healthy() { return }
            if !p.isRunning { break }
        }
        throw PGError("The Pare Voice helper didn't start. See ~/Library/Logs/Pare Guide voice.log.")
    }

    /// Stops the helper (when Pare Guide quits).
    static func stop() {
        lock.withLock {
            process?.terminate()
            process = nil
        }
    }

    /// Speaks `text` in a Pare Voice voice into `url` (WAV). Returns the length in seconds.
    static func say(_ text: String, voice: String, to url: URL) async throws -> Double {
        try await start()
        var req = URLRequest(url: base.appendingPathComponent("say"))
        req.httpMethod = "POST"
        req.timeoutInterval = 900   // the first line also loads the voice model
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: [
            "text": text, "voice": voice, "mode": mode.engineName,
            "exaggeration": exaggeration, "cfg": cfg, "out": url.path,
        ])
        let (data, resp) = try await URLSession.shared.data(for: req)
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        guard (resp as? HTTPURLResponse)?.statusCode == 200, let secs = json?["seconds"] as? Double else {
            throw PGError("Pare Voice: \((json?["error"] as? String) ?? "no answer")")
        }
        return secs
    }
}
