// Editor — edit a recorded guide: titles, step wording, order, pictures (blur, crop, highlight),
// AI wording, earlier versions, and export.

import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct StepRef: Identifiable { let id: UUID }

struct GuideEditor: View {
    let guideID: UUID
    @ObservedObject private var store = GuideStore.shared
    @State private var editing: StepRef?
    @State private var busy: String?
    @State private var errorText: String?
    @State private var scanning = false
    @State private var aiTask: Task<Void, Never>?
    @AppStorage("showNarration") private var showNarration = true
    /// 0 Steps, 1 Grid, 2 Script.
    @AppStorage("editorLayout") private var layout = 0
    @AppStorage("captionsOn") private var captionsOn = true
    @AppStorage("captionSize") private var captionSize = 1
    @AppStorage("captionPosition") private var captionPosition = "auto"
    @AppStorage("captionShort") private var captionShort = false
    @State private var picked = Set<UUID>()
    @State private var lastPicked: Int?
    /// Earlier states of this guide, newest last, for the Undo button.
    @State private var undoStack: [(guide: Guide, what: String)] = []
    @State private var undoNote: String?
    @ObservedObject private var brands = BrandStore.shared

    private var guide: Binding<Guide> {
        Binding(get: { store.guide(guideID) ?? Guide(title: "") },
                set: { store.update($0) })
    }

    private func text(_ kp: WritableKeyPath<Guide, String?>) -> Binding<String> {
        Binding(get: { guide.wrappedValue[keyPath: kp] ?? "" },
                set: { v in var g = guide.wrappedValue; g[keyPath: kp] = v.isEmpty ? nil : v; guide.wrappedValue = g })
    }

    private var brandChoice: Binding<String> {
        Binding(get: { guide.wrappedValue.brandID ?? "" },
                set: { v in var g = guide.wrappedValue; g.brandID = v.isEmpty ? nil : v; guide.wrappedValue = g })
    }

