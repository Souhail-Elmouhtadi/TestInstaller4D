import Foundation

// Unit tests of Core.swift (statuses, permissions, signing, events, stale results, contrast, processes).
// Built and run by tests/test_core.sh: swiftc -parse-as-library Core.swift tests/test_core.swift

var passed = 0, failed = 0
func check(_ name: String, _ cond: @autoclosure () -> Bool) {
    if cond() { passed += 1 } else { failed += 1; print("FAIL: \(name)") }
}

@main
struct CoreTests {
    static func main() {
        statuses()
        resultFiles()
        permissions()
        tracker()
        signing()
        events()
        candidates()
        downloadWatch()
        dmgContent()
        staleResults()
        installRecord()
        dmgWindow()
        hostPlatform()
        contrast()
        processes()
        print("core: \(passed) checks passed, \(failed) failed")
        exit(failed == 0 ? 0 : 1)
    }

    static func statuses() {
        check("only ok is a success", ResultStatus.allCases.filter(\.isSuccess) == [.ok])
        check("unknown token", ResultStatus(token: "passed") == .unknown)
        check("token trimmed", ResultStatus(token: " ok\n") == .ok)
        check("notrun label", ResultStatus.notrun.label == "Non exécuté")
        check("action label", ResultStatus.action.label == "Action requise")
        check("undetermined label", ResultStatus.undetermined.label == "Indéterminé")
        check("ko worse than action", ResultStatus.ko.rank > ResultStatus.action.rank)
        check("action worse than undetermined", ResultStatus.action.rank > ResultStatus.undetermined.rank)
        check("undetermined worse than notrun", ResultStatus.undetermined.rank > ResultStatus.notrun.rank)
        check("notrun worse than manual", ResultStatus.notrun.rank > ResultStatus.manual.rank)
        check("manual worse than ok", ResultStatus.manual.rank > ResultStatus.ok.rank)
        check("unknown never green", ResultStatus.unknown.tone != .success && ResultStatus.unknown.rank > ResultStatus.ok.rank)
        let tones = ResultStatus.allCases.filter { $0 != .ok }.map(\.tone)
        check("no other status uses the success colour", !tones.contains(.success))
        check("distinct symbols", Set(ResultStatus.allCases.map(\.symbol)).count == ResultStatus.allCases.count)
    }

    static func resultFiles() {
        let txt = "#RUN\t20261022-1\r\n#LANG\tFR\n#HASH\ta.dmg\t12\tABC\n#HASH\tb.zip\t3\tDEF\n"
            + "The download\tok\tline1\\nline2\t2026-10-22 10:00:00\t/tmp/a.dmg\n"
            + "Execution WITHOUT Internet\tnotrun\tdeclined\t2026-10-22 10:01:00\t/Applications/4D.app\n"
            + "Legacy row\tmanual\tthree columns only\n"
            + "Weird\tgreen\tx\n\n"
        let r = ResultFile.parse(txt)
        check("headers", r.headers["RUN"] == "20261022-1" && r.headers["LANG"] == "FR")
        check("hashes", r.hashes.count == 2)
        check("rows", r.rows.count == 4)
        check("5 columns", r.rows[0].date == "2026-10-22 10:00:00" && r.rows[0].path == "/tmp/a.dmg")
        check("unescaped detail", r.rows[0].detail == "line1\nline2")
        check("3 columns tolerated", r.rows[2].date.isEmpty && r.rows[2].path.isEmpty && r.rows[2].status == .manual)
        check("unknown status kept", r.rows[3].status == .unknown && r.rows[3].rawStatus == "green")
        check("worst", r.worst == .unknown)
        check("ids unique", Set(r.rows.map(\.id)).count == r.rows.count)
        check("count", r.count(.notrun) == 1)
        check("empty file", ResultFile.parse("").rows.isEmpty && ResultFile.parse("").worst == nil)
        for status in ResultStatus.allCases {
            let row = ResultFile.parse("Components\t\(status.rawValue)\texpected 6, observed 8\\nMissing: (none)\\nUnexpected: Extra A, Extra B\\nAction: review package\tdate\t/test/Components").rows[0]
            check("full diagnostic visibility for \(status)", row.showsFullDetail == (status != .ok && status != .na))
            check("diagnostic not truncated for \(status)", row.detail.contains("Unexpected: Extra A, Extra B\nAction: review package"))
            check("diagnostic preserves status for \(status)", row.status == status)
        }
    }

