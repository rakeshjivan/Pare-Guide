// AI — optional step wording. Four ways to do it:
// • Claude subscription: runs the official Claude Code tool ("claude -p") that you've signed in to,
//   so it uses your Pro/Max plan rather than paid API credits. No key needed.
// • Apple Intelligence: Apple's on-device model. Free, private, offline (macOS 26 or later).
// • Anthropic or OpenAI API key, for people with API credits.

import Foundation
import AppKit
#if canImport(FoundationModels)
import FoundationModels
#endif

enum AIProvider: String, CaseIterable, Identifiable, Codable {
    case claudeCode = "Claude subscription (via Claude Code)"
    case apple = "Apple Intelligence (on this Mac)"
    case anthropic = "Anthropic API key"
    case openai = "OpenAI API key"
    var id: String { rawValue }
    var defaultModel: String {
        switch self {
        case .claudeCode: return "sonnet"
        case .apple: return ""
        case .anthropic: return "claude-haiku-5-5"
        case .openai: return "gpt-4.1-mini"
        }
    }
    var keyAccount: String {
        switch self {
        case .claudeCode: return "claude-code"
        case .apple: return "apple"
        case .anthropic: return "anthropic-key"
        case .openai: return "openai-key"
        }
    }
    var needsKey: Bool { self == .anthropic || self == .openai }
}

/// A step to be written, with its finished picture.
struct AIJob {
    let number: Int
    let step: Step
    let picture: CGImage
}

