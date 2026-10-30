import AppKit
import CoreText

// Vector source of the application icon: AppIcon.icns is generated from it (icon/make_icon.sh) and the header of
// the window draws it live, so the Finder, the Dock and the window always show the same artwork.
// Theme "installer": an open package, a download arrow dropping into it and a check badge (installed and verified),
// on the brand gradient (Palette.gradient). Coordinates: 1024-point macOS icon grid, y downward, body = the
// 824-point squircle at (100, 100). Renderings smaller than 48 px use a bolder drawing that stays legible at 16 px.
enum AppIconArt {
    struct Pose: Equatable {
        var arrow: CGFloat = 0     // 0 = at rest in the box, 1 = above the icon (out of view), < 0 = deeper
        var badge: CGFloat = 1     // scale of the check badge
        var sparkle: CGFloat = 1   // opacity of the sparkles

        static let rest = Pose()
        // launch animation, progress 0...1: the arrow drops into the box, the check pops, then the sparkles
        static func launch(_ p: Double) -> Pose {
            Pose(arrow: CGFloat(1 - backOut(clamp(p / 0.6))),
                 badge: CGFloat(backOut(clamp((p - 0.5) / 0.4))),
                 sparkle: CGFloat(clamp((p - 0.7) / 0.3)))
        }
        static func clamp(_ x: Double) -> Double { min(1, max(0, x)) }
        static func backOut(_ x: Double) -> Double {
            let c1 = 1.70158, c3 = c1 + 1
            return x <= 0 ? 0 : 1 + c3 * pow(x - 1, 3) + c1 * pow(x - 1, 2)
        }
    }

    static let grid: CGFloat = 1024
    static let body = CGRect(x: 100, y: 100, width: 824, height: 824)
    static let simplifiedBelow: CGFloat = 48   // device pixels of the body

    // macOS icon shape (superellipse, n = 5)
    static func squircle(_ r: CGRect) -> CGPath {
        let p = CGMutablePath(), n = 5.0, steps = 360
        for i in 0...steps {
            let t = Double(i) / Double(steps) * 2 * .pi, c = cos(t), s = sin(t)
            let x = r.midX + r.width / 2 * CGFloat(copysign(pow(abs(c), 2 / n), c))
            let y = r.midY + r.height / 2 * CGFloat(copysign(pow(abs(s), 2 / n), s))
            if i == 0 { p.move(to: CGPoint(x: x, y: y)) } else { p.addLine(to: CGPoint(x: x, y: y)) }
        }
        p.closeSubpath()
        return p
    }

