import Foundation
import AppKit

// Tests of Runner.swift with a fake engine and a fake permission helper (built and prepared by tests/test_runner.sh):
// permissions granted / denied / changed while running / error, request flow and restart advice, results reset when
// they become stale, disk image reading without guessing, installation (success, existing installation, no space,
// cancel), download (domains, success, sign-in required, cancel), Dock icon taken from the running bundle.

var passed = 0, failed = 0
func check(_ name: String, _ cond: @autoclosure () -> Bool) {
    if cond() { passed += 1 } else { failed += 1; print("FAIL: \(name)") }
}

@MainActor func waitFor(_ timeout: TimeInterval = 10, _ cond: () -> Bool) -> Bool {
    let end = Date().addingTimeInterval(timeout)
    while !cond() && Date() < end { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
    return cond()
}

@MainActor func pause(_ s: TimeInterval) { RunLoop.main.run(until: Date().addingTimeInterval(s)) }

let H = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "/tmp/ti4d_runner_home")
let helpers = H.appendingPathComponent("helpers")
func put(_ url: URL, _ s: String) { try? s.write(to: url, atomically: true, encoding: .utf8) }
func read(_ url: URL) -> String { (try? String(contentsOf: url, encoding: .utf8)) ?? "" }
func perm(ax: String, screen: String) { put(helpers.appendingPathComponent("perm"), "AX\t\(ax)\nSCREEN\t\(screen)\n") }
func flag(_ name: String, _ on: Bool) {
    let u = helpers.appendingPathComponent(name)
    if on { put(u, "1") } else { try? FileManager.default.removeItem(at: u) }
}
func mode(_ name: String, _ m: String) { put(H.appendingPathComponent(name), m) }

extension PermissionState {
    var isChecking: Bool { self == .checking }
    var isError: Bool { if case .error = self { return true }; return false }
}

@main
struct RunnerTests {
    @MainActor static func main() {
        _ = NSApplication.shared
        permissions()
        missingHelper()
        dmgSelection()
        platformDetection()
        staleResults()
        installation()
        download()
        watchDownloads()
        netGuard()
        bundleIcon()
        print("runner: \(passed) checks passed, \(failed) failed")
        exit(failed == 0 ? 0 : 1)
    }

    @MainActor static func make() -> Runner { let r = Runner(home: H, helperDir: helpers); r.detectPlatform(); return r }

    @MainActor static func settle(_ r: Runner) -> Bool { waitFor(20) { !r.ax.state.isChecking && !r.screen.state.isChecking } }