    static func permissions() {
        let both = PermissionSnapshot.parse("EXE\t/x/about_check\nPID\t42\nAX\t1\nSCREEN\t1\n", exitCode: 0)
        check("granted", both.accessibility == .granted && both.screen == .granted)
        check("exe/pid", both.executable == "/x/about_check" && both.pid == "42")
        let denied = PermissionSnapshot.parse("AX\t0\nSCREEN\t0\n", exitCode: 0)
        check("denied", denied.accessibility == .denied && denied.screen == .denied)
        let mixed = PermissionSnapshot.parse("AX\t1\nSCREEN\t0\n", exitCode: 0)
        check("independent", mixed.accessibility == .granted && mixed.screen == .denied)
        func isError(_ s: PermissionState) -> Bool { if case .error = s { return true }; return false }
        check("missing value = error", isError(PermissionSnapshot.parse("AX\t1\n", exitCode: 0).screen))
        check("empty output = error", isError(PermissionSnapshot.parse("", exitCode: 0).accessibility))
        check("exit code = error even if 1", isError(PermissionSnapshot.parse("AX\t1\nSCREEN\t1\n", exitCode: 2).accessibility))
        check("launch failure = error", isError(PermissionSnapshot.parse("AX\t1\n", exitCode: 0, launchError: "no file").accessibility))
        check("conflict = error", isError(PermissionSnapshot.parse("AX\t1\nAX\t0\nSCREEN\t1\n", exitCode: 0).accessibility))
        check("garbage value = error", isError(PermissionSnapshot.parse("AX\tyes\nSCREEN\t1\n", exitCode: 0).accessibility))
        check("prefix line not accepted", isError(PermissionSnapshot.parse("XAX\t1\nSCREEN\t1\n", exitCode: 0).accessibility))
        check("checking not granted", !PermissionState.checking.isGranted && PermissionState.checking.tone != .success)
        check("error not granted", !PermissionState.error("x").isGranted && PermissionState.error("x").tone != .success)
        check("denied red", PermissionState.denied.tone == .failure)
        check("only granted is green", [PermissionState.checking, .denied, .error("e")].allSatisfy { $0.tone != .success })
        check("settings anchors", PermissionKind.accessibility.settingsAnchor == "Privacy_Accessibility"
              && PermissionKind.screen.settingsAnchor == "Privacy_ScreenCapture")
    }

    static func tracker() {
        // startup: checking -> denied, no restart advice without an explicit request
        var t = PermissionTracker()
        check("starts checking", t.state == .checking)
        t.apply(.denied)
        check("denied at start", t.state == .denied && !t.restartAdvised)

        // the request itself is never a proof: the immediate check after the prompt stays denied
        t.userRequested()
        t.apply(.denied, afterUserReturn: false)
        check("no green after a request", t.state == .denied)
        check("no restart advice before the user returns", !t.restartAdvised)

        // back from System Settings: still denied -> restart advised
        t.beginCheck()
        check("checking while refreshing", t.state == .checking && !t.state.isGranted)
        let c1 = t.apply(.denied)
        check("restart advised after return", t.restartAdvised && c1 == .none)

        // granted after the relaunch / refresh
        let c2 = t.apply(.granted)
        check("granted change", c2 == .granted && t.state == .granted && !t.restartAdvised)

        // revoked while the app runs
        let c3 = t.apply(.denied)
        check("revoked detected", c3 == .revoked && t.state == .denied && !t.restartAdvised)

        // an error never erases the last known state nor shows green
        var e = PermissionTracker()
        e.apply(.granted)
        let c4 = e.apply(.error("timeout"))
        check("error after granted", c4 == .none && !e.state.isGranted)
        let c5 = e.apply(.denied)
        check("revoked after an error", c5 == .revoked)

        // granted without any request (granted outside the app) is reported, not credited to a click
        var g = PermissionTracker()
        g.apply(.denied)
        check("granted outside the app", g.apply(.granted) == .granted)
    }

