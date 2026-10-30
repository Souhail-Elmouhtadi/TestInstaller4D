import SwiftUI
import AppKit
import UniformTypeIdentifiers

// State and actions of the app. The bash kit (~/TestInstaller4D, copied from the bundle) does the work:
// download_4d.sh (download / detection), dmg_info.sh (content of the image), install_4d.sh (installation),
// qa_mac.sh (checklist), rapport_mac.sh (report). The app never blocks its interface: every child process runs
// off the main actor and reports through events.

enum PrereqState: Equatable {
    case checking, ok, warn, info
    var tone: Tone {
        switch self { case .checking: return .progress; case .ok: return .success; case .warn: return .warning; case .info: return .info }
    }
    var label: String {
        switch self { case .checking: return "Vérification…"; case .ok: return "OK"; case .warn: return "À vérifier"; case .info: return "Facultatif" }
    }
    var symbol: String {
        switch self {
        case .checking: return "hourglass"; case .ok: return "checkmark.circle.fill"
        case .warn: return "exclamationmark.triangle.fill"; case .info: return "info.circle.fill"
        }
    }
}

struct Prereq: Identifiable, Equatable {
    let id: String
    let title: String
    var state: PrereqState
    var detail: String
    var action: String? = nil
}

enum DMGReadState: Equatable { case none, reading, read, failed(String) }

enum OpState: Equatable {
    case idle
    case running(progress: Double?, step: String)
    case succeeded(String)
    case failed(title: String, message: String)
    case cancelled(String)
    var isRunning: Bool { if case .running = self { return true }; return false }
}

struct ExistingInstall: Equatable {
    let path: String
    let version: String
    let build: String
    let same: Bool
}

enum PermissionCheckReason { case startup, foreground, recheck, afterRequest }

// lines of a child process, delivered complete (a chunk may end in the middle of a line)
final class LineBuffer: @unchecked Sendable {
    private var data = Data()
    private let lock = NSLock()
    func append(_ d: Data) -> [String] {
        lock.lock(); defer { lock.unlock() }
        data.append(d)
        var lines: [String] = []
        while let i = data.firstIndex(of: 0x0A) {
            lines.append(String(decoding: data[data.startIndex..<i], as: UTF8.self))
            data.removeSubrange(data.startIndex...i)
        }
        return lines
    }
    func flush() -> [String] {
        lock.lock(); defer { lock.unlock() }
        guard !data.isEmpty else { return [] }
        let s = String(decoding: data, as: UTF8.self); data.removeAll()
        return [s]
    }
}

// ---------- application icon in the Dock ----------
// The Dock and the Finder take the icon from LaunchServices, which can keep the icon of an older copy with the same
// bundle identifier (Trash, disk image, temporary build). While the app runs, its Dock tile shows the AppIcon.icns of
// the running bundle: set once at launch, never animated.
enum BundleIcon {
    static func url(bundle: URL) -> URL? {
        guard let info = NSDictionary(contentsOf: bundle.appendingPathComponent("Contents/Info.plist")),
              var name = info["CFBundleIconFile"] as? String, !name.isEmpty, !name.contains("/") else { return nil }
        if (name as NSString).pathExtension.isEmpty { name += ".icns" }
        let u = bundle.appendingPathComponent("Contents/Resources").appendingPathComponent(name)
        return FileManager.default.fileExists(atPath: u.path) ? u : nil
    }

    static func image(bundle: URL) -> NSImage? {
        guard let u = url(bundle: bundle), let img = NSImage(contentsOf: u), img.isValid,
              img.representations.contains(where: { $0.pixelsWide > 0 }) else { return nil }
        return img
    }

    // false (Dock unchanged) when the bundle has no readable icon, e.g. the bare executable of a development build
    @MainActor @discardableResult
    static func applyToDock(bundle: URL = Bundle.main.bundleURL) -> Bool {
        guard let img = image(bundle: bundle) else { return false }
        NSApp.applicationIconImage = img
        return true
    }
}

@MainActor
final class Runner: ObservableObject {
    let languages = ["EN", "FR", "DE", "CS", "JA"]
    let products = ["4D", "4D Server", "4D Volume Desktop"]
    let demo: Bool

    // ---------- selection: single source of truth for the installation, the checklist and the results ----------
    @Published var dmgPath = "" { didSet { if dmgPath != oldValue { selectionChanged() } } }
    @Published var product = "4D" { didSet { if product != oldValue { applyDMGInfo(); selectionChanged() } } }
    @Published var version = "" { didSet { if version != oldValue { selectionChanged() } } }
    @Published var build = "" { didSet { if build != oldValue { selectionChanged() } } }
    // detected from the hardware of this Mac (never chosen, never read from a saved configuration)
    @Published var platformError: String?
    @Published var platformNote = ""
    @Published var platform = "" { didSet { if platform != oldValue { selectionChanged() } } }
    @Published var dmgApps: [DMGApp] = []
    @Published var dmgState: DMGReadState = .none
    @Published var dmgSize: Int64 = 0
    @Published var dmgSHA = ""

    // ---------- download ----------
    @Published var candidates: [DownloadCandidate] = []
    @Published var watch = DownloadWatch()   // single source of truth of the Downloads watch
    @Published var scanError: String?        // last scan of Downloads failed: the list is not "empty", it is unknown
    @Published var directURL = ""
    @Published var downloadOp: OpState = .idle
    var watchInterval: TimeInterval = 3      // tests: shorter
    var watchLimit: TimeInterval = 7200
    var watching: Bool { watch.isWatching }

    // ---------- installation ----------
    @Published var installDest = "/Applications"
    @Published var installOp: OpState = .idle
    @Published var installRecord: InstallRecord?
    @Published var existing: ExistingInstall?
    @Published var showExistingAlert = false
    // window of the disk image: checked (files + Finder window + screenshot) before every installation
    @Published var dmgWindow: DMGWindowCheck?
    @Published var windowOp: OpState = .idle
    var dmgWindowStatePath: String { work.appendingPathComponent("dmg_window.tsv").path }

    // ---------- permissions and prerequisites ----------
    @Published var ax = PermissionTracker()
    @Published var screen = PermissionTracker()
    @Published var permissionProcess = ""
    @Published var permissionCheckedAt: Date?
    @Published var signing: SigningInfo?
    @Published var prereqs: [Prereq] = []

    // ---------- checklist ----------
    @Published var selectedLanguages: Set<String> = ["EN"]
    @Published var testControl = true
    @Published var testGitHub = true
    @Published var testIC = false
    @Published var netAuto = false
    @Published var icFiles: [String] = []
    @Published var log = ""
    @Published var rowsByLang: [String: ResultFile] = [:]
    @Published var viewLanguage = "EN"
    @Published var running = false
    @Published var progressText = ""
    @Published var reportPath = ""
    @Published var status = "Prêt"
    @Published var staleNote = ""
    @Published var restoreNeeded = false