    // ---------- permissions ----------
    @MainActor static func permissions() {
        let r = make()
        perm(ax: "1", screen: "0")
        r.refreshPermissions(.startup)
        check("checking shown while the helper runs (AX)", r.ax.state == .checking)
        check("checking shown while the helper runs (screen)", r.screen.state == .checking)
        check("startup check finishes", settle(r))
        check("AX granted", r.ax.state == .granted)
        check("screen denied (not green)", r.screen.state == .denied)
        check("checking process shown", r.permissionProcess.contains(helpers.appendingPathComponent("about_check").path))
        check("check time recorded", r.permissionCheckedAt != nil)

        // back to the foreground right away: throttled (no new helper process)
        r.refreshPermissions(.foreground)
        check("foreground check throttled within 1.5 s", r.ax.state == .granted && r.screen.state == .denied)

        // granted in System Settings while the app runs, then the app comes back to the front
        perm(ax: "1", screen: "1")
        pause(1.6)
        r.refreshPermissions(.foreground)
        check("foreground check started after the throttle", r.screen.state == .checking)
        check("foreground check finishes", settle(r))
        check("screen granted after the return from Settings", r.screen.state == .granted)
        check("grant logged", r.log.contains("« Enregistrement de l'écran » : accordée"))

        // revoked while running
        perm(ax: "0", screen: "1")
        r.refreshPermissions(.recheck)
        check("recheck finishes", settle(r))
        check("AX revoked shown as denied", r.ax.state == .denied)
        check("revocation logged", r.log.contains("« Accessibilité » retirée"))

        // helper failing / unreadable answers: error, never granted
        flag("fail", true)
        r.refreshPermissions(.recheck)
        _ = settle(r)
        check("helper failure -> AX error", r.ax.state.isError)
        check("helper failure -> screen error, not granted", r.screen.state.isError && !r.screen.state.isGranted)
        flag("fail", false)
        put(helpers.appendingPathComponent("perm"), "AX\tyes\nSCREEN\t1\nSCREEN\t0\n")
        r.refreshPermissions(.recheck)
        _ = settle(r)
        check("unexpected answer -> error", r.ax.state.isError)
        check("contradictory answers -> error", r.screen.state.isError)

        // explicit request: the prompt is not a proof; restart advice only after the user came back
        perm(ax: "1", screen: "0")
        r.refreshPermissions(.recheck); _ = settle(r)
        try? FileManager.default.removeItem(at: helpers.appendingPathComponent("requests.log"))
        r.requestPermission(.screen)
        check("request: checking", r.screen.state == .checking)
        _ = settle(r)
        check("request flag passed to the helper", read(helpers.appendingPathComponent("requests.log")).contains("--request-screen"))
        check("request alone does not grant", r.screen.state == .denied)
        check("no restart advice right after the request", !r.screen.restartAdvised)
        r.refreshPermissions(.recheck); _ = settle(r)
        check("restart advised: allowed in Settings but still refused", r.screen.restartAdvised)
        check("no restart advice for the granted one", !r.ax.restartAdvised)
        perm(ax: "1", screen: "1")
        r.refreshPermissions(.recheck); _ = settle(r)
        check("granted after relaunch/recheck", r.screen.state == .granted && !r.screen.restartAdvised)

        // a stale answer (older token) never overwrites a newer check
        perm(ax: "0", screen: "0")
        flag("slow", true)
        let started = helpers.appendingPathComponent("started.log")
        let n = read(started).count
        r.refreshPermissions(.recheck)
        _ = waitFor(5) { read(started).count > n } // the slow helper has read its answer
        pause(0.2)
        flag("slow", false)
        perm(ax: "1", screen: "1")
        pause(0.1)
        r.refreshPermissions(.recheck)
        _ = settle(r)
        pause(1.5)
        check("late answer of an older check ignored", r.ax.state == .granted && r.screen.state == .granted)
    }

    @MainActor static func missingHelper() {
        let r = Runner(home: H, helperDir: H.appendingPathComponent("nowhere"))
        r.refreshPermissions(.startup)
        _ = settle(r)
        check("missing helper -> error (AX)", r.ax.state.isError)
        check("missing helper -> error (screen)", r.screen.state.isError)
        check("missing helper reported in the identity notes", r.identityNotes.contains { $0.0 == .failure })
    }

    // ---------- disk image ----------
    @MainActor static func dmgSelection() {
        let r = make()
        let good = H.appendingPathComponent("Downloads/4D good.dmg").path
        r.setDMG(good)
        check("dmg read", waitFor(20) { r.dmgState == .read })
        check("version from the image", r.version == "21.2")
        check("build from the image", r.build == "100629")
        check("size recorded", r.dmgSize == 4096)
        check("SHA-256 recorded", waitFor(20) { !r.dmgSHA.isEmpty } && r.dmgSHA == read(H.appendingPathComponent("good.sha")).uppercased())
        check("log has path, size and hash", waitFor(5) { r.log.contains(good) && r.log.contains("SHA-256 \(r.dmgSHA)") })
        check("can install", r.canInstall)
        r.product = "4D Volume Desktop"
        check("absent product: no other application taken", r.version.isEmpty && r.build.isEmpty && r.productInDMG == nil)
        check("absent product blocks the run", r.runBlockers.contains { $0.contains("absent") } && !r.canRun)
        check("absent product blocks the installation", !r.canInstall)
        r.product = "4D Server"
        check("other product of the image", r.version == "21.2" && r.build == "100629" && r.productInDMG?.name == "4D Server")
        r.product = "4D"
        r.build = "999"
        check("typed build different from the image flagged", r.dmgMismatch != nil)
        r.build = "100629"
        check("same build: no mismatch", r.dmgMismatch == nil)

        r.setDMG(H.appendingPathComponent("Downloads/4D bad.dmg").path)
        check("unreadable image -> failed", waitFor(20) { if case .failed = r.dmgState { return true }; return false })
        check("unreadable image: nothing guessed from its name", r.version.isEmpty && r.build.isEmpty)
        check("unreadable image blocks the run", !r.canRun && !r.canInstall)
        r.setDMG(H.appendingPathComponent("Downloads/missing.dmg").path)
        check("missing image -> failed", { if case .failed(let m) = r.dmgState { return m.contains("introuvable") }; return false }())
    }

