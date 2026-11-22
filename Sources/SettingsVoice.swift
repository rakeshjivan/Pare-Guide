// Settings › Voice and Settings › Intros & Outros.

import SwiftUI
import AppKit
import AVFoundation
import UniformTypeIdentifiers

// MARK: - Voice

struct VoiceSettings: View {
    @AppStorage("narratorKind") private var kindRaw = ""
    @AppStorage("pareVoiceName") private var voiceName = ""
    @AppStorage("pareVoiceMode") private var modeRaw = PareVoiceMode.turbo.rawValue
    @AppStorage("pareVoiceExpressiveness") private var expressiveness = 0.45
    @AppStorage("pareVoicePace") private var pace = 0.5
    @AppStorage("voiceID") private var macVoiceID = ""
    @ObservedObject private var setup = VoiceSetup.shared

    @State private var voices: [String] = PareVoice.voices
    @State private var message: String?
    @State private var working: String?
    @State private var preview: AVAudioPlayer?
    @State private var showRecorder = false
    @State private var renaming: String?
    @State private var newName = ""
    @State private var removeMusic = false

    private var kind: NarratorKind {
        NarratorKind(rawValue: kindRaw) ?? (PareVoice.isInstalled ? .pareVoice : .mac)
    }

    var body: some View {
        Form {
            Section {
                Picker("Narrator", selection: Binding(get: { kind.rawValue }, set: { kindRaw = $0 })) {
                    ForEach(NarratorKind.allCases) { Text($0.rawValue).tag($0.rawValue) }
                }
                if kind == .mac {
                    Picker("Mac voice", selection: $macVoiceID) {
                        Text("System default").tag("")
                        ForEach(Speech.voices, id: \.identifier) { v in Text("\(v.name) (\(v.language))").tag(v.identifier) }
                    }
                    Text("Better Mac voices: System Settings › Accessibility › Spoken Content › System Voice › Manage Voices.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }

            if kind == .pareVoice {
                Section("Pare Voice") {
                    setupRow
                    if PareVoice.isInstalled {
                        Picker("Voice", selection: Binding(get: { PareVoice.selectedVoice ?? "" }, set: { voiceName = $0 })) {
                            ForEach(voices, id: \.self) { Text($0).tag($0) }
                        }
                        .disabled(voices.isEmpty)
                        Picker("Mode", selection: $modeRaw) {
                            ForEach(PareVoiceMode.allCases) { Text($0.rawValue).tag($0.rawValue) }
                        }
                        .pickerStyle(.segmented)
                        if modeRaw == PareVoiceMode.standard.rawValue {
                            LabeledContent("Expressiveness") {
                                Slider(value: $expressiveness, in: 0.25...1.0) { EmptyView() }
                            }
                            LabeledContent("Pace and steadiness") {
                                Slider(value: $pace, in: 0.0...0.8) { EmptyView() }
                            }
                            Text("Lower expressiveness is calmer; lower pace is slower and more deliberate (0 is fastest to make).")
                                .font(.caption).foregroundStyle(.secondary)
                        } else {
                            Text("Fast is several times quicker. You can type tags like [laugh] or [sigh] in narration lines.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        HStack {
                            Button("Play a Sample") { playSample() }.disabled(working != nil || voices.isEmpty)
                            if let w = working { ProgressView().controlSize(.small); Text(w).font(.caption) }
                        }
                    }
                }

                if PareVoice.isInstalled {
                    Section("Voice library") {
                        if voices.isEmpty {
                            Text("No voices yet. Record one, or add one from an audio or video file.")
                                .foregroundStyle(.secondary)
                        }
                        ForEach(voices, id: \.self) { v in voiceRow(v) }
                        HStack {
                            Button("Record a Voice…") { showRecorder = true }
                            Button("Add from File…") { addFromFile() }
                            Spacer()
                            Menu("More") {
                                Button("Import Voices…") { importVoices() }
                                Button("Export Voices…") { exportVoices() }.disabled(voices.isEmpty)
                                Button("Show in Finder") {
                                    try? FileManager.default.createDirectory(at: VoiceLibrary.folder, withIntermediateDirectories: true)
                                    NSWorkspace.shared.open(VoiceLibrary.folder)
                                }
                            }
                            .fixedSize()
                        }
                        Toggle("Remove background music when adding from a file", isOn: $removeMusic)
                        Text("Only clone voices you have permission to use. A clean 10–20 second sample of one person speaking works best.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }

            if let m = message {
                Section { Text(m).font(.callout) }
            }
        }
        .formStyle(.grouped)
        .onAppear { voices = PareVoice.voices }
        .onChange(of: setup.phase) { _, _ in voices = PareVoice.voices }
        .sheet(isPresented: $showRecorder) {
            RecordVoiceSheet { voices = PareVoice.voices; message = $0 }
        }
        .alert("Rename voice", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Name", text: $newName)
            Button("Rename") {
                if let old = renaming {
                    do { try VoiceLibrary.rename(old, to: newName); if voiceName == old { voiceName = VoiceLibrary.safeName(newName) } }
                    catch { message = error.localizedDescription }
                    voices = PareVoice.voices
                }
                renaming = nil
            }
            Button("Cancel", role: .cancel) { renaming = nil }
        }
    }

    @ViewBuilder private var setupRow: some View {
        switch setup.phase {
        case .running(let step):
            HStack { ProgressView().controlSize(.small); Text(step); Spacer(); Button("Stop") { setup.cancel() } }
            Text("Setup downloads and installs everything by itself. It can take 10–20 minutes the first time.")
                .font(.caption).foregroundStyle(.secondary)
        case .failed(let why):
            Text(why).font(.callout).foregroundStyle(.orange)
            Button("Try Again") { setup.run() }
        case .done:
            Label("Pare Voice is set up.", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
        case .idle:
            if PareVoice.isInstalled {
                HStack {
                    Label("Ready on this Mac", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                    Spacer()
                    Button("Repair or Update") { setup.run() }.controlSize(.small)
                }
            } else {
                Text("Pare Voice narrates videos in cloned voices, entirely on this Mac. One click installs everything it needs (a few GB).")
                    .font(.callout).foregroundStyle(.secondary)
                Button("Set Up Pare Voice") { setup.run() }.buttonStyle(.borderedProminent)
            }
        }
    }

    private func voiceRow(_ v: String) -> some View {
        HStack {
            Image(systemName: v == PareVoice.selectedVoice ? "person.wave.2.fill" : "person.wave.2")
                .foregroundStyle(v == PareVoice.selectedVoice ? Color(cgColor: Renderer.accent) : .secondary)
            Text(v)
            Spacer()
            Button { play(VoiceLibrary.url(v)) } label: { Image(systemName: "play.circle") }.help("Play the sample")
            Button { newName = v; renaming = v } label: { Image(systemName: "pencil") }.help("Rename")
            Button { VoiceLibrary.delete(v); voices = PareVoice.voices } label: { Image(systemName: "trash") }.help("Move to Bin")
        }
        .buttonStyle(.borderless)
    }

    private func play(_ url: URL) {
        preview?.stop()
        preview = try? AVAudioPlayer(contentsOf: url)
        preview?.play()
    }

    private func playSample() {
        guard let v = PareVoice.selectedVoice else { return }
        working = "Speaking (the first time loads the voice model)…"
        message = nil
        Task {
            defer { working = nil }
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("pare-voice-sample.wav")
            do {
                _ = try await PareVoice.say("Here's how to shrink a large PDF with Pare. It only takes a few seconds.", voice: v, to: url)
                play(url)
            } catch { message = error.localizedDescription }
        }
    }

    private func addFromFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.audio, .movie, .mpeg4Movie, .quickTimeMovie, .mp3, .wav]
        panel.message = "Choose a recording of one person speaking (audio or video)."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let name = url.deletingPathExtension().lastPathComponent
        working = removeMusic ? "Removing music and adding the voice (a minute or two)…" : "Adding the voice…"
        message = nil
        let clean = removeMusic
        Task {
            defer { working = nil }
            do {
                try await VoiceLibrary.add(from: url, name: name, removeMusic: clean)
                voices = PareVoice.voices
                message = "Added \(VoiceLibrary.safeName(name)). Click ▶ to check it, and the pencil to rename it."
            } catch { message = error.localizedDescription }
        }
    }

    private func exportVoices() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "Pare Voices.zip"
        panel.allowedContentTypes = [.zip]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try VoiceLibrary.exportAll(to: url); NSWorkspace.shared.activateFileViewerSelecting([url]) }
        catch { message = error.localizedDescription }
    }

    private func importVoices() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.zip]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let n = try VoiceLibrary.importAll(from: url)
            voices = PareVoice.voices
            message = n == 0 ? "No new voices in that file." : "Added \(n) voice\(n == 1 ? "" : "s")."
        } catch { message = error.localizedDescription }
    }
}

/// Record a new voice with the microphone, reading a short script.
struct RecordVoiceSheet: View {
    let onDone: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @StateObject private var rec = VoiceRecorder()
    @State private var name = "My voice"
    @State private var error: String?
    @State private var saving = false
    @State private var hasTake = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Record a voice").font(.title2.bold())
            Text("In a quiet room, read this in the voice you want for your videos. Start straight away and keep the same energy.")
                .foregroundStyle(.secondary)
            Text(VoiceRecorder.script)
                .font(.system(size: 18))
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 10).fill(Color.secondary.opacity(0.1)))
            HStack(spacing: 12) {
                Button(rec.recording ? "Stop" : (hasTake ? "Record Again" : "Start Recording")) {
                    if rec.recording { rec.stop(); hasTake = true }
                    else { Task { error = await rec.start() } }
                }
                .buttonStyle(.borderedProminent)
                .tint(rec.recording ? Color.red : nil)
                ProgressView(value: Double(rec.level)).frame(width: 140)
                Text(String(format: "%.0f s", rec.seconds)).monospacedDigit().foregroundStyle(.secondary)
                if hasTake && !rec.recording {
                    Button("Play") { NSSound(contentsOf: rec.file, byReference: true)?.play() }
                }
            }
            if rec.seconds > 0 && rec.seconds < 10 && hasTake {
                Text("Aim for 12–20 seconds.").font(.caption).foregroundStyle(.orange)
            }
            TextField("Name this voice", text: $name)
            if let e = error { Text(e).foregroundStyle(.orange).font(.callout) }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { rec.stop(); dismiss() }
                Button(saving ? "Saving…" : "Save Voice") { save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!hasTake || rec.recording || saving)
            }
        }
        .padding(22)
        .frame(width: 560)
    }

    private func save() {
        saving = true
        Task {
            defer { saving = false }
            do {
                try await VoiceLibrary.add(from: rec.file, name: name, removeMusic: false)
                onDone("Saved \(VoiceLibrary.safeName(name)).")
                dismiss()
            } catch { self.error = error.localizedDescription }
        }
    }
}