    private func stepBinding(_ id: UUID) -> Binding<Step> {
        Binding(get: { guide.wrappedValue.steps.first { $0.id == id } ?? Step(kind: .note, text: "") },
                set: { new in
                    var g = guide.wrappedValue
                    if let i = g.steps.firstIndex(where: { $0.id == id }) { g.steps[i] = new; guide.wrappedValue = g }
                })
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            switch layout {
            case 1: gridView
            case 2: scriptView
            default: listView
            }
            if let note = undoNote {
                HStack {
                    Image(systemName: "arrow.uturn.backward.circle").foregroundStyle(.secondary)
                    Text(note)
                    Spacer()
                    if !undoStack.isEmpty && !note.hasPrefix("Undid") { Button("Undo") { undo() }.buttonStyle(.borderedProminent) }
                    Button { undoNote = nil } label: { Image(systemName: "xmark") }.buttonStyle(.borderless)
                }
                .font(.callout)
                .padding(.horizontal, 16).padding(.vertical, 8)
                .background(.bar)
                .task(id: note) {
                    try? await Task.sleep(nanoseconds: 8_000_000_000)
                    if undoNote == note { undoNote = nil }
                }
            }
            if busy != nil || errorText != nil || scanning { statusBar }
        }
        .toolbar { toolbar }
        .sheet(item: $editing) { ref in
            StepPictureEditor(guideID: guideID, step: stepBinding(ref.id))
        }
        .onReceive(NotificationCenter.default.publisher(for: .autoBlurChanged)) { _ in
            scanning = AutoBlur.scanning.contains(guideID)
        }
        .onAppear {
            scanning = AutoBlur.scanning.contains(guideID)
            if showNarration { PareVoice.warmUp() }   // so the first tutorial export starts quickly
        }
        .onDisappear { aiTask?.cancel() }
    }

    // MARK: Grid: see every step at once and delete several together

    private var gridView: some View {
        let steps = guide.wrappedValue.steps
        return VStack(spacing: 0) {
            HStack(spacing: 10) {
                Text(picked.isEmpty ? "Click steps to select them (Shift-click for a range)" : "\(picked.count) selected")
                    .foregroundStyle(.secondary)
                Spacer()
                Button(picked.count == steps.count && !steps.isEmpty ? "Select None" : "Select All") {
                    picked = picked.count == steps.count ? [] : Set(steps.map(\.id))
                }
                Button(role: .destructive) { deletePicked() } label: {
                    Label(picked.count > 1 ? "Delete \(picked.count) Steps" : "Delete Step", systemImage: "trash")
                }
                .disabled(picked.isEmpty)
            }
            .padding(.horizontal, 16).padding(.vertical, 8)
            Divider()
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 230), spacing: 14)], spacing: 14) {
                    ForEach(Array(steps.enumerated()), id: \.element.id) { i, step in
                        StepTile(guideID: guideID, step: step, number: i + 1, zoom: guide.wrappedValue.zoom,
                                 selected: picked.contains(step.id))
                            .onTapGesture { pick(i, steps) }
                            .contextMenu {
                                Button("Delete Step", role: .destructive) { picked = [step.id]; deletePicked() }
                            }
                    }
                }
                .padding(16)
            }
            .onDeleteCommand { deletePicked() }
        }
        .onChange(of: steps.map(\.id)) { _, ids in picked.formIntersection(ids) }
    }

    /// Call before a change so Undo can bring the guide back.
    private func remember(_ what: String) {
        undoStack.append((guide.wrappedValue, what))
        if undoStack.count > 40 { undoStack.removeFirst() }
    }

    private func undo() {
        guard let last = undoStack.popLast() else { return }
        var g = last.guide
        g.id = guideID
        store.update(g, forceSnapshot: true)
        undoNote = "Undid: \(last.what)"
        picked = []
    }

    private func pick(_ i: Int, _ steps: [Step]) {
        let id = steps[i].id
        if NSEvent.modifierFlags.contains(.shift), let a = lastPicked, a < steps.count {
            for j in min(a, i)...max(a, i) { picked.insert(steps[j].id) }
        } else if picked.contains(id) {
            picked.remove(id)
        } else {
            picked.insert(id)
        }
        lastPicked = i
    }

    private func deletePicked() {
        guard !picked.isEmpty else { return }
        let n = picked.count
        remember(n == 1 ? "delete step" : "delete \(n) steps")
        undoNote = n == 1 ? "Deleted 1 step" : "Deleted \(n) steps"
        var g = guide.wrappedValue
        g.steps.removeAll { picked.contains($0.id) }
        store.update(g, forceSnapshot: true)   // Versions can bring them back
        picked = []
        lastPicked = nil
    }

    private var listView: some View {
            List {
                ForEach(Array(guide.wrappedValue.steps.enumerated()), id: \.element.id) { i, step in
                    StepRow(guideID: guideID, step: stepBinding(step.id), number: i + 1, zoom: guide.wrappedValue.zoom,
                            showNarration: showNarration,
                            onEditPicture: { editing = StepRef(id: step.id) },
                            onDelete: { delete(step.id) },
                            onAI: { writeWithAI(only: step.id) })
                        .listRowSeparator(.hidden)
                        .padding(.vertical, 6)
                }
                .onMove { from, to in
                    remember("move step")
                    var g = guide.wrappedValue
                    g.steps.move(fromOffsets: from, toOffset: to)
                    store.update(g, forceSnapshot: true)
                }
                Button {
                    var g = guide.wrappedValue
                    g.steps.append(Step(kind: .note, text: "Add a note or tip here."))
                    guide.wrappedValue = g
                } label: { Label("Add a text-only step", systemImage: "plus") }
                    .buttonStyle(.borderless)
                    .padding(.vertical, 8)
            }
            .listStyle(.inset)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            TextField("Guide title", text: guide.title)
                .textFieldStyle(.plain)
                .font(.system(size: 24, weight: .bold))
            TextField("Add a one-line summary (optional)", text: guide.summary, axis: .vertical)
                .textFieldStyle(.plain)
                .foregroundStyle(.secondary)
            HStack {
                Picker("Pictures", selection: guide.zoom) {
                    ForEach(Zoom.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 420)
                Spacer()
                Text("\(guide.wrappedValue.steps.count) steps · click text to edit · drag to reorder")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if showNarration || layout == 2 {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 10) {
                        Picker("Intro & outro", selection: brandChoice) {
                            let def = brands.brand(nil)?.name ?? "None"
                            Text("Default (\(def))").tag("")
                            ForEach(brands.all) { Text($0.name).tag($0.id) }
                            Text("None").tag(Brand.noneID)
                        }
                        .frame(maxWidth: 320)
                        SettingsLink { Text("Edit…") }.controlSize(.small)
                        Spacer()
                        Label(Narrator.summary, systemImage: "waveform").font(.caption).foregroundStyle(.secondary)
                    }
                    if layout != 2 {
                        NarrationField(label: "Intro", text: text(\.introNarration),
                                       placeholder: "Spoken over the intro. Leave blank to read the title.")
                        NarrationField(label: "Outro", text: text(\.outroNarration),
                                       placeholder: "Spoken over the closing card (optional).")
                    }
                }
                .padding(.top, 4)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    private var statusBar: some View {
        HStack(spacing: 8) {
            if busy != nil || scanning { ProgressView().controlSize(.small) }
            if let b = busy { Text(b) } else if scanning { Text("Checking screenshots for private details…") }
            if let e = errorText {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                Text(e).lineLimit(2)
            }
            Spacer()
            if aiTask != nil { Button("Stop") { aiTask?.cancel() } }
            if errorText != nil { Button("Dismiss") { errorText = nil } }
        }
        .font(.callout)
        .padding(.horizontal, 16).padding(.vertical, 8)
        .background(.bar)
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem {
            Picker("Layout", selection: $layout) {
                Text("Steps").tag(0)
                Text("Grid").tag(1)
                Text("Script").tag(2)
            }
            .pickerStyle(.segmented)
            .frame(width: 210)
            .help("Steps: edit each step · Grid: see them all and delete several · Script: write and hear the voiceover")
        }
        ToolbarItem {
            Button { undo() } label: { Label("Undo", systemImage: "arrow.uturn.backward") }
                .disabled(undoStack.isEmpty)
                .help(undoStack.last.map { "Undo \($0.what)" } ?? "Nothing to undo")
        }
        ToolbarItemGroup {
            Menu {
                Button("Write Every Step") { writeWithAI(only: nil) }
                Button("Write Title and Summary") { writeTitle() }
                Button("Write Narration Script") { writeNarration() }
                Button("Polish My Spoken Narration") { polishSpoken() }
                    .help("Tidies what you said while recording into clean voiceover lines")
                Divider()
                SettingsLink { Text("AI Settings…") }
            } label: { Label("Write with AI", systemImage: "sparkles") }
                .disabled(busy != nil)
                .help("Uses your Claude subscription, Apple Intelligence or an API key (Settings › AI)")

            Toggle(isOn: $showNarration) { Label("Narration", systemImage: "waveform") }
                .help("Show the narration lines used in tutorial videos")

            Button { AutoBlur.scan(guideID: guideID, force: true) } label: {
                Label("Blur Private Details", systemImage: "eye.slash")
            }
            .help("Find emails, phone and card numbers in every screenshot and blur them")

            Menu {
                let versions = store.versions(guideID)
                if versions.isEmpty { Text("No earlier versions yet") }
                ForEach(versions.prefix(25)) { v in
                    Button(v.date.formatted(date: .abbreviated, time: .standard)) { store.restore(v, into: guideID) }
                }
            } label: { Label("Versions", systemImage: "clock.arrow.circlepath") }
                .help("Roll back to an earlier version of this guide")

            Menu {
                Button("Tutorial Video (.mp4)") { export(.tutorial, narrate: true) }
                Menu("Captions") {
                    Toggle("Show Captions", isOn: $captionsOn)
                    Divider()
                    Picker("Size", selection: $captionSize) {
                        Text("Small").tag(0); Text("Medium").tag(1); Text("Large").tag(2)
                    }
                    Picker("Position", selection: $captionPosition) {
                        Text("Auto (moves away from the click)").tag("auto")
                        Text("Bottom").tag("bottom")
                        Text("Top").tag("top")
                    }
                    Toggle("Short Captions (one line)", isOn: $captionShort)
                }
                Divider()
                ForEach(ExportFormat.allCases.filter { $0 != .tutorial }) { f in
                    Button(f.rawValue) { export(f, narrate: false) }
                    if f == .mp4 { Button("Simple slideshow with Mac narration (.mp4)") { export(.mp4, narrate: true) } }
                }
            } label: { Label("Export", systemImage: "square.and.arrow.up") }
                .disabled(busy != nil || guide.wrappedValue.steps.isEmpty)
        }
    }

    // MARK: Actions

    private func delete(_ id: UUID) {
        remember("delete step")
        undoNote = "Deleted 1 step"
        var g = guide.wrappedValue
        g.steps.removeAll { $0.id == id }
        store.update(g, forceSnapshot: true)
    }

    private func writeWithAI(only: UUID?) {
        guard AI.isReady else { errorText = AI.notReadyMessage; return }
        let g = guide.wrappedValue
        remember("AI step wording")
        store.update(g, forceSnapshot: true)
        let targets = g.steps.enumerated().filter { (only == nil || $0.element.id == only) && $0.element.image != nil }
        guard !targets.isEmpty else { return }
        errorText = nil
        aiTask = Task {
            defer { busy = nil; aiTask = nil }
            // Claude Code reads several screenshots per request; the others go one at a time.
            let chunk = AI.provider == .claudeCode ? 8 : 1
            var i = 0
            while i < targets.count {
                if Task.isCancelled { return }
                let slice = Array(targets[i..<min(i + chunk, targets.count)])
                busy = targets.count == 1 ? "Writing step \(slice[0].offset + 1)…"
                    : "Writing steps \(i + 1)–\(i + slice.count) of \(targets.count)…"
                let zoom = g.zoom
                let inputs = slice.map { ($0.offset + 1, $0.element, $0.element.image.map { store.imageURL(guideID, $0) }) }
                let jobs: [AIJob] = await Task.detached {
                    inputs.compactMap { n, s, url -> AIJob? in
                        guard let pic = url.flatMap(GuideStore.loadImage)
                            .flatMap({ Renderer.render(s, base: $0, zoom: zoom, maxWidth: 1600) }) else { return nil }
                        return AIJob(number: n, step: s, picture: pic)
                    }
                }.value
                do {
                    let texts = try await AI.write(jobs)
                    for (id, t) in texts where !t.isEmpty {
                        let b = stepBinding(id)
                        b.wrappedValue.text = t
                    }
                    if let note = AI.lastNote { errorText = note }
                } catch {
                    if !Task.isCancelled { errorText = error.localizedDescription }
                    return
                }
                i += chunk
            }
        }
    }

    private func writeTitle() {
        guard AI.isReady else { errorText = AI.notReadyMessage; return }
        remember("AI title")
        busy = "Writing title…"
        errorText = nil
        Task {
            defer { busy = nil }
            do {
                let (t, s) = try await AI.titleAndSummary(guide.wrappedValue)
                var g = guide.wrappedValue
                g.title = t
                g.summary = s
                store.update(g, forceSnapshot: true)
            } catch { errorText = error.localizedDescription }
        }
    }

    private func writeNarration() {
        guard AI.isReady else { errorText = AI.notReadyMessage; return }
        busy = "Writing the narration script…"
        errorText = nil
        let g = guide.wrappedValue
        remember("AI narration")
        store.update(g, forceSnapshot: true)
        let brand = brands.brand(g.brandID)
        aiTask = Task {
            defer { busy = nil; aiTask = nil }
            do {
                let script = try await AI.narration(g, brand: brand)
                var now = guide.wrappedValue
                if !script.intro.isEmpty { now.introNarration = script.intro }
                if !script.outro.isEmpty { now.outroNarration = script.outro }
                for i in now.steps.indices { if let l = script.steps[now.steps[i].id] { now.steps[i].narration = l } }
                store.update(now, forceSnapshot: true)
                showNarration = true
            } catch {
                if !Task.isCancelled { errorText = error.localizedDescription }
            }
        }
    }

    private func polishSpoken() {
        guard AI.isReady else { errorText = AI.notReadyMessage; return }
        busy = "Polishing your narration…"
        errorText = nil
        let g = guide.wrappedValue
        remember("AI narration polish")
        aiTask = Task {
            defer { busy = nil; aiTask = nil }
            do {
                let lines = try await AI.polishSpoken(g)
                var now = guide.wrappedValue
                for i in now.steps.indices { if let l = lines[now.steps[i].id] { now.steps[i].narration = l } }
                store.update(now, forceSnapshot: true)
                showNarration = true
                layout = 2
            } catch {
                if !Task.isCancelled { errorText = error.localizedDescription }
            }
        }
    }

    // MARK: Script: the whole voiceover in one place

    private var scriptView: some View {
        let g = guide.wrappedValue
        let total = Narrator.estimate(g.introNarration ?? g.title)
            + g.steps.reduce(0) { $0 + Narrator.estimate(($1.narration ?? "").isEmpty ? $1.text : $1.narration!) }
            + Narrator.estimate(g.outroNarration ?? "")
        return VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "waveform").foregroundStyle(Color(cgColor: Renderer.accent))
                Text("Voiceover script").font(.headline)
                Text("about \(Self.duration(total)) of speaking").foregroundStyle(.secondary)
                Spacer()
                Text("Press ▶ Play to hear a line. Blank lines read the step text.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 20).padding(.vertical, 10)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    scriptRow(badge: "Intro", picture: nil) {
                        NarrationField(label: nil, text: text(\.introNarration),
                                       placeholder: g.title.plain.isEmpty ? "Spoken over the intro" : g.title.plain,
                                       context: g.title.plain, full: true,
                                       beforeRewrite: { remember("rewrite"); undoNote = "Line rewritten" })
                    }
                    ForEach(Array(g.steps.enumerated()), id: \.element.id) { i, step in
                        scriptRow(badge: "\(i + 1)", picture: step) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(step.text.plain.isEmpty ? "(no step text)" : step.text.plain)
                                    .font(.caption).foregroundStyle(.secondary).lineLimit(2)
                                NarrationField(label: nil,
                                               text: Binding(get: { stepBinding(step.id).wrappedValue.narration ?? "" },
                                                             set: { v in stepBinding(step.id).wrappedValue.narration = v.isEmpty ? nil : v }),
                                               placeholder: step.text.plain.isEmpty ? "What the narrator says" : step.text.plain,
                                               context: g.title.plain, full: true,
                                       beforeRewrite: { remember("rewrite"); undoNote = "Line rewritten" })
                            }
                        }
                    }
                    scriptRow(badge: "Outro", picture: nil) {
                        NarrationField(label: nil, text: text(\.outroNarration),
                                       placeholder: "Spoken over the closing card (optional)",
                                       context: g.title.plain, full: true,
                                       beforeRewrite: { remember("rewrite"); undoNote = "Line rewritten" })
                    }
                }
                .padding(20)
            }
        }
        .onDisappear { NarrationPlayer.shared.stop() }
    }

    private func scriptRow<C: View>(badge: String, picture: Step?, @ViewBuilder content: () -> C) -> some View {
        HStack(alignment: .top, spacing: 14) {
            ZStack(alignment: .topLeading) {
                if let step = picture, step.image != nil {
                    StepPicture(guideID: guideID, step: step, zoom: guide.wrappedValue.zoom, maxWidth: 320)
                        .aspectRatio(16 / 10, contentMode: .fit)
                } else {
                    RoundedRectangle(cornerRadius: 6).fill(Color.secondary.opacity(0.12))
                        .aspectRatio(16 / 10, contentMode: .fit)
                        .overlay(Image(systemName: picture == nil ? "film" : "text.alignleft").foregroundStyle(.secondary))
                }
                Text(badge)
                    .font(.system(size: 11, weight: .bold)).foregroundStyle(.white)
                    .padding(.horizontal, 7).frame(minWidth: 22, minHeight: 22)
                    .background(Capsule().fill(Color(cgColor: Renderer.accent)))
                    .padding(5)
            }
            .frame(width: 150)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            content()
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    static func duration(_ s: Double) -> String {
        let t = Int(s.rounded())
        return t < 60 ? "\(t) sec" : "\(t / 60) min \(t % 60) sec"
    }

    private func export(_ format: ExportFormat, narrate: Bool) {
        let g = guide.wrappedValue
        let panel = NSSavePanel()
        panel.canCreateDirectories = true
        if format == .markdown {
            panel.nameFieldStringValue = Exporter.safeName(g.title)
            panel.message = "Pare Guide makes a folder with the Markdown file and its images."
        } else {
            panel.nameFieldStringValue = Exporter.safeName(g.title) + "." + format.ext
            panel.allowedContentTypes = [UTType(filenameExtension: format.ext) ?? .data]
        }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        busy = "Exporting…"
        errorText = nil
        Task {
            defer { busy = nil }
            do {
                try await Exporter.run(format, guide: g, to: url, narrate: narrate) { msg in
                    Task { @MainActor in if busy != nil { busy = msg } }
                }
                let shown = format == .markdown ? url.deletingPathExtension() : url
                NSWorkspace.shared.activateFileViewerSelecting([shown])
            } catch {
                errorText = "Export failed: \(error.localizedDescription)"
            }
        }
    }
}

// MARK: - One step in the list

struct StepRow: View {
    let guideID: UUID
    @Binding var step: Step
    let number: Int
    let zoom: Zoom
    var showNarration = false
    let onEditPicture: () -> Void
    let onDelete: () -> Void
    let onAI: () -> Void
    @State private var hovering = false
    @State private var isEditing = false
    @FocusState private var focused: Bool

    /// The step text with **bold** shown as bold.
    private var rendered: AttributedString {
        guard !step.text.trimmed.isEmpty else {
            var a = AttributedString("Describe this step")
            a.foregroundColor = .secondary
            return a
        }
        var out = AttributedString()
        for part in step.text.boldParts {
            var a = AttributedString(part.text)
            if part.bold { a.font = .system(size: 15, weight: .semibold) }
            out += a
        }
        return out
    }

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Text("\(number)")
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 26, height: 26)
                .background(Circle().fill(Color(cgColor: Renderer.accent)))
            VStack(alignment: .leading, spacing: 8) {
                if isEditing {
                    TextField("Describe this step", text: $step.text, axis: .vertical)
                        .textFieldStyle(.plain)
                        .font(.system(size: 15))
                        .focused($focused)
                        .onSubmit { isEditing = false }
                        .onChange(of: focused) { _, now in if !now { isEditing = false } }
                } else {
                    Text(rendered)
                        .font(.system(size: 15))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            isEditing = true
                            DispatchQueue.main.async { focused = true }
                        }
                        .help("Click to edit. Put **double asterisks** around words to make them bold.")
                }
                if showNarration {
                    NarrationField(label: nil,
                                   text: Binding(get: { step.narration ?? "" },
                                                 set: { step.narration = $0.isEmpty ? nil : $0 }),
                                   placeholder: step.text.plain.isEmpty ? "What the narrator says" : step.text.plain)
                }
                if !step.appName.isEmpty {
                    Text([step.appName, step.windowTitle].filter { !$0.isEmpty }.joined(separator: " — "))
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                if step.image != nil {
                    StepPicture(guideID: guideID, step: step, zoom: zoom, maxWidth: 1100)
                        .frame(maxWidth: 640, alignment: .leading)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.separator))
                        .onTapGesture(perform: onEditPicture)
                        .help("Click to blur, crop or move the highlight")
                }
            }
            Spacer(minLength: 0)
            VStack(spacing: 6) {
                if step.image != nil {
                    Button(action: onEditPicture) { Image(systemName: "crop") }.help("Edit picture")
                    Button(action: onAI) { Image(systemName: "sparkles") }.help("Write this step with AI")
                }
                Button(action: onDelete) { Image(systemName: "trash") }.help("Delete step")
            }
            .buttonStyle(.borderless)
            .opacity(hovering ? 1 : 0.35)
        }
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
    }
}

