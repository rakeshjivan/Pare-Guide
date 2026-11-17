// AI — optional step wording with your own Anthropic or OpenAI key.
// Each step's picture (with the clicked item boxed) and what the Mac said was clicked are sent;
// the reply is one short instruction. Keys are kept in your Mac's Keychain.

import Foundation
import AppKit

enum AIProvider: String, CaseIterable, Identifiable, Codable {
    case anthropic = "Anthropic (Claude)"
    case openai = "OpenAI"
    var id: String { rawValue }
    var defaultModel: String {
        switch self {
        case .anthropic: return "claude-haiku-5-5"
        case .openai: return "gpt-4.1-mini"
        }
    }
    var keyAccount: String { self == .anthropic ? "anthropic-key" : "openai-key" }
}

enum AI {
    static var provider: AIProvider {
        get { AIProvider(rawValue: UserDefaults.standard.string(forKey: "aiProvider") ?? "") ?? .anthropic }
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
    static var isReady: Bool { !(Keychain.get(provider.keyAccount) ?? "").isEmpty }

    /// Writes one step's instruction.
    static func describe(_ step: Step, picture: CGImage, number: Int) async throws -> String {
        var context = "Action: \(actionWords(step))."
        if !step.appName.isEmpty { context += " App: \(step.appName)." }
        if !step.windowTitle.isEmpty { context += " Window: \(step.windowTitle)." }
        if !step.label.isEmpty { context += " The item is labelled \"\(step.label)\"." }
        context += " Current draft: \"\(step.text.plain)\"."
        let prompt = """
        You are writing step \(number) of a how-to guide for a Mac. The screenshot shows the screen at this step; \
        the orange box and dot mark what the person clicked or typed into.
        \(context)
        Write ONE short, plain instruction (at most 20 words) that a beginner can follow, in \(language). \
        Start with a verb. Put on-screen labels in **double asterisks**. Keep any typed text exactly as in the draft. \
        Reply with the instruction only.
        """
        let text = try await send(prompt: prompt, image: picture, maxTokens: 120)
        return clean(text)
    }

    /// A title and one-line summary from the finished steps.
    static func titleAndSummary(_ guide: Guide) async throws -> (String, String) {
        let steps = guide.steps.enumerated().map { "\($0.offset + 1). \($0.element.text.plain)" }.joined(separator: "\n")
        let prompt = """
        These are the steps of a how-to guide for a Mac:
        \(steps)
        In \(language), reply with exactly two lines: line 1 a short title (max 8 words, no quotes) saying what the guide \
        teaches; line 2 a one-sentence summary for the top of the guide.
        """
        let text = try await send(prompt: prompt, image: nil, maxTokens: 150)
        let lines = text.split(separator: "\n").map { String($0).trimmed }.filter { !$0.isEmpty }
        return (clean(lines.first ?? guide.title), clean(lines.dropFirst().first ?? guide.summary))
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

    private static func clean(_ s: String) -> String {
        var t = s.trimmed
        if t.hasPrefix("\""), t.hasSuffix("\""), t.count > 1 { t = String(t.dropFirst().dropLast()) }
        if t.lowercased().hasPrefix("title:") { t = String(t.dropFirst(6)).trimmed }
        if t.lowercased().hasPrefix("summary:") { t = String(t.dropFirst(8)).trimmed }
        return t
    }

    private static func send(prompt: String, image: CGImage?, maxTokens: Int) async throws -> String {
        let p = provider
        guard let key = Keychain.get(p.keyAccount), !key.isEmpty else {
            throw PGError("Add your \(p.rawValue) key in Settings first.")
        }
        var b64: String?
        if let image {
            let small = image.width > 1400 ? (Renderer.scaled(image, width: 1400) ?? image) : image
            b64 = Renderer.jpeg(small, quality: 0.8)?.base64EncodedString()
        }
        var req: URLRequest
        var body: [String: Any]
        switch p {
        case .anthropic:
            req = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
            req.setValue(key, forHTTPHeaderField: "x-api-key")
            req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
            var content: [[String: Any]] = []
            if let b64 {
                content.append(["type": "image", "source": ["type": "base64", "media_type": "image/jpeg", "data": b64]])
            }
            content.append(["type": "text", "text": prompt])
            body = ["model": model(p), "max_tokens": maxTokens, "messages": [["role": "user", "content": content]]]
        case .openai:
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
            throw PGError("\(p.rawValue) said: \(msg.prefix(300))")
        }
        switch p {
        case .anthropic:
            let blocks = json?["content"] as? [[String: Any]] ?? []
            return blocks.compactMap { $0["text"] as? String }.joined()
        case .openai:
            let choices = json?["choices"] as? [[String: Any]] ?? []
            return ((choices.first?["message"] as? [String: Any])?["content"] as? String) ?? ""
        }
    }
}