// MARK: - Intros & Outros

struct BrandSettings: View {
    @ObservedObject private var store = BrandStore.shared
    @State private var selected: String = Brand.pare.id
    @State private var introPreview: NSImage?
    @State private var outroPreview: NSImage?

    private var current: Brand { store.all.first { $0.id == selected } ?? Brand.pare }

    var body: some View {
        Form {
            Section {
                Picker("Default for new videos", selection: Binding(get: { store.defaultID }, set: { store.defaultID = $0 })) {
                    ForEach(store.all) { Text($0.name).tag($0.id) }
                    Text("None").tag(Brand.noneID)
                }
                Text("Each guide can pick its own in the editor (Narration › Intro & outro).")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Styles") {
                Picker("Edit", selection: $selected) {
                    ForEach(store.all) { Text($0.name + ($0.builtIn ? " (built in)" : "")).tag($0.id) }
                }
                HStack {
                    Button("Add a Style") {
                        var b = Brand(name: "My brand", wordmark: "My brand")
                        b.tagline = "Your tagline here."
                        store.save(b)
                        selected = b.id
                    }
                    Button("Duplicate") {
                        var b = current
                        b.id = UUID().uuidString
                        b.name += " copy"
                        b.builtIn = false
                        b.logo = nil; b.introVideo = nil; b.outroVideo = nil
                        store.save(b)
                        selected = b.id
                    }
                    Spacer()
                    if !current.builtIn {
                        Button("Delete", role: .destructive) { store.delete(current.id); selected = Brand.pare.id }
                    }
                }
            }
            if current.builtIn {
                Section { Text("The Pare PDF style is built in. Use Duplicate to make your own version.").foregroundStyle(.secondary) }
            } else {
                BrandEditor(brand: Binding(get: { current }, set: { store.save($0) }))
            }
            Section("Preview") {
                HStack(spacing: 10) {
                    previewBox(introPreview, "Intro")
                    previewBox(outroPreview, "Outro")
                }
            }
        }
        .formStyle(.grouped)
        .task(id: current) { await renderPreviews() }
    }