    static func signing() {
        check("unsigned", SigningKind.classify(signed: false, adhoc: false, authorities: [], team: nil) == .unsigned)
        check("adhoc flag", SigningKind.classify(signed: true, adhoc: true, authorities: [], team: nil) == .adhoc)
        check("no authority = adhoc", SigningKind.classify(signed: true, adhoc: false, authorities: [], team: nil) == .adhoc)
        check("developer id", SigningKind.classify(signed: true, adhoc: false,
              authorities: ["Developer ID Application: 4D SAS (37UG5W39Z2)", "Developer ID Certification Authority"], team: "37UG5W39Z2")
              == .developerID(team: "37UG5W39Z2"))
        check("apple development", SigningKind.classify(signed: true, adhoc: false,
              authorities: ["Apple Development: x (ABC)"], team: "ABC") == .appleDevelopment(team: "ABC"))
        check("local certificate", SigningKind.classify(signed: true, adhoc: false,
              authorities: ["TestInstaller4D Local Signing"], team: nil) == .certificate(name: "TestInstaller4D Local Signing"))
        check("adhoc not stable", !SigningKind.adhoc.keepsPermissionsAcrossBuilds && !SigningKind.unsigned.keepsPermissionsAcrossBuilds)
        check("certificate stable", SigningKind.certificate(name: "x").keepsPermissionsAcrossBuilds
              && SigningKind.developerID(team: "T").keepsPermissionsAcrossBuilds)
        let me = SigningInfo.current()
        check("current signing readable", !me.kind.label.isEmpty)
    }

    static func events() {
        check("step", EngineEvent.parse("STEP\tMontage") == .step("Montage"))
        check("install progress", EngineEvent.parse("PROGRESS\t28\tMontage de l'image disque") == .progress(28, "Montage de l'image disque"))
        if case .progress(let p, let t) = EngineEvent.parse("PROGRESS\t50\t1048576\t2097152") {
            check("download progress", p == 50 && t.contains("/"))
        } else { check("download progress", false) }
        check("progress clamped", EngineEvent.parse("PROGRESS\t150\tx") == .progress(100, "x"))
        check("exists", EngineEvent.parse("EXISTS\t/Applications/4D 21.2\t21.2\t100624\tdifferent")
              == .exists(path: "/Applications/4D 21.2", version: "21.2", build: "100624", same: false))
        check("error", EngineEvent.parse("ERROR\tSPACE\tneeded 2 GB") == .error(code: "SPACE", message: "needed 2 GB"))
        check("result ok", EngineEvent.parse("RESULT\tok\t/x/4D.app") == .result(ok: true, path: "/x/4D.app"))
        check("result ko", EngineEvent.parse("RESULT\tko\t") == .result(ok: false, path: ""))
        check("other", EngineEvent.parse("hdiutil: blah") == .other("hdiutil: blah"))
        for code in ["INCOMPLETE", "MOUNT", "SPACE", "DENIED", "VERSION", "ADMIN", "AUTH", "DOMAIN", "PRODUCT"] {
            check("title \(code)", !EngineEvent.title(ofError: code).hasPrefix("Erreur "))
        }
        check("title space", EngineEvent.title(ofError: "SPACE") == "Espace disque insuffisant")
        check("title mount", EngineEvent.title(ofError: "MOUNT") == "Montage impossible")
    }

    static func candidates() {
        let txt = "CANDIDATE\t/d/old.dmg\t10\tcomplete\tofficial\tproduct-download.4d.com\t100\n"
            + "CANDIDATE\t/d/new.dmg\t20\tpartial\tunknown\t\t300\n"
            + "CANDIDATE\t/d/mid.dmg\t0\tempty\tother\texample.com\t200\n"
            + "CANDIDATE\tbroken\n"
        let c = DownloadCandidate.parse(txt)
        check("3 candidates", c.count == 3)
        check("newest first", c.map(\.name) == ["new.dmg", "mid.dmg", "old.dmg"])
        check("partial not usable", !c[0].usable && c[0].state == .partial)
        check("empty not usable", !c[1].usable)
        check("complete usable", c[2].usable && c[2].origin == .official)
        let inv = DownloadCandidate.parse("CANDIDATE\t/d/t.dmg\t10\tinvalid\tofficial\t4d.com\t1\n")
        check("invalid parsed, not usable", inv.count == 1 && inv[0].state == .invalid && !inv[0].usable)
    }

