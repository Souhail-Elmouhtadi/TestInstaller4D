import Foundation
import Security

// Logic of the app without user interface (tested by tests/test_core.swift).
// Single source of truth of the statuses: the engine writes the tokens (results.sh), the app and the report
// (rapport_mac.sh) only translate them. Only "ok" is a success.

enum ResultStatus: String, CaseIterable, Sendable {
    case ok, ko, manual, na, notrun, action, undetermined, unknown

    init(token: String) {
        let t = token.trimmingCharacters(in: .whitespacesAndNewlines)
        self = ResultStatus(rawValue: t) ?? .unknown
    }

    var label: String {
        switch self {
        case .ok: return "OK"
        case .ko: return "Échec"
        case .manual: return "À vérifier"
        case .na: return "N/A"
        case .notrun: return "Non exécuté"
        case .action: return "Action requise"
        case .undetermined: return "Indéterminé"
        case .unknown: return "Statut inconnu"
        }
    }

    var symbol: String {
        switch self {
        case .ok: return "checkmark.circle.fill"
        case .ko: return "xmark.octagon.fill"
        case .manual: return "exclamationmark.triangle.fill"
        case .na: return "minus.circle"
        case .notrun: return "forward.end.circle.fill"
        case .action: return "hand.raised.fill"
        case .undetermined: return "questionmark.diamond.fill"
        case .unknown: return "questionmark.circle"
        }
    }

    // same order as results.sh (st_rank): the worst status wins
    var rank: Int {
        switch self {
        case .ko: return 6
        case .action: return 5
        case .undetermined, .unknown: return 4
        case .notrun: return 3
        case .manual: return 2
        case .ok: return 1
        case .na: return 0
        }
    }

    var isSuccess: Bool { self == .ok }
    var tone: Tone {
        switch self {
        case .ok: return .success
        case .ko: return .failure
        case .manual: return .warning
        case .action: return .action
        case .undetermined, .unknown: return .undetermined
        case .notrun: return .neutral
        case .na: return .info
        }
    }
}

struct CheckRow: Identifiable, Equatable, Sendable {
    let id: String
    let action: String
    let status: ResultStatus
    let rawStatus: String
    let detail: String
    let date: String
    let path: String

    var showsFullDetail: Bool { status != .ok && status != .na }
}

struct ResultFile: Equatable, Sendable {
    var headers: [String: String] = [:]
    var hashes: [String] = []
    var rows: [CheckRow] = []

    // <action> TAB <status> TAB <detail, \n escaped> TAB <date> TAB <tested path>; headers "#KEY TAB value"
    static func parse(_ txt: String) -> ResultFile {
        var r = ResultFile()
        for (i, raw) in txt.components(separatedBy: "\n").enumerated() {
            let line = raw.hasSuffix("\r") ? String(raw.dropLast()) : raw
            if line.isEmpty { continue }
            let f = line.components(separatedBy: "\t")
            if line.hasPrefix("#") {
                let key = String(f[0].dropFirst())
                if key == "HASH" { r.hashes.append(f.dropFirst().joined(separator: " ")) }
                else if r.headers[key] == nil { r.headers[key] = f.count > 1 ? f[1] : "" }
                continue
            }
            guard f.count >= 2, !f[0].isEmpty else { continue }
            r.rows.append(CheckRow(id: "\(i)-\(f[0])", action: f[0], status: ResultStatus(token: f[1]), rawStatus: f[1],
                                   detail: f.count > 2 ? f[2].replacingOccurrences(of: "\\n", with: "\n") : "",
                                   date: f.count > 3 ? f[3] : "", path: f.count > 4 ? f[4] : ""))
        }
        return r
    }

    var worst: ResultStatus? { rows.map(\.status).max { $0.rank < $1.rank } }
    func count(_ s: ResultStatus) -> Int { rows.filter { $0.status == s }.count }
}

// ---------- permissions (Accessibility, Screen Recording) ----------
// Checked by the helper that performs the actions (about_check), started by the app: macOS attributes its accesses
// to the app (responsible process). A fresh process per check: no state cached since the app started.
enum PermissionState: Equatable, Sendable {
    case checking, granted, denied, error(String)

