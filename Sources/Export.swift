// Export — HTML, Markdown, PDF, Word (.docx) and a shareable .pareguide file.
// Everything is made on your Mac; nothing is uploaded.

import AppKit
import UniformTypeIdentifiers

enum ExportFormat: String, CaseIterable, Identifiable {
    case pdf = "PDF"
    case docx = "Word (.docx)"
    case html = "Web page (.html)"
    case markdown = "Markdown"
    case tutorial = "Tutorial video (.mp4)"
    case mp4 = "Simple slideshow video (.mp4)"
    case gif = "GIF"
    case bundle = "Pare Guide file (to share)"
    var id: String { rawValue }
    var ext: String {
        switch self {
        case .pdf: return "pdf"
        case .docx: return "docx"
        case .html: return "html"
        case .markdown: return "md"
        case .mp4, .tutorial: return "mp4"
        case .gif: return "gif"
        case .bundle: return "pareguide"
        }
    }
}

struct ExportItem {
    let number: Int
    let text: String
    let image: CGImage?
    var png: Data? { image.flatMap(Renderer.png) }
}

enum Exporter {
    /// Renders every step's picture (in the background).
    static func prepare(_ guide: Guide, store: GuideStore, maxWidth: Int) async -> [ExportItem] {
        let jobs: [(Int, Step, URL?)] = await MainActor.run {
            guide.steps.enumerated().map { (i, s) in (i + 1, s, s.image.map { store.imageURL(guide.id, $0) }) }
        }
        let zoom = guide.zoom
        return await Task.detached(priority: .userInitiated) {
            jobs.map { (n, s, url) in
                let img = url.flatMap(GuideStore.loadImage).flatMap { Renderer.render(s, base: $0, zoom: zoom, maxWidth: maxWidth) }
                return ExportItem(number: n, text: s.text, image: img)
            }
        }.value
    }

    static func run(_ format: ExportFormat, guide: Guide, to url: URL, narrate: Bool = false,
                    progress: @escaping (String) -> Void) async throws {
        let store = await MainActor.run { GuideStore.shared }
        switch format {
        case .bundle:
            let folder = await MainActor.run { store.folder(guide.id) }
            try bundle(folder: folder, to: url)
            return
        case .tutorial:
            try await TutorialVideo.make(guide: guide, to: url, progress: progress)
            return
        case .mp4:
            progress("Rendering steps…")
            let items = await prepare(guide, store: store, maxWidth: 1920)
            try await VideoMaker.mp4(guide: guide, items: items, narrate: narrate, to: url, progress: progress)
            return
        case .gif:
            progress("Rendering steps…")
            let items = await prepare(guide, store: store, maxWidth: 1600)
            try VideoMaker.gif(guide: guide, items: items, to: url)
            return
        default: break
        }
        progress("Rendering steps…")
        let items = await prepare(guide, store: store, maxWidth: 1600)
        progress("Writing \(format.rawValue)…")
        try await Task.detached(priority: .userInitiated) {
            switch format {
            case .html: try html(guide, items).write(to: url, atomically: true, encoding: .utf8)
            case .markdown: try markdown(guide, items, to: url)
            case .pdf: try pdf(guide, items, to: url)
            case .docx: try docx(guide, items, to: url)
            default: break
            }
        }.value
    }

    // MARK: HTML

    static func esc(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
    }

    /// **bold** → <strong>bold</strong>
    static func htmlInline(_ s: String) -> String {
        s.boldParts.map { $0.bold ? "<strong>\(esc($0.text))</strong>" : esc($0.text) }.joined()
    }