    var resultsContext: ResultsContext?
    private var runID = ""
    private var process: Process?
    private var downloadProcess: Process?
    private var queue: [String] = []
    private var total = 0
    private var currentLanguage = ""
    private var stopped = false
    // automatic offline test: environment given to each language run, guard started for this run
    private var netEnv: [String: String] = [:]
    private var guardSession = false
    private var didSetup = false
    private var permissionToken = UUID()
    private var prereqToken = UUID()
    private var lastPermissionCheck: Date?
    private var lastRowsLoad = Date.distantPast
    private var watchTask: Task<Void, Never>?
    private var installError: (code: String, message: String)?
    private var downloadError: (code: String, message: String)?
    private var downloadInfo: [String: String] = [:]

    let home: URL
    private let helperDir: URL?
    var kit: URL { home.appendingPathComponent("TestInstaller4D") }
    var work: URL { home.appendingPathComponent("4DQA_mac") }
    var downloadsDir: URL { home.appendingPathComponent("Downloads") }
    var installStatePath: String { work.appendingPathComponent("install_state.tsv").path }

    // home and helperDir: injected by the tests (fake engine and helpers); the app uses the real ones
    init(demo: Bool = false, home: URL? = nil, helperDir: URL? = nil) {
        self.demo = demo
        self.home = home ?? FileManager.default.homeDirectoryForCurrentUser
        self.helperDir = helperDir
    }

    // signed helpers of the bundle (Contents/Helpers): the processes that use Accessibility and Screen Recording
    func helper(_ name: String) -> String {
        if let d = helperDir { return d.appendingPathComponent(name).path }
        return Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/\(name)").path
    }

    var selection: Selection { Selection(dmg: dmgPath, product: product, version: version, build: build, platform: platform) }
    var installStamp: String { (try? String(contentsOfFile: installStatePath, encoding: .utf8)) ?? "" }
    var busy: Bool { running || installOp.isRunning || downloadOp.isRunning || windowOp.isRunning }

    // Called from .task (not from init): SwiftUI must not be re-entered while it creates the @StateObject.
    func setup() {
        guard !didSetup, !demo else { return }
        didSetup = true
        signing = SigningInfo.current()
        installKit()
        detectPlatform()
        selectedLanguages = [Runner.currentLanguage()]
        viewLanguage = Runner.currentLanguage()
        loadPreviousConf()
        refreshIC()
        refreshInstallRecord()
        if !dmgPath.isEmpty {
            if FileManager.default.fileExists(atPath: dmgPath) {
                appendLog("Image disque de la session précédente : \(dmgPath)")
                readDMG()
            } else {
                appendLog("Image disque de la session précédente introuvable : \(dmgPath)")
                dmgPath = ""; version = ""; build = ""
            }
        }
        scanDownloads()
        recoverLeftovers()
        refreshPermissions(.startup)
        refreshPrereqs()
    }

    func detectPlatform(_ r: Result<String, PlatformError> = HostPlatform.detect()) {
        switch r {
        case .success(let p):
            platform = p; platformError = nil
            platformNote = HostPlatform.translated ? "Test Installer 4D tourne sous Rosetta : plateforme lue sur le matériel" : ""
        case .failure(let e):
            platform = ""; platformError = "Plateforme non détectée : \(e.message)"; appendLog("== \(platformError!) ==")
        }
    }

    // hardware of the Mac (Apple Silicon even when this process is translated by Rosetta)
    static var isARM: Bool { HostPlatform.sysctlInt("hw.optional.arm64") == 1 }

    static func currentLanguage() -> String {
        let code = (Locale.preferredLanguages.first ?? "en").prefix(2).uppercased()
        return ["EN", "FR", "DE", "CS", "JA"].contains(code) ? code : "EN"
    }

    func appendLog(_ s: String) {
        log += s.hasSuffix("\n") ? s : s + "\n"
        if log.count > 600_000 { log = "…\n" + String(log.suffix(450_000)) }
    }

    // ---------- kit ----------
    func installKit() {
        guard let src = Bundle.main.resourceURL?.appendingPathComponent("kit") else { return }
        let fm = FileManager.default
        do {
            try fm.createDirectory(at: kit, withIntermediateDirectories: true)
            // Refresh tools while keeping configuration, reports, custom words and plugin zips.
            for name in try fm.contentsOfDirectory(atPath: src.path) {
                let s = src.appendingPathComponent(name), d = kit.appendingPathComponent(name)
                if ["kit.conf", "results", "readme_words.txt"].contains(name), fm.fileExists(atPath: d.path) { continue }
                if name == "ic" {
                    try fm.createDirectory(at: d, withIntermediateDirectories: true)
                    continue
                }
                if fm.fileExists(atPath: d.path) { try fm.removeItem(at: d) }
                try fm.copyItem(at: s, to: d)
            }
            // the helpers only run from Contents/Helpers of the signed app (never copied): copies left in the kit by
            // versions < 3.4 are removed
            for name in ["about_check", "readme_check"] {
                let d = kit.appendingPathComponent(name)
                if fm.fileExists(atPath: d.path) { try fm.removeItem(at: d) }
            }
        } catch {
            status = "Mise à jour du moteur impossible : \(error.localizedDescription)"
            appendLog(status)
            return
        }
        // no quarantine is ever removed: the scripts are run with /bin/bash (not assessed by Gatekeeper)
        let k = Runner.q(kit.path)
        _ = Proc.run("/bin/bash", ["-c", "cd \(k) && chmod +x *.sh *.command 2>/dev/null; true"], timeout: 20)
    }

    func loadPreviousConf() {
        let f = kit.appendingPathComponent("kit.conf").path
        guard FileManager.default.fileExists(atPath: f) else { return }
        // let bash unquote the %q values
        let out = Proc.run("/bin/bash", ["-c", ". \(Runner.q(f)); printf '%s\\n' \"$PRODUCT\" \"$VERSION\" \"$BUILD\" \"$DMG\" \"$TEST_CONTROL\" \"$TEST_GITHUB\" \"${NET_AUTO:-0}\" \"$LANGS\" \"${INSTALL_DEST:-/Applications}\""], timeout: 10)
        let v = out.output.components(separatedBy: "\n")
        guard v.count >= 9 else { return }
        if products.contains(v[0]) { product = v[0] }
        version = v[1]; build = v[2]; dmgPath = v[3]
        testControl = v[4] != "0"; testGitHub = v[5] != "0"
        netAuto = v[6] == "1"
        let l = Set(v[7].split(separator: " ").map(String.init)).intersection(languages)
        if !l.isEmpty { selectedLanguages = l; viewLanguage = languages.first { l.contains($0) } ?? viewLanguage }
        if !v[8].isEmpty { installDest = v[8] }
    }

    // ---------- disk image ----------
    func setDMG(_ path: String) {
        guard !busy else { return }
        dmgPath = path
        version = ""; build = ""
        endWatch("image choisie : \((path as NSString).lastPathComponent)")
        readDMG()
    }