/// The finished picture for a step, rendered in the background.
struct StepPicture: View {
    let guideID: UUID
    let step: Step
    let zoom: Zoom
    var maxWidth = 1100
    @State private var image: NSImage?

    private var key: String {
        "\(step.image ?? "")|\(step.blurs)|\(String(describing: step.crop))|\(String(describing: step.highlight))|\(step.showHighlight)|\(zoom.rawValue)"
    }

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fit)
            } else {
                Rectangle().fill(.quaternary).aspectRatio(16 / 10, contentMode: .fit)
                    .overlay(ProgressView().controlSize(.small))
            }
        }
        .task(id: key) {
            guard let name = step.image else { return }
            let url = GuideStore.shared.imageURL(guideID, name)
            let s = step, z = zoom, m = maxWidth
            let cg = await Task.detached(priority: .userInitiated) {
                GuideStore.loadImage(url).flatMap { Renderer.render(s, base: $0, zoom: z, maxWidth: m) }
            }.value
            if let cg { image = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height)) }
        }
    }
}

// MARK: - Picture editor (blur, crop, highlight)

struct StepPictureEditor: View {
    let guideID: UUID
    @Binding var step: Step
    @Environment(\.dismiss) private var dismiss

    enum Tool: String, CaseIterable, Identifiable {
        case blur = "Blur", crop = "Crop", highlight = "Highlight"
        var id: String { rawValue }
        var help: String {
            switch self {
            case .blur: return "Drag over anything private. Click a blur box to remove it."
            case .crop: return "Drag to choose the part of the screen to show."
            case .highlight: return "Drag a box around the thing to click."
            }
        }
    }