    var isGranted: Bool { self == .granted }
    var label: String {
        switch self {
        case .checking: return "Vérification…"
        case .granted: return "Accordé"
        case .denied: return "Non accordé"
        case .error: return "Erreur de vérification"
        }
    }
    var tone: Tone {
        switch self {
        case .checking: return .progress
        case .granted: return .success
        case .denied: return .failure
        case .error: return .undetermined
        }
    }
}

struct PermissionSnapshot: Equatable, Sendable {
    var accessibility: PermissionState
    var screen: PermissionState
    var executable: String
    var pid: String

    static let checking = PermissionSnapshot(accessibility: .checking, screen: .checking, executable: "", pid: "")

    // output of "about_check --permissions": EXE <path>, PID <n>, AX 0|1, SCREEN 0|1
    static func parse(_ output: String, exitCode: Int32, launchError: String? = nil) -> PermissionSnapshot {
        var values: [String: [String]] = [:]
        for line in output.components(separatedBy: "\n") {
            let f = line.components(separatedBy: "\t")
            guard f.count == 2 else { continue }
            values[f[0], default: []].append(f[1].trimmingCharacters(in: .whitespaces))
        }
        func state(_ key: String) -> PermissionState {
            if let e = launchError { return .error("vérificateur non lancé : \(e)") }
            if exitCode != 0 { return .error("le vérificateur a échoué (code \(exitCode))") }
            let v = values[key] ?? []
            if v.isEmpty { return .error("aucune réponse du vérificateur") }
            if Set(v).count > 1 { return .error("réponses contradictoires") }
            switch v[0] {
            case "1": return .granted
            case "0": return .denied
            default: return .error("réponse inattendue : \(v[0])")
            }
        }
        return PermissionSnapshot(accessibility: state("AX"), screen: state("SCREEN"),
                                  executable: values["EXE"]?.first ?? "", pid: values["PID"]?.first ?? "")
    }
}

enum PermissionKind: String, CaseIterable, Sendable {
    case accessibility, screen
    var title: String { self == .accessibility ? "Accessibilité" : "Enregistrement de l'écran" }
    var settingsAnchor: String { self == .accessibility ? "Privacy_Accessibility" : "Privacy_ScreenCapture" }
    var requestFlag: String { self == .accessibility ? "--request-accessibility" : "--request-screen" }
    var purpose: String {
        self == .accessibility
            ? "Ouvrir la boîte « À propos » de 4D et répondre à l'alerte Gatekeeper."
            : "Capturer la boîte « À propos » pour la lire (OCR)."
    }
}

// State of one permission over time: explicit user requests, changes while the app runs, restart advice.
struct PermissionTracker: Equatable, Sendable {
    enum Change: Equatable, Sendable { case none, granted, revoked }
    private(set) var state: PermissionState = .checking
    private(set) var lastKnown: PermissionState?
    private(set) var requested = false
    private(set) var checksSinceRequest = 0

    mutating func beginCheck() { state = .checking }

    // an explicit action of the user (request button or System Settings opened from the app); never a proof
    mutating func userRequested() { requested = true; checksSinceRequest = 0 }

    // afterUserReturn: check made once the user could act in System Settings (app back to the front, "Revérifier");
    // false for the check printed right after a request (the user has not answered yet)
    @discardableResult
    mutating func apply(_ s: PermissionState, afterUserReturn: Bool = true) -> Change {
        state = s
        if requested && afterUserReturn { checksSinceRequest += 1 }
        defer { if s == .granted || s == .denied { lastKnown = s } }
        if s == .granted { let c: Change = lastKnown == .denied ? .granted : .none; requested = false; return c }
        if s == .denied && lastKnown == .granted { return .revoked }
        return .none
    }

    // allowed in System Settings but still refused to the running app: macOS applies some permissions
    // (Screen Recording in particular) only after the app is relaunched
    var restartAdvised: Bool { requested && state == .denied && checksSinceRequest >= 1 }
}