    // version and build come from the Info.plist of the applications inside the image: never guessed from its name
    func readDMG() {
        let path = dmgPath, script = kit.appendingPathComponent("dmg_info.sh").path
        guard !path.isEmpty else { dmgState = .none; return }
        guard FileManager.default.fileExists(atPath: path) else { dmgState = .failed("Fichier introuvable : \(path)"); return }
        dmgState = .reading
        dmgApps = []; dmgSHA = ""
        dmgSize = ((try? FileManager.default.attributesOfItem(atPath: path))?[.size] as? NSNumber)?.int64Value ?? 0
        Task.detached { [weak self] in
            let out = Proc.run("/bin/bash", [script, path], timeout: 240)
            await self?.dmgRead(path, out)
        }
        Task.detached { [weak self] in
            let out = Proc.run("/usr/bin/shasum", ["-a", "256", path], timeout: 900)
            await self?.dmgHashed(path, out)
        }
    }

    private func dmgRead(_ path: String, _ out: ProcessOutput) {
        guard path == dmgPath else { return }
        dmgApps = DMGContent.parse(out.output)
        if dmgApps.isEmpty {
            let why = out.timedOut ? "lecture interrompue après 4 min" : "montage impossible, image endommagée ou sans application 4D"
            dmgState = .failed("Contenu de l'image illisible (\(why)). La version et le build ne sont pas devinés : choisissez une autre image.")
            version = ""; build = ""
            appendLog("Image disque illisible : \(path)\n\(out.output.suffix(600))")
        } else {
            dmgState = .read
            appendLog("Contenu de l'image : " + dmgApps.map { "\($0.name) \($0.version) build \($0.build) (\($0.relativePath))" }.joined(separator: " ; "))
            applyDMGInfo()
        }
    }

    private func dmgHashed(_ path: String, _ out: ProcessOutput) {
        guard path == dmgPath else { return }
        let h = out.output.split(separator: " ").first.map { String($0).uppercased() } ?? ""
        if out.status == 0, h.count == 64 {
            dmgSHA = h
            appendLog("Image disque : \(path) — \(ByteCountFormatter.string(fromByteCount: dmgSize, countStyle: .file)) (\(dmgSize) octets) — SHA-256 \(h)")
        } else {
            dmgSHA = "?"
        }
    }

    var productInDMG: DMGApp? { DMGContent.app(dmgApps, product: product) }

    func applyDMGInfo() {
        guard dmgState == .read else { return }
        if let a = productInDMG {
            if version != a.version { version = a.version }
            if build != a.build { build = a.build }
        } else {
            // the selected product is not in the image: no other application is taken in its place
            version = ""; build = ""
        }
    }

    // version/build typed by the user and different from the image: the installation will refuse it
    var dmgMismatch: String? {
        guard let a = productInDMG, !version.isEmpty || !build.isEmpty else { return nil }
        if Version.normalize(version) != Version.normalize(a.version) || build.trimmingCharacters(in: .whitespaces) != a.build {
            return "L'image contient \(a.name) \(a.version) build \(a.build), pas \(version) build \(build) : l'installation et la checklist le signaleront en échec."
        }
        return nil
    }

    func chooseDMG() {
        let panel = NSOpenPanel()
        panel.title = "Choisissez l'image disque 4D téléchargée depuis product-download.4d.com"
        panel.allowedContentTypes = [UTType(filenameExtension: "dmg") ?? .diskImage]
        panel.directoryURL = downloadsDir
        if panel.runModal() == .OK, let url = panel.url { setDMG(url.path) }
    }

    // ---------- download ----------
    private var downloadsScan: (script: String, dir: String) { (kit.appendingPathComponent("download_4d.sh").path, downloadsDir.path) }

    nonisolated private static func scan(_ script: String, _ dir: String) async -> DownloadWatch.ScanResult {
        await Task.detached { DownloadCandidate.scanResult(Proc.run("/bin/bash", [script, "--scan", dir], timeout: 60), folder: dir) }.value
    }

    func scanDownloads() {
        let s = downloadsScan
        Task { [weak self] in
            let result = await Runner.scan(s.script, s.dir)
            self?.scanned(result)
        }
    }

    private func scanned(_ result: DownloadWatch.ScanResult) {
        switch result {
        case .ok(let found):
            candidates = Array(found.prefix(8)); scanError = nil
        case .failure(let why):
            if scanError != why { appendLog("Recherche des images dans Téléchargements impossible : \(why)") }
            scanError = why
        }
    }

    func isNew(_ c: DownloadCandidate) -> Bool { watch.isNew(c) }

    // sign-in and download in the browser: the tool never asks for nor stores a password
    func openDownloadPage() {
        NSWorkspace.shared.open(URL(string: "https://product-download.4d.com/")!)
        startWatching()
    }

    // one scan at a time (awaited), until an image is found, an error repeats, the time limit or an image is chosen
    func startWatching() {
        watchTask?.cancel()
        watch.start(at: Date(), limit: watchLimit)
        appendLog("Surveillance de \(downloadsDir.path) : l'image apparaîtra une fois le téléchargement complet")
        let s = downloadsScan
        watchTask = Task { [weak self] in
            while !Task.isCancelled {
                let result = await Runner.scan(s.script, s.dir)
                guard !Task.isCancelled, let self, self.watch.isWatching else { return }
                self.scanned(result)
                for l in self.watch.apply(result, now: Date()) { self.appendLog(l) }
                guard self.watch.isWatching else { return }
                try? await Task.sleep(nanoseconds: UInt64(self.watchInterval * 1_000_000_000))
            }
        }
    }

    func stopWatching() { endWatch("arrêtée par l'utilisateur") }

    // « Fermer » on a finished watch (image found, error, time limit)
    func dismissWatch() { watchTask?.cancel(); watch.stop() }

    private func endWatch(_ why: String) {
        watchTask?.cancel(); watchTask = nil
        if watch.isWatching { appendLog("Surveillance de Téléchargements terminée : \(why)") }
        watch.imageChosen()
    }

    func useCandidate(_ c: DownloadCandidate) {
        guard c.usable else { return }
        setDMG(c.path)
    }

    var directURLValid: Bool {
        guard let u = URL(string: directURL.trimmingCharacters(in: .whitespaces)), u.scheme?.lowercased() == "https",
              let h = u.host?.lowercased(), u.user == nil, u.password == nil else { return false }
        return h == "4d.com" || h.hasSuffix(".4d.com")
    }

    func downloadDirect() {
        guard directURLValid, !busy else { return }
        let url = directURL.trimmingCharacters(in: .whitespaces)
        downloadError = nil; downloadInfo = [:]
        downloadOp = .running(progress: nil, step: "Connexion à \(URL(string: url)?.host ?? "")…")
        appendLog("== Téléchargement direct : \(url) ==")
        downloadProcess = startStreaming([kit.appendingPathComponent("download_4d.sh").path, "--url", url, "--dir", downloadsDir.path],
            onLine: { [weak self] l in self?.downloadEvent(l) },
            done: { [weak self] code in self?.downloadFinished(code) })
    }