    static func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
        CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
    }

    // the body of the icon (squircle and content) drawn into `rect` of a context whose y axis points down
    static func draw(_ c: CGContext, in rect: CGRect, pose: Pose = .rest) {
        let u = rect.width / body.width
        c.saveGState()
        c.translateBy(x: rect.minX - body.minX * u, y: rect.minY - body.minY * u)
        c.scaleBy(x: u, y: u)
        let t = c.userSpaceToDeviceSpaceTransform
        let k = max(0.0001, hypot(t.a, t.b))   // device pixels per design point (shadow blur is not scaled by the CTM)
        let small = body.width * k < simplifiedBelow
        c.setLineCap(.round); c.setLineJoin(.round)

        let shape = squircle(body)
        c.saveGState()
        c.addPath(shape); c.clip()
        background(c, small: small)
        if !small { halo(c); sparkles(c, k: k, alpha: pose.sparkle) }
        let g = small ? Box.small : Box.large
        boxBack(c, g, small: small)
        arrow(c, g, k: k, offset: -pose.arrow * 620, small: small)
        boxFront(c, g, small: small)
        badge(c, g, k: k, scale: pose.badge)
        c.restoreGState()
        // light rim: the edge stays visible on dark and light backgrounds
        c.addPath(shape); c.setStrokeColor(color(0xFFFFFF, small ? 0.22 : 0.16)); c.setLineWidth(small ? 14 : 6); c.strokePath()
        c.restoreGState()
    }

    // ---------- geometry ----------
    struct Box {
        let top: CGPoint, half: CGSize, height: CGFloat          // top = centre of the opening
        let shaft: (x0: CGFloat, x1: CGFloat, y0: CGFloat, y1: CGFloat)
        let head: (y: CGFloat, half: CGFloat, tip: CGFloat)
        let badge: (center: CGPoint, r: CGFloat, ring: CGFloat, stroke: CGFloat)
        var T: CGPoint { CGPoint(x: top.x, y: top.y - half.height) }
        var R: CGPoint { CGPoint(x: top.x + half.width, y: top.y) }
        var B: CGPoint { CGPoint(x: top.x, y: top.y + half.height) }
        var L: CGPoint { CGPoint(x: top.x - half.width, y: top.y) }
        func down(_ p: CGPoint) -> CGPoint { CGPoint(x: p.x, y: p.y + height) }
        static let large = Box(top: CGPoint(x: 512, y: 560), half: CGSize(width: 190, height: 76), height: 210,
                               shaft: (452, 572, 150, 490), head: (470, 160, 680),
                               badge: (CGPoint(x: 730, y: 770), 118, 16, 40))
        static let small = Box(top: CGPoint(x: 512, y: 548), half: CGSize(width: 250, height: 96), height: 236,
                               shaft: (432, 592, 120, 420), head: (400, 200, 650),
                               badge: (CGPoint(x: 704, y: 728), 186, 30, 84))
    }

    static func poly(_ pts: [CGPoint]) -> CGPath {
        let p = CGMutablePath(); p.addLines(between: pts); p.closeSubpath(); return p
    }

    static func fill(_ c: CGContext, _ path: CGPath, _ hexes: [UInt32], from a: CGPoint, to b: CGPoint, alpha: CGFloat = 1) {
        let cols = hexes.map { color($0, alpha) } as CFArray
        guard let g = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: cols, locations: nil) else { return }
        c.saveGState(); c.addPath(path); c.clip()
        c.drawLinearGradient(g, start: a, end: b, options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
        c.restoreGState()
    }

    // ---------- layers ----------
    static func background(_ c: CGContext, small: Bool) {
        let cols = Palette.gradient.map { color($0) } as CFArray
        if let g = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: cols, locations: [0, 0.36, 0.68, 1]) {
            c.drawLinearGradient(g, start: CGPoint(x: 160, y: 140), end: CGPoint(x: 830, y: 870), options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
        }
        // soft light from the top left
        let glow = [color(0xFFFFFF, small ? 0.14 : 0.24), color(0xFFFFFF, 0)] as CFArray
        if let g = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: glow, locations: nil) {
            c.drawRadialGradient(g, startCenter: CGPoint(x: 290, y: 220), startRadius: 0,
                                 endCenter: CGPoint(x: 290, y: 220), endRadius: 560, options: [])
        }
    }

    static func halo(_ c: CGContext) {
        for (r, a) in [(300.0, 0.10), (390.0, 0.07), (480.0, 0.05)] {
            c.addEllipse(in: CGRect(x: 512 - r, y: 640 - r, width: 2 * r, height: 2 * r))
            c.setStrokeColor(color(0xFFFFFF, CGFloat(a))); c.setLineWidth(14); c.strokePath()
        }
    }

    static func sparkle(_ ctr: CGPoint, _ r: CGFloat) -> CGPath {
        let p = CGMutablePath()
        p.move(to: CGPoint(x: ctr.x, y: ctr.y - r))
        p.addQuadCurve(to: CGPoint(x: ctr.x + r, y: ctr.y), control: ctr)
        p.addQuadCurve(to: CGPoint(x: ctr.x, y: ctr.y + r), control: ctr)
        p.addQuadCurve(to: CGPoint(x: ctr.x - r, y: ctr.y), control: ctr)
        p.addQuadCurve(to: CGPoint(x: ctr.x, y: ctr.y - r), control: ctr)
        p.closeSubpath()
        return p
    }

    static func sparkles(_ c: CGContext, k: CGFloat, alpha: CGFloat) {
        guard alpha > 0 else { return }
        c.saveGState()
        c.setShadow(offset: .zero, blur: 18 * k, color: color(0xFFFFFF, 0.7 * alpha))
        for (x, y, r, a) in [(790.0, 250.0, 62.0, 1.0), (240.0, 330.0, 38.0, 0.85), (850.0, 430.0, 28.0, 0.75)] {
            c.addPath(sparkle(CGPoint(x: x, y: y), CGFloat(r)))
            c.setFillColor(color(0xFFFFFF, CGFloat(a) * alpha)); c.fillPath()
        }
        c.restoreGState()
    }

    static func boxBack(_ c: CGContext, _ g: Box, small: Bool) {
        if !small {
            // back flaps, open outwards (inner faces visible)
            let left = poly([g.L, g.T, CGPoint(x: g.T.x - 56, y: g.T.y - 96), CGPoint(x: g.L.x - 72, y: g.L.y - 98)])
            let right = poly([g.T, g.R, CGPoint(x: g.R.x + 72, y: g.R.y - 98), CGPoint(x: g.T.x + 56, y: g.T.y - 96)])
            fill(c, left, [0xF5F3FF, 0xD8CCFF], from: CGPoint(x: 300, y: 400), to: g.L)
            fill(c, right, [0xEDE7FF, 0xC9B8FF], from: CGPoint(x: 720, y: 400), to: g.R)
        }
        // inside of the box
        fill(c, poly([g.L, g.T, g.R, g.B]), [0x2E1065, 0x1E1B4B], from: g.T, to: g.B)
    }

    static func arrow(_ c: CGContext, _ g: Box, k: CGFloat, offset: CGFloat, small: Bool) {
        let s = g.shaft, h = g.head, w = s.x1 - s.x0
        let p = CGMutablePath()
        p.addRoundedRect(in: CGRect(x: s.x0, y: s.y0 + offset, width: w, height: s.y1 - s.y0), cornerWidth: w * 0.22, cornerHeight: w * 0.22)
        p.addPath(poly([CGPoint(x: g.top.x - h.half, y: h.y + offset), CGPoint(x: g.top.x + h.half, y: h.y + offset),
                        CGPoint(x: g.top.x, y: h.tip + offset)]))
        if !small {
            // motion lines
            c.saveGState()
            c.setStrokeColor(color(0xFFFFFF, 0.5)); c.setLineWidth(18)
            for x in [s.x0 - 62, s.x1 + 62] {
                c.move(to: CGPoint(x: x, y: s.y0 + 30 + offset)); c.addLine(to: CGPoint(x: x, y: s.y0 + 150 + offset))
            }
            c.strokePath()
            c.restoreGState()
        }
        c.saveGState()
        c.setShadow(offset: .zero, blur: (small ? 10 : 26) * k, color: color(0x1E1B4B, 0.45))
        c.addPath(p); c.setFillColor(color(0xFFFFFF)); c.fillPath()
        c.restoreGState()
        fill(c, p, [0xFFFFFF, 0xFCE7F3], from: CGPoint(x: 0, y: s.y0 + offset), to: CGPoint(x: 0, y: h.tip + offset))
    }

    static func boxFront(_ c: CGContext, _ g: Box, small: Bool) {
        let left = poly([g.L, g.B, g.down(g.B), g.down(g.L)])
        let right = poly([g.B, g.R, g.down(g.R), g.down(g.B)])
        fill(c, left, [0xFFFFFF, 0xE9E5FF], from: g.L, to: g.down(g.L))
        fill(c, right, [0xC4B5FD, 0x8B5CF6], from: g.R, to: g.down(g.B))
        if !small { brand(c, g) }
        // rim of the opening and front edge
        c.saveGState()
        c.move(to: g.L); c.addLine(to: g.B); c.addLine(to: g.R)
        c.setStrokeColor(color(0xFFFFFF)); c.setLineWidth(small ? 14 : 7); c.strokePath()
        if !small {
            c.move(to: g.B); c.addLine(to: g.down(g.B))
            c.setStrokeColor(color(0xFFFFFF, 0.55)); c.setLineWidth(4); c.strokePath()
        }
        c.restoreGState()
    }

    // "4D" printed on the left face of the package (isometric shear)
    static func brand(_ c: CGContext, _ g: Box) {
        let size: CGFloat = 120
        var font = NSFont.systemFont(ofSize: size, weight: .heavy)
        if let d = font.fontDescriptor.withDesign(.rounded), let f = NSFont(descriptor: d, size: size) { font = f }
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: "4D", attributes: [.font: font]))
        let glyphs = CGMutablePath()
        for run in (CTLineGetGlyphRuns(line) as? [CTRun]) ?? [] {
            let n = CTRunGetGlyphCount(run)
            var ids = [CGGlyph](repeating: 0, count: n), pos = [CGPoint](repeating: .zero, count: n)
            CTRunGetGlyphs(run, CFRange(location: 0, length: n), &ids)
            CTRunGetPositions(run, CFRange(location: 0, length: n), &pos)
            let attrs = CTRunGetAttributes(run) as NSDictionary
            let runFont = (attrs[kCTFontAttributeName as String] as! CTFont?) ?? (font as CTFont)
            for i in 0..<n {
                if let gp = CTFontCreatePathForGlyph(runFont, ids[i], nil) {
                    glyphs.addPath(gp, transform: CGAffineTransform(translationX: pos[i].x, y: pos[i].y))
                }
            }
        }
        let width = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
        let slope = g.half.height / g.half.width
        let cx = (g.L.x + g.B.x) / 2, x0 = cx - width / 2
        let base = g.L.y + slope * (x0 - g.L.x) + g.height / 2 + font.capHeight / 2
        let m = CGAffineTransform(a: 1, b: slope, c: 0, d: -1, tx: x0, ty: base)
        guard let path = glyphs.copy(using: [m]) else { return }
        fill(c, path, [Palette.gradient[0], Palette.gradient[2]], from: CGPoint(x: x0, y: base - 90), to: CGPoint(x: x0 + width, y: base))
    }

    static func badge(_ c: CGContext, _ g: Box, k: CGFloat, scale: CGFloat) {
        guard scale > 0.01 else { return }
        let b = g.badge
        c.saveGState()
        c.translateBy(x: b.center.x, y: b.center.y); c.scaleBy(x: scale, y: scale)
        let outer = CGRect(x: -(b.r + b.ring), y: -(b.r + b.ring), width: 2 * (b.r + b.ring), height: 2 * (b.r + b.ring))
        c.saveGState()
        c.setShadow(offset: .zero, blur: 22 * k * scale, color: color(0x1E1B4B, 0.45))
        c.addEllipse(in: outer); c.setFillColor(color(0xFFFFFF)); c.fillPath()
        c.restoreGState()
        let inner = CGPath(ellipseIn: CGRect(x: -b.r, y: -b.r, width: 2 * b.r, height: 2 * b.r), transform: nil)
        fill(c, inner, [0x34D399, 0x16A34A, 0x15803D], from: CGPoint(x: 0, y: -b.r), to: CGPoint(x: 0, y: b.r))
        let r = b.r
        c.move(to: CGPoint(x: -0.47 * r, y: 0.02 * r))
        c.addLine(to: CGPoint(x: -0.13 * r, y: 0.36 * r))
        c.addLine(to: CGPoint(x: 0.5 * r, y: -0.34 * r))
        c.setStrokeColor(color(0xFFFFFF)); c.setLineWidth(b.stroke); c.strokePath()
        c.restoreGState()
    }
}