// ---------- signing identity (stability of the permissions) ----------
enum SigningKind: Equatable, Sendable {
    case developerID(team: String), appleDevelopment(team: String), certificate(name: String), adhoc, unsigned

    static func classify(signed: Bool, adhoc: Bool, authorities: [String], team: String?) -> SigningKind {
        guard signed else { return .unsigned }
        if adhoc || authorities.isEmpty { return .adhoc }
        let leaf = authorities[0]
        if leaf.hasPrefix("Developer ID Application") { return .developerID(team: team ?? "") }
        if leaf.hasPrefix("Apple Development") || leaf.hasPrefix("Mac Developer") { return .appleDevelopment(team: team ?? "") }
        return .certificate(name: leaf)
    }

    // ad hoc: the designated requirement is the code hash, so every new build is a new application for macOS
    var keepsPermissionsAcrossBuilds: Bool {
        switch self { case .adhoc, .unsigned: return false; default: return true }
    }

    var label: String {
        switch self {
        case .developerID(let t): return "Developer ID (\(t))"
        case .appleDevelopment(let t): return "Apple Development (\(t))"
        case .certificate(let n): return "Certificat local « \(n) »"
        case .adhoc: return "Signature ad hoc"
        case .unsigned: return "Non signée"
        }
    }
}

struct SigningInfo: Equatable, Sendable {
    var kind: SigningKind
    var identifier: String
    var requirement: String

    static func current() -> SigningInfo {
        var code: SecCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code else {
            return SigningInfo(kind: .unsigned, identifier: Bundle.main.bundleIdentifier ?? "", requirement: "")
        }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode else {
            return SigningInfo(kind: .unsigned, identifier: Bundle.main.bundleIdentifier ?? "", requirement: "")
        }
        var info: CFDictionary?
        let signed = SecStaticCodeCheckValidity(staticCode, [], nil) == errSecSuccess
        SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &info)
        let d = (info as? [String: Any]) ?? [:]
        let flags = (d[kSecCodeInfoFlags as String] as? NSNumber)?.uint32Value ?? 0
        let certs = (d[kSecCodeInfoCertificates as String] as? [SecCertificate]) ?? []
        let names = certs.compactMap { SecCertificateCopySubjectSummary($0) as String? }
        var req: SecRequirement?
        var reqText: CFString?
        if SecCodeCopyDesignatedRequirement(staticCode, [], &req) == errSecSuccess, let req {
            SecRequirementCopyString(req, [], &reqText)
        }
        let kind = SigningKind.classify(signed: signed || d[kSecCodeInfoIdentifier as String] != nil,
                                        adhoc: flags & 0x2 != 0, authorities: names,
                                        team: d[kSecCodeInfoTeamIdentifier as String] as? String)
        return SigningInfo(kind: kind, identifier: d[kSecCodeInfoIdentifier as String] as? String ?? "",
                           requirement: (reqText as String?) ?? "")
    }
}

// ---------- installation / download events (install_4d.sh, download_4d.sh) ----------
enum EngineEvent: Equatable, Sendable {
    case step(String)
    case progress(Int, String)
    case info(String, String)
    case exists(path: String, version: String, build: String, same: Bool)
    case error(code: String, message: String)
    case result(ok: Bool, path: String)
    case other(String)

    static func parse(_ line: String) -> EngineEvent {
        let f = line.components(separatedBy: "\t")
        func at(_ i: Int) -> String { f.count > i ? f[i] : "" }
        switch f[0] {
        case "STEP": return .step(at(1))
        case "PROGRESS":
            // install_4d.sh: PROGRESS <pct> <text>; download_4d.sh: PROGRESS <pct> <received> <total>
            let pct = max(0, min(100, Int(at(1)) ?? 0))
            if f.count >= 4, let got = Int64(at(2)), let all = Int64(at(3)) {
                return .progress(pct, "\(ByteCountFormatter.string(fromByteCount: got, countStyle: .file)) / \(ByteCountFormatter.string(fromByteCount: all, countStyle: .file))")
            }
            return .progress(pct, at(2))
        case "INFO": return .info(at(1), at(2))
        case "EXISTS": return .exists(path: at(1), version: at(2), build: at(3), same: at(4) == "same")
        case "ERROR": return .error(code: at(1), message: at(2))
        case "RESULT": return .result(ok: at(1) == "ok", path: at(2))
        default: return .other(line)
        }
    }