    @State private var draft = Step(kind: .note, text: "")
    @State private var tool: Tool = .blur
    @State private var preview: NSImage?
    @State private var pixelSize = CGSize(width: 16, height: 10)
    @State private var dragStart: CGPoint?
    @State private var dragNow: CGPoint?
    @State private var detecting = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 14) {
                Picker("Tool", selection: $tool) {
                    ForEach(Tool.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 280)
                Text(tool.help).font(.callout).foregroundStyle(.secondary)
                Spacer()
            }
            .padding(12)

            GeometryReader { geo in
                let fit = fitted(pixelSize, in: geo.size)
                let s = fit.width > 0 ? pixelSize.width / fit.width : 1
                ZStack(alignment: .topLeading) {
                    if let preview {
                        Image(nsImage: preview).resizable().frame(width: fit.width, height: fit.height)
                    } else {
                        Rectangle().fill(.quaternary).frame(width: fit.width, height: fit.height).overlay(ProgressView())
                    }
                    // Crop: dim everything outside.
                    if let c = draft.crop {
                        let r = view(c, s)
                        Path { p in
                            p.addRect(CGRect(origin: .zero, size: fit))
                            p.addRect(r)
                        }
                        .fill(Color.black.opacity(0.5), style: FillStyle(eoFill: true))
                        Rectangle().strokeBorder(Color.white, lineWidth: 2)
                            .frame(width: r.width, height: r.height).offset(x: r.minX, y: r.minY)
                    }
                    ForEach(Array(draft.blurs.enumerated()), id: \.offset) { _, b in
                        let r = view(b, s)
                        Rectangle().strokeBorder(Color.blue, style: StrokeStyle(lineWidth: 1.5, dash: [5, 3]))
                            .frame(width: r.width, height: r.height).offset(x: r.minX, y: r.minY)
                    }
                    if let a = dragStart, let b = dragNow {
                        let r = rect(a, b)
                        Rectangle().strokeBorder(tool == .blur ? Color.blue : tool == .crop ? Color.white : Color(cgColor: Renderer.accent),
                                                 style: StrokeStyle(lineWidth: 2, dash: [6, 3]))
                            .background(Color.white.opacity(0.08))
                            .frame(width: r.width, height: r.height).offset(x: r.minX, y: r.minY)
                    }
                }
                .frame(width: fit.width, height: fit.height)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { v in
                            dragStart = clamp(v.startLocation, fit)
                            dragNow = clamp(v.location, fit)
                        }
                        .onEnded { v in
                            let a = clamp(v.startLocation, fit), b = clamp(v.location, fit)
                            dragStart = nil
                            dragNow = nil
                            finishDrag(a, b, scale: s)
                        }
                )
                .position(x: geo.size.width / 2, y: geo.size.height / 2)
            }
            .padding(.horizontal, 12)

            HStack {
                Toggle("Show highlight", isOn: $draft.showHighlight)
                Button("Remove all blurs") { draft.blurs = [] }.disabled(draft.blurs.isEmpty)
                Button("Find private details") { detect() }.disabled(detecting)
                if detecting { ProgressView().controlSize(.small) }
                Button("Reset crop") { draft.crop = nil }.disabled(draft.crop == nil)
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Done") { step = draft; dismiss() }.keyboardShortcut(.defaultAction)
            }
            .padding(12)
        }
        .frame(minWidth: 980, idealWidth: 1200, minHeight: 680, idealHeight: 820)
        .onAppear { draft = step }
        .task(id: previewKey) { await renderPreview() }
    }

    private var previewKey: String { "\(draft.blurs)|\(String(describing: draft.highlight))|\(draft.showHighlight)|\(draft.image ?? "")" }

    private func renderPreview() async {
        guard let name = draft.image else { return }
        let url = GuideStore.shared.imageURL(guideID, name)
        var s = draft
        s.crop = nil
        let st = s
        let result = await Task.detached(priority: .userInitiated) { () -> (CGImage, CGSize)? in
            guard let base = GuideStore.loadImage(url),
                  let out = Renderer.render(st, base: base, zoom: .off, maxWidth: 2400) else { return nil }
            return (out, CGSize(width: base.width, height: base.height))
        }.value
        if let r = result {
            pixelSize = r.1
            preview = NSImage(cgImage: r.0, size: NSSize(width: r.0.width, height: r.0.height))
        }
    }

    private func detect() {
        guard let name = draft.image else { return }
        let url = GuideStore.shared.imageURL(guideID, name)
        detecting = true
        Task {
            let found = await Task.detached { GuideStore.loadImage(url).map(Sensitive.find) ?? [] }.value
            for r in found where !draft.blurs.contains(where: { $0.contains(CGPoint(x: r.midX, y: r.midY)) }) {
                draft.blurs.append(r)
            }
            detecting = false
        }
    }

    private func finishDrag(_ a: CGPoint, _ b: CGPoint, scale s: CGFloat) {
        let r = rect(a, b)
        let px = CGRect(x: r.minX * s, y: r.minY * s, width: r.width * s, height: r.height * s)
        let isClick = r.width < 4 && r.height < 4
        switch tool {
        case .blur:
            if isClick {
                let p = CGPoint(x: a.x * s, y: a.y * s)
                if let i = draft.blurs.lastIndex(where: { $0.contains(p) }) { draft.blurs.remove(at: i) }
            } else { draft.blurs.append(px) }
        case .crop:
            if !isClick { draft.crop = px }
        case .highlight:
            if isClick {
                draft.clickPoint = CGPoint(x: a.x * s, y: a.y * s)
            } else {
                draft.highlight = px
                draft.clickPoint = CGPoint(x: px.midX, y: px.midY)
            }
            draft.showHighlight = true
        }
    }

    private func fitted(_ size: CGSize, in box: CGSize) -> CGSize {
        guard size.width > 0, size.height > 0 else { return .zero }
        let k = min(box.width / size.width, box.height / size.height)
        return CGSize(width: size.width * k, height: size.height * k)
    }

    private func view(_ r: CGRect, _ s: CGFloat) -> CGRect {
        CGRect(x: r.minX / s, y: r.minY / s, width: r.width / s, height: r.height / s)
    }

    private func rect(_ a: CGPoint, _ b: CGPoint) -> CGRect {
        CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y))
    }

    private func clamp(_ p: CGPoint, _ size: CGSize) -> CGPoint {
        CGPoint(x: min(max(0, p.x), size.width), y: min(max(0, p.y), size.height))
    }
}