    private func downloadEvent(_ line: String) {
        switch EngineEvent.parse(line) {
        case .step(let s): downloadOp = .running(progress: nil, step: s); appendLog("  " + s)
        case .progress(let p, let t): downloadOp = .running(progress: Double(p) / 100, step: t)
        case .info(let k, let v): downloadInfo[k] = v; appendLog("  \(k) : \(v)")
        case .error(let c, let m): downloadError = (c, m); appendLog("  ERREUR \(c) : \(m)")
        case .result(_, let p): if !p.isEmpty { downloadInfo["PATH"] = p }
        case .exists, .other: if !line.isEmpty { appendLog("  " + line) }
        }
    }

    private func downloadFinished(_ code: Int32) {
        downloadProcess = nil
        if case .cancelled = downloadOp { scanDownloads(); return }
        if code == 0, let p = downloadInfo["PATH"], FileManager.default.fileExists(atPath: p) {
            let size = Int64(downloadInfo["SIZE"] ?? "") ?? 0
            downloadOp = .succeeded("\((p as NSString).lastPathComponent) — \(ByteCountFormatter.string(fromByteCount: size, countStyle: .file)) — SHA-256 \(downloadInfo["SHA256"] ?? "?")")
            scanDownloads()
            setDMG(p) // the file the user has just asked for
        } else {
            let c = downloadError?.code ?? "NETWORK"
            var msg = downloadError?.message ?? "le téléchargement s'est arrêté (code \(code))"
            if c == "AUTH" { msg += " — Connectez-vous dans le navigateur (bouton « Télécharger dans le navigateur ») : l'outil ne demande ni n'enregistre aucun mot de passe." }
            downloadOp = .failed(title: EngineEvent.title(ofError: c), message: msg)
            scanDownloads()
        }
    }

    func cancelDownload() {
        guard let p = downloadProcess, p.isRunning else { return }
        downloadOp = .cancelled("Téléchargement annulé : le fichier partiel est supprimé.")
        p.terminate()
    }

    // ---------- installation ----------
    func refreshInstallRecord() {
        guard !demo else { return }
        installRecord = FileManager.default.fileExists(atPath: installStatePath) ? InstallRecord.parse(installStamp) : nil
    }

    var installedForSelection: Bool { installRecord?.matches(selection) ?? false }

    var canInstall: Bool {
        !busy && dmgState == .read && productInDMG != nil && !version.isEmpty && !build.isEmpty && !platform.isEmpty
    }

    func chooseInstallDest() {
        let panel = NSOpenPanel()
        panel.title = "Dossier d'installation de 4D"
        panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.canCreateDirectories = true
        panel.directoryURL = URL(fileURLWithPath: installDest)
        if panel.runModal() == .OK, let url = panel.url { installDest = url.path; saveConf() }
    }

    var dmgStamp: String {
        guard let a = try? FileManager.default.attributesOfItem(atPath: dmgPath),
              let n = a[.size] as? NSNumber, let d = a[.modificationDate] as? Date else { return "" }
        return "\(n.int64Value) \(Int(d.timeIntervalSince1970))"
    }

    // "Installer et vérifier": the window of the disk image is always checked first and compared automatically with the reference window
    func install() {
        guard canInstall, !windowOp.isRunning else { return }
        let v = Version.normalize(version)
        if v != version { version = v }
        installError = nil; existing = nil; dmgWindow = nil; installOp = .idle
        windowOp = .running(progress: 0, step: "Contrôle de la fenêtre de l'image disque")
        appendLog("== Fenêtre de l'image disque : \(dmgPath) ==")
        let args = [kit.appendingPathComponent("dmg_window.sh").path, "--dmg", dmgPath, "--product", product,
                    "--version", version, "--build", build, "--state", dmgWindowStatePath]
        process = startStreaming(args, onLine: { [weak self] l in self?.windowEvent(l) },
                                 done: { [weak self] code in self?.windowFinished(code) })
    }

    private func windowEvent(_ line: String) {
        let f = line.components(separatedBy: " ")
        switch f.first {
        case "STEP": let t = f.dropFirst().joined(separator: " "); windowOp = .running(progress: 0, step: t); appendLog("• " + t)
        case "CHECK": appendLog("  [\(f.count > 1 ? f[1] : "")] " + f.dropFirst(2).joined(separator: " "))
        default: if !line.isEmpty { appendLog("  " + line) }
        }
    }

    private func windowFinished(_ code: Int32) {
        process = nil
        let txt = (try? String(contentsOfFile: dmgWindowStatePath, encoding: .utf8)) ?? ""
        let c = DMGWindowCheck.parse(txt)
        guard !txt.isEmpty, c.matches(selection, stamp: dmgStamp) else {
            dmgWindow = nil
            windowOp = .failed(title: "Contrôle de la fenêtre impossible", message: "aucun résultat exploitable (code \(code)) : voir le journal. L'installation n'a pas été lancée.")
            return
        }
        dmgWindow = c
        switch c.status {
        case .pending:
            windowOp = .idle
            status = "Vérifiez la capture de la fenêtre de l'image disque, puis confirmez pour installer."
        case .ok: windowOp = .succeeded(c.shot); runInstall(mode: nil)
        case .ko:
            windowOp = .failed(title: "Fenêtre de l'image disque non conforme", message: (c.failures.first ?? "voir le détail") + " — installation non lancée.")
        case .action:
            windowOp = .failed(title: "Action requise", message: (c.failures.first ?? c.lines.last?.text ?? "autorisation manquante") + " — installation non lancée.")
        case .error:
            windowOp = .failed(title: "Erreur du contrôle de la fenêtre", message: (c.lines.last?.text ?? "voir le journal") + " — installation non lancée.")
        }
    }

    // the user's verdict on the screenshot; only "conforme" lets the installation start
    func confirmDMGWindow(_ yes: Bool) {
        guard let c = dmgWindow, c.status == .pending, c.matches(selection, stamp: dmgStamp) else {
            dmgWindow = nil; windowOp = .failed(title: "Contrôle périmé", message: "l'image disque ou la sélection a changé : relancez « Installer et vérifier ».")
            return
        }
        let script = kit.appendingPathComponent("dmg_window.sh").path, dmg = dmgPath, state = dmgWindowStatePath
        windowOp = .running(progress: 0, step: "Enregistrement du verdict")
        Task.detached {
            let r = Proc.run("/bin/bash", [script, "--confirm", yes ? "yes" : "no", "--dmg", dmg, "--state", state], timeout: 20)
            await MainActor.run { self.confirmFinished(yes, r.output) }
        }
    }

    private func confirmFinished(_ yes: Bool, _ output: String) {
        let n = DMGWindowCheck.parse((try? String(contentsOfFile: dmgWindowStatePath, encoding: .utf8)) ?? "")
        dmgWindow = n
        appendLog("  Fenêtre de l'image disque : \(n.verdict.isEmpty ? output : n.verdict)")
        if yes && n.status == .ok { windowOp = .succeeded(n.shot); runInstall(mode: nil) }
        else if yes { windowOp = .failed(title: "Confirmation non enregistrée", message: "relancez « Installer et vérifier ».") }
        else { windowOp = .failed(title: "Fenêtre de l'image disque non conforme", message: "rejetée sur la capture — installation non lancée.") }
    }