    static func title(ofError code: String) -> String {
        switch code {
        case "INCOMPLETE": return "Téléchargement incomplet"
        case "EMPTY": return "Fichier vide"
        case "CORRUPT": return "Image disque endommagée"
        case "FORMAT": return "Ce n'est pas une image disque 4D"
        case "ORIGIN": return "Origine non officielle"
        case "DOMAIN": return "Adresse refusée (serveurs *.4d.com uniquement)"
        case "AUTH": return "Connexion requise dans le navigateur"
        case "NOTFOUND": return "Fichier introuvable sur le serveur"
        case "HTTP": return "Erreur du serveur"
        case "NETWORK": return "Erreur réseau"
        case "MOUNT": return "Montage impossible"
        case "PRODUCT": return "Produit absent du DMG"
        case "VERSION": return "Version incorrecte"
        case "ARCH": return "Architecture incompatible"
        case "SIGNATURE": return "Signature invalide"
        case "SPACE": return "Espace disque insuffisant"
        case "DENIED": return "Copie refusée"
        case "ADMIN": return "Autorisation administrateur refusée"
        case "COPY": return "Copie impossible"
        case "WRITE": return "Écriture impossible"
        case "VERIFY": return "Vérification de l'installation échouée"
        case "EXISTS": return "Une installation existe déjà"
        case "ARGS": return "Paramètres invalides"
        case "ACCESS": return "Dossier illisible"
        default: return "Erreur \(code)"
        }
    }
}

struct DownloadCandidate: Identifiable, Equatable, Sendable {
    // invalid: no UDIF "koly" trailer (truncated file or unsupported format)
    enum State: String, Sendable { case complete, partial, empty, invalid }
    enum Origin: String, Sendable { case official, other, unknown }
    var id: String { path }
    let path: String
    let size: Int64
    let state: State
    let origin: Origin
    let hosts: String
    let modified: Date

    var name: String { (path as NSString).lastPathComponent }
    var usable: Bool { state == .complete }

    // CANDIDATE <path> <size> <complete|partial|empty> <official|other|unknown> <hosts> <mtime>
    static func parse(_ txt: String) -> [DownloadCandidate] {
        txt.components(separatedBy: "\n").compactMap { line in
            let f = line.components(separatedBy: "\t")
            guard f.count >= 7, f[0] == "CANDIDATE", let st = State(rawValue: f[3]) else { return nil }
            return DownloadCandidate(path: f[1], size: Int64(f[2]) ?? 0, state: st, origin: Origin(rawValue: f[4]) ?? .unknown,
                                     hosts: f[5], modified: Date(timeIntervalSince1970: TimeInterval(f[6]) ?? 0))
        }
        .sorted { $0.modified > $1.modified }
    }

    // download_4d.sh --scan: an error, a failed run or a timeout is never shown as "no image found"
    static func scanResult(_ out: ProcessOutput, folder: String) -> DownloadWatch.ScanResult {
        if out.timedOut { return .failure("la recherche dans \(folder) n'a pas répondu en 60 s") }
        if let e = out.launchError { return .failure("recherche impossible : \(e)") }
        for line in out.output.components(separatedBy: "\n") {
            guard case .error(let code, let msg) = EngineEvent.parse(line) else { continue }
            switch code {
            case "ACCESS": return .failure("dossier \(folder) illisible : autorisez Test Installer 4D dans Réglages Système > Confidentialité et sécurité > Fichiers et dossiers (Téléchargements), puis « Réessayer »")
            case "ARGS": return .failure("dossier \(folder) introuvable")
            default: return .failure("recherche impossible (\(code)) : \(msg)")
            }
        }
        if out.status != 0 { return .failure("recherche impossible (code \(out.status))") }
        return .ok(parse(out.output))
    }
}