    // watch of Downloads: every path ends in a visible state; incomplete files are never accepted
    static func downloadWatch() {
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        func c(_ name: String, _ state: String, _ mtime: TimeInterval, origin: String = "official", size: Int = 10) -> DownloadCandidate {
            DownloadCandidate.parse("CANDIDATE\t/d/\(name)\t\(size)\t\(state)\t\(origin)\t\(origin == "other" ? "mirror.example.com" : "builds2.4d.com")\t\(Int(mtime))\n")[0]
        }
        func found(_ w: DownloadWatch) -> String? { if case .found(let x) = w.phase { return x.name }; return nil }
        let old = c("old.dmg", "complete", t0.timeIntervalSince1970 - 3600)

        var w = DownloadWatch()
        check("watch idle", w.phase == .idle && !w.isWatching)
        check("idle ignores scans", w.apply(.ok([c("x.dmg", "complete", t0.timeIntervalSince1970 + 10)]), now: t0).isEmpty && w.phase == .idle)
        w.start(at: t0)
        check("watch started", w.isWatching && w.since == t0 && w.limit == 7200)
        _ = w.apply(.ok([old]), now: t0.addingTimeInterval(1))
        check("baseline set", w.baseline == ["/d/old.dmg"])
        check("old image is not the download", w.isWatching && !w.isNew(old))
        // Chrome: .crdownload while receiving, then renamed
        let part = c("4D.dmg.crdownload", "partial", t0.timeIntervalSince1970 + 20)
        _ = w.apply(.ok([part, old]), now: t0.addingTimeInterval(21))
        check("partial listed in progress", w.inProgress.map(\.name) == ["4D.dmg.crdownload"])
        check("partial never accepted", w.isWatching && found(w) == nil)
        let stalePart = c("abandoned.dmg.crdownload", "partial", t0.timeIntervalSince1970 - 86400)
        _ = w.apply(.ok([part, old, stalePart]), now: t0.addingTimeInterval(22))
        check("abandoned partial not in progress", w.inProgress.count == 1 && !w.isNew(stalePart))
        // just renamed: still being written (scan reports partial) -> not accepted yet
        _ = w.apply(.ok([c("4D.dmg", "partial", t0.timeIntervalSince1970 + 30), old]), now: t0.addingTimeInterval(31))
        check("fresh file not accepted", w.isWatching)
        let log = w.apply(.ok([c("4D.dmg", "complete", t0.timeIntervalSince1970 + 30), old]), now: t0.addingTimeInterval(34))
        check("complete image found", found(w) == "4D.dmg")
        check("found ends the watch", !w.isWatching && w.inProgress.isEmpty)
        check("found logged", log.contains { $0.hasPrefix("Téléchargement terminé : /d/4D.dmg (10 octets, origine builds2.4d.com)") })
        check("terminal: later scans ignored", w.apply(.ok([]), now: t0.addingTimeInterval(40)).isEmpty && found(w) == "4D.dmg")
        w.imageChosen()
        check("chosen image: idle", w.phase == .idle && w.notes.isEmpty)
        check("pill kept after the watch", w.isNew(c("4D.dmg", "complete", t0.timeIntervalSince1970 + 30)))

        // refused / ignored files are explained and the watch goes on
        w.start(at: t0)
        _ = w.apply(.ok([old]), now: t0)
        let refused = [c("t.dmg", "invalid", t0.timeIntervalSince1970 + 5), c("e.dmg", "empty", t0.timeIntervalSince1970 + 5, size: 0),
                       c("m.dmg", "complete", t0.timeIntervalSince1970 + 5, origin: "other"), old]
        let l1 = w.apply(.ok(refused), now: t0.addingTimeInterval(9))
        check("refused: still watching", w.isWatching && found(w) == nil)
        check("refused: 3 notes", w.notes.count == 3)
        check("invalid explained", w.notes.contains { $0.hasPrefix("t.dmg") && $0.contains("fin d'image disque absente") })
        check("empty explained", w.notes.contains { $0.hasPrefix("e.dmg") && $0.contains("vide") })
        check("other origin explained", w.notes.contains { $0.hasPrefix("m.dmg") && $0.contains("mirror.example.com") })
        check("notes logged", l1.count == 3)
        check("notes logged once", w.apply(.ok(refused), now: t0.addingTimeInterval(12)).isEmpty)
        _ = w.apply(.ok(refused + [c("u.dmg", "complete", t0.timeIntervalSince1970 + 15, origin: "unknown")]), now: t0.addingTimeInterval(16))
        check("unknown origin accepted (content checked when read)", found(w) == "u.dmg")
        w.stop()
        check("stop: idle, notes cleared", w.phase == .idle && w.notes.isEmpty && !w.isWatching)

        // new file keeping an old date: absent at the first scan -> new
        w.start(at: t0)
        _ = w.apply(.ok([old]), now: t0)
        _ = w.apply(.ok([c("server-date.dmg", "complete", t0.timeIntervalSince1970 - 99999), old]), now: t0.addingTimeInterval(3))
        check("old-dated new file found", found(w) == "server-date.dmg")
        // old invalid file present before the watch: not reported
        w.start(at: t0)
        let oldBad = c("old-trunc.dmg", "invalid", t0.timeIntervalSince1970 - 3600)
        _ = w.apply(.ok([oldBad, old]), now: t0)
        check("old invalid file not reported", w.notes.isEmpty && w.isWatching)

        // errors: one retry, then a terminal error with the reason
        w.start(at: t0)
        _ = w.apply(.failure("dossier illisible"), now: t0.addingTimeInterval(3))
        check("first error: retry", w.isWatching && w.failures == 1 && w.lastError == "dossier illisible")
        _ = w.apply(.ok([old]), now: t0.addingTimeInterval(6))
        check("success resets the errors", w.failures == 0 && w.lastError.isEmpty)
        _ = w.apply(.failure("dossier illisible"), now: t0.addingTimeInterval(9))
        let le = w.apply(.failure("dossier illisible"), now: t0.addingTimeInterval(12))
        check("repeated error: failed with reason", w.phase == .failed("dossier illisible") && !w.isWatching)
        check("error logged", le.contains { $0.contains("dossier illisible") })

        // time limit
        w.start(at: t0, limit: 60)
        _ = w.apply(.ok([old]), now: t0.addingTimeInterval(30))
        check("before the limit", w.isWatching)
        let lt = w.apply(.ok([old]), now: t0.addingTimeInterval(61))
        check("time limit: timed out", w.phase == .timedOut && !w.isWatching)
        check("time limit logged", lt.contains { $0.contains("aucune image complète") })
        // found at the limit: found wins
        w.start(at: t0, limit: 60)
        _ = w.apply(.ok([old]), now: t0)
        _ = w.apply(.ok([c("late.dmg", "complete", t0.timeIntervalSince1970 + 58), old]), now: t0.addingTimeInterval(65))
        check("found at the limit wins", found(w) == "late.dmg")

        // scan output -> result: an error is never an empty list
        func out(_ s: String, _ status: Int32 = 0, timedOut: Bool = false) -> ProcessOutput { ProcessOutput(output: s, status: status, timedOut: timedOut, launchError: nil) }
        if case .failure(let m) = DownloadCandidate.scanResult(out("ERROR\tACCESS\tfolder not readable: /d\n", 1), folder: "/d") {
            check("access error explained", m.contains("illisible") && m.contains("Fichiers et dossiers"))
        } else { check("access error", false) }
        if case .failure(let m) = DownloadCandidate.scanResult(out("ERROR\tARGS\tfolder not found: /d\n", 1), folder: "/d") {
            check("missing folder explained", m.contains("introuvable"))
        } else { check("missing folder", false) }
        check("timeout is an error", DownloadCandidate.scanResult(out("", 0, timedOut: true), folder: "/d") != .ok([]))
        check("failed run is an error", DownloadCandidate.scanResult(out("", 2), folder: "/d") != .ok([]))
        check("empty folder is an empty list", DownloadCandidate.scanResult(out(""), folder: "/d") == .ok([]))
        check("title access", EngineEvent.title(ofError: "ACCESS") == "Dossier illisible")
    }