enum AI {
    static var provider: AIProvider {
        get { AIProvider(rawValue: UserDefaults.standard.string(forKey: "aiProvider") ?? "") ?? .claudeCode }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "aiProvider") }
    }
    static func model(_ p: AIProvider) -> String {
        let m = UserDefaults.standard.string(forKey: "aiModel-\(p.keyAccount)")?.trimmed ?? ""
        return m.isEmpty ? p.defaultModel : m
    }
    static var language: String {
        let l = UserDefaults.standard.string(forKey: "aiLanguage")?.trimmed ?? ""
        return l.isEmpty ? "English" : l
    }

    static var isReady: Bool {
        switch provider {
        case .claudeCode: return ClaudeCLI.find() != nil || AppleAI.isAvailable
        case .apple: return AppleAI.isAvailable
        case .anthropic, .openai: return !(Keychain.get(provider.keyAccount) ?? "").isEmpty
        }
    }

    static var notReadyMessage: String {
        switch provider {
        case .claudeCode: return "Claude Code isn't installed yet. See Settings › AI."
        case .apple: return "Apple Intelligence isn't available. See Settings › AI."
        case .anthropic, .openai: return "Add your API key in Settings › AI first."
        }
    }

    /// Set when the last request had to fall back to Apple Intelligence.
    @MainActor static var lastNote: String?

    // MARK: Writing steps

    /// Writes instructions for a batch of steps. Returns new text by step id.
    static func write(_ jobs: [AIJob]) async throws -> [UUID: String] {
        guard !jobs.isEmpty else { return [:] }
        await MainActor.run { lastNote = nil }
        switch provider {
        case .claudeCode:
            if ClaudeCLI.find() != nil {
                do { return try await ClaudeCLI.write(jobs) }
                catch {
                    guard AppleAI.isAvailable, !Task.isCancelled else { throw error }
                    let reason = String(error.localizedDescription.prefix(140))
                    await MainActor.run { lastNote = "Claude Code didn't answer (\(reason)), so Apple Intelligence wrote these." }
                }
            }
            return try await appleWrite(jobs)
        case .apple:
            return try await appleWrite(jobs)
        case .anthropic, .openai:
            var out: [UUID: String] = [:]
            for j in jobs {
                try Task.checkCancellation()
                out[j.step.id] = clean(try await send(prompt: singlePrompt(j), image: j.picture, maxTokens: 120))
            }
            return out
        }
    }

    private static func appleWrite(_ jobs: [AIJob]) async throws -> [UUID: String] {
        var out: [UUID: String] = [:]
        for j in jobs {
            try Task.checkCancellation()
            out[j.step.id] = clean(try await AppleAI.respond(textOnlyPrompt(j)))
        }
        return out
    }

    /// A title and one-line summary from the finished steps.
    static func titleAndSummary(_ guide: Guide) async throws -> (String, String) {
        let steps = guide.steps.enumerated().map { "\($0.offset + 1). \($0.element.text.plain)" }.joined(separator: "\n")
        let prompt = """
        These are the steps of a how-to guide for a Mac:
        \(steps)
        In \(language), reply with exactly two lines and nothing else: line 1 a short title (max 8 words, no quotes) \
        saying what the guide teaches; line 2 a one-sentence summary for the top of the guide.
        """
        let text: String
        switch provider {
        case .claudeCode:
            if ClaudeCLI.find() != nil {
                do { text = try await ClaudeCLI.ask(prompt) }
                catch {
                    guard AppleAI.isAvailable else { throw error }
                    text = try await AppleAI.respond(prompt)
                }
            } else { text = try await AppleAI.respond(prompt) }
        case .apple: text = try await AppleAI.respond(prompt)
        case .anthropic, .openai: text = try await send(prompt: prompt, image: nil, maxTokens: 150)
        }
        let lines = text.split(separator: "\n").map { String($0).trimmed }.filter { !$0.isEmpty }
        return (clean(lines.first ?? guide.title), clean(lines.dropFirst().first ?? guide.summary))
    }

    // MARK: Prompts

    static func facts(_ j: AIJob) -> String {
        let s = j.step
        var c = "action: \(actionWords(s))"
        if !s.appName.isEmpty { c += "; app: \(s.appName)" }
        if !s.windowTitle.isEmpty { c += "; window: \(s.windowTitle)" }
        if !s.label.isEmpty { c += "; item label: \"\(s.label)\"" }
        if !s.role.isEmpty { c += "; item type: \(s.role.replacingOccurrences(of: "AX", with: ""))" }
        c += "; current draft: \"\(s.text.plain)\""
        return c
    }

    static let rules = """
    Write ONE short, plain instruction (at most 20 words) a beginner can follow. Start with a verb. \
    Put on-screen labels in **double asterisks**. Keep any typed text exactly as in the draft. \
    Never include passwords or private details.
    """

    private static func singlePrompt(_ j: AIJob) -> String {
        """
        You are writing step \(j.number) of a how-to guide for a Mac. The screenshot shows the screen at this step; \
        the orange box and dot mark what the person clicked or typed into.
        Facts: \(facts(j)).
        \(rules) Write in \(language). Reply with the instruction only.
        """
    }

    private static func textOnlyPrompt(_ j: AIJob) -> String {
        """
        You are writing step \(j.number) of a how-to guide for a Mac, from what the Mac recorded.
        Facts: \(facts(j)).
        \(rules) Write in \(language). Reply with the instruction only.
        """
    }

    private static func actionWords(_ s: Step) -> String {
        switch s.kind {
        case .click: return "single click"
        case .rightClick: return "right-click"
        case .doubleClick: return "double-click"
        case .type: return "typing into a field"
        case .shortcut: return "keyboard shortcut"
        case .note: return "note"
        }
    }

    static func clean(_ s: String) -> String {
        var t = s.trimmed
        if t.hasPrefix("\""), t.hasSuffix("\""), t.count > 1 { t = String(t.dropFirst().dropLast()) }
        for p in ["title:", "summary:", "instruction:"] where t.lowercased().hasPrefix(p) {
            t = String(t.dropFirst(p.count)).trimmed
        }
        return t
    }

    // MARK: API keys

    private static func send(prompt: String, image: CGImage?, maxTokens: Int) async throws -> String {
        let p = provider
        guard let key = Keychain.get(p.keyAccount), !key.isEmpty else {
            throw PGError("Add your \(p.rawValue) in Settings first.")
        }
        var b64: String?
        if let image {
            let small = image.width > 1400 ? (Renderer.scaled(image, width: 1400) ?? image) : image
            b64 = Renderer.jpeg(small, quality: 0.8)?.base64EncodedString()
        }
        var req: URLRequest
        var body: [String: Any]
        if p == .anthropic {
            req = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
            req.setValue(key, forHTTPHeaderField: "x-api-key")
            req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
            var content: [[String: Any]] = []
            if let b64 {
                content.append(["type": "image", "source": ["type": "base64", "media_type": "image/jpeg", "data": b64]])
            }
            content.append(["type": "text", "text": prompt])
            body = ["model": model(p), "max_tokens": maxTokens, "messages": [["role": "user", "content": content]]]
        } else {
            req = URLRequest(url: URL(string: "https://api.openai.com/v1/chat/completions")!)
            req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
            var content: [[String: Any]] = [["type": "text", "text": prompt]]
            if let b64 {
                content.append(["type": "image_url", "image_url": ["url": "data:image/jpeg;base64,\(b64)"]])
            }
            body = ["model": model(p), "messages": [["role": "user", "content": content]]]
        }
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "content-type")
        req.timeoutInterval = 60
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, resp) = try await URLSession.shared.data(for: req)
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        guard let http = resp as? HTTPURLResponse, http.statusCode == 200 else {
            let msg = ((json?["error"] as? [String: Any])?["message"] as? String) ?? String(data: data, encoding: .utf8) ?? "Unknown error"
            throw PGError("\(p == .anthropic ? "Anthropic" : "OpenAI") said: \(msg.prefix(300))")
        }
        if p == .anthropic {
            let blocks = json?["content"] as? [[String: Any]] ?? []
            return blocks.compactMap { $0["text"] as? String }.joined()
        }
        let choices = json?["choices"] as? [[String: Any]] ?? []
        return ((choices.first?["message"] as? [String: Any])?["content"] as? String) ?? ""
    }
}