// ---------- watch of the Downloads folder after « Télécharger dans le navigateur » ----------
// Pure state machine: the watch always ends in a visible state (image found, error, time limit, stopped or image
// chosen) instead of an endless spinner. Nothing is selected in place of the user.
struct DownloadWatch: Equatable, Sendable {
    enum Phase: Equatable, Sendable {
        case idle
        case watching
        case found(DownloadCandidate)  // new complete image: the watch is over, the user chooses « Utiliser »
        case failed(String)            // the folder could not be scanned (repeated error)
        case timedOut
    }
    enum ScanResult: Equatable, Sendable { case ok([DownloadCandidate]), failure(String) }

    static let tolerance: TimeInterval = 5
    static let failuresBeforeError = 2

    var phase: Phase = .idle
    var since: Date?
    var limit: TimeInterval = 7200
    var baseline: Set<String>?           // images present (not in progress) at the first scan of the watch
    var inProgress: [DownloadCandidate] = []
    var notes: [String] = []             // new files refused or ignored, with the reason
    var failures = 0
    var lastError = ""

    var isWatching: Bool { phase == .watching }

    mutating func start(at date: Date, limit: TimeInterval = 7200) {
        self = DownloadWatch(phase: .watching, since: date, limit: limit)
    }

    // appeared or rewritten since the watch started (the file date alone is not enough: some tools keep the server date)
    func isNew(_ c: DownloadCandidate) -> Bool {
        guard let since else { return false }
        if c.modified >= since.addingTimeInterval(-Self.tolerance) { return true }
        guard c.state != .partial, let baseline else { return false }
        return !baseline.contains(c.path)
    }

    // one scan of the folder: returns the lines for the log
    mutating func apply(_ result: ScanResult, now: Date) -> [String] {
        guard phase == .watching, let since else { return [] }
        var log: [String] = []
        switch result {
        case .failure(let why):
            failures += 1; lastError = why
            if failures >= Self.failuresBeforeError {
                phase = .failed(why); inProgress = []
                log.append("Surveillance de Téléchargements arrêtée : \(why)")
            }
        case .ok(let found):
            failures = 0; lastError = ""
            if baseline == nil { baseline = Set(found.filter { $0.state != .partial }.map(\.path)) }
            inProgress = found.filter { $0.state == .partial && $0.modified >= since.addingTimeInterval(-Self.tolerance) }
            var newNotes: [String] = [], hit: DownloadCandidate?
            for c in found where isNew(c) {
                switch c.state {
                case .partial: continue
                case .empty: newNotes.append("\(c.name) : fichier vide, refusé.")
                case .invalid: newNotes.append("\(c.name) : fin d'image disque absente (téléchargement inachevé ou fichier tronqué), refusé.")
                case .complete:
                    if c.origin == .other { newNotes.append("\(c.name) : ignoré, origine autre que 4d.com (\(c.hosts)).") }
                    else if hit == nil { hit = c }
                }
            }
            log += newNotes.filter { !notes.contains($0) }.map { "Téléchargements : " + $0 }
            notes = newNotes
            if let c = hit {
                phase = .found(c); inProgress = []
                log.append("Téléchargement terminé : \(c.path) (\(c.size) octets, origine \(c.hosts.isEmpty ? "inconnue" : c.hosts)) — surveillance terminée")
            }
        }
        if phase == .watching, now.timeIntervalSince(since) >= limit {
            phase = .timedOut; inProgress = []
            log.append("Surveillance de Téléchargements arrêtée après \(Int(limit / 60)) min : aucune image complète n'est apparue")
        }
        return log
    }

    // an image chosen by any means (« Utiliser », « Choisir… », direct download) ends the watch and its messages
    mutating func imageChosen() { end() }
    mutating func stop() { end() }
    private mutating func end() { phase = .idle; inProgress = []; notes = []; failures = 0; lastError = "" }
}

struct DMGApp: Equatable, Sendable {
    let name: String
    let version: String
    let build: String
    let bundleID: String
    let relativePath: String
}