    static func dmgContent() {
        let apps = DMGContent.parse("4D\t21.2\t100629\tcom.4D.4D\t4D 21.2/4D.app\n4D Server\t21.2\t100629\tcom.4D.4DServer\t4D 21.2/4D Server.app\n\n")
        check("2 apps", apps.count == 2)
        check("relpath", apps[0].relativePath == "4D 21.2/4D.app")
        check("lookup", DMGContent.app(apps, product: "4D Server")?.build == "100629")
        check("no fallback for a missing product", DMGContent.app(apps, product: "4D Volume Desktop") == nil)
        check("unreadable = empty", DMGContent.parse("").isEmpty)
    }

    static func staleResults() {
        let sel = Selection(dmg: "/d/a.dmg", product: "4D", version: "21.2", build: "100629", platform: "macOS ARM")
        let ctx = ResultsContext(selection: sel, installStamp: "s1")
        check("same selection keeps results", ctx.invalidation(selection: sel, installStamp: "s1") == nil)
        var s = sel; s.product = "4D Server"
        check("product change", ctx.invalidation(selection: s, installStamp: "s1") == "autre produit sélectionné")
        s = sel; s.dmg = "/d/b.dmg"
        check("dmg change", ctx.invalidation(selection: s, installStamp: "s1") == "autre image disque sélectionnée")
        s = sel; s.build = "100630"
        check("build change", ctx.invalidation(selection: s, installStamp: "s1") != nil)
        s = sel; s.version = " 21.2 "
        check("whitespace is not a change", ctx.invalidation(selection: s, installStamp: "s1") == nil)
        s = sel; s.platform = "macOS Intel"
        check("platform change", ctx.invalidation(selection: s, installStamp: "s1") != nil)
        check("new installation", ctx.invalidation(selection: sel, installStamp: "s2") == "nouvelle installation")
    }