    private func runInstall(mode: String?) {
        guard canInstall else { return }
        let v = Version.normalize(version)
        if v != version { version = v }
        installError = nil; existing = nil
        installOp = .running(progress: 0, step: "Préparation")
        var args = [kit.appendingPathComponent("install_4d.sh").path, "--dmg", dmgPath, "--product", product, "--version", version,
                    "--build", build, "--platform", platform, "--dest", installDest, "--state", installStatePath]
        if let mode { args.append("--\(mode)") }
        appendLog("== Installation de \(product) \(version) build \(build) (\(platform)) dans \(installDest)\(mode.map { " — \($0)" } ?? "") ==")
        saveConf()
        process = startStreaming(args, onLine: { [weak self] l in self?.installEvent(l) },
                                 done: { [weak self] code in self?.installFinished(code) })
    }

    private func installEvent(_ line: String) {
        switch EngineEvent.parse(line) {
        case .step(let s): appendLog("• " + s)
        case .progress(let p, let t): installOp = .running(progress: Double(p) / 100, step: t)
        case .info(let k, let v): appendLog("  \(k) : \(v)")
        case .exists(let path, let v, let b, let same):
            existing = ExistingInstall(path: path, version: v, build: b, same: same)
            appendLog("  Installation existante : \(path) (\(v) build \(b))")
        case .error(let c, let m): installError = (c, m); appendLog("  ERREUR \(c) : \(m)")
        case .result(let ok, let p): appendLog("  Résultat : \(ok ? "installé et vérifié" : "échec") \(p)")
        case .other(let s): if !s.isEmpty { appendLog("  " + s) }
        }
    }

    private func installFinished(_ code: Int32) {
        process = nil
        refreshInstallRecord()
        switch code {
        case 0:
            installOp = .succeeded(installRecord?.app ?? "")
            status = "Installation terminée et vérifiée."
        case 3 where existing != nil:
            installOp = .cancelled("Une installation existe déjà : confirmation requise, rien n'a été modifié.")
            showExistingAlert = true
        default:
            let c = installError?.code ?? "COPY"
            if c == "INTERRUPTED" || code == 130 || code == 143 {
                installOp = .cancelled("Installation interrompue : la copie partielle est retirée et l'installation précédente remise en place.")
            } else {
                installOp = .failed(title: EngineEvent.title(ofError: c), message: installError?.message ?? "l'installation s'est arrêtée (code \(code)) : voir le journal")
            }
        }
        selectionChanged()
    }

    func cancelInstall() {
        guard installOp.isRunning || windowOp.isRunning, let p = process, p.isRunning else { return }
        p.terminate() // install_4d.sh: trap -> its own cleanup (own image detached, previous installation put back)
    }

    func resolveExisting(_ choice: String?) {
        showExistingAlert = false
        guard let choice else {
            installOp = .cancelled("Installation annulée : l'installation existante n'a pas été modifiée.")
            return
        }
        runInstall(mode: choice)
    }

    // ---------- results: shown only for the selection and the installation they were produced for ----------
    func selectionChanged() {
        guard !demo else { return }
        if let c = dmgWindow, !windowOp.isRunning, !c.matches(selection, stamp: dmgStamp) { dmgWindow = nil; windowOp = .idle }
        refreshInstallRecord()
        guard !running, let ctx = resultsContext else { return }
        if let why = ctx.invalidation(selection: selection, installStamp: installStamp) {
            rowsByLang = [:]; reportPath = ""; resultsContext = nil
            staleNote = "Résultats précédents effacés : \(why). Relancez la checklist."
            appendLog("== \(staleNote) ==")
        }
    }

    // ---------- permissions (checked by the helper that uses them, in a fresh process) ----------
    func tracker(_ k: PermissionKind) -> PermissionTracker { k == .accessibility ? ax : screen }

    private func updateTracker(_ k: PermissionKind, _ f: (inout PermissionTracker) -> Void) {
        if k == .accessibility { f(&ax) } else { f(&screen) }
    }

    func refreshPermissions(_ reason: PermissionCheckReason) {
        guard !demo else { return }
        if reason == .foreground, let last = lastPermissionCheck, Date().timeIntervalSince(last) < 1.5 { return }
        lastPermissionCheck = Date()
        ax.beginCheck(); screen.beginCheck()
        let token = UUID(); permissionToken = token
        let h = helper("about_check")
        Task.detached { [weak self] in
            let out = Proc.run(h, ["--permissions"], timeout: 15)
            await self?.permissionsChecked(out, token: token, afterUserReturn: true)
        }
    }