    // ---------- stale results ----------
    @MainActor static func seed(_ r: Runner) {
        r.rowsByLang = ["EN": ResultFile.parse("Version number\tok\tv21.2\t10:00\t/x\n")]
        r.reportPath = "/tmp/report.html"
        r.staleNote = ""
        r.resultsContext = ResultsContext(selection: r.selection, installStamp: r.installStamp)
    }

    // platform: detected on the hardware, never chosen nor restored from a saved configuration
    @MainActor static func platformDetection() {
        let r = make()
        let hw = HostPlatform.detect()
        check("platform detected on this Mac", (try? hw.get()) == r.platform && !r.platform.isEmpty && r.platformError == nil)
        put(r.kit.appendingPathComponent("kit.conf"), "PRODUCT=4D\nVERSION=21.2\nBUILD=1\nPLATFORM='macOS Intel'\nDMG=\nTEST_CONTROL=1\nTEST_GITHUB=0\nLANGS=EN\n")
        let before = r.platform
        r.loadPreviousConf()
        check("saved platform ignored", r.platform == before)
        r.saveConf()
        r.detectPlatform(.failure(PlatformError(message: "matériel non reconnu")))
        check("detection failure: no invented platform", r.platform.isEmpty && r.platformError?.contains("matériel non reconnu") == true)
        check("detection failure: run blocked with the reason", !r.canRun && r.runBlockers.contains { $0.contains("Plateforme non détectée") })
        check("detection failure: install blocked", !r.canInstall)
        r.detectPlatform(.success(HostPlatform.intel))
        check("intel hardware shown as macOS Intel", r.platform == "macOS Intel" && r.platformError == nil)
        r.detectPlatform()
    }

    @MainActor static func staleResults() {
        let r = make()
        r.setDMG(H.appendingPathComponent("Downloads/4D good.dmg").path)
        _ = waitFor(20) { r.dmgState == .read }
        seed(r)
        r.version = "21.2"; r.platform = r.platform
        check("same values: results kept", r.rowsByLang["EN"] != nil && r.staleNote.isEmpty)
        r.product = "4D Server"
        check("other product: results cleared", r.rowsByLang.isEmpty && r.reportPath.isEmpty)
        check("other product: reason shown", r.staleNote.contains("autre produit"))
        check("reason logged", r.log.contains(r.staleNote))
        r.product = "4D"
        seed(r)
        r.build = "100630"
        check("other build: results cleared", r.rowsByLang.isEmpty && r.staleNote.contains("autre version ou build"))
        r.build = "100629"
        seed(r)
        r.platform = r.platform == "macOS ARM" ? "macOS Intel" : "macOS ARM"
        check("other platform: results cleared", r.rowsByLang.isEmpty && r.staleNote.contains("autre plateforme"))
        r.platform = "macOS ARM"
        seed(r)
        put(URL(fileURLWithPath: r.installStatePath), "STATUS\tok\nDATE\tnew\n")
        r.selectionChanged()
        check("new installation: results cleared", r.rowsByLang.isEmpty && r.staleNote.contains("nouvelle installation"))
        seed(r)
        r.setDMG(H.appendingPathComponent("Downloads/4D other.dmg").path)
        check("other image: results cleared", r.rowsByLang.isEmpty && r.staleNote.contains("autre image"))
        _ = waitFor(20) { r.dmgState != .reading }
        try? FileManager.default.removeItem(atPath: r.installStatePath)
    }