    private func previewBox(_ img: NSImage?, _ label: String) -> some View {
        VStack(spacing: 4) {
            Group {
                if let img { Image(nsImage: img).resizable().aspectRatio(16 / 9, contentMode: .fit) }
                else { Rectangle().fill(.quaternary).aspectRatio(16 / 9, contentMode: .fit) }
            }
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.separator))
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
    }

    private func renderPreviews() async {
        let b = current
        if b.introVideo != nil || b.outroVideo != nil {
            // A clip replaces the designed card; show its first frame.
            introPreview = b.introVideo.flatMap { store.fileURL($0) }.flatMap(firstFrame)
            outroPreview = b.outroVideo.flatMap { store.fileURL($0) }.flatMap(firstFrame)
        }
        let logo = store.fileURL(b.logo).flatMap(GuideStore.loadImage)
        let size = CGSize(width: 640, height: 360)
        let i = TutorialVideo.cardPreview(brand: b, logo: logo, intro: true, title: "How to compress a PDF", size: size)
        let o = TutorialVideo.cardPreview(brand: b, logo: logo, intro: false, title: "How to compress a PDF", size: size)
        if b.introVideo == nil { introPreview = i.map { NSImage(cgImage: $0, size: size) } }
        if b.outroVideo == nil { outroPreview = o.map { NSImage(cgImage: $0, size: size) } }
    }

    private func firstFrame(_ url: URL) -> NSImage? {
        let gen = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        gen.appliesPreferredTrackTransform = true
        guard let cg = try? gen.copyCGImage(at: CMTime(seconds: 0.5, preferredTimescale: 600), actualTime: nil) else { return nil }
        return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
    }
}