    private func permissionsChecked(_ out: ProcessOutput, token: UUID, afterUserReturn: Bool) {
        guard token == permissionToken else { return }
        let snap = PermissionSnapshot.parse(out.output, exitCode: out.status,
                                            launchError: out.timedOut ? "pas de réponse en 15 s" : out.launchError)
        let changes = [(PermissionKind.accessibility, ax.apply(snap.accessibility, afterUserReturn: afterUserReturn)),
                       (PermissionKind.screen, screen.apply(snap.screen, afterUserReturn: afterUserReturn))]
        permissionProcess = snap.executable.isEmpty ? helper("about_check") : "\(snap.executable) (PID \(snap.pid))"
        permissionCheckedAt = Date()
        for (k, c) in changes {
            switch c {
            case .granted: appendLog("Autorisation « \(k.title) » : accordée (vérifiée par \(permissionProcess))")
            case .revoked: appendLog("⚠ Autorisation « \(k.title) » retirée\(running ? " pendant l'exécution : les étapes qui en dépendent échoueront" : "")")
            case .none: break
            }
        }
    }

    // explicit user action only: shows the macOS request (never a proof of permission)
    func requestPermission(_ k: PermissionKind) {
        guard !demo else { return }
        updateTracker(k) { $0.userRequested(); $0.beginCheck() }
        let token = UUID(); permissionToken = token
        let h = helper("about_check")
        appendLog("Demande d'autorisation « \(k.title) » affichée par macOS (à accepter dans Réglages Système)")
        Task.detached { [weak self] in
            let out = Proc.run(h, [k.requestFlag], timeout: 30)
            await self?.permissionsChecked(out, token: token, afterUserReturn: false)
        }
    }

    func openSettings(_ k: PermissionKind) {
        updateTracker(k) { $0.userRequested() }
        let urls = ["x-apple.systempreferences:com.apple.preference.security?\(k.settingsAnchor)",
                    "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?\(k.settingsAnchor)"]
        for s in urls { if let u = URL(string: s), NSWorkspace.shared.open(u) { return } }
    }

    // some permissions (Screen Recording in particular) apply only to a newly started app
    func relaunch() {
        guard !busy else { return }
        let app = Bundle.main.bundleURL.path, pid = getpid()
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", "while kill -0 \(pid) 2>/dev/null; do sleep 0.2; done; /usr/bin/open \(Runner.q(app))"]
        try? p.run()
        NSApp.terminate(nil)
    }

    // identity of the app as seen by macOS for the permissions
    var identityNotes: [(Tone, String)] {
        var n: [(Tone, String)] = []
        let path = Bundle.main.bundleURL.path
        if let s = signing {
            if s.kind.keepsPermissionsAcrossBuilds {
                n.append((.success, "Signature : \(s.kind.label) — identité stable (\(s.identifier)) : les autorisations restent valables après une mise à jour signée de la même façon."))
            } else {
                n.append((.warning, "Signature : \(s.kind.label) — macOS identifie cette copie par son empreinte : chaque nouvelle version de l'app est une nouvelle app pour Réglages Système (autorisation à redonner, entrées en double possibles)."))
            }
        }
        if path.contains("/AppTranslocation/") {
            n.append((.action, "L'app est lancée depuis un emplacement temporaire (translocation de Gatekeeper) : déplacez-la dans Applications puis relancez-la."))
        }
        if !FileManager.default.isExecutableFile(atPath: helper("about_check")) {
            n.append((.failure, "Outil de vérification absent : \(helper("about_check")). Réinstallez l'app."))
        }
        return n
    }

    // ---------- other prerequisites ----------
    func refreshPrereqs() {
        guard !demo else { return }
        let arm = Runner.isARM
        let token = UUID(); prereqToken = token
        var list: [Prereq] = []
        if arm { list.append(Prereq(id: "rosetta", title: "Rosetta", state: .checking, detail: "vérification…")) }
        list += [Prereq(id: "clt", title: "Command Line Tools", state: .checking, detail: "vérification…"),
                 Prereq(id: "net", title: "Réseau (test hors ligne)", state: .checking, detail: "vérification…"),
                 Prereq(id: "github", title: "API GitHub", state: .checking, detail: "vérification…")]
        prereqs = list
        let auto = netAuto
        Task.detached { [weak self] in
            let rosetta = arm ? Proc.run("/usr/bin/arch", ["-x86_64", "/usr/bin/true"], timeout: 10).status == 0 : false
            let clt = Proc.run("/usr/bin/xcode-select", ["-p"], timeout: 10).status == 0
            let admin = Proc.run("/usr/bin/id", ["-Gn"], timeout: 5).output.split(whereSeparator: { $0 == " " || $0 == "\n" }).contains("admin")
            let pf = Runner.pfConfEvaluatesAnchors()
            let gh = Proc.run("/bin/bash", ["-c", "j=\"$(curl -s --max-time 8 https://api.github.com/rate_limit)\"; printf '%s %s' \"$(printf '%s' \"$j\" | plutil -extract resources.core.remaining raw -o - - 2>/dev/null)\" \"$(printf '%s' \"$j\" | plutil -extract resources.core.reset raw -o - - 2>/dev/null)\""], timeout: 20).output
            await self?.prereqsChecked(token: token, rosetta: rosetta, clt: clt, admin: admin, auto: auto, pf: pf,
                                       github: gh.split(separator: " ").map(String.init))
        }
    }

    // the guard only loads rules into com.apple/000.TestInstaller4D: the standard /etc/pf.conf must evaluate com.apple/*
    nonisolated static func pfConfEvaluatesAnchors(_ path: String = "/etc/pf.conf") -> Bool {
        guard let txt = try? String(contentsOfFile: path, encoding: .utf8) else { return false }
        return txt.split(separator: "\n").contains { $0.trimmingCharacters(in: .whitespaces).hasPrefix("anchor \"com.apple/*\"") }
    }

    private func prereqsChecked(token: UUID, rosetta: Bool, clt: Bool, admin: Bool, auto: Bool, pf: Bool, github: [String]) {
        guard token == prereqToken else { return }
        prereqs = prereqs.map { p in
            var p = p
            switch p.id {
            case "rosetta":
                (p.state, p.detail, p.action) = rosetta ? (.ok, "installé (test Rosetta automatique, open --arch x86_64)", nil)
                                                        : (.warn, "absent : le test Rosetta échouera sans lui", "Installer…")
            case "clt":
                (p.state, p.detail, p.action) = clt ? (.ok, "installés (lipo, stapler)", nil)
                                                    : (.info, "absents : facultatifs, file / codesign sont utilisés à la place", "Installer…")
            case "net":
                if !auto { (p.state, p.detail) = (.ok, "vous coupez le réseau quand le test le demande (Wi-Fi, câble, VPN) ; l'absence d'Internet est vérifiée par plusieurs sondes avant le lancement") }
                else if !pf { (p.state, p.detail) = (.warn, "coupure automatique indisponible : /etc/pf.conf n'évalue pas les ancres com.apple/* (l'outil ne le modifie pas) ; la coupure manuelle vous sera demandée") }
                else if admin { (p.state, p.detail) = (.ok, "automatique (pare-feu pf) : au lancement de la checklist, confirmation puis mot de passe administrateur de macOS ; trafic bloqué pendant chaque test sans Internet seulement (5 min au plus), puis rétabli") }
                else { (p.state, p.detail) = (.info, "automatique (pare-feu pf) : compte standard, macOS demandera le nom et le mot de passe d'un administrateur ; sans eux, la coupure manuelle vous sera demandée") }
            case "github":
                if let left = Int(github.first ?? "") {
                    if left > 0 { (p.state, p.detail) = (.ok, "\(left) requêtes restantes ; erreurs passagères relancées automatiquement (3 essais)") }
                    else {
                        let reset = Double(github.count > 1 ? github[1] : "").map { Date(timeIntervalSince1970: $0).formatted(date: .omitted, time: .shortened) } ?? "?"
                        (p.state, p.detail) = (.warn, "quota de l'API épuisé jusqu'à \(reset) : le test attendra (15 min max) ou sera signalé")
                    }
                } else { (p.state, p.detail) = (.warn, "api.github.com inaccessible : le test GitHub sera relancé puis signalé") }
            default: break
            }
            return p
        }
    }

    func prereqAction(_ id: String) {
        switch id {
        case "rosetta":
            status = "Installation de Rosetta… (macOS demande un administrateur)"
            Task.detached { [weak self] in
                let r = Proc.run("/usr/bin/osascript", ["-e", "do shell script \"/usr/sbin/softwareupdate --install-rosetta --agree-to-license\" with administrator privileges"], timeout: 1800)
                await self?.actionDone("Rosetta : " + (r.status == 0 ? "terminé" : r.output))
            }
        case "clt":
            _ = Proc.run("/usr/bin/xcode-select", ["--install"], timeout: 10)
            status = "Command Line Tools : suivez la fenêtre d'installation d'Apple, puis « Revérifier »."
        default: break
        }
    }

    private func actionDone(_ msg: String) {
        status = String(msg.prefix(300))
        refreshPrereqs()
    }

    // ---------- plugins ----------
    func addICZips() {
        let panel = NSOpenPanel()
        panel.title = "Zips 4D Internet Commands supplémentaires (en plus du plugin de référence)"
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [.zip]
        panel.directoryURL = downloadsDir
        guard panel.runModal() == .OK else { return }
        let ic = kit.appendingPathComponent("ic")
        try? FileManager.default.createDirectory(at: ic, withIntermediateDirectories: true)
        for u in panel.urls {
            let d = ic.appendingPathComponent(u.lastPathComponent)
            try? FileManager.default.removeItem(at: d)
            try? FileManager.default.copyItem(at: u, to: d)
        }
        refreshIC()
        testIC = !icFiles.isEmpty
    }

    func clearIC() {
        for f in icFiles { try? FileManager.default.removeItem(at: kit.appendingPathComponent("ic").appendingPathComponent(f)) }
        refreshIC(); testIC = false
    }

    func refreshIC() {
        icFiles = ((try? FileManager.default.contentsOfDirectory(atPath: kit.appendingPathComponent("ic").path)) ?? [])
            .filter { $0.lowercased().hasSuffix(".zip") }.sorted()
    }

    var majorVersion: Int? {
        guard let r = version.range(of: "[0-9]+", options: .regularExpression) else { return nil }
        return Int(version[r])
    }

    // GitHub dependencies ("Follow 4D version") exist only from 4D 21
    var githubSupported: Bool { (majorVersion ?? 21) >= 21 }

    var icFixedVersion: String? {
        let plist = kit.appendingPathComponent("ic_fixed/4D InternetCommands.bundle/Contents/Info.plist")
        guard let d = NSDictionary(contentsOf: plist) else { return nil }
        return d["CFBundleShortVersionString"] as? String ?? "?"
    }

    // ---------- checklist ----------
    var runBlockers: [String] {
        var b: [String] = []
        if dmgPath.isEmpty { b.append("Sélectionnez une image disque 4D.") }
        else if dmgState == .reading { b.append("Lecture de l'image disque en cours…") }
        else if case .failed = dmgState { b.append("Image disque illisible.") }
        else if dmgState == .read && productInDMG == nil { b.append("\(product) est absent de l'image disque.") }
        if dmgState == .read && (version.isEmpty || build.isEmpty) && productInDMG != nil { b.append("Version et build requis.") }
        if selectedLanguages.isEmpty { b.append("Cochez au moins une langue.") }
        if platform.isEmpty { b.append(platformError ?? "Plateforme du Mac non détectée.") }
        return b
    }

    var canRun: Bool { !busy && runBlockers.isEmpty }

    func saveConf() {
        guard !demo else { return }
        let langs = languages.filter { selectedLanguages.contains($0) }
        let conf = """
        PRODUCT=\(Runner.q(product))
        VERSION=\(Runner.q(version))
        BUILD=\(Runner.q(build))
        PLATFORM=\(Runner.q(platform))
        DMG=\(Runner.q(dmgPath))
        TEST_CONTROL=\(testControl ? 1 : 0)
        TEST_GITHUB=\(testGitHub && githubSupported ? 1 : 0)
        TEST_IC=\(testIC && !icFiles.isEmpty ? 1 : 0)
        NET_AUTO=\(netAuto ? 1 : 0)
        LANGS=\(Runner.q(langs.joined(separator: " ")))
        INSTALL_DEST=\(Runner.q(installDest))

        """
        try? conf.write(to: kit.appendingPathComponent("kit.conf"), atomically: true, encoding: .utf8)
    }

    func run() {
        guard canRun else { return }
        let v = Version.normalize(version)
        if v != version { version = v }
        saveConf()
        let langs = languages.filter { selectedLanguages.contains($0) }
        let f = DateFormatter(); f.dateFormat = "yyyyMMdd-HHmmss"
        runID = "\(f.string(from: Date()))-\(getpid())"
        queue = langs; total = langs.count; stopped = false
        log = ""; rowsByLang = [:]; reportPath = ""; staleNote = ""
        resultsContext = ResultsContext(selection: selection, installStamp: installStamp)
        running = true
        appendLog("== Checklist \(product) \(version) build \(build) — \(platform) — exécution \(runID) ==")
        if !installedForSelection {
            appendLog("Aucune installation vérifiée de cette sélection : les tests de lancement seront « Non exécuté ».")
        }
        netEnv = [:]; guardSession = false
        guard netAuto else { runNext(); return }
        // one permission for the whole run: confirmation, then the macOS administrator dialog (never in this app)
        status = "Test sans Internet automatique : confirmez, puis saisissez le mot de passe administrateur dans la fenêtre de macOS…"
        appendLog("Test sans Internet automatique : demande d'autorisation (pare-feu pf)…")
        let args = [kit.appendingPathComponent("net_guard.sh").path, "start", String(getpid())]
        var env = ProcessInfo.processInfo.environment
        env["GUI"] = "1"; env["PATH"] = "/usr/bin:/bin:/usr/sbin:/sbin"
        Task.detached { [weak self, env] in
            let r = Proc.run("/bin/bash", args, timeout: 400, environment: env)
            await self?.guardStarted(r)
        }
    }

    private func guardStarted(_ r: ProcessOutput) {
        let line = r.output.split(separator: "\n").last.map(String.init) ?? ""
        let detail = line.split(separator: " ", maxSplits: 1).dropFirst().first.map(String.init) ?? line
        netEnv = ["NET_SESSION": "1"]
        switch r.status {
        case 0:
            guardSession = true
            appendLog("Garde réseau prêt : le trafic sera bloqué (pare-feu pf) pendant chaque test sans Internet, puis rétabli automatiquement (5 min au plus, ou dès que l'app se ferme).")
        case 2:
            netEnv["NET_GUARD_NOTE"] = "automatic cut declined at the start of the run"
            appendLog("Coupure automatique refusée : le test sans Internet vous demandera de couper le réseau vous-même.")
        default:
            let why = r.timedOut ? "no answer" : (detail.isEmpty ? "error \(r.status)" : detail)
            netEnv["NET_GUARD_NOTE"] = "automatic cut unavailable: \(why)"
            appendLog("Coupure automatique indisponible (\(why)) : coupure manuelle demandée.")
        }
        runNext()
    }

    private func quitGuard() {
        guard guardSession else { return }
        guardSession = false
        let args = [kit.appendingPathComponent("net_guard.sh").path, "quit"]
        Task.detached { [weak self] in
            let r = Proc.run("/bin/bash", args, timeout: 60)
            let ok = r.status == 0
            await self?.appendLog(ok ? "Garde réseau arrêté : aucune règle de pare-feu de l'outil ne reste active."
                                     : "Garde réseau : \(r.output.trimmingCharacters(in: .whitespacesAndNewlines)) — il s'arrête de lui-même à la fermeture de l'app.")
        }
    }

    private func runNext() {
        guard !stopped, !queue.isEmpty else { allFinished(); return }
        let lang = queue.removeFirst()
        currentLanguage = lang; viewLanguage = lang
        try? FileManager.default.removeItem(at: kit.appendingPathComponent("qa_mac_results.tsv"))
        let n = total - queue.count
        progressText = "Checklist \(lang) (\(n)/\(total))"
        status = "\(progressText) en cours… 4D va s'ouvrir plusieurs fois, ne fermez pas cette fenêtre."
        appendLog("\n===== \(lang) (\(n)/\(total)) =====")
        process = startStreaming([kit.appendingPathComponent("qa_mac.sh").path, lang],
                                 env: ["RUN_ID": runID, "INSTALL_STATE": installStatePath].merging(netEnv) { a, _ in a },
                                 onLine: { [weak self] l in self?.appendLog(l); self?.loadRows() },
                                 done: { [weak self] _ in self?.finishedOne(lang) })
        if process == nil { finishedOne(lang) }
    }

    func restoreLocale() {
        appendLog("\n== Restauration des langues (macOS / 4D) ==")
        running = true
        process = startStreaming([kit.appendingPathComponent("qa_mac.sh").path, "--restore-locale"],
                                 onLine: { [weak self] l in self?.appendLog(l) },
                                 done: { [weak self] _ in
                                     self?.running = false; self?.restoreNeeded = false; self?.process = nil
                                     self?.status = "Voir le journal. Déconnectez-vous / reconnectez-vous si la langue de macOS a été restaurée."
                                 })
    }

    // network or 4D language left modified by an interrupted run
    func recoverLeftovers() {
        let files = (try? FileManager.default.contentsOfDirectory(atPath: work.path)) ?? []
        restoreNeeded = files.contains("original_locale.txt")
        guard files.contains("net_disabled.txt") || files.contains(where: { $0.hasPrefix("applang_") }) || Runner.guardLeftBlocked()
        else { return }
        appendLog("\n== Restauration après une exécution interrompue (réseau, langue de 4D) ==")
        running = true
        process = startStreaming([kit.appendingPathComponent("qa_mac.sh").path, "--recover"],
                                 onLine: { [weak self] l in self?.appendLog(l) },
                                 done: { [weak self] _ in
                                     self?.running = false; self?.process = nil
                                     self?.status = "Réseau et langue de 4D restaurés."
                                 })
    }

    private func startStreaming(_ args: [String], env extra: [String: String] = [:],
                                onLine: @escaping @MainActor (String) -> Void,
                                done: @escaping @MainActor (Int32) -> Void) -> Process? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/bash")
        p.arguments = args
        p.currentDirectoryURL = kit
        var env = ProcessInfo.processInfo.environment
        env["GUI"] = "1"
        // the signed helpers stay inside the app bundle: macOS attributes their accesses to this app
        env["ABOUT_CHECK"] = helper("about_check")
        env["README_CHECK"] = helper("readme_check")
        env["PATH"] = "/usr/bin:/bin:/usr/sbin:/sbin:/usr/local/bin:/opt/homebrew/bin"
        for (k, v) in extra { env[k] = v }
        p.environment = env
        let pipe = Pipe(), buffer = LineBuffer()
        p.standardOutput = pipe; p.standardError = pipe
        p.standardInput = FileHandle.nullDevice
        pipe.fileHandleForReading.readabilityHandler = { h in
            let data = h.availableData
            guard !data.isEmpty else { return }
            let lines = buffer.append(data)
            guard !lines.isEmpty else { return }
            Task { @MainActor in lines.forEach(onLine) }
        }
        p.terminationHandler = { proc in
            let code = proc.terminationStatus
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 300_000_000) // let the last output arrive
                pipe.fileHandleForReading.readabilityHandler = nil
                buffer.flush().forEach(onLine)
                done(code)
            }
        }
        do { try p.run(); return p } catch {
            appendLog("Erreur de lancement : \(error.localizedDescription)")
            DispatchQueue.main.async { done(-1) }
            return nil
        }
    }

    func stop() {
        stopped = true; queue = []
        guard running, let p = process, p.isRunning else { return }
        let pid = p.processIdentifier
        // children of the engine only (by parent PID): its trap then stops the 4D processes it started, by PID
        _ = Proc.run("/usr/bin/pkill", ["-TERM", "-P", String(pid)], timeout: 5)
        p.terminate()
        appendLog("\n== Arrêté par l'utilisateur ==")
    }

    func loadRows(force: Bool = false) {
        guard running, !currentLanguage.isEmpty else { return }
        guard force || Date().timeIntervalSince(lastRowsLoad) > 0.4 else { return }
        lastRowsLoad = Date()
        guard let txt = try? String(contentsOf: kit.appendingPathComponent("qa_mac_results.tsv"), encoding: .utf8) else { return }
        let r = ResultFile.parse(txt)
        // a file of another run is never shown
        guard r.headers["RUN"] == nil || r.headers["RUN"] == runID else { return }
        if rowsByLang[currentLanguage] != r { rowsByLang[currentLanguage] = r }
    }

    private func finishedOne(_ lang: String) {
        process = nil
        loadRows(force: true)
        let out = kit.appendingPathComponent("qa_mac_results.tsv")
        guard let txt = try? String(contentsOf: out, encoding: .utf8), ResultFile.parse(txt).headers["RUN"] == runID else {
            appendLog("\n(\(lang) : aucun résultat de cette exécution)")
            runNext(); return
        }
        let r = ResultFile.parse(txt)
        let l = r.headers["LANG"] ?? lang
        let safe = "\(version)_\(build)".replacingOccurrences(of: " ", with: "_").replacingOccurrences(of: "/", with: "_")
        let results = kit.appendingPathComponent("results")
        try? FileManager.default.createDirectory(at: results, withIntermediateDirectories: true)
        let dest = results.appendingPathComponent("\(safe)_\(l).tsv")
        try? FileManager.default.removeItem(at: dest)
        try? FileManager.default.copyItem(at: out, to: dest)
        let args = [kit.appendingPathComponent("rapport_mac.sh").path, results.path, safe, product, version, build, platform, runID]
        Task.detached { [weak self] in
            let rep = Proc.run("/bin/bash", args, timeout: 120)
            await self?.reportBuilt(rep)
        }
    }

    private func reportBuilt(_ rep: ProcessOutput) {
        let path = rep.output.split(separator: "\n").last.map { String($0).trimmingCharacters(in: .whitespaces) } ?? ""
        if rep.status == 0, !path.isEmpty, FileManager.default.fileExists(atPath: path) { reportPath = path }
        else { appendLog("Rapport non généré : \(rep.output.suffix(400))") }
        runNext()
    }

    private func allFinished() {
        running = false; process = nil; progressText = ""
        quitGuard()
        if stopped {
            status = "Arrêté."
            recoverLeftovers()
            return
        }
        if !reportPath.isEmpty {
            status = "Terminé – rapport : \(reportPath)"
            NSWorkspace.shared.open(URL(fileURLWithPath: reportPath))
        } else {
            status = "Terminé sans rapport (voir le journal)."
        }
        refreshPermissions(.recheck)
        refreshPrereqs()
    }

    // pf rules possibly left by a network guard that is no longer running (qa_mac.sh --recover decides and removes them)
    nonisolated static func guardLeftBlocked(stateDir: String = "/var/run/com.4d.ti4d.netguard") -> Bool {
        guard let txt = try? String(contentsOfFile: stateDir + "/state", encoding: .utf8) else { return false }
        let f = txt.split(separator: " ", maxSplits: 4).map(String.init)
        guard f.count >= 3, ["blocked", "error"].contains(f[2]), let pid = Int32(f[0]), pid > 0 else { return false }
        return kill(pid, 0) != 0 && errno == ESRCH
    }

    nonisolated static func q(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }
}
