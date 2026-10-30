import AppKit
import ImageIO
import UniformTypeIdentifiers

// Renders the iconset of AppIcon.icns from the vector source (../AppIconArt.swift). Used by make_icon.sh.
//   make_icon <iconset folder>               the 10 PNG files of a macOS iconset (16 to 1024 px)
//   make_icon --frames <folder> <px> <n>     n frames of the launch animation (preview and tests)
@main
struct MakeIcon {
    static func render(_ px: Int, pose: AppIconArt.Pose, template: Bool = true) -> CGImage? {
        guard let c = CGContext(data: nil, width: px, height: px, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        c.translateBy(x: 0, y: CGFloat(px)); c.scaleBy(x: 1, y: -1)   // y downward, as in the app
        let s = CGFloat(px) / AppIconArt.grid
        let body = template ? CGRect(x: AppIconArt.body.minX * s, y: AppIconArt.body.minY * s,
                                     width: AppIconArt.body.width * s, height: AppIconArt.body.height * s)
                            : CGRect(x: 0, y: 0, width: CGFloat(px), height: CGFloat(px))
        if template { // drop shadow of the macOS icon grid (offset in device space: y upward)
            c.saveGState()
            c.setShadow(offset: CGSize(width: 0, height: -10 * s), blur: 28 * s, color: AppIconArt.color(0x000000, 0.35))
            c.addPath(AppIconArt.squircle(body)); c.setFillColor(AppIconArt.color(0x4F46E5)); c.fillPath()
            c.restoreGState()
        }
        AppIconArt.draw(c, in: body, pose: pose)
        return c.makeImage()
    }

    static func write(_ img: CGImage, _ path: String, dpi: Int) -> Bool {
        guard let d = CGImageDestinationCreateWithURL(URL(fileURLWithPath: path) as CFURL, UTType.png.identifier as CFString, 1, nil) else { return false }
        CGImageDestinationAddImage(d, img, [kCGImagePropertyDPIWidth: dpi, kCGImagePropertyDPIHeight: dpi] as CFDictionary)
        return CGImageDestinationFinalize(d)
    }

    static func main() {
        let a = CommandLine.arguments
        if a.count == 5, a[1] == "--frames", let px = Int(a[3]), let n = Int(a[4]), n > 1 {
            try? FileManager.default.createDirectory(atPath: a[2], withIntermediateDirectories: true)
            for i in 0..<n {
                let pose = AppIconArt.Pose.launch(Double(i) / Double(n - 1))
                guard let img = render(px, pose: pose, template: false),
                      write(img, a[2] + String(format: "/frame_%03d.png", i), dpi: 72) else { exit(1) }
            }
            exit(0)
        }
        guard a.count == 2 else { fputs("usage: make_icon <iconset> | --frames <folder> <px> <n>\n", stderr); exit(64) }
        try? FileManager.default.createDirectory(atPath: a[1], withIntermediateDirectories: true)
        for pt in [16, 32, 128, 256, 512] {
            for scale in [1, 2] {
                let name = scale == 1 ? "icon_\(pt)x\(pt).png" : "icon_\(pt)x\(pt)@2x.png"
                guard let img = render(pt * scale, pose: .rest), write(img, a[1] + "/" + name, dpi: 72 * scale) else {
                    fputs("render failed: \(name)\n", stderr); exit(1)
                }
            }
        }
    }
}