    // ---------- installation ----------
    @MainActor static func installation() {
        let r = make()
        let args = H.appendingPathComponent("install_args.log")
        try? FileManager.default.removeItem(at: args)
        r.installDest = H.appendingPathComponent("Applications").path
        check("no image: install disabled", !r.canInstall)
        r.setDMG(H.appendingPathComponent("Downloads/4D good.dmg").path)
        _ = waitFor(20) { r.dmgState == .read }
        check("not installed before", !r.installedForSelection)

        mode("window_mode", "ok")
        mode("install_mode", "space")
        r.install()
        check("window check first, busy", r.windowOp.isRunning && r.busy && !r.installOp.isRunning)
        check("no space: failed", waitFor(20) { !r.windowOp.isRunning && !r.installOp.isRunning })
        check("no space: precise title", r.installOp == .failed(title: "Espace disque insuffisant", message: "3 Go nécessaires, 1 Go libres"))
        check("no space: not installed", !r.installedForSelection)

        mode("install_mode", "exists")
        r.install(); _ = waitFor(20) { !r.windowOp.isRunning }
        _ = waitFor(20) { !r.installOp.isRunning }
        check("existing install: confirmation asked", r.showExistingAlert && r.existing?.same == true)
        check("existing install: nothing installed", !r.installedForSelection)
        let calls = read(args).components(separatedBy: "\n").filter { !$0.isEmpty }.count
        r.resolveExisting(nil)
        check("cancel: no second call", read(args).components(separatedBy: "\n").filter { !$0.isEmpty }.count == calls)
        check("cancel: state cancelled", { if case .cancelled = r.installOp { return true }; return false }())

        seed(r)
        r.install(); _ = waitFor(20) { !r.windowOp.isRunning }
        _ = waitFor(20) { !r.installOp.isRunning }
        r.resolveExisting("replace")
        check("replace: confirmed call", waitFor(20) { !r.installOp.isRunning } && read(args).contains("--replace"))
        check("replace: succeeded", { if case .succeeded = r.installOp { return true }; return false }())
        check("selected values passed", read(args).contains("--product|4D|--version|21.2|--build|100629|--platform|\(r.platform)|--dest|\(r.installDest)"))
        check("verified installation of the selection", r.installedForSelection)
        check("results of the previous installation cleared", r.rowsByLang.isEmpty && r.staleNote.contains("nouvelle installation"))
        r.build = "100630"
        check("other build: installation no longer counted", !r.installedForSelection)
        r.build = "100629"

        mode("install_mode", "slow")
        r.install(); _ = waitFor(20) { !r.windowOp.isRunning }
        check("slow install started", waitFor(5) { if case .running(_, let s) = r.installOp { return s == "Copie" }; return false })
        r.cancelInstall()
        check("cancel install", waitFor(20) { !r.installOp.isRunning })
        check("cancelled, not failed nor succeeded", { if case .cancelled = r.installOp { return true }; return false }())
        try? FileManager.default.removeItem(atPath: r.installStatePath)
        dmgWindowGate(r, args)
    }

    // the window of the disk image gates every installation; success = automatic match with the reference window
    @MainActor static func dmgWindowGate(_ r: Runner, _ args: URL) {
        func installs() -> Int { read(args).components(separatedBy: "\n").filter { !$0.isEmpty }.count }
        func failed() -> Bool { if case .failed = r.windowOp { return true }; return false }
        mode("install_mode", "ok")
        let before = installs()
        for m in ["ko", "action", "nostate", "stale"] {
            mode("window_mode", m)
            r.install()
            _ = waitFor(20) { !r.windowOp.isRunning }
            check("window \(m): install blocked", failed() && installs() == before && !r.installOp.isRunning)
        }
        mode("window_mode", "ko"); r.install(); _ = waitFor(20) { !r.windowOp.isRunning }
        check("window ko: precise reason", { if case .failed(_, let m) = r.windowOp { return m.contains("Applications shortcut missing") }; return false }())
        check("window ko: status ko", r.dmgWindow?.status == .ko)
        mode("window_mode", "action"); r.install(); _ = waitFor(20) { !r.windowOp.isRunning }
        check("window action: Action requise", { if case .failed(let t, _) = r.windowOp { return t == "Action requise" }; return false }())

        // automatic verdict (identical to the 21.2 reference window): installs at once, no confirmation asked
        mode("window_mode", "ok"); r.install()
        check("window ok: installs automatically", waitFor(20) { installs() == before + 1 && !r.installOp.isRunning && !r.windowOp.isRunning })
        check("window ok: status ok, nothing pending", r.dmgWindow?.status == .ok && !r.busy)
        let afterAuto = installs()
        // pending (old kit only): still never an installation without an explicit verdict
        mode("window_mode", "pending"); r.install(); _ = waitFor(20) { !r.windowOp.isRunning }
        check("pending: waits for the user, no install", r.dmgWindow?.status == .pending && r.windowOp == .idle && installs() == afterAuto && !r.busy)
        check("pending: checks parsed", r.dmgWindow?.lines.count == 2 && r.dmgWindow?.lines.first?.tone == "ok")
        r.confirmDMGWindow(false)
        _ = waitFor(20) { !r.windowOp.isRunning }
        check("rejected: KO, no install", r.dmgWindow?.status == .ko && installs() == afterAuto && failed())

        r.install(); _ = waitFor(20) { !r.windowOp.isRunning }
        check("rejection does not stick: re-checked, pending again", r.dmgWindow?.status == .pending)
        r.build = "100630"; r.selectionChanged()
        check("selection changed: pending check dropped", r.dmgWindow == nil)
        r.build = "100629"
        r.install(); _ = waitFor(20) { !r.windowOp.isRunning }
        r.confirmDMGWindow(true)
        check("confirmed: installation runs", waitFor(20) { installs() == afterAuto + 1 && !r.installOp.isRunning && !r.windowOp.isRunning })
        check("confirmed: status ok", r.dmgWindow?.status == .ok)
        mode("window_mode", "ok")
        try? FileManager.default.removeItem(atPath: r.installStatePath)
    }