// MARK: - Claude Code (your Claude subscription)

enum ClaudeCLI {
    private static let lock = NSLock()
    private static var cached: String??

    /// Where the `claude` tool is installed, if it is.
    static func find() -> String? {
        if let c = lock.withLock({ cached }) { return c }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let candidates = ["\(home)/.local/bin/claude", "\(home)/.claude/local/claude", "/opt/homebrew/bin/claude",
                          "/usr/local/bin/claude", "\(home)/.npm-global/bin/claude", "\(home)/.bun/bin/claude",
                          "\(home)/.volta/bin/claude"]
        var found = candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
        if found == nil {
            // Ask a login shell, which knows the user's PATH.
            let r = run("/bin/zsh", ["-lc", "command -v claude"], cwd: nil, env: nil, timeout: 10)
            let p = r.out.trimmed
            if r.status == 0, !p.isEmpty, FileManager.default.isExecutableFile(atPath: p) { found = p }
        }
        lock.withLock { cached = .some(found) }
        return found
    }

    /// Look again next time (after installing Claude Code).
    static func forgetLocation() { lock.withLock { cached = nil } }

    /// Environment for claude: the user's normal one, minus anything that would switch it to paid API billing.
    private static var env: [String: String] {
        var e = ProcessInfo.processInfo.environment
        for k in ["ANTHROPIC_API_KEY", "ANTHROPIC_AUTH_TOKEN", "ANTHROPIC_BASE_URL", "CLAUDE_CODE_USE_BEDROCK",
                  "CLAUDE_CODE_USE_VERTEX", "CLAUDE_CODE_USE_FOUNDRY"] { e[k] = nil }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        e["PATH"] = ["\(home)/.local/bin", "/opt/homebrew/bin", "/usr/local/bin", "\(home)/.npm-global/bin",
                     "/usr/bin", "/bin", "/usr/sbin", "/sbin", e["PATH"] ?? ""].joined(separator: ":")
        return e
    }

    /// Quick check from Settings: is it installed and signed in?
    static func test() async -> String {
        forgetLocation()
        guard find() != nil else { return "Claude Code isn't installed." }
        do {
            let reply = try await ask("Reply with just the word OK.")
            return reply.uppercased().contains("OK") ? "Working. Steps will use your Claude subscription." : "Claude Code replied: \(reply.prefix(80))"
        } catch { return error.localizedDescription }
    }