// output of dmg_info.sh: <name> <version> <build> <bundle id> <path in the image>
enum DMGContent {
    static func parse(_ txt: String) -> [DMGApp] {
        txt.components(separatedBy: "\n").compactMap { line in
            let f = line.components(separatedBy: "\t")
            guard f.count >= 3, !f[0].isEmpty, !f[1].isEmpty else { return nil }
            return DMGApp(name: f[0], version: f[1], build: f[2], bundleID: f.count > 3 ? f[3] : "", relativePath: f.count > 4 ? f[4] : "")
        }
    }

    // the selected product only: never another application of the image
    static func app(_ apps: [DMGApp], product: String) -> DMGApp? { apps.first { $0.name == product } }
}

// ---------- results context: a result is shown only for the selection and the installation it was made for ----------
struct Selection: Equatable, Sendable {
    var dmg = ""
    var product = ""
    var version = ""
    var build = ""
    var platform = ""
}

struct ResultsContext: Equatable, Sendable {
    var selection: Selection
    var installStamp: String

    func invalidation(selection s: Selection, installStamp i: String) -> String? {
        if s.dmg != selection.dmg { return "autre image disque sélectionnée" }
        if s.product != selection.product { return "autre produit sélectionné" }
        if s.version.trimmingCharacters(in: .whitespaces) != selection.version.trimmingCharacters(in: .whitespaces)
            || s.build.trimmingCharacters(in: .whitespaces) != selection.build.trimmingCharacters(in: .whitespaces) {
            return "autre version ou build sélectionné"
        }
        if s.platform != selection.platform { return "autre plateforme sélectionnée" }
        if i != installStamp { return "nouvelle installation" }
        return nil
    }
}

// ---------- colours: one tone per meaning, readable in light and dark mode (contrast checked by the tests) ----------
enum Tone: CaseIterable, Sendable {
    case success, failure, warning, action, undetermined, neutral, info, progress
}

struct RGB: Equatable, Sendable {
    let r: Double, g: Double, b: Double
    init(_ hex: UInt32) {
        r = Double((hex >> 16) & 0xFF) / 255; g = Double((hex >> 8) & 0xFF) / 255; b = Double(hex & 0xFF) / 255
    }
    init(r: Double, g: Double, b: Double) { self.r = r; self.g = g; self.b = b }

    func blended(over base: RGB, alpha: Double) -> RGB {
        RGB(r: r * alpha + base.r * (1 - alpha), g: g * alpha + base.g * (1 - alpha), b: b * alpha + base.b * (1 - alpha))
    }
    var luminance: Double {
        func lin(_ c: Double) -> Double { c <= 0.03928 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
        return 0.2126 * lin(r) + 0.7152 * lin(g) + 0.0722 * lin(b)
    }
    static func contrast(_ a: RGB, _ b: RGB) -> Double {
        let (l1, l2) = (max(a.luminance, b.luminance), min(a.luminance, b.luminance))
        return (l1 + 0.05) / (l2 + 0.05)
    }
}

enum Palette {
    static let pillAlpha = 0.16
    static let lightCard = RGB(0xFFFFFF)
    static let darkCard = RGB(0x1F2133)

    // foreground used for the icon and the text of a pill (strong in light mode, bright in dark mode)
    static func foreground(_ t: Tone, dark: Bool) -> RGB {
        switch (t, dark) {
        case (.success, false): return RGB(0x0E6E36)
        case (.success, true): return RGB(0x4ADE80)
        case (.failure, false): return RGB(0xC0262D)
        case (.failure, true): return RGB(0xFF7B7B)
        case (.warning, false): return RGB(0x8A5300)
        case (.warning, true): return RGB(0xFBBF24)
        case (.action, false): return RGB(0xA63A0A)
        case (.action, true): return RGB(0xFF9F5A)
        case (.undetermined, false): return RGB(0x6D28D9)
        case (.undetermined, true): return RGB(0xC4A5FF)
        case (.neutral, false): return RGB(0x4B5563)
        case (.neutral, true): return RGB(0xC3C8D2)
        case (.info, false): return RGB(0x0B6A9A)
        case (.info, true): return RGB(0x67C8F5)
        case (.progress, false): return RGB(0x3346C8)
        case (.progress, true): return RGB(0x93A5FF)
        }
    }