    // ---------- download ----------
    @MainActor static func download() {
        let r = make()
        for (u, ok) in [("https://product-download.4d.com/4D.dmg", true), ("https://4d.com/x.dmg", true),
                        ("http://product-download.4d.com/4D.dmg", false), ("https://evil.com/4d.com/4D.dmg", false),
                        ("https://4d.com.evil.com/4D.dmg", false), ("https://evil4d.com/4D.dmg", false),
                        ("https://user:pw@product-download.4d.com/4D.dmg", false), ("ftp://product-download.4d.com/4D.dmg", false)] {
            r.directURL = u
            check("url \(u) \(ok ? "accepted" : "refused")", r.directURLValid == ok)
        }
        r.directURL = "https://evil.com/4D.dmg"
        r.downloadDirect()
        check("refused url: nothing started", r.downloadOp == .idle)

        r.directURL = "https://product-download.4d.com/auth/4D.dmg"
        r.downloadDirect()
        check("auth: failed", waitFor(20) { !r.downloadOp.isRunning })
        check("auth: sign-in in the browser, no password asked",
              { if case .failed(let t, let m) = r.downloadOp { return t == "Connexion requise dans le navigateur" && m.contains("mot de passe") }; return false }())
        check("auth: no image selected", r.dmgPath.isEmpty)

        r.directURL = "https://product-download.4d.com/slow/4D.dmg"
        r.downloadDirect()
        check("slow download running", waitFor(5) { if case .running(let p, _) = r.downloadOp { return p != nil }; return false })
        r.cancelDownload()
        pause(1.5) // the engine has handled TERM: its error must not replace the cancellation
        check("cancelled download", { if case .cancelled = r.downloadOp { return true }; return false }())
        check("cancelled download: no image selected", r.dmgPath.isEmpty)

        r.directURL = "https://product-download.4d.com/ok/4D.dmg"
        r.downloadDirect()
        check("download succeeded", waitFor(20) { if case .succeeded = r.downloadOp { return true }; return false })
        check("downloaded image selected", r.dmgPath == H.appendingPathComponent("Downloads/4D good.dmg").path)
        check("downloaded image read", waitFor(20) { r.dmgState == .read } && r.version == "21.2")
        check("hash in the result", { if case .succeeded(let m) = r.downloadOp { return m.contains("SHA-256 ABC123") }; return false }())

        r.scanDownloads()
        check("scan lists candidates", waitFor(20) { !r.candidates.isEmpty })
        let partial = r.candidates.first { $0.state == .partial }
        check("partial download listed but not usable", partial != nil && partial?.usable == false)
        if let p = partial {
            let before = r.dmgPath
            r.useCandidate(p)
            check("partial download never selected", r.dmgPath == before)
        }
    }