    static func hostPlatform() {
        check("apple silicon", (try? HostPlatform.classify(arm64: 1, x86_64: 0).get()) == "macOS ARM")
        check("apple silicon seen from Rosetta (x86_64 key 1)", (try? HostPlatform.classify(arm64: 1, x86_64: 1).get()) == "macOS ARM")
        check("intel without arm64 key", (try? HostPlatform.classify(arm64: nil, x86_64: 1).get()) == "macOS Intel")
        check("intel arm64=0", (try? HostPlatform.classify(arm64: 0, x86_64: 1).get()) == "macOS Intel")
        if case .failure(let e) = HostPlatform.classify(arm64: nil, x86_64: nil) { check("unknown hardware: error", e.message.contains("absent")) }
        else { check("unknown hardware: error", false) }
        check("this Mac detected", (try? HostPlatform.detect().get()) != nil)
    }

    static func dmgWindow() {
        let txt = "STATUS\tpending\nDATE\t2026-10-30 15:00:00\nPRODUCT\t4D\nVERSION\t21.2\nBUILD\t100629\nDMG\t/d/a.dmg\nSTAMP\t10 20\n"
            + "VOLUME\t4D 21.2 Release\nSHOT\t/w/s.png\nDETAIL\t[info] mounted\\n[ok] title\\n[ko] no ReadMe\n"
        let c = DMGWindowCheck.parse(txt)
        let sel = Selection(dmg: "/d/a.dmg", product: "4D", version: "21.0.2", build: "100629", platform: "macOS ARM")
        check("dmg window: pending", c.status == .pending && c.shot == "/w/s.png")
        check("dmg window: lines", c.lines.map(\.tone) == ["info", "ok", "ko"] && c.failures == ["no ReadMe"])
        check("dmg window: matches", c.matches(sel, stamp: "10 20"))
        check("dmg window: image changed", !c.matches(sel, stamp: "11 20"))
        var s = sel; s.version = "21.1"
        check("dmg window: other version", !c.matches(s, stamp: "10 20"))
        s = sel; s.build = "100630"
        check("dmg window: other build", !c.matches(s, stamp: "10 20"))
        s = sel; s.product = "4D Server"
        check("dmg window: other product", !c.matches(s, stamp: "10 20"))
        check("dmg window: unknown status is an error, never ok", DMGWindowCheck.parse("STATUS\tgreen\n").status == .error)
        check("dmg window: empty file is an error", DMGWindowCheck.parse("").status == .error)
    }