    /// A text-only question.
    static func ask(_ prompt: String) async throws -> String {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("pareguide-ai-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        return try await call(prompt, in: dir, allowRead: false)
    }

    /// Writes all the steps in one go: the pictures are saved to a temporary folder and Claude reads them.
    static func write(_ jobs: [AIJob]) async throws -> [UUID: String] {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("pareguide-ai-\(UUID().uuidString)")
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dir) }
        var lines: [String] = []
        for (i, j) in jobs.enumerated() {
            let name = String(format: "step-%02d.jpg", j.number)
            let small = j.picture.width > 1400 ? (Renderer.scaled(j.picture, width: 1400) ?? j.picture) : j.picture
            try Renderer.jpeg(small, quality: 0.8)?.write(to: dir.appendingPathComponent(name))
            lines.append("\(i + 1). image file: \(name) | \(AI.facts(j))")
        }
        let prompt = """
        You are writing steps for a how-to guide for a Mac. For each step below, open its screenshot with the Read tool \
        (the files are in the current folder). The orange box and dot mark what the person clicked or typed into.
        For each step: \(AI.rules) Write in \(AI.language).
        Reply with ONLY a JSON array of \(jobs.count) strings, one per step, in the same order. No other text.

        Steps:
        \(lines.joined(separator: "\n"))
        """
        let reply = try await call(prompt, in: dir, allowRead: true)
        guard let start = reply.firstIndex(of: "["), let end = reply.lastIndex(of: "]"), start < end,
              let data = String(reply[start...end]).data(using: .utf8),
              let arr = try? JSONSerialization.jsonObject(with: data) as? [String], arr.count == jobs.count else {
            throw PGError("Claude's reply wasn't in the expected format. Try again.")
        }
        var out: [UUID: String] = [:]
        for (j, text) in zip(jobs, arr) where !text.trimmed.isEmpty { out[j.step.id] = AI.clean(text) }
        return out
    }

    private static func call(_ prompt: String, in dir: URL, allowRead: Bool) async throws -> String {
        guard let exe = find() else { throw PGError("Claude Code isn't installed.") }
        var args = ["-p", prompt, "--output-format", "text", "--model", AI.model(.claudeCode)]
        if allowRead { args += ["--allowedTools", "Read"] }
        let environment = env
        let r = await Task.detached(priority: .userInitiated) {
            run(exe, args, cwd: dir, env: environment, timeout: 300)
        }.value
        if r.timedOut { throw PGError("Claude Code took too long to answer.") }
        let text = r.out.trimmed
        guard r.status == 0, !text.isEmpty else {
            let detail = r.err.trimmed.isEmpty ? text : r.err.trimmed
            let lower = detail.lowercased()
            if lower.contains("login") || lower.contains("log in") || lower.contains("authenticat") || lower.contains("api key") {
                throw PGError("Claude Code isn't signed in. Open Terminal, type claude, press Return and sign in with your Claude account.")
            }
            if lower.contains("limit") || lower.contains("credit") || lower.contains("quota") || lower.contains("usage") {
                throw PGError("Your Claude allowance is used up for now. \(detail.prefix(160))")
            }
            throw PGError("Claude Code: \(detail.isEmpty ? "no answer" : String(detail.prefix(200)))")
        }
        return text
    }

    struct Result { var status: Int32; var out: String; var err: String; var timedOut: Bool }

    static func run(_ exe: String, _ args: [String], cwd: URL?, env: [String: String]?, timeout: TimeInterval) -> Result {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = args
        if let cwd { p.currentDirectoryURL = cwd }
        if let env { p.environment = env }
        let outPipe = Pipe(), errPipe = Pipe()
        p.standardOutput = outPipe
        p.standardError = errPipe
        p.standardInput = FileHandle.nullDevice
        do { try p.run() } catch { return Result(status: -1, out: "", err: error.localizedDescription, timedOut: false) }
        // Read both pipes while it runs so a long reply can't block it.
        let box = PipeBox()
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global().async { box.set(out: outPipe.fileHandleForReading.readDataToEndOfFile()); group.leave() }
        group.enter()
        DispatchQueue.global().async { box.set(err: errPipe.fileHandleForReading.readDataToEndOfFile()); group.leave() }
        var timedOut = false
        if group.wait(timeout: .now() + timeout) == .timedOut {
            timedOut = true
            p.terminate()
            _ = group.wait(timeout: .now() + 5)
        }
        p.waitUntilExit()
        let (o, e) = box.get()
        return Result(status: p.terminationStatus, out: String(decoding: o, as: UTF8.self),
                      err: String(decoding: e, as: UTF8.self), timedOut: timedOut)
    }
}

private final class PipeBox: @unchecked Sendable {
    private let lock = NSLock()
    private var out = Data(), err = Data()
    func set(out d: Data) { lock.withLock { out = d } }
    func set(err d: Data) { lock.withLock { err = d } }
    func get() -> (Data, Data) { lock.withLock { (out, err) } }
}

// MARK: - Apple Intelligence (on-device)

enum AppleAI {
    static var isAvailable: Bool {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) { return SystemLanguageModel.default.isAvailable }
        #endif
        return false
    }

    static var status: String {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            switch SystemLanguageModel.default.availability {
            case .available: return "Ready on this Mac (reads the step details, not the screenshots)."
            case .unavailable(let reason):
                switch reason {
                case .appleIntelligenceNotEnabled: return "Turn on Apple Intelligence in System Settings › Apple Intelligence & Siri."
                case .modelNotReady: return "Apple Intelligence is still downloading. Try again later."
                case .deviceNotEligible: return "This Mac can't run Apple Intelligence."
                @unknown default: return "Apple Intelligence isn't available right now."
                }
            @unknown default: return "Apple Intelligence isn't available right now."
            }
        }
        #endif
        return "Needs macOS 26 or later."
    }

    static func respond(_ prompt: String) async throws -> String {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            guard SystemLanguageModel.default.isAvailable else { throw PGError(status) }
            let session = LanguageModelSession(instructions: "You write short, clear instructions for how-to guides about using a Mac.")
            let r = try await session.respond(to: prompt)
            return r.content
        }
        #endif
        throw PGError("Apple Intelligence needs macOS 26 or later.")
    }
}