/// One line of narration: what the narrator says. Blank uses the placeholder (the step text).
/// `full` (Script view) adds the length, ▶ Play and Rewrite; otherwise just a compact ▶ Play.
struct NarrationField: View {
    let label: String?
    @Binding var text: String
    let placeholder: String
    var context: String = ""
    var full = false
    /// Called just before a rewrite replaces the line, so Undo can bring it back.
    var beforeRewrite: () -> Void = {}
    @ObservedObject private var player = NarrationPlayer.shared
    @State private var rewriting = false
    @State private var problem: String?

    private var spoken: String { text.trimmed.isEmpty ? placeholder : text }
    private var seconds: Double { Narrator.estimate(spoken) }

    var body: some View {
        if full { big } else { compact }
    }

    private var compact: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: "waveform").foregroundStyle(Color(cgColor: Renderer.accent)).font(.caption)
            if let label { Text(label).font(.caption.weight(.semibold)).foregroundStyle(.secondary).frame(width: 40, alignment: .leading) }
            TextField(placeholder, text: $text, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.callout)
                .foregroundStyle(.secondary)
            playButton(small: true)
        }
        .padding(.horizontal, 8).padding(.vertical, 5)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.secondary.opacity(0.08)))
        .help("What the narrator says in tutorial videos. Leave blank to read the step text.")
    }

    private var big: some View {
        VStack(alignment: .leading, spacing: 6) {
            TextField(placeholder, text: $text, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.system(size: 15))
                .lineLimit(2...6)
                .padding(10)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .textBackgroundColor)))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.separator))
            HStack(spacing: 10) {
                playButton(small: false)
                Menu {
                    Button("Shorter") { rewrite("shorter and punchier") }
                    Button("Friendlier") { rewrite("warmer and friendlier") }
                    Button("More formal") { rewrite("more formal and professional") }
                    Button("Fix wording") { rewrite("clearer, with grammar and wording fixed") }
                } label: { Label("Rewrite", systemImage: "sparkles") }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                    .disabled(rewriting || spoken.trimmed.isEmpty)
                    .help("Ask the AI to rewrite this line")
                if rewriting { ProgressView().controlSize(.small); Text("Rewriting…").font(.caption).foregroundStyle(.secondary) }
                Spacer()
                if seconds > 0 {
                    Label("\(Int(seconds.rounded())) sec", systemImage: seconds > 12 ? "exclamationmark.triangle.fill" : "clock")
                        .font(.caption)
                        .foregroundStyle(seconds > 12 ? Color.orange : Color.secondary)
                        .help(seconds > 12 ? "A long line — the step will stay on screen a while. Try Rewrite › Shorter."
                                           : "About how long this line takes to say")
                }
            }
            if let problem {
                Text(problem).font(.caption).foregroundStyle(.red)
            }
        }
    }

    @ViewBuilder private func playButton(small: Bool) -> some View {
        let busy = player.preparing == spoken
        let on = player.playing == spoken
        Button {
            problem = nil
            let line = spoken
            Task {
                do { try await player.toggle(line) }
                catch { problem = "Couldn't play: \(error.localizedDescription)" }
            }
        } label: {
            if small {
                Image(systemName: busy ? "hourglass" : on ? "stop.fill" : "play.fill")
            } else {
                Label(busy ? "Preparing…" : on ? "Stop" : "Play",
                      systemImage: busy ? "hourglass" : on ? "stop.fill" : "play.fill")
            }
        }
        .buttonStyle(small ? AnyButtonStyle(.borderless) : AnyButtonStyle(.bordered))
        .disabled(spoken.trimmed.isEmpty)
        .help(on ? "Stop" : "Hear this line in your chosen voice")
    }

    private func rewrite(_ how: String) {
        guard AI.isReady else { problem = AI.notReadyMessage; return }
        problem = nil
        rewriting = true
        let line = spoken
        Task {
            defer { rewriting = false }
            do {
                let new = try await AI.rewriteLine(line, how: how, title: context)
                beforeRewrite()
                text = new
            }
            catch { problem = error.localizedDescription }
        }
    }
}