    static func installRecord() {
        let txt = "STATUS\tok\nDATE\t2026-10-22 10:00:00\nPRODUCT\t4D\nVERSION\t21.2\nBUILD\t100629\nPLATFORM\tmacOS ARM\n"
            + "DMG\t/d/a.dmg\nAPP\t/tmp/i/4D 21.2/4D.app\n"
        let r = InstallRecord.parse(txt)
        let sel = Selection(dmg: "/d/a.dmg", product: "4D", version: "21.0.2", build: "100629", platform: "macOS ARM")
        check("record app", r.app == "/tmp/i/4D 21.2/4D.app")
        check("matches (normalized version)", r.matches(sel))
        var s = sel; s.build = "100624"
        check("other build not matched", !r.matches(s))
        s = sel; s.product = "4D Server"
        check("other product not matched", !r.matches(s))
        let ko = InstallRecord.parse(txt.replacingOccurrences(of: "STATUS\tok", with: "STATUS\tko\nERROR_CODE\tSPACE"))
        check("failed install never matches", !ko.matches(sel) && ko.errorCode == "SPACE")
        check("normalize build suffix", Version.normalize(" 21.2 build 100629 ") == "21.2")
        check("normalize 21.0.2 HF1", Version.normalize("21.0.2 HF1") == "21.2 HF1")
        check("normalize keeps 21 R2", Version.normalize("21 R2") == "21 R2")
        check("normalize keeps 20.0.10.1", Version.normalize("20.0.10.1") == "20.0.10.1")
    }

    static func contrast() {
        for dark in [false, true] {
            let card = dark ? Palette.darkCard : Palette.lightCard
            for t in Tone.allCases {
                let fg = Palette.foreground(t, dark: dark), bg = Palette.background(t, dark: dark)
                check("pill text \(t) dark=\(dark) >= 4.5", RGB.contrast(fg, bg) >= 4.5)
                check("icon \(t) on card dark=\(dark) >= 3", RGB.contrast(fg, card) >= 3)
            }
        }
        // the success colour stays distinguishable from failure (not only by hue: icons and labels differ too)
        check("success != failure", Palette.foreground(.success, dark: false) != Palette.foreground(.failure, dark: false))
        check("white on gradient", Palette.gradient.allSatisfy { RGB.contrast(RGB($0), RGB(0xFFFFFF)) >= 3 })
        check("white text on the veiled header >= 4.5", Palette.gradient.allSatisfy { RGB.contrast(Palette.headerColor($0), RGB(0xFFFFFF)) >= 4.5 })
    }

    static func processes() {
        let ok = Proc.run("/bin/echo", ["hello"], timeout: 5)
        check("process output", ok.output == "hello\n" && ok.status == 0 && !ok.timedOut)
        let t0 = Date()
        let slow = Proc.run("/bin/sleep", ["10"], timeout: 0.5)
        check("timeout", slow.timedOut && Date().timeIntervalSince(t0) < 5)
        let missing = Proc.run("/nonexistent/helper", [], timeout: 1)
        check("launch error", missing.launchError != nil)
        let snap = PermissionSnapshot.parse(missing.output, exitCode: missing.status, launchError: missing.launchError)
        if case .error = snap.accessibility { check("missing helper = error", true) } else { check("missing helper = error", false) }
        let code = Proc.run("/bin/sh", ["-c", "echo AX; exit 3"], timeout: 5)
        check("exit status", code.status == 3)
    }
}