    // pill background: the tone over the card colour
    static func background(_ t: Tone, dark: Bool) -> RGB {
        foreground(t, dark: dark).blended(over: dark ? darkCard : lightCard, alpha: pillAlpha)
    }

    static let gradient: [UInt32] = [0x4F46E5, 0x9333EA, 0xDB2777, 0xEA580C]
    // black veil laid over the header gradient: the white texts keep a contrast >= 4.5 on every colour
    static let headerVeil = 0.2
    static func headerColor(_ hex: UInt32) -> RGB { RGB(hex).blended(over: RGB(0x000000), alpha: 1 - headerVeil) }
}

// ---------- installation record written by install_4d.sh (~/4DQA_mac/install_state.tsv) ----------
enum Version {
    // same rules as version_normalize (version.sh): "21.0.2 build 100" -> "21.2"
    static func normalize(_ v: String) -> String {
        var s = v.trimmingCharacters(in: .whitespacesAndNewlines)
        if let r = s.range(of: " [Bb]uild.*$", options: .regularExpression) { s.removeSubrange(r) }
        if let m = s.range(of: "^([0-9]+)\\.0\\.([0-9]+)(\\s.*|$)", options: .regularExpression), m.lowerBound == s.startIndex {
            let parts = s.split(separator: ".", maxSplits: 2, omittingEmptySubsequences: false)
            if parts.count == 3 { s = "\(parts[0]).\(parts[2])" }
        }
        return s
    }
}

struct InstallRecord: Equatable, Sendable {
    var values: [String: String] = [:]
    var status: String { values["STATUS"] ?? "" }
    var app: String { values["APP"] ?? "" }
    var date: String { values["DATE"] ?? "" }
    var errorCode: String { values["ERROR_CODE"] ?? "" }
    var error: String { values["ERROR"] ?? "" }

    static func parse(_ txt: String) -> InstallRecord {
        var r = InstallRecord()
        for line in txt.components(separatedBy: "\n") {
            let f = line.components(separatedBy: "\t")
            guard f.count >= 2, !f[0].isEmpty, r.values[f[0]] == nil else { continue }
            r.values[f[0]] = f[1...].joined(separator: "\t")
        }
        return r
    }

    // a verified installation of exactly the selected image, product, version, build and platform
    func matches(_ s: Selection) -> Bool {
        status == "ok" && values["DMG"] == s.dmg && values["PRODUCT"] == s.product
            && Version.normalize(values["VERSION"] ?? "") == Version.normalize(s.version)
            && (values["BUILD"] ?? "").trimmingCharacters(in: .whitespaces) == s.build.trimmingCharacters(in: .whitespaces)
            && values["PLATFORM"] == s.platform
    }
}

// ---------- window of the disk image, checked by dmg_window.sh before every installation ----------
// Files alone never prove what Finder shows: "pending" = automatic checks passed, the screenshot waits for the user.
struct DMGWindowCheck: Equatable, Sendable {
    enum Status: String, Sendable { case pending, ok, ko, action, error }
    var values: [String: String] = [:]
    var status: Status { Status(rawValue: values["STATUS"] ?? "") ?? .error }
    var shot: String { values["SHOT"] ?? "" }
    var date: String { values["DATE"] ?? "" }
    var volume: String { values["VOLUME"] ?? "" }
    var verdict: String { values["VERDICT"] ?? "" }
    var lines: [(tone: String, text: String)] {
        (values["DETAIL"] ?? "").components(separatedBy: "\\n").compactMap { l in
            guard l.hasPrefix("["), let e = l.firstIndex(of: "]") else { return l.isEmpty ? nil : ("info", l) }
            return (String(l[l.index(after: l.startIndex)..<e]), String(l[l.index(after: e)...]).trimmingCharacters(in: .whitespaces))
        }
    }
    var failures: [String] { lines.filter { $0.tone == "ko" }.map(\.text) }

    static func parse(_ txt: String) -> DMGWindowCheck { DMGWindowCheck(values: InstallRecord.parse(txt).values) }