    static func html(_ g: Guide, _ items: [ExportItem]) -> String {
        var steps = ""
        for it in items {
            var img = ""
            if let d = it.png { img = "<img src=\"data:image/png;base64,\(d.base64EncodedString())\" alt=\"Step \(it.number)\">" }
            steps += "<li class=\"step\"><div class=\"text\"><span class=\"n\">\(it.number)</span><p>\(htmlInline(it.text))</p></div>\(img)</li>\n"
        }
        return """
        <!DOCTYPE html>
        <html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
        <title>\(esc(g.title))</title>
        <style>
        :root{color-scheme:light dark;--fg:#1d1d1f;--muted:#6e6e73;--bg:#fff;--card:#f5f5f7;--accent:#ff5440}
        @media (prefers-color-scheme:dark){:root{--fg:#f5f5f7;--muted:#a1a1a6;--bg:#111;--card:#1c1c1e}}
        body{margin:0;background:var(--bg);color:var(--fg);font:17px/1.5 -apple-system,BlinkMacSystemFont,"Segoe UI",Roboto,sans-serif}
        main{max-width:960px;margin:0 auto;padding:48px 24px 80px}
        h1{font-size:34px;line-height:1.15;margin:0 0 8px;letter-spacing:-.02em}
        .summary{color:var(--muted);margin:0 0 8px;font-size:19px}
        .meta{color:var(--muted);font-size:14px;margin-bottom:40px}
        ol{list-style:none;padding:0;margin:0}
        .step{background:var(--card);border-radius:16px;padding:20px;margin:0 0 24px}
        .text{display:flex;gap:14px;align-items:flex-start;margin-bottom:14px}
        .text p{margin:3px 0 0}
        .n{flex:none;width:30px;height:30px;border-radius:50%;background:var(--accent);color:#fff;font-weight:600;display:grid;place-items:center;font-size:15px}
        img{display:block;width:100%;height:auto;border-radius:10px;border:1px solid rgba(127,127,127,.25)}
        footer{color:var(--muted);font-size:13px;margin-top:40px;text-align:center}
        @media print{.step{break-inside:avoid;background:none;border:1px solid #ddd}}
        </style></head><body><main>
        <h1>\(esc(g.title))</h1>
        \(g.summary.isEmpty ? "" : "<p class=\"summary\">\(htmlInline(g.summary))</p>")
        <div class="meta">\(items.count) steps</div>
        <ol>
        \(steps)</ol>
        <footer>Made with Pare Guide</footer>
        </main></body></html>
        """
    }

    // MARK: Markdown (a folder with guide.md and images/)

    static func markdown(_ g: Guide, _ items: [ExportItem], to url: URL) throws {
        let fm = FileManager.default
        let folder = url.deletingPathExtension()
        try? fm.removeItem(at: folder)
        try fm.createDirectory(at: folder.appendingPathComponent("images"), withIntermediateDirectories: true)
        var md = "# \(g.title)\n\n"
        if !g.summary.isEmpty { md += "\(g.summary)\n\n" }
        for it in items {
            md += "## Step \(it.number)\n\n\(it.text)\n\n"
            if let d = it.png {
                let name = String(format: "step-%02d.png", it.number)
                try d.write(to: folder.appendingPathComponent("images/\(name)"))
                md += "![Step \(it.number)](images/\(name))\n\n"
            }
        }
        try md.write(to: folder.appendingPathComponent("\(safeName(g.title)).md"), atomically: true, encoding: .utf8)
    }

    static func safeName(_ s: String) -> String {
        let bad = CharacterSet(charactersIn: "/\\:?%*|\"<>")
        let t = s.components(separatedBy: bad).joined(separator: "-").trimmed
        return t.isEmpty ? "Guide" : String(t.prefix(80))
    }

    // MARK: PDF (A4)

    static func attributed(_ s: String, size: CGFloat, color: NSColor = .black, bold: Bool = false) -> NSAttributedString {
        let out = NSMutableAttributedString()
        for part in s.boldParts {
            let isBold = bold || part.bold
            out.append(NSAttributedString(string: part.text, attributes: [
                .font: isBold ? NSFont.systemFont(ofSize: size, weight: .semibold) : NSFont.systemFont(ofSize: size),
                .foregroundColor: color,
            ]))
        }
        return out
    }

    static func pdf(_ g: Guide, _ items: [ExportItem], to url: URL) throws {
        var box = CGRect(x: 0, y: 0, width: 595, height: 842)
        guard let ctx = CGContext(url as CFURL, mediaBox: &box, nil) else { throw PGError("Couldn't create the PDF.") }
        let margin: CGFloat = 48
        let width = box.width - margin * 2
        var y: CGFloat = 0
        var pageOpen = false

        func newPage() {
            if pageOpen { NSGraphicsContext.restoreGraphicsState(); ctx.endPDFPage() }
            ctx.beginPDFPage(nil)
            ctx.translateBy(x: 0, y: box.height)
            ctx.scaleBy(x: 1, y: -1)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: true)
            pageOpen = true
            y = margin
        }
        func height(_ a: NSAttributedString, _ w: CGFloat) -> CGFloat {
            ceil(a.boundingRect(with: CGSize(width: w, height: .greatestFiniteMagnitude), options: [.usesLineFragmentOrigin, .usesFontLeading]).height)
        }
        func draw(_ a: NSAttributedString, x: CGFloat, w: CGFloat) {
            let h = height(a, w)
            a.draw(with: CGRect(x: x, y: y, width: w, height: h), options: [.usesLineFragmentOrigin, .usesFontLeading])
            y += h
        }

