// Pare Guide — record any workflow on your Mac and turn it into a step-by-step guide.
// A Mac desktop take on Mimik (github.com/westpoint-io/mimik, MIT): instead of a browser
// extension it watches clicks and typing in every app, with screenshots and the clicked item boxed.

import SwiftUI
import AppKit
import UniformTypeIdentifiers

@main
struct PareGuideApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        WindowGroup("Pare Guide") {
            RootView()
                .frame(minWidth: 940, minHeight: 620)
                .task { await Updater.shared.check() }
        }
        .commands {
            CommandGroup(after: .newItem) {
                Button("New Recording") { Recorder.shared.start() }
                    .keyboardShortcut("r", modifiers: [.command, .shift])
                Button("Import Guide…") { RootView.importGuide() }
                    .keyboardShortcut("o")
            }
        }
        Settings {
            SettingsView()
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated { Updater.shared.install(relaunch: false) }
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        MainActor.assumeIsolated {
            for u in urls where u.pathExtension.lowercased() == "pareguide" {
                if let id = try? GuideStore.shared.importBundle(u) { RootView.pendingSelection = id }
            }
        }
    }
}

/// Settings read by the recorder (the Settings window writes the same keys).
enum Prefs {
    static var countdown: Bool { UserDefaults.standard.object(forKey: "countdown") as? Bool ?? true }
    static var autoBlur: Bool { UserDefaults.standard.object(forKey: "autoBlur") as? Bool ?? true }
    static var defaultZoom: Zoom { Zoom(rawValue: UserDefaults.standard.string(forKey: "defaultZoom") ?? "") ?? .some }
}

// MARK: - Main window

struct RootView: View {
    @ObservedObject private var store = GuideStore.shared
    @ObservedObject private var recorder = Recorder.shared
    @State private var selection: UUID?
    @State private var search = ""
    @State private var confirmDelete: UUID?

    @MainActor static var pendingSelection: UUID? {
        didSet { NotificationCenter.default.post(name: .selectGuide, object: nil) }
    }

    private var filtered: [Guide] {
        let q = search.trimmed.lowercased()
        guard !q.isEmpty else { return store.guides }
        return store.guides.filter { g in
            g.title.lowercased().contains(q) || g.steps.contains { $0.text.lowercased().contains(q) }
        }
    }

    var body: some View {
        NavigationSplitView {
            List(selection: $selection) {
                ForEach(filtered) { g in
                    VStack(alignment: .leading, spacing: 3) {
                        Text(g.title).lineLimit(2)
                        Text("\(g.steps.count) step\(g.steps.count == 1 ? "" : "s") · \(g.modified.formatted(date: .abbreviated, time: .shortened))")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 3)
                    .tag(g.id)
                    .contextMenu {
                        Button("Delete Guide…", role: .destructive) { confirmDelete = g.id }
                    }
                }
            }
            .searchable(text: $search, placement: .sidebar, prompt: "Search guides")
            .navigationSplitViewColumnWidth(min: 220, ideal: 270)
            .safeAreaInset(edge: .bottom) {
                Button {
                    recorder.start()
                } label: {
                    Label("New Recording", systemImage: "record.circle.fill")
                        .frame(maxWidth: .infinity)
                }
                .controlSize(.large)
                .buttonStyle(.borderedProminent)
                .tint(.red)
                .disabled(recorder.isBusy || !Permissions.accessibility || !Permissions.screenRecording)
                .padding(12)
            }
            .overlay {
                if store.guides.isEmpty {
                    Text("Your guides will appear here.").foregroundStyle(.secondary).font(.callout)
                }
            }
        } detail: {
            VStack(spacing: 0) {
                UpdateBanner(busy: recorder.isBusy).padding(.horizontal, 12).padding(.top, 8)
                if let id = selection, store.guide(id) != nil {
                    GuideEditor(guideID: id).id(id)
                } else {
                    HomeView()
                }
            }
        }
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Button { Self.importGuide() } label: { Label("Import", systemImage: "square.and.arrow.down") }
                    .help("Open a .pareguide file someone shared with you")
            }
        }
        .onAppear {
            recorder.onFinish = { id in selection = id }
            if let p = Self.pendingSelection { selection = p }
        }
        .onReceive(NotificationCenter.default.publisher(for: .selectGuide)) { _ in
            if let p = Self.pendingSelection { selection = p }
        }
        .confirmationDialog("Delete this guide?", isPresented: Binding(get: { confirmDelete != nil }, set: { if !$0 { confirmDelete = nil } })) {
            Button("Delete", role: .destructive) {
                if let id = confirmDelete {
                    if selection == id { selection = nil }
                    store.delete(id)
                }
                confirmDelete = nil
            }
        } message: {
            Text("Its steps and screenshots are removed from this Mac.")
        }
    }

    @MainActor
    static func importGuide() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "pareguide") ?? .zip, .zip]
        panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK else { return }
        for u in panel.urls {
            do { pendingSelection = try GuideStore.shared.importBundle(u) }
            catch { NSAlert(error: error).runModal() }
        }
    }
}

extension Notification.Name {
    static let selectGuide = Notification.Name("PareGuideSelect")
}

// MARK: - Home (no guide selected)

