import Foundation
import AppKit
import ApplicationServices
import CoreGraphics
import ImageIO
import Vision

// about_check <pid> <out.png> <EN|FR|DE|CS|JA> <4D.app> [timeout s]
//   Opens the 4D "About" box through the application menu (Accessibility), captures the window
//   (screencapture) and reads it (Vision OCR). The texts expected in the tested language are read
//   from the About<LANG>.xlf of the 4D app.
//   Output, tab separated: MENU <item>, TITLE <window>, PNG <file>, OCR <line>,
//   LOC OK|KO <key> <expected>, LANG OK|KO <summary>, ERR AX|MENU|WINDOW|SCREEN|CAPTURE|RENDER <message>.
//   Exit code: 0 = OCR done, 3 = no Screen Recording permission, 4 = content not displayed, 2 = other error.
// about_check --gatekeeper <app name> [timeout s]
//   Answers the macOS first-launch alert of a quarantined app ("<app> is an app downloaded from the
//   Internet. Are you sure you want to open it?") with its default button (Open). An alert refusing
//   the app ("cannot be opened") is answered with its default button too (Done): the app stays closed.
//   Output: GK <button> <alert text>, or GK NONE. Exit code: 0 = alert answered, 1 = no alert.
// about_check --windows <pid|uiagent>
//   Lists the on-screen windows of a process (or of the macOS alert agent CoreServicesUIAgent), used to tell a
//   dialog preventing the start from a hang. Output: WIN <pid> <layer> <w>x<h> <owner> <title>, AXWIN <pid>
//   <title> <texts> (texts only with Accessibility). Exit code: 0 = window(s) found, 1 = none.
// Never prompts for a permission except --request-accessibility / --request-screen (explicit user action):
// test modes only report a missing permission.

setvbuf(stdout, nil, _IOLBF, 0)
func out(_ f: String...) { print(f.joined(separator: "\t")) }
func fail(_ code: String, _ msg: String, _ rc: Int32 = 2) -> Never { out("ERR", code, msg); exit(rc) }

let args = CommandLine.arguments
if args.count == 2 && ["--permissions", "--request-accessibility", "--request-screen"].contains(args[1]) {
    // A fresh process avoids stale permission state after returning from System Settings.
    // --permissions never prompts or captures; request modes follow an explicit UI action.
    if args[1] == "--request-accessibility" {
        _ = AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary)
    } else if args[1] == "--request-screen" {
        _ = CGRequestScreenCaptureAccess()
    }
    out("EXE", CommandLine.arguments[0])
    out("PID", String(getpid()))
    out("AX", AXIsProcessTrusted() ? "1" : "0")
    out("SCREEN", CGPreflightScreenCaptureAccess() ? "1" : "0")
    exit(0)
}
let axMissing = "Accessibility permission missing: System Settings > Privacy & Security > Accessibility > allow Test Installer 4D (or Terminal), then re-run"

// ---------- Accessibility ----------
func attr(_ e: AXUIElement, _ a: String) -> AnyObject? {
    var v: AnyObject?
    return AXUIElementCopyAttributeValue(e, a as CFString, &v) == .success ? v : nil
}
func element(_ e: AXUIElement, _ a: String) -> AXUIElement? {
    guard let v = attr(e, a), CFGetTypeID(v) == AXUIElementGetTypeID() else { return nil }
    return (v as! AXUIElement)
}
func kids(_ e: AXUIElement) -> [AXUIElement] { (attr(e, kAXChildrenAttribute) as? [AXUIElement]) ?? [] }
func title(_ e: AXUIElement) -> String { (attr(e, kAXTitleAttribute) as? String) ?? "" }
func label(_ e: AXUIElement) -> String { let t = title(e); return t.isEmpty ? ((attr(e, kAXDescriptionAttribute) as? String) ?? "") : t }
func windows(_ app: AXUIElement) -> [AXUIElement] { (attr(app, kAXWindowsAttribute) as? [AXUIElement]) ?? [] }
func frame(_ w: AXUIElement) -> CGRect? {
    guard let p = attr(w, kAXPositionAttribute), let s = attr(w, kAXSizeAttribute),
          CFGetTypeID(p) == AXValueGetTypeID(), CFGetTypeID(s) == AXValueGetTypeID() else { return nil }
    var pt = CGPoint.zero, sz = CGSize.zero
    AXValueGetValue(p as! AXValue, .cgPoint, &pt)
    AXValueGetValue(s as! AXValue, .cgSize, &sz)
    return CGRect(origin: pt, size: sz)
}

func texts(_ e: AXUIElement, _ depth: Int = 0) -> [String] {
    guard depth < 8 else { return [] }
    var r: [String] = []
    if (attr(e, kAXRoleAttribute) as? String) == (kAXStaticTextRole as String), let v = attr(e, kAXValueAttribute) as? String, !v.isEmpty { r.append(v) }
    for k in kids(e) { r += texts(k, depth + 1) }
    return r
}