/// Lets one button switch between borderless and bordered.
struct AnyButtonStyle: PrimitiveButtonStyle {
    private let make: (Configuration) -> AnyView
    init<S: PrimitiveButtonStyle>(_ s: S) { make = { AnyView(s.makeBody(configuration: $0)) } }
    func makeBody(configuration: Configuration) -> some View { make(configuration) }
}


/// One step as a thumbnail in the grid.
struct StepTile: View {
    let guideID: UUID
    let step: Step
    let number: Int
    let zoom: Zoom
    let selected: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ZStack(alignment: .topLeading) {
                if step.image != nil {
                    StepPicture(guideID: guideID, step: step, zoom: zoom, maxWidth: 520)
                        .aspectRatio(16 / 10, contentMode: .fit)
                } else {
                    RoundedRectangle(cornerRadius: 6).fill(.quaternary).aspectRatio(16 / 10, contentMode: .fit)
                        .overlay(Image(systemName: "text.alignleft").foregroundStyle(.secondary))
                }
                Text("\(number)")
                    .font(.system(size: 12, weight: .bold)).foregroundStyle(.white)
                    .frame(width: 24, height: 24)
                    .background(Circle().fill(Color(cgColor: Renderer.accent)))
                    .padding(6)
            }
            .overlay(alignment: .topTrailing) {
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 20))
                    .foregroundStyle(selected ? Color.accentColor : Color.white)
                    .shadow(radius: 2)
                    .padding(6)
            }
            .clipShape(RoundedRectangle(cornerRadius: 6))
            Text(step.text.plain.isEmpty ? "(no text)" : step.text.plain)
                .font(.callout).lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
            if !step.appName.isEmpty {
                Text(step.appName).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 10).fill(selected ? Color.accentColor.opacity(0.14) : Color.secondary.opacity(0.06)))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(selected ? Color.accentColor : .clear, lineWidth: 2))
        .contentShape(Rectangle())
    }
}
