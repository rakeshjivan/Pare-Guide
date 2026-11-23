// Render — turns a step's original screenshot into the finished picture:
// blurred areas, the highlight box and click marker, then the crop or automatic zoom.
// Also: finding private details (emails, phone and card numbers) to blur automatically.

import AppKit
import CoreImage
import CoreImage.CIFilterBuiltins
import Vision

enum Renderer {
    private static let ci = CIContext(options: [.cacheIntermediates: false])
    static let accent = CGColor(red: 1.0, green: 0.33, blue: 0.24, alpha: 1)

    /// The finished step picture. `maxWidth` shrinks large screenshots for export.
    static func render(_ step: Step, base: CGImage, zoom: Zoom, maxWidth: Int? = nil) -> CGImage? {
        let W = CGFloat(base.width), H = CGFloat(base.height)
        let full = CGRect(x: 0, y: 0, width: W, height: H)

        // 1. Blur (pixelate + soften so the text can't be read back).
        var image: CGImage = base
        if !step.blurs.isEmpty {
            var c = CIImage(cgImage: base)
            for b in step.blurs {
                let r = CGRect(x: b.minX, y: H - b.maxY, width: b.width, height: b.height).integral.intersection(full)
                guard !r.isNull, r.width > 1, r.height > 1 else { continue }
                let s = max(12, min(r.width, r.height) / 3)
                let px = c.clampedToExtent()
                    .applyingFilter("CIPixellate", parameters: ["inputScale": s, "inputCenter": CIVector(x: r.minX, y: r.minY)])
                    .applyingGaussianBlur(sigma: Double(s) / 2)
                    .cropped(to: r)
                c = px.composited(over: c)
            }
            if let out = ci.createCGImage(c, from: full) { image = out }
        }

        // 2. Highlight box and click marker.
        guard let ctx = CGContext(data: nil, width: Int(W), height: Int(H), bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        else { return nil }
        ctx.interpolationQuality = .high
        ctx.draw(image, in: full)
        ctx.translateBy(x: 0, y: H)
        ctx.scaleBy(x: 1, y: -1)   // now top-left origin, same as the stored coordinates
        let u = CGFloat(step.scale)

        if step.showHighlight {
            if let h = step.highlight {
                let r = h.insetBy(dx: -4 * u, dy: -4 * u)
                let path = CGPath(roundedRect: r, cornerWidth: 6 * u, cornerHeight: 6 * u, transform: nil)
                ctx.setFillColor(accent.copy(alpha: 0.12)!)
                ctx.addPath(path); ctx.fillPath()
                ctx.setStrokeColor(accent)
                ctx.setLineWidth(3 * u)
                ctx.addPath(path); ctx.strokePath()
            }
            if let p = step.clickPoint {
                let rad = 11 * u
                let dot = CGRect(x: p.x - rad, y: p.y - rad, width: rad * 2, height: rad * 2)
                ctx.setFillColor(accent.copy(alpha: 0.35)!)
                ctx.fillEllipse(in: dot)
                ctx.setStrokeColor(CGColor(gray: 1, alpha: 1))
                ctx.setLineWidth(2.5 * u)
                ctx.strokeEllipse(in: dot)
                ctx.setFillColor(accent)
                ctx.fillEllipse(in: dot.insetBy(dx: rad * 0.6, dy: rad * 0.6))
            }
        }
        guard var out = ctx.makeImage() else { return nil }

        // 3. Crop, or zoom in around the click.
        if let c = step.crop ?? autoZoom(step, zoom: step.zoomOverride ?? zoom, size: CGSize(width: W, height: H)) {
            let r = c.integral.intersection(full)
            if !r.isNull, r.width > 10, r.height > 10, let cropped = out.cropping(to: r) { out = cropped }
        }
        if let m = maxWidth, out.width > m { return scaled(out, width: m) ?? out }
        return out
    }

    /// A 16:10 window around the clicked element, kept inside the screenshot.
    static func autoZoom(_ step: Step, zoom: Zoom, size: CGSize) -> CGRect? {
        guard let f = zoom.fraction else { return nil }
        let focus: CGRect
        if let h = step.highlight { focus = h }
        else if let p = step.clickPoint { focus = CGRect(x: p.x, y: p.y, width: 1, height: 1) }
        else { return nil }
        var w = max(size.width * f, focus.width * 1.6)
        var h = w * 10 / 16
        if h < focus.height * 1.6 { h = focus.height * 1.6; w = h * 16 / 10 }
        w = min(w, size.width); h = min(h, size.height)
        var x = focus.midX - w / 2, y = focus.midY - h / 2
        x = min(max(0, x), size.width - w)
        y = min(max(0, y), size.height - h)
        return CGRect(x: x, y: y, width: w, height: h)
    }

    static func scaled(_ img: CGImage, width: Int) -> CGImage? {
        let h = Int((CGFloat(img.height) * CGFloat(width) / CGFloat(img.width)).rounded())
        guard let ctx = CGContext(data: nil, width: width, height: max(1, h), bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        else { return nil }
        ctx.interpolationQuality = .high
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: width, height: max(1, h)))
        return ctx.makeImage()
    }