    // ---------- watch of Downloads (« Télécharger dans le navigateur »): always ends, never an endless spinner ----------
    @MainActor static func watchDownloads() {
        let fm = FileManager.default, dl = H.appendingPathComponent("Downloads")
        let calls = H.appendingPathComponent("scan_calls"), failFlag = H.appendingPathComponent("scan_fail")
        func scans() -> Int { read(calls).split(separator: "\n").count }
        func age(_ name: String, _ seconds: TimeInterval) {
            try? fm.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -seconds)], ofItemAtPath: dl.appendingPathComponent(name).path)
        }
        func file(_ name: String, _ size: Int) { fm.createFile(atPath: dl.appendingPathComponent(name).path, contents: Data(count: size)) }
        func remove(_ names: String...) { for n in names { try? fm.removeItem(at: dl.appendingPathComponent(n)) } }
        func found(_ r: Runner) -> DownloadCandidate? { if case .found(let c) = r.watch.phase { return c }; return nil }
        func failedReason(_ r: Runner) -> String? { if case .failed(let w) = r.watch.phase { return w }; return nil }
        // files already there before the watch: not new
        for n in (try? fm.contentsOfDirectory(atPath: dl.path)) ?? [] { age(n, 3600) }

        // 1. the reported case: Chrome download (.crdownload) renamed when finished -> found, spinner gone, polling stopped
        let r = make(); r.watchInterval = 0.2
        r.setDMG(dl.appendingPathComponent("4D good.dmg").path)
        check("watch: selection read", waitFor(20) { r.dmgState == .read })
        let selection = r.selection
        r.startWatching()
        check("watch: watching", r.watching && r.watch.phase == .watching)
        check("watch: first scan sets the baseline", waitFor(10) { r.watch.baseline != nil })
        check("watch: old images are not new", r.watching && found(r) == nil)
        file("4D 21.4 LTS Mac.dmg.crdownload", 2048)
        check("watch: download in progress listed", waitFor(10) { r.watch.inProgress.map(\.name) == ["4D 21.4 LTS Mac.dmg.crdownload"] })
        check("watch: in progress never accepted", r.watching && found(r) == nil)
        try? fm.moveItem(at: dl.appendingPathComponent("4D 21.4 LTS Mac.dmg.crdownload"), to: dl.appendingPathComponent("4D 21.4 LTS Mac.dmg"))
        check("watch: finished download found", waitFor(10) { found(r)?.name == "4D 21.4 LTS Mac.dmg" })
        check("watch: spinner gone once found", !r.watching)
        check("watch: in progress list cleared", r.watch.inProgress.isEmpty)
        check("watch: nothing selected in place of the user", r.selection == selection)
        check("watch: end logged", r.log.contains("Téléchargement terminé : \(dl.path)/4D 21.4 LTS Mac.dmg"))
        let n = scans(); pause(1.2)
        check("watch: polling stopped once found", scans() == n)
        if let c = found(r) { r.useCandidate(c) }
        check("watch: « Utiliser » selects the found image", r.dmgPath == dl.appendingPathComponent("4D 21.4 LTS Mac.dmg").path)
        check("watch: found notice closed by the selection", r.watch.phase == .idle)
        check("watch: found image read", waitFor(20) { r.dmgState == .read })
        check("watch: still new after the watch (pill)", r.candidates.first { $0.name == "4D 21.4 LTS Mac.dmg" }.map(r.isNew) ?? false)
        age("4D 21.4 LTS Mac.dmg", 3600) // downloaded before the next watches

        // 2. an image chosen another way (« Choisir… », direct download) ends the watch
        r.startWatching()
        check("watch 2: watching", waitFor(10) { r.watch.baseline != nil } && r.watching)
        r.setDMG(dl.appendingPathComponent("4D good.dmg").path)
        check("watch 2: chosen image ends the watch", !r.watching && r.watch.phase == .idle)
        check("watch 2: logged", r.log.contains("Surveillance de Téléchargements terminée : image choisie : 4D good.dmg"))
        let n2 = scans(); pause(1.0)
        check("watch 2: polling stopped", scans() == n2)

        // 3. new file keeping an old date (server date): new because absent at the first scan
        r.startWatching()
        check("watch 3: baseline", waitFor(10) { r.watch.baseline != nil })
        file("4D stamped.dmg", 4096); age("4D stamped.dmg", 86400)
        check("watch 3: found by the baseline", waitFor(10) { found(r)?.name == "4D stamped.dmg" })
        r.dismissWatch()
        check("watch 3: « Fermer »", r.watch.phase == .idle && !r.watching)

        // 4. refused or ignored files: explained, the watch goes on
        r.startWatching()
        check("watch 4: baseline", waitFor(10) { r.watch.baseline != nil })
        file("4D trunc.dmg", 4096); file("4D empty.dmg", 0); file("4D mirror.dmg", 4096)
        check("watch 4: three notes", waitFor(10) { r.watch.notes.count == 3 })
        check("watch 4: truncated refused", r.watch.notes.contains { $0.hasPrefix("4D trunc.dmg") && $0.contains("fin d'image disque absente") })
        check("watch 4: empty refused", r.watch.notes.contains { $0.hasPrefix("4D empty.dmg") && $0.contains("vide") })
        check("watch 4: other origin ignored", r.watch.notes.contains { $0.hasPrefix("4D mirror.dmg") && $0.contains("mirror.example.com") })
        check("watch 4: still watching", r.watching && found(r) == nil)
        check("watch 4: notes logged once", r.log.components(separatedBy: "Téléchargements : 4D trunc.dmg").count == 2)
        r.stopWatching()
        check("watch 4: « Arrêter »", !r.watching && r.watch.phase == .idle && r.watch.notes.isEmpty)
        check("watch 4: stop logged", r.log.contains("terminée : arrêtée par l'utilisateur"))
        remove("4D trunc.dmg", "4D empty.dmg", "4D mirror.dmg", "4D stamped.dmg")

        // 5. unreadable folder: error with its reason after a retry, spinner gone; « Réessayer » works again
        put(failFlag, "1")
        r.startWatching()
        check("watch 5: failed", waitFor(10) { failedReason(r) != nil })
        check("watch 5: reason given", failedReason(r)?.contains("illisible") == true && failedReason(r)?.contains("Fichiers et dossiers") == true)
        check("watch 5: retried once before failing", r.watch.failures == DownloadWatch.failuresBeforeError)
        check("watch 5: spinner gone", !r.watching)
        check("watch 5: error kept for the list", r.scanError != nil)
        try? fm.removeItem(at: failFlag)
        r.startWatching()
        check("watch 5: retry watches again", waitFor(10) { r.watch.baseline != nil } && r.watching && r.scanError == nil)
        r.stopWatching()

        // 6. time limit: ends with its own state
        r.watchLimit = 0.5
        r.startWatching()
        check("watch 6: timed out", waitFor(10) { r.watch.phase == .timedOut })
        check("watch 6: spinner gone", !r.watching)
        check("watch 6: logged", r.log.contains("aucune image complète n'est apparue"))
        r.watchLimit = 7200

        // 7. refresh without a watch: a failed scan is reported, not shown as an empty folder
        put(failFlag, "1")
        r.scanDownloads()
        check("scan error reported", waitFor(10) { r.scanError?.contains("illisible") == true })
        try? fm.removeItem(at: failFlag)
        r.scanDownloads()
        check("scan error cleared", waitFor(10) { r.scanError == nil })
        remove("4D 21.4 LTS Mac.dmg")
    }

    // ---------- automatic offline test: pf prerequisites and leftover detection (no root, no real pf) ----------
    static func netGuard() {
        let d = H.appendingPathComponent("netguard").path
        try? FileManager.default.createDirectory(atPath: d, withIntermediateDirectories: true)
        let conf = H.appendingPathComponent("pf.conf").path
        try? "scrub-anchor \"com.apple/*\"\nanchor \"com.apple/*\"\nload anchor \"com.apple\" from \"/etc/pf.anchors/com.apple\"\n".write(toFile: conf, atomically: true, encoding: .utf8)
        check("standard pf.conf evaluates com.apple/*", Runner.pfConfEvaluatesAnchors(conf))
        try? "# anchor \"com.apple/*\"\npass all\n".write(toFile: conf, atomically: true, encoding: .utf8)
        check("pf.conf without the anchor (commented) refused", !Runner.pfConfEvaluatesAnchors(conf))
        check("missing pf.conf refused", !Runner.pfConfEvaluatesAnchors(conf + ".none"))
        func state(_ s: String) { try? s.write(toFile: d + "/state", atomically: true, encoding: .utf8) }
        let now = Int(Date().timeIntervalSince1970)
        check("no state: nothing to recover", !Runner.guardLeftBlocked(stateDir: d))
        // a dead guard (PID beyond pid_max) that left its rules
        state("99999999 3 blocked \(now) pf firewall\n")
        check("dead guard while blocked: recovery", Runner.guardLeftBlocked(stateDir: d))
        state("99999999 3 error \(now) rules still present\n")
        check("dead guard in error: recovery", Runner.guardLeftBlocked(stateDir: d))
        state("99999999 3 stopped \(now) done\n")
        check("stopped guard: nothing to recover", !Runner.guardLeftBlocked(stateDir: d))
        state("99999999 3 open \(now) done\n")
        check("open guard: nothing to recover", !Runner.guardLeftBlocked(stateDir: d))
        state("\(getpid()) 3 blocked \(now) pf firewall\n")
        check("running guard: never recovered by the app", !Runner.guardLeftBlocked(stateDir: d))
        state("garbage\n")
        check("unreadable state ignored", !Runner.guardLeftBlocked(stateDir: d))
    }

    // ---------- Dock icon: AppIcon.icns of the running bundle, set once at launch ----------
    @MainActor static func bundleIcon() {
        NSApp.setActivationPolicy(.prohibited) // never shown in the Dock during the tests
        let fm = FileManager.default
        let base = H.appendingPathComponent("bundles")
        func bundle(_ name: String, iconKey: String?, icns: Data?) -> URL {
            let app = base.appendingPathComponent(name + ".app")
            let res = app.appendingPathComponent("Contents/Resources")
            try? fm.createDirectory(at: res, withIntermediateDirectories: true)
            var info: [String: Any] = ["CFBundleIdentifier": "com.4d.qa.testinstaller4d"]
            if let k = iconKey { info["CFBundleIconFile"] = k }
            (info as NSDictionary).write(to: app.appendingPathComponent("Contents/Info.plist"), atomically: true)
            if let d = icns { try? d.write(to: res.appendingPathComponent("AppIcon.icns")) }
            return app
        }
        guard let real = try? Data(contentsOf: H.appendingPathComponent("AppIcon.icns")) else {
            check("real AppIcon.icns available to the test", false); return
        }
        let good = bundle("Good", iconKey: "AppIcon", icns: real)
        let withExt = bundle("Ext", iconKey: "AppIcon.icns", icns: real)
        let noKey = bundle("NoKey", iconKey: nil, icns: real)
        let noFile = bundle("NoFile", iconKey: "AppIcon", icns: nil)
        let garbage = bundle("Garbage", iconKey: "AppIcon", icns: Data("not an icon".utf8))
        let escape = bundle("Escape", iconKey: "../Resources/AppIcon", icns: real)

        check("icon name without extension resolved to Resources/AppIcon.icns",
              BundleIcon.url(bundle: good)?.lastPathComponent == "AppIcon.icns")
        check("icon name with extension resolved", BundleIcon.url(bundle: withExt)?.lastPathComponent == "AppIcon.icns")
        check("no CFBundleIconFile: no icon", BundleIcon.url(bundle: noKey) == nil)
        check("missing icon file: no icon", BundleIcon.url(bundle: noFile) == nil)
        check("icon name with a path refused", BundleIcon.url(bundle: escape) == nil)
        check("unreadable icon file: no image", BundleIcon.image(bundle: garbage) == nil)
        let img = BundleIcon.image(bundle: good)
        let widest = img?.representations.map(\.pixelsWide).max() ?? 0
        check("real icon loaded up to 1024 px (got \(widest))", widest == 1024)
        check("real icon has the small sizes too", img?.representations.contains { $0.pixelsWide == 16 } == true)

        // NSApp.applicationIconImage always returns the same object: compare what it draws (64 x 64 px)
        func pixels(_ i: NSImage?) -> [UInt8] {
            guard let i = i, let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 64, pixelsHigh: 64,
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                bytesPerRow: 256, bitsPerPixel: 32), let g = NSGraphicsContext(bitmapImageRep: rep) else { return [] }
            NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = g
            i.draw(in: NSRect(x: 0, y: 0, width: 64, height: 64))
            NSGraphicsContext.restoreGraphicsState()
            return Array(UnsafeBufferPointer(start: rep.bitmapData, count: 64 * 256))
        }
        func distance(_ a: [UInt8], _ b: [UInt8]) -> Double {
            guard a.count == b.count, !a.isEmpty else { return .infinity }
            return Double(zip(a, b).reduce(0) { $0 + abs(Int($1.0) - Int($1.1)) }) / Double(a.count)
        }
        let generic = pixels(NSApp.applicationIconImage), wanted = pixels(img)
        let gap = distance(generic, wanted)
        check("test icon differs from the default icon (diff \(gap))", gap > 20)
        check("bundle without icon: refused", !BundleIcon.applyToDock(bundle: noFile))
        check("Dock icon untouched after a refused bundle", distance(pixels(NSApp.applicationIconImage), generic) < 1)
        check("bundle with icon: Dock icon set", BundleIcon.applyToDock(bundle: good))
        let shown = pixels(NSApp.applicationIconImage)
        // the getter returns a resampled snapshot: much closer to AppIcon.icns than to the default icon
        check("Dock icon draws the bundle AppIcon.icns (diff \(distance(shown, wanted)) vs \(gap))",
              distance(shown, wanted) < min(12, gap / 4))
        check("garbage icon: refused", !BundleIcon.applyToDock(bundle: garbage))
        check("garbage icon: Dock icon kept", distance(pixels(NSApp.applicationIconImage), shown) < 1)
        NSApp.applicationIconImage = nil
        try? fm.removeItem(at: base)
    }
}