struct HomeView: View {
    @ObservedObject private var recorder = Recorder.shared
    @State private var ax = Permissions.accessibility
    @State private var screen = Permissions.screenRecording
    private let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Pare Guide").font(.system(size: 34, weight: .bold))
                    Text("Do a task once on your Mac. Pare Guide turns every click and entry into a step-by-step guide with screenshots, then exports it as a PDF, Word file, web page, video or GIF.")
                        .font(.title3).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if !ax || !screen {
                    GroupBox {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("Two permissions first").font(.headline)
                            PermissionRow(done: ax, title: "Accessibility",
                                          detail: "Lets Pare Guide see where you click, what you clicked on, and what you type.",
                                          action: Permissions.askAccessibility)
                            PermissionRow(done: screen, title: "Screen Recording",
                                          detail: "Lets Pare Guide take a screenshot for each step.",
                                          action: Permissions.askScreenRecording)
                            HStack {
                                Text("Already switched them on? macOS needs the app to reopen.")
                                    .font(.caption).foregroundStyle(.secondary)
                                Button("Quit & Reopen") { relaunch() }.controlSize(.small)
                            }
                        }
                        .padding(8)
                    }
                }

                Button {
                    recorder.start()
                } label: {
                    Label("Start Recording", systemImage: "record.circle.fill")
                        .font(.title3.weight(.semibold))
                        .padding(.horizontal, 14).padding(.vertical, 6)
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
                .controlSize(.large)
                .disabled(!ax || !screen || recorder.isBusy)

                if let e = recorder.lastError {
                    Label(e, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                }

                GroupBox {
                    VStack(alignment: .leading, spacing: 8) {
                        tip("record.circle", "The window hides and recording starts after a 3-second countdown. A red dot in the menu bar shows the step count.")
                        tip("stop.circle", "Stop with **⌃⌥⌘S** or the menu bar dot. Pause with **⌃⌥⌘P**.")
                        tip("eye.slash", "Emails, phone and card numbers in screenshots are blurred automatically. Passwords are never recorded.")
                        tip("sparkles", "Add an Anthropic or OpenAI key in Settings to have each step written for you.")
                    }
                    .padding(6)
                }
            }
            .padding(32)
            .frame(maxWidth: 760, alignment: .leading)
        }
        .onReceive(timer) { _ in
            ax = Permissions.accessibility
            screen = Permissions.screenRecording
        }
    }

    private func tip(_ icon: String, _ text: LocalizedStringKey) -> some View {
        Label { Text(text).fixedSize(horizontal: false, vertical: true) } icon: { Image(systemName: icon).foregroundStyle(.secondary) }
    }

    private func relaunch() {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", "sleep 1; open \"$APP\""]
        p.environment = ["APP": Bundle.main.bundlePath]
        try? p.run()
        NSApp.terminate(nil)
    }
}

struct PermissionRow: View {
    let done: Bool
    let title: String
    let detail: String
    let action: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: done ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(done ? .green : .secondary).font(.title3)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).fontWeight(.semibold)
                Text(detail).font(.callout).foregroundStyle(.secondary)
            }
            Spacer()
            if !done { Button("Allow…", action: action) }
        }
    }
}

// MARK: - Settings

struct SettingsView: View {
    @AppStorage("countdown") private var countdown = true
    @AppStorage("autoBlur") private var autoBlur = true
    @AppStorage("defaultZoom") private var defaultZoom = Zoom.some.rawValue
    @AppStorage("aiProvider") private var providerRaw = AIProvider.anthropic.rawValue
    @AppStorage("aiLanguage") private var language = ""
    @AppStorage("voiceID") private var voiceID = ""
    @State private var key = ""
    @State private var model = ""
    @State private var saved = false

    private var provider: AIProvider { AIProvider(rawValue: providerRaw) ?? .anthropic }

    var body: some View {
        TabView {
            Form {
                Toggle("3-second countdown before recording starts", isOn: $countdown)
                Toggle("Blur emails, phone and card numbers automatically", isOn: $autoBlur)
                Picker("New guides", selection: $defaultZoom) {
                    ForEach(Zoom.allCases) { Text($0.rawValue).tag($0.rawValue) }
                }
                Picker("Narration voice", selection: $voiceID) {
                    Text("System default").tag("")
                    ForEach(Speech.voices, id: \.identifier) { v in
                        Text("\(v.name) (\(v.language))").tag(v.identifier)
                    }
                }
                Text("Better voices: System Settings › Accessibility › Spoken Content › System Voice › Manage Voices.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .formStyle(.grouped)
            .tabItem { Label("General", systemImage: "gearshape") }

            Form {
                Picker("Provider", selection: $providerRaw) {
                    ForEach(AIProvider.allCases) { Text($0.rawValue).tag($0.rawValue) }
                }
                SecureField("API key", text: $key)
                TextField("Model", text: $model, prompt: Text(provider.defaultModel))
                TextField("Write steps in", text: $language, prompt: Text("English"))
                HStack {
                    Button("Save") {
                        Keychain.set(key.trimmed, for: provider.keyAccount)
                        UserDefaults.standard.set(model.trimmed, forKey: "aiModel-\(provider.keyAccount)")
                        saved = true
                    }
                    if saved { Text("Saved").foregroundStyle(.secondary) }
                }
                Text("Optional. Your key stays in your Mac's Keychain. When you ask for AI wording, each step's screenshot (with blurs applied) is sent to the provider you choose.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .formStyle(.grouped)
            .tabItem { Label("AI", systemImage: "sparkles") }
            .onAppear(perform: loadKey)
            .onChange(of: providerRaw) { _, _ in loadKey() }

            Form {
                LabeledContent("Version", value: "Build \(Updater.shared.currentBuild)")
                UpdateButton(busy: false)
                Text("Based on the idea of Mimik by Westpoint (MIT licence), rebuilt as a native Mac app that works in every app.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .formStyle(.grouped)
            .tabItem { Label("About", systemImage: "info.circle") }
        }
        .frame(width: 520, height: 400)
    }

    private func loadKey() {
        key = Keychain.get(provider.keyAccount) ?? ""
        model = UserDefaults.standard.string(forKey: "aiModel-\(provider.keyAccount)") ?? ""
        saved = false
    }
}