// ---------- Gatekeeper first-launch alert ----------
if args.count >= 3 && args[1] == "--gatekeeper" {
    let name = args[2]
    let limit = Date().addingTimeInterval(args.count > 3 ? (Double(args[3]) ?? 60) : 60)
    guard AXIsProcessTrusted() else { fail("AX", axMissing) }
    while Date() < limit {
        for agent in NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.coreservices.uiagent") {
            let ui = AXUIElementCreateApplication(agent.processIdentifier)
            AXUIElementSetMessagingTimeout(ui, 3)
            for w in windows(ui) {
                let t = texts(w).joined(separator: " ")
                guard t.contains(name), let b = element(w, kAXDefaultButtonAttribute) else { continue }
                let button = label(b) // read before the click: the alert is gone afterwards
                if AXUIElementPerformAction(b, kAXPressAction as CFString) == .success {
                    out("GK", button, t)
                    exit(0)
                }
            }
        }
        usleep(500_000)
    }
    out("GK", "NONE")
    exit(1)
}

// ---------- windows of a process (dialog vs hang) ----------
if args.count == 3 && args[1] == "--windows" {
    var pids: Set<pid_t> = []
    if args[2] == "uiagent" {
        pids = Set(NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.coreservices.uiagent").map { $0.processIdentifier })
    } else if let p = pid_t(args[2]) { pids = [p] }
    let list = (CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]) ?? []
    var found = 0
    for w in list {
        guard let owner = (w[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value, pids.contains(owner) else { continue }
        guard ((w[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 1) > 0,
              let b = w[kCGWindowBounds as String] as? NSDictionary,
              let r = CGRect(dictionaryRepresentation: b as CFDictionary), r.width >= 60, r.height >= 40 else { continue }
        found += 1
        out("WIN", String(owner), String((w[kCGWindowLayer as String] as? NSNumber)?.intValue ?? 0),
            "\(Int(r.width))x\(Int(r.height))", (w[kCGWindowOwnerName as String] as? String) ?? "",
            (w[kCGWindowName as String] as? String) ?? "") // the title needs Screen Recording
    }
    if AXIsProcessTrusted() {
        for p in pids {
            let ui = AXUIElementCreateApplication(p)
            AXUIElementSetMessagingTimeout(ui, 3)
            for w in windows(ui) { out("AXWIN", String(p), title(w), String(texts(w).joined(separator: " ").prefix(300))) }
        }
    }
    exit(found > 0 ? 0 : 1)
}

guard args.count >= 5, let pid = pid_t(args[1]) else {
    FileHandle.standardError.write("usage: about_check <pid> <out.png> <EN|FR|DE|CS|JA> <4D.app> [timeout]\n       about_check --gatekeeper <app name> [timeout]\n       about_check --windows <pid|uiagent>\n       about_check --permissions | --request-accessibility | --request-screen\n".data(using: .utf8)!)
    exit(64)
}
let png = args[2], lang = args[3].uppercased(), appPath = args[4]
let timeout = args.count > 5 ? (Double(args[5]) ?? 60) : 60
let ocrTag = ["EN": "en-US", "FR": "fr-FR", "DE": "de-DE", "CS": "cs-CZ", "JA": "ja-JP"][lang] ?? "en-US"

guard AXIsProcessTrusted() else { fail("AX", axMissing) }

let app = AXUIElementCreateApplication(pid)
AXUIElementSetMessagingTimeout(app, 5)

// "About 4D" = first item of the application menu (2nd menu of the menu bar), whatever the language
var aboutItem: AXUIElement?
let deadline = Date().addingTimeInterval(timeout)
while Date() < deadline {
    if let bar = element(app, kAXMenuBarAttribute) {
        let menus = kids(bar)
        if menus.count > 1, let menu = kids(menus[1]).first, let first = kids(menu).first,
           !title(first).isEmpty, (attr(first, kAXEnabledAttribute) as? Bool) ?? true {
            aboutItem = first
            break
        }
    }
    usleep(500_000)
}
guard let item = aboutItem else { fail("MENU", "4D application menu not found (pid \(pid))") }
out("MENU", title(item))

let before = windows(app)
let pressed = AXUIElementPerformAction(item, kAXPressAction as CFString)
guard pressed == .success else { fail("MENU", "cannot open the About box (AXPress error \(pressed.rawValue))") }

// ---------- expected texts (4D resources of the tested language) ----------
func norm(_ s: String) -> String {
    let f = s.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
    return String(String.UnicodeScalarView(f.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }))
}
func expectedTexts() -> [(String, String)] {
    let xlf = "\(appPath)/Contents/Resources/Internal Components/runtime.4dbase/Contents/Resources/\(lang.lowercased()).lproj/About\(lang).xlf"
    guard let doc = try? XMLDocument(contentsOf: URL(fileURLWithPath: xlf), options: []) else { return [] }
    return ["AboutGenericWindowTitle", "AboutThisProductIsLicensedTo", "AboutLegalInformations", "4DAroundTheWorld"].compactMap { key in
        guard let unit = (try? doc.nodes(forXPath: "//trans-unit[@resname='\(key)']"))?.first as? XMLElement else { return nil }
        let t = unit.elements(forName: "target").first?.stringValue ?? unit.elements(forName: "source").first?.stringValue ?? ""
        return t.isEmpty ? nil : (key, t)
    }
}
let expected = expectedTexts()

// ---------- About window ----------
var win: AXUIElement?
let d2 = Date().addingTimeInterval(20)
while win == nil && Date() < d2 {
    usleep(300_000)
    win = windows(app).first { w in !before.contains { CFEqual($0, w) } }
}
if win == nil {
    // already open before the click: take the window titled like the About box
    let t = norm(expected.first { $0.0 == "AboutGenericWindowTitle" }?.1 ?? "")
    win = windows(app).first { !t.isEmpty && norm(title($0)) == t } ?? element(app, kAXFocusedWindowAttribute)
}
guard let about = win, let rect = frame(about) else { fail("WINDOW", "the About window did not open") }
let winTitle = title(about)
out("TITLE", winTitle)

func closeAbout() {
    if let b = element(about, kAXCloseButtonAttribute) { AXUIElementPerformAction(b, kAXPressAction as CFString) }
}

// ---------- capture + OCR ----------
func windowID() -> CGWindowID? {
    let list = (CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]) ?? []
    var byName: CGWindowID?
    for w in list where (w[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == pid {
        guard let num = (w[kCGWindowNumber as String] as? NSNumber)?.uint32Value else { continue }
        if let b = w[kCGWindowBounds as String] as? NSDictionary, let r = CGRect(dictionaryRepresentation: b as CFDictionary),
           abs(r.minX - rect.minX) < 3, abs(r.minY - rect.minY) < 3, abs(r.width - rect.width) < 3, abs(r.height - rect.height) < 3 {
            return num
        }
        if byName == nil, (w[kCGWindowName as String] as? String) == winTitle { byName = num }
    }
    return byName
}
func capture(_ wid: CGWindowID) -> CGImage? {
    try? FileManager.default.removeItem(atPath: png)
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
    p.arguments = ["-x", "-o", "-l\(wid)", png]
    guard (try? p.run()) != nil else { return nil }
    p.waitUntilExit()
    guard let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: png) as CFURL, nil) else { return nil }
    return CGImageSourceCreateImageAtIndex(src, 0, nil)
}
func ocr(_ img: CGImage) -> [String] {
    let req = VNRecognizeTextRequest()
    req.recognitionLevel = .accurate
    req.usesLanguageCorrection = false
    let supported = (try? req.supportedRecognitionLanguages()) ?? []
    let langs = [ocrTag, "en-US"].filter { supported.contains($0) }
    if !langs.isEmpty { req.recognitionLanguages = langs }
    try? VNImageRequestHandler(cgImage: img, options: [:]).perform([req])
    return (req.results ?? []).compactMap { $0.topCandidates(1).first?.string }
}

func report(_ lines: [String]) {
    let all = norm(lines.joined(separator: " "))
    var titleOK = true, found = 0, total = 0
    for (key, text) in expected {
        let ok: Bool
        if key == "AboutGenericWindowTitle" { ok = norm(winTitle) == norm(text); titleOK = ok }
        else {
            if lines.isEmpty { continue }
            total += 1
            ok = all.contains(norm(text))
            if ok { found += 1 }
        }
        out("LOC", ok ? "OK" : "KO", key, text)
    }
    if expected.isEmpty { out("LANG", "KO", "About\(lang).xlf not found in the 4D app") }
    else if titleOK && (lines.isEmpty || found > 0) { out("LANG", "OK", "window title" + (lines.isEmpty ? "" : " + \(found)/\(total) texts") + " in \(lang)") }
    else { out("LANG", "KO", "About box not in \(lang): title '\(winTitle)', \(found)/\(total) texts found") }
}

guard CGPreflightScreenCaptureAccess() else {
    report([])
    closeAbout()
    fail("SCREEN", "Screen Recording permission missing: System Settings > Privacy & Security > Screen & System Audio Recording > allow Test Installer 4D (or Terminal), then re-run", 3)
}
guard let wid = windowID() else { closeAbout(); fail("CAPTURE", "About window not found in the window list") }

// the content is a web area, painted only when the window is visible: 4D to the front, About window raised,
// then wait until the version line is displayed
AXUIElementSetAttributeValue(app, kAXFrontmostAttribute as CFString, kCFBooleanTrue)
AXUIElementPerformAction(about, kAXRaiseAction as CFString)
var lines: [String] = []
var rendered = false
let d3 = Date().addingTimeInterval(20)
repeat {
    usleep(lines.isEmpty ? 1_500_000 : 1_000_000)
    AXUIElementPerformAction(about, kAXRaiseAction as CFString)
    guard let img = capture(wid) else { continue }
    lines = ocr(img)
    rendered = lines.contains { $0.range(of: "[0-9]+\\.[0-9]{3,}", options: .regularExpression) != nil }
} while !rendered && Date() < d3
if FileManager.default.fileExists(atPath: png) { out("PNG", png) }
lines.forEach { out("OCR", $0) }
report(rendered ? lines : [])
closeAbout()
if !rendered { fail("RENDER", "About box content not displayed after 20 s (screen locked or asleep?): see the screenshot", 4) }
exit(0)