    static func png(_ img: CGImage) -> Data? {
        NSBitmapImageRep(cgImage: img).representation(using: .png, properties: [:])
    }

    static func jpeg(_ img: CGImage, quality: Double = 0.85) -> Data? {
        NSBitmapImageRep(cgImage: img).representation(using: .jpeg, properties: [.compressionFactor: quality])
    }
}

// MARK: - Private details

enum Sensitive {
    static let patterns: [NSRegularExpression] = [
        #"[A-Z0-9._%+\-]+@[A-Z0-9.\-]+\.[A-Z]{2,}"#,                         // email
        #"(?:\+?\d{1,3}[\s\-.]?)?(?:\(?\d{2,4}\)?[\s\-.]?)\d{3,4}[\s\-.]?\d{3,4}"#, // phone
        #"\b(?:\d[ \-]?){13,19}\b"#,                                           // card number
        #"\b\d{3}-\d{2}-\d{4}\b"#,                                             // US SSN
        #"\b\d{3}[ ]?\d{3}[ ]?\d{3}\b"#,                                       // AU TFN
        #"\b\d{4}[ ]?\d{5}[ ]?\d{1,2}\b"#,                                     // Medicare
    ].compactMap { try? NSRegularExpression(pattern: $0, options: [.caseInsensitive]) }

    static func matches(in s: String) -> [Range<String.Index>] {
        let ns = s as NSString
        var out: [Range<String.Index>] = []
        for p in patterns {
            for m in p.matches(in: s, range: NSRange(location: 0, length: ns.length)) {
                // Phone-like matches need at least 8 digits, to skip dates, times and prices.
                let digits = ns.substring(with: m.range).filter(\.isNumber).count
                if p.pattern.contains("@") || digits >= 8, let r = Range(m.range, in: s) { out.append(r) }
            }
        }
        return out
    }

    /// Replaces private details in typed text with dots.
    static func mask(_ s: String) -> String {
        var out = s
        for r in matches(in: s).sorted(by: { $0.lowerBound > $1.lowerBound }) {
            out.replaceSubrange(r, with: String(repeating: "•", count: 8))
        }
        return out
    }

    /// Rectangles (screenshot pixels, top-left origin) around private details in a picture.
    static func find(in image: CGImage) -> [CGRect] {
        let req = VNRecognizeTextRequest()
        req.recognitionLevel = .accurate
        req.usesLanguageCorrection = false
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        try? handler.perform([req])
        let W = CGFloat(image.width), H = CGFloat(image.height)
        var rects: [CGRect] = []
        for obs in req.results ?? [] {
            guard let cand = obs.topCandidates(1).first else { continue }
            for r in matches(in: cand.string) {
                guard let box = try? cand.boundingBox(for: r)?.boundingBox else { continue }
                let rect = CGRect(x: box.minX * W, y: (1 - box.maxY) * H, width: box.width * W, height: box.height * H)
                rects.append(rect.insetBy(dx: -6, dy: -4))
            }
        }
        return rects
    }
}

@MainActor
enum AutoBlur {
    @MainActor static var scanning = Set<UUID>()

    /// Looks through every step not yet checked and adds blur boxes over private details.
    static func scan(guideID: UUID, force: Bool = false) {
        guard !scanning.contains(guideID), let g = GuideStore.shared.guide(guideID) else { return }
        let store = GuideStore.shared
        let jobs: [(UUID, URL)] = g.steps.compactMap { s in
            guard force || !s.autoBlurDone, let name = s.image else { return nil }
            return (s.id, store.imageURL(guideID, name))
        }
        guard !jobs.isEmpty else { return }
        scanning.insert(guideID)
        NotificationCenter.default.post(name: .autoBlurChanged, object: nil)
        Task.detached(priority: .utility) {
            var found: [UUID: [CGRect]] = [:]
            for (id, url) in jobs {
                guard let img = GuideStore.loadImage(url) else { continue }
                found[id] = Sensitive.find(in: img)
            }
            let results = found
            await MainActor.run {
                scanning.remove(guideID)
                if var g = GuideStore.shared.guide(guideID) {
                    for i in g.steps.indices {
                        guard let rects = results[g.steps[i].id] else { continue }
                        for r in rects where !g.steps[i].blurs.contains(where: { $0.intersects(r) && $0.contains(CGPoint(x: r.midX, y: r.midY)) }) {
                            g.steps[i].blurs.append(r)
                        }
                        g.steps[i].autoBlurDone = true
                    }
                    GuideStore.shared.update(g)
                }
                NotificationCenter.default.post(name: .autoBlurChanged, object: nil)
            }
        }
    }
}

extension Notification.Name {
    static let autoBlurChanged = Notification.Name("PareGuideAutoBlurChanged")
}