        newPage()
        draw(attributed(g.title, size: 24, bold: true), x: margin, w: width)
        y += 6
        if !g.summary.isEmpty { draw(attributed(g.summary, size: 12, color: .darkGray), x: margin, w: width); y += 4 }
        y += 18

        let accent = NSColor(cgColor: Renderer.accent) ?? .systemRed
        for it in items {
            let text = attributed(it.text, size: 12.5)
            let textH = max(22, height(text, width - 34))
            var imgSize = CGSize.zero
            if let img = it.image {
                let w = min(width, CGFloat(img.width) / 2)
                imgSize = CGSize(width: w, height: w * CGFloat(img.height) / CGFloat(img.width))
                let maxH = box.height - margin * 2 - textH - 20
                if imgSize.height > maxH { imgSize = CGSize(width: imgSize.width * maxH / imgSize.height, height: maxH) }
            }
            if y + textH + 10 + imgSize.height > box.height - margin { newPage() }

            // Number badge
            let badge = CGRect(x: margin, y: y, width: 22, height: 22)
            accent.setFill()
            NSBezierPath(ovalIn: badge).fill()
            let num = NSAttributedString(string: "\(it.number)", attributes: [
                .font: NSFont.systemFont(ofSize: 11, weight: .bold), .foregroundColor: NSColor.white])
            let ns = num.size()
            num.draw(at: CGPoint(x: badge.midX - ns.width / 2, y: badge.midY - ns.height / 2))
            let top = y
            y += 3
            draw(text, x: margin + 34, w: width - 34)
            y = max(y, top + 22) + 10
            if let img = it.image {
                let r = CGRect(x: margin, y: y, width: imgSize.width, height: imgSize.height)
                NSImage(cgImage: img, size: r.size).draw(in: r, from: .zero, operation: .sourceOver, fraction: 1,
                                                         respectFlipped: true, hints: [.interpolation: NSImageInterpolation.high])
                NSColor(white: 0.85, alpha: 1).setStroke()
                NSBezierPath(rect: r).stroke()
                y += imgSize.height
            }
            y += 26
        }
        NSGraphicsContext.restoreGraphicsState()
        ctx.endPDFPage()
        ctx.closePDF()
    }

    // MARK: Word (.docx)

    static func xml(_ s: String) -> String { esc(s).replacingOccurrences(of: "'", with: "&apos;") }

    static func runs(_ s: String, size: Int = 24, bold: Bool = false) -> String {
        s.boldParts.map { part -> String in
            let p = part.text
            guard !p.isEmpty else { return "" }
            let b = bold || part.bold
            return "<w:r><w:rPr>\(b ? "<w:b/>" : "")<w:sz w:val=\"\(size)\"/></w:rPr><w:t xml:space=\"preserve\">\(xml(p))</w:t></w:r>"
        }.joined()
    }

    static func docx(_ g: Guide, _ items: [ExportItem], to url: URL) throws {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("docx-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: dir) }
        try fm.createDirectory(at: dir.appendingPathComponent("_rels"), withIntermediateDirectories: true)
        try fm.createDirectory(at: dir.appendingPathComponent("word/_rels"), withIntermediateDirectories: true)
        try fm.createDirectory(at: dir.appendingPathComponent("word/media"), withIntermediateDirectories: true)

        var body = "<w:p><w:pPr><w:spacing w:after=\"120\"/></w:pPr>\(runs(g.title, size: 44, bold: true))</w:p>"
        if !g.summary.isEmpty { body += "<w:p><w:pPr><w:spacing w:after=\"240\"/></w:pPr>\(runs(g.summary, size: 24))</w:p>" }
        var rels = ""
        let maxEMU = 5_943_600.0   // 6.5 inches
        for it in items {
            body += "<w:p><w:pPr><w:keepNext/><w:spacing w:before=\"240\" w:after=\"120\"/></w:pPr>\(runs("Step \(it.number). ", bold: true))\(runs(it.text))</w:p>"
            if let img = it.image, let png = it.png {
                let rid = "rIdImg\(it.number)"
                try png.write(to: dir.appendingPathComponent("word/media/image\(it.number).png"))
                rels += "<Relationship Id=\"\(rid)\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/image\" Target=\"media/image\(it.number).png\"/>"
                let wPts = min(Double(img.width) / 2, 468)          // points, max 6.5"
                var cx = wPts * 12700
                var cy = cx * Double(img.height) / Double(img.width)
                if cx > maxEMU { cy *= maxEMU / cx; cx = maxEMU }
                let maxH = 7_500_000.0
                if cy > maxH { cx *= maxH / cy; cy = maxH }
                body += """
                <w:p><w:r><w:drawing><wp:inline distT="0" distB="0" distL="0" distR="0"><wp:extent cx="\(Int(cx))" cy="\(Int(cy))"/>\
                <wp:docPr id="\(it.number)" name="Step \(it.number)"/><wp:cNvGraphicFramePr><a:graphicFrameLocks noChangeAspect="1"/></wp:cNvGraphicFramePr>\
                <a:graphic><a:graphicData uri="http://schemas.openxmlformats.org/drawingml/2006/picture"><pic:pic>\
                <pic:nvPicPr><pic:cNvPr id="\(it.number)" name="image\(it.number).png"/><pic:cNvPicPr/></pic:nvPicPr>\
                <pic:blipFill><a:blip r:embed="\(rid)"/><a:stretch><a:fillRect/></a:stretch></pic:blipFill>\
                <pic:spPr><a:xfrm><a:off x="0" y="0"/><a:ext cx="\(Int(cx))" cy="\(Int(cy))"/></a:xfrm><a:prstGeom prst="rect"><a:avLst/></a:prstGeom>\
                <a:ln w="6350"><a:solidFill><a:srgbClr val="D9D9D9"/></a:solidFill></a:ln></pic:spPr>\
                </pic:pic></a:graphicData></a:graphic></wp:inline></w:drawing></w:r></w:p>
                """
            }
        }
        let document = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main" \
        xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships" \
        xmlns:wp="http://schemas.openxmlformats.org/drawingml/2006/wordprocessingDrawing" \
        xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" \
        xmlns:pic="http://schemas.openxmlformats.org/drawingml/2006/picture">
        <w:body>\(body)<w:sectPr><w:pgSz w:w="11906" w:h="16838"/><w:pgMar w:top="1134" w:right="1134" w:bottom="1134" w:left="1134" w:header="567" w:footer="567" w:gutter="0"/></w:sectPr></w:body></w:document>
        """
        let contentTypes = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">\
        <Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>\
        <Default Extension="xml" ContentType="application/xml"/>\
        <Default Extension="png" ContentType="image/png"/>\
        <Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/>\
        </Types>
        """
        let rootRels = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">\
        <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="word/document.xml"/>\
        </Relationships>
        """
        let docRels = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">\(rels)</Relationships>
        """
        try contentTypes.write(to: dir.appendingPathComponent("[Content_Types].xml"), atomically: true, encoding: .utf8)
        try rootRels.write(to: dir.appendingPathComponent("_rels/.rels"), atomically: true, encoding: .utf8)
        try document.write(to: dir.appendingPathComponent("word/document.xml"), atomically: true, encoding: .utf8)
        try docRels.write(to: dir.appendingPathComponent("word/_rels/document.xml.rels"), atomically: true, encoding: .utf8)
        try? fm.removeItem(at: url)
        let status = Tools.runQuick("/usr/bin/zip", ["-X", "-r", "-q", url.path, "[Content_Types].xml", "_rels", "word"], cwd: dir)
        guard status == 0 else { throw PGError("Couldn't write the Word file.") }
    }

    // MARK: .pareguide (zip of the guide folder, without old versions)

    static func bundle(folder: URL, to url: URL) throws {
        let fm = FileManager.default
        try? fm.removeItem(at: url)
        let status = Tools.runQuick("/usr/bin/zip", ["-X", "-r", "-q", url.path, "guide.json", "images"], cwd: folder)
        guard status == 0 else { throw PGError("Couldn't write the file.") }
    }
}