    // only a check of this very file (path, size, date), product and version counts
    func matches(_ s: Selection, stamp: String) -> Bool {
        values["DMG"] == s.dmg && values["STAMP"] == stamp && values["PRODUCT"] == s.product
            && Version.normalize(values["VERSION"] ?? "") == Version.normalize(s.version)
            && (values["BUILD"] ?? "").trimmingCharacters(in: .whitespaces) == s.build.trimmingCharacters(in: .whitespaces)
    }

    static func ==(a: DMGWindowCheck, b: DMGWindowCheck) -> Bool { a.values == b.values }
}

// ---------- platform of the Mac used for the test: hardware, not the architecture of this process ----------
// hw.optional.arm64 = 1 on Apple Silicon even for a process translated by Rosetta; Intel Macs have no such key (or 0)
// and report hw.optional.x86_64 = 1 natively. Anything else is an error, never a guessed platform.
enum HostPlatform {
    static let arm = "macOS ARM", intel = "macOS Intel"
    static func classify(arm64: Int32?, x86_64: Int32?) -> Result<String, PlatformError> {
        if arm64 == 1 { return .success(arm) }
        if x86_64 == 1 && (arm64 == nil || arm64 == 0) { return .success(intel) }
        return .failure(PlatformError(message: "matériel non reconnu (hw.optional.arm64=\(arm64.map(String.init) ?? "absent"), hw.optional.x86_64=\(x86_64.map(String.init) ?? "absent"))"))
    }
    static func sysctlInt(_ name: String) -> Int32? {
        var v: Int32 = 0; var n = MemoryLayout<Int32>.size
        return sysctlbyname(name, &v, &n, nil, 0) == 0 ? v : nil
    }
    static var translated: Bool { sysctlInt("sysctl.proc_translated") == 1 }
    static func detect() -> Result<String, PlatformError> {
        classify(arm64: sysctlInt("hw.optional.arm64"), x86_64: sysctlInt("hw.optional.x86_64"))
    }
}
struct PlatformError: Error, Equatable, Sendable { var message: String }

// ---------- child processes with a time limit (never blocks the interface: called off the main actor) ----------
struct ProcessOutput: Equatable, Sendable {
    var output: String
    var status: Int32
    var timedOut: Bool
    var launchError: String?
}

enum Proc {
    static func run(_ executable: String, _ args: [String], timeout: TimeInterval,
                    environment: [String: String]? = nil) -> ProcessOutput {
        let p = Process(), pipe = Pipe()
        p.executableURL = URL(fileURLWithPath: executable)
        p.arguments = args
        if let environment { p.environment = environment }
        p.standardOutput = pipe; p.standardError = pipe
        p.standardInput = FileHandle.nullDevice
        let box = DataBox(), done = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            box.data = pipe.fileHandleForReading.readDataToEndOfFile()
            done.signal()
        }
        do { try p.run() } catch {
            try? pipe.fileHandleForWriting.close()
            _ = done.wait(timeout: .now() + 1)
            return ProcessOutput(output: "", status: -1, timedOut: false, launchError: error.localizedDescription)
        }
        try? pipe.fileHandleForWriting.close()
        let deadline = Date().addingTimeInterval(timeout)
        var timedOut = false
        // not waitUntilExit(): it spins the run loop of the calling thread
        while p.isRunning {
            if Date() > deadline {
                timedOut = true
                p.terminate()
                let grace = Date().addingTimeInterval(2)
                while p.isRunning && Date() < grace { usleep(20_000) }
                if p.isRunning { kill(p.processIdentifier, SIGKILL) }
                break
            }
            usleep(10_000)
        }
        while p.isRunning { usleep(10_000) }
        // a grandchild may keep the pipe open: do not wait for it forever
        _ = done.wait(timeout: .now() + 2)
        let out = String(data: box.data, encoding: .utf8) ?? String(decoding: box.data, as: UTF8.self)
        return ProcessOutput(output: out, status: p.terminationStatus, timedOut: timedOut, launchError: nil)
    }

    private final class DataBox: @unchecked Sendable { var data = Data() }
}