struct BrandEditor: View {
    @Binding var brand: Brand
    @State private var error: String?

    var body: some View {
        Section("Words") {
            TextField("Style name", text: $brand.name)
            TextField("Wordmark (big name on the intro)", text: $brand.wordmark)
            TextField("Tagline (under the title, and on the outro)", text: $brand.tagline)
            TextField("Website", text: $brand.website)
        }
        Section("Colours") {
            colour("Background", \.background)
            colour("Text", \.text)
            colour("Accent (bar, clicks, highlight)", \.accent)
            colour("Tagline", \.highlight)
        }
        Section("Logo and clips") {
            fileRow("Logo (replaces the wordmark)", name: brand.logo, types: [.png, .jpeg, .heic, .tiff], kind: "logo") { brand.logo = $0 }
            fileRow("Intro clip (replaces the intro card)", name: brand.introVideo, types: [.movie, .mpeg4Movie, .quickTimeMovie], kind: "intro") { brand.introVideo = $0 }
            fileRow("Outro clip (replaces the outro card)", name: brand.outroVideo, types: [.movie, .mpeg4Movie, .quickTimeMovie], kind: "outro") { brand.outroVideo = $0 }
            if let e = error { Text(e).foregroundStyle(.orange).font(.caption) }
            Text("Clips play with their own sound, up to 30 seconds.").font(.caption).foregroundStyle(.secondary)
        }
    }

    private func colour(_ label: String, _ kp: WritableKeyPath<Brand, String>) -> some View {
        ColorPicker(label, selection: Binding(
            get: { Color(hex: brand[keyPath: kp]) },
            set: { brand[keyPath: kp] = NSColor($0).hex }), supportsOpacity: false)
    }

    private func fileRow(_ label: String, name: String?, types: [UTType], kind: String, set: @escaping (String?) -> Void) -> some View {
        HStack {
            Text(label)
            Spacer()
            Text(name == nil ? "None" : "Added").foregroundStyle(.secondary)
            Button(name == nil ? "Choose…" : "Change…") {
                let panel = NSOpenPanel()
                panel.allowedContentTypes = types
                guard panel.runModal() == .OK, let url = panel.url else { return }
                do { set(try BrandStore.shared.importFile(url, for: brand.id, kind: kind)) }
                catch { self.error = error.localizedDescription }
            }
            if name != nil { Button("Remove") { set(nil) } }
        }
    }
}
