import SwiftUI
import AppKit

// Interface: wide window = preparation column + checklist / results / log; narrow window = three tabs.
// Every state comes from the Runner (single source of truth); a status is always shown with its icon and its label.

enum Pane: String, CaseIterable, Identifiable {
    case prepare = "Préparation", results = "Résultats", log = "Journal"
    var id: String { rawValue }
}

// state local to the window (presentation only: never a test result)
final class ViewState: ObservableObject {
    @Published var pane: Pane = .prepare
    @Published var appeared = false
    @Published var expanded: Set<String> = []
    @Published var showDirect = false
}

struct ContentView: View {
    @ObservedObject var r: Runner
    var animateIn = true
    var forcedPane: Pane? = nil
    @StateObject private var ui = ViewState()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var spring: Animation? { reduceMotion ? nil : .spring(response: 0.45, dampingFraction: 0.86) }

    var body: some View {
        GeometryReader { g in
            let wide = g.size.width >= 1080
            VStack(spacing: 12) {
                header(compact: !wide)
                if wide {
                    HStack(alignment: .top, spacing: 14) {
                        ScrollView { preparation.padding(.bottom, 6) }
                            .frame(width: min(max(g.size.width * 0.42, 460), 580))
                        VStack(spacing: 12) {
                            runCard.entrance(0, ui.appeared)
                            resultsCard.frame(maxHeight: .infinity).entrance(1, ui.appeared)
                            logCard.frame(height: max(150, g.size.height * 0.22)).entrance(2, ui.appeared)
                        }
                    }
                } else {
                    Picker("Vue", selection: Binding(get: { forcedPane ?? ui.pane }, set: { ui.pane = $0 })) {
                        ForEach(Pane.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented).labelsHidden().frame(maxWidth: 420)
                    switch forcedPane ?? ui.pane {
                    case .prepare: ScrollView { VStack(spacing: 12) { runCard; preparation } }
                    case .results: VStack(spacing: 12) { runCard; resultsCard.frame(maxHeight: .infinity) }
                    case .log: logCard.frame(maxHeight: .infinity)
                    }
                }
                HStack {
                    Spacer()
                    Text("© Souhail QA").font(.caption2).foregroundStyle(Color.subtle)
                }
            }
            .padding(16)
        }
        .background(LinearGradient(colors: [.canvasTop, .canvasBottom], startPoint: .top, endPoint: .bottom).ignoresSafeArea())
        .frame(minWidth: 760, minHeight: 640)
        .task {
            r.setup()
            if animateIn && !reduceMotion { withAnimation(.easeOut(duration: 0.5)) { ui.appeared = true } } else { ui.appeared = true }
        }
        .onAppear { if !animateIn { ui.appeared = true } }
        // back from System Settings (or any other app): permissions checked again in a fresh helper process
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            r.refreshPermissions(.foreground)
            if !r.busy { r.refreshPrereqs() }
        }
        .alert("Une installation existe déjà", isPresented: $r.showExistingAlert, presenting: r.existing) { e in
            Button("Remplacer", role: .destructive) { r.resolveExisting("replace") }
            if e.same { Button("Utiliser l'existante") { r.resolveExisting("adopt") } }
            Button("Annuler", role: .cancel) { r.resolveExisting(nil) }
        } message: { e in
            Text("\(e.path)\nVersion installée : \(e.version) build \(e.build) — \(e.same ? "identique à" : "différente de") la sélection.\n\n« Remplacer » : l'installation actuelle n'est mise à la corbeille qu'une fois la nouvelle copie installée et vérifiée ; elle reste en place en cas d'échec.")
        }
    }

    // ---------- header ----------
    private func header(compact: Bool) -> some View {
        let subtitle = r.version.isEmpty
            ? (r.dmgPath.isEmpty ? "Sélectionnez ou téléchargez une image disque 4D" : "\(r.product) — version à lire dans l'image disque")
            : "\(r.product) \(r.version) build \(r.build) · \(r.platform)\(r.installedForSelection ? " · installé et vérifié" : "")"
        return HeaderBanner(title: "Test Installer 4D", subtitle: subtitle, busy: r.busy) {
            ViewThatFits(in: .horizontal) {
                headerChips(limit: 5)
                headerChips(limit: 2)
                EmptyView()
            }
        }
    }

    private var allCounts: [(ResultStatus, Int)] {
        let rows = r.rowsByLang.values.flatMap(\.rows)
        return [ResultStatus.ko, .action, .undetermined, .unknown, .notrun, .manual, .ok]
            .map { s in (s, rows.filter { $0.status == s }.count) }.filter { $0.1 > 0 }
    }

    private func headerChips(limit: Int) -> some View {
        HStack(spacing: 6) {
            if r.busy {
                HStack(spacing: 5) {
                    ProgressView().controlSize(.mini).tint(.white)
                    Text(r.running ? (r.progressText.isEmpty ? "En cours" : r.progressText)
                                   : (r.installOp.isRunning ? "Installation" : "Téléchargement"))
                        .font(.system(size: 11, weight: .semibold)).lineLimit(1).fixedSize()
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 8).padding(.vertical, 4)
                .background(Capsule().fill(.black.opacity(0.28)))
            }
            ForEach(Array(allCounts.prefix(limit)), id: \.0) { HeaderChip(count: $0.1, status: $0.0) }
        }
        .animation(spring, value: allCounts.map(\.1))
    }

    // ---------- preparation column ----------
    private var preparation: some View {
        VStack(spacing: 12) {
            dmgCard.entrance(0, ui.appeared)
            productCard.entrance(1, ui.appeared)
            installCard.entrance(2, ui.appeared)
            permissionsCard.entrance(3, ui.appeared)
            prereqCard.entrance(4, ui.appeared)
            testsCard.entrance(5, ui.appeared)
        }
    }

    private var dmgCard: some View {
        Card("Image disque 4D", symbol: "externaldrive.fill", accent: 0) {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(r.dmgPath.isEmpty ? "Aucune image sélectionnée" : (r.dmgPath as NSString).lastPathComponent)
                        .font(.system(size: 13, weight: .medium)).lineLimit(1).truncationMode(.middle)
                        .foregroundStyle(r.dmgPath.isEmpty ? Color.subtle : .primary)
                    if !r.dmgPath.isEmpty {
                        Text((r.dmgPath as NSString).deletingLastPathComponent).font(.caption2).foregroundStyle(Color.subtle)
                            .lineLimit(1).truncationMode(.middle)
                    }
                }
                .help(r.dmgPath)
                Spacer()
                Button("Choisir…") { r.chooseDMG() }.disabled(r.busy)
            }
            switch r.dmgState {
            case .none: EmptyView()
            case .reading:
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Lecture du contenu (montage en lecture seule, démonté ensuite)…").font(.caption).foregroundStyle(Color.subtle)
                }
            case .failed(let m): Notice(tone: .failure, symbol: "xmark.octagon.fill", title: "Image disque inutilisable", message: m)
            case .read:
                FlowRow(spacing: 6) {
                    ForEach(r.dmgApps, id: \.name) { a in
                        Pill(label: "\(a.name) \(a.version) · build \(a.build)", symbol: "app.badge.checkmark",
                             tone: a.name == r.product ? .progress : .neutral, compact: true)
                    }
                }
            }
            if !r.dmgPath.isEmpty && r.dmgSize > 0 {
                VStack(alignment: .leading, spacing: 1) {
                    Text("Taille : \(ByteCountFormatter.string(fromByteCount: r.dmgSize, countStyle: .file)) (\(r.dmgSize) octets)")
                    Text("SHA-256 : \(r.dmgSHA.isEmpty ? "calcul en cours…" : r.dmgSHA)").lineLimit(1).truncationMode(.middle)
                }
                .font(.system(size: 10.5, design: .monospaced)).foregroundStyle(Color.subtle).textSelection(.enabled)
            }
            Divider().padding(.vertical, 2)
            downloadSection
        }
    }

    private var downloadSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Button { r.openDownloadPage() } label: { Label("Télécharger dans le navigateur", systemImage: "safari") }
                    .disabled(r.busy)
                Spacer()
                Button { r.scanDownloads() } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.borderless).help("Rechercher à nouveau les images 4D dans Téléchargements")
            }
            watchView
            if let e = r.scanError, !r.watching {
                Notice(tone: .failure, symbol: "folder.badge.questionmark", title: "Recherche des images impossible", message: e)
            }
            Text("Connexion à votre compte 4D dans le navigateur : l'outil ne demande ni n'enregistre aucun mot de passe. Seules les images complètes (fin d'image disque vérifiée) et non vides sont proposées.")
                .font(.caption).foregroundStyle(Color.subtle).fixedSize(horizontal: false, vertical: true)
            if !r.candidates.isEmpty {
                VStack(spacing: 4) {
                    ForEach(r.candidates.prefix(5)) { c in candidateRow(c) }
                }
                .animation(spring, value: r.candidates.map(\.id))
            }
            DisclosureGroup(isExpanded: $ui.showDirect) {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        TextField("https://…4d.com/…/4D.dmg", text: $r.directURL).textFieldStyle(.roundedBorder)
                        Button("Télécharger") { r.downloadDirect() }.disabled(!r.directURLValid || r.busy)
                    }
                    if !r.directURL.isEmpty && !r.directURLValid {
                        Text("Adresse refusée : https et serveurs *.4d.com uniquement, sans identifiant dans l'adresse.")
                            .font(.caption).foregroundStyle(Tone.failure.fg)
                    }
                    opView(r.downloadOp, cancel: r.cancelDownload)
                }
                .padding(.top, 4)
            } label: {
                Text("Lien direct (serveurs *.4d.com)").font(.caption.weight(.semibold))
            }
        }
        .animation(spring, value: r.watch.phase)
    }

    // every phase of the watch is explained: no spinner is left without a message
    @ViewBuilder private var watchView: some View {
        switch r.watch.phase {
        case .idle:
            EmptyView()
        case .watching:
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Surveillance du dossier Téléchargements : l'image apparaîtra ici une fois complète.")
                        .font(.caption).foregroundStyle(Tone.progress.fg).lineLimit(2)
                    Spacer()
                    Button("Arrêter") { r.stopWatching() }.controlSize(.small)
                }
                ForEach(r.watch.inProgress) { c in
                    Label("Téléchargement en cours : \(c.name) — \(ByteCountFormatter.string(fromByteCount: c.size, countStyle: .file)) reçus",
                          systemImage: "arrow.down.circle")
                        .font(.caption).foregroundStyle(Tone.progress.fg).lineLimit(1).truncationMode(.middle)
                }
                ForEach(r.watch.notes, id: \.self) { n in
                    Label(n, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(Tone.warning.fg)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if r.watch.failures > 0 {
                    Label("Nouvel essai : \(r.watch.lastError)", systemImage: "arrow.clockwise")
                        .font(.caption).foregroundStyle(Tone.warning.fg).fixedSize(horizontal: false, vertical: true)
                }
            }
            .transition(.opacity)
        case .found(let c):
            VStack(alignment: .leading, spacing: 6) {
                Notice(tone: .success, symbol: "checkmark.circle.fill", title: "Téléchargement terminé : \(c.name)",
                       message: "\(ByteCountFormatter.string(fromByteCount: c.size, countStyle: .file)) · \(originText(c)) · image complète (fin d'image disque vérifiée). Surveillance arrêtée. Aucune image n'est choisie à votre place : la version et le build seront lus dans l'image.")
                HStack(spacing: 8) {
                    if c.path == r.dmgPath {
                        Pill(label: "Sélectionnée", symbol: "checkmark", tone: .progress, compact: true)
                    } else {
                        Button("Utiliser cette image") { r.useCandidate(c) }.disabled(r.busy)
                    }
                    Spacer()
                    Button("Fermer") { r.dismissWatch() }.controlSize(.small)
                }
            }
            .transition(.opacity)
        case .failed(let why):
            VStack(alignment: .leading, spacing: 6) {
                Notice(tone: .failure, symbol: "exclamationmark.octagon.fill", title: "Surveillance interrompue", message: why)
                HStack(spacing: 8) {
                    Button("Réessayer") { r.startWatching() }.disabled(r.busy)
                    Spacer()
                    Button("Fermer") { r.dismissWatch() }.controlSize(.small)
                }
            }
            .transition(.opacity)
        case .timedOut:
            VStack(alignment: .leading, spacing: 6) {
                Notice(tone: .warning, symbol: "clock.badge.exclamationmark", title: "Surveillance arrêtée après \(Int(r.watch.limit / 60)) min",
                       message: "Aucune image complète n'est apparue dans Téléchargements. Vérifiez le téléchargement dans le navigateur, puis relancez la surveillance ou utilisez « Choisir… ».")
                HStack(spacing: 8) {
                    Button("Relancer la surveillance") { r.startWatching() }.disabled(r.busy)
                    Spacer()
                    Button("Fermer") { r.dismissWatch() }.controlSize(.small)
                }
            }
            .transition(.opacity)
        }
    }

    private func candidateRow(_ c: DownloadCandidate) -> some View {
        let selected = c.path == r.dmgPath
        let state: (String, String, Tone) = {
            switch c.state {
            case .complete: return ("Complet", "checkmark.circle.fill", .success)
            case .partial: return ("Incomplet", "arrow.down.circle", .warning)
            case .empty: return ("Vide", "xmark.circle", .failure)
            case .invalid: return ("Invalide", "xmark.octagon", .failure)
            }
        }()
        return HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 5) {
                    Text(c.name).font(.system(size: 12, weight: .medium)).lineLimit(1).truncationMode(.middle)
                    if r.isNew(c) { Pill(label: "Nouveau", symbol: "sparkles", tone: .progress, compact: true) }
                }
                Text("\(ByteCountFormatter.string(fromByteCount: c.size, countStyle: .file)) · \(c.modified.formatted(Self.dateStyle)) · \(originText(c))")
                    .font(.caption2).foregroundStyle(Color.subtle).lineLimit(1)
            }
            .help(c.path)
            Spacer(minLength: 4)
            Pill(label: state.0, symbol: state.1, tone: state.2, compact: true)
            if selected {
                Pill(label: "Sélectionnée", symbol: "checkmark", tone: .progress, compact: true)
            } else {
                Button("Utiliser") { r.useCandidate(c) }.controlSize(.small).disabled(!c.usable || r.busy)
            }
        }
        .padding(.horizontal, 8).padding(.vertical, 5)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(selected ? Tone.progress.bg : Color.logBackground))
        .transition(.opacity.combined(with: .move(edge: .top)))
    }

    static let dateStyle = Date.FormatStyle(date: .abbreviated, time: .shortened).locale(Locale(identifier: "fr_FR"))

    private func originText(_ c: DownloadCandidate) -> String {
        switch c.origin {
        case .official: return "origine 4d.com"
        case .other: return "⚠ origine non 4d.com (\(c.hosts))"
        case .unknown: return "origine inconnue"
        }
    }

    @ViewBuilder private func opView(_ op: OpState, cancel: @escaping () -> Void) -> some View {
        switch op {
        case .idle: EmptyView()
        case .running(let p, let step):
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(step).font(.caption).foregroundStyle(Color.subtle).lineLimit(1)
                    Spacer()
                    if let p { Text("\(Int(p * 100)) %").font(.caption.monospacedDigit()).foregroundStyle(Tone.progress.fg) }
                    Button("Annuler", action: cancel).controlSize(.small)
                }
                GradientProgress(value: p)
            }
        case .succeeded(let m): Notice(tone: .success, symbol: "checkmark.circle.fill", title: "Terminé", message: m)
        case .failed(let t, let m): Notice(tone: .failure, symbol: "xmark.octagon.fill", title: t, message: m)
        case .cancelled(let m): Notice(tone: .neutral, symbol: "stop.circle.fill", title: "Annulé", message: m)
        }
    }

    private var productCard: some View {
        Card("Produit testé", symbol: "shippingbox.fill", accent: 1) {
            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 8) {
                GridRow {
                    Text("Produit").gridLabel()
                    Picker("Produit", selection: $r.product) { ForEach(r.products, id: \.self) { Text($0) } }.labelsHidden()
                }
                GridRow {
                    Text("Version").gridLabel()
                    TextField("Version", text: $r.version, prompt: Text("lue dans l'image disque")).textFieldStyle(.roundedBorder)
                }
                GridRow {
                    Text("Build").gridLabel()
                    TextField("Build", text: $r.build, prompt: Text("lu dans l'image disque")).textFieldStyle(.roundedBorder)
                }
                GridRow {
                    Text("Plateforme").gridLabel()
                    if let e = r.platformError {
                        Label(e, systemImage: "exclamationmark.triangle.fill").foregroundStyle(Tone.failure.fg).font(.system(size: 12, weight: .medium))
                    } else {
                        HStack(spacing: 6) {
                            Image(systemName: r.platform == "macOS ARM" ? "cpu.fill" : "cpu").foregroundStyle(Tone.info.fg)
                            Text(r.platform).font(.system(size: 12, weight: .semibold))
                            Text(r.platformNote.isEmpty ? "détectée sur ce Mac" : r.platformNote).font(.caption).foregroundStyle(Color.subtle)
                        }
                        .help("Plateforme du Mac utilisé pour le test, lue sur le matériel (non modifiable)")
                        .accessibilityElement(children: .combine)
                    }
                }
            }
            .disabled(r.busy)
            if r.dmgState == .read && r.productInDMG == nil {
                Notice(tone: .failure, symbol: "xmark.octagon.fill", title: "\(r.product) est absent de cette image disque",
                       message: "Elle contient : \(r.dmgApps.map(\.name).joined(separator: ", ")). Aucune autre application n'est prise à sa place : choisissez le bon produit ou la bonne image.")
            } else if let m = r.dmgMismatch {
                Notice(tone: .warning, symbol: "exclamationmark.triangle.fill", title: "Version différente de l'image disque", message: m)
            }
        }
    }

    private var installCard: some View {
        Card("Installation", symbol: "square.and.arrow.down.on.square.fill", accent: 2) {
            HStack(spacing: 8) {
                Image(systemName: "folder.fill").foregroundStyle(Tone.info.fg)
                Text(r.installDest).font(.system(size: 12, weight: .medium)).lineLimit(1).truncationMode(.middle).help(r.installDest)
                Spacer()
                Button("Changer…") { r.chooseInstallDest() }.controlSize(.small).disabled(r.busy)
            }
            installRecordNotice
            dmgWindowPanel
            opView(r.installOp, cancel: r.cancelInstall)
            HStack {
                Button { r.install() } label: { Label("Installer et vérifier", systemImage: "arrow.down.app.fill") }
                    .buttonStyle(GradientButtonStyle()).disabled(!r.canInstall)
                Spacer()
            }
            Text("Avant toute installation, la fenêtre de l'image disque est ouverte dans le Finder, contrôlée (titre, dossier produit, raccourci Applications, ReadMe, disposition), capturée et comparée automatiquement à la fenêtre de référence (4D 21.2) : taille, vue, icônes, positions et image de fond. L'installation démarre seule si tout est identique ; toute différence la bloque, avec le détail. Copie depuis l'image disque (permissions, signature et attributs conservés), puis vérification de la version, du build et de la signature. Une installation existante n'est jamais remplacée sans votre accord ; si le dossier est protégé, macOS demande lui-même un administrateur.")
                .font(.caption).foregroundStyle(Color.subtle).fixedSize(horizontal: false, vertical: true)
        }
    }

    // window of the disk image: automatic checks + screenshot + comparison with the reference window
    @ViewBuilder private var dmgWindowPanel: some View {
        opView(r.windowOp, cancel: r.cancelInstall)
        if let c = r.dmgWindow {
            VStack(alignment: .leading, spacing: 6) {
                switch c.status {
                case .pending: Notice(tone: .warning, symbol: "eye.fill", title: "Fenêtre de l'image disque : À vérifier",
                                      message: "Ancien kit sans fenêtre de référence : comparez la capture puis confirmez.")
                case .ok: Notice(tone: .success, symbol: "checkmark.circle.fill", title: "Fenêtre de l'image disque conforme", message: c.verdict)
                case .ko: Notice(tone: .failure, symbol: "xmark.octagon.fill", title: "Fenêtre de l'image disque non conforme", message: c.verdict.isEmpty ? c.failures.joined(separator: " · ") : c.verdict)
                case .action: Notice(tone: .warning, symbol: "hand.raised.fill", title: "Fenêtre de l'image disque : Action requise", message: c.failures.joined(separator: " · "))
                case .error: Notice(tone: .failure, symbol: "exclamationmark.triangle.fill", title: "Fenêtre de l'image disque : erreur", message: c.lines.last?.text ?? "")
                }
                if !c.shot.isEmpty, let img = NSImage(contentsOfFile: c.shot) {
                    Image(nsImage: img).resizable().scaledToFit().frame(maxWidth: 420, maxHeight: 320)
                        .clipShape(RoundedRectangle(cornerRadius: 8)).overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.secondary.opacity(0.4)))
                        .accessibilityLabel("Capture de la fenêtre \(c.volume)")
                }
                ForEach(Array(c.lines.enumerated()), id: \.offset) { _, l in
                    Label(l.text, systemImage: l.tone == "ok" ? "checkmark.circle.fill" : l.tone == "ko" ? "xmark.circle.fill" : "info.circle")
                        .font(.caption).foregroundStyle(l.tone == "ok" ? Tone.success.fg : l.tone == "ko" ? Tone.failure.fg : Color.subtle)
                }
                if c.status == .pending {
                    HStack {
                        Button { r.confirmDMGWindow(true) } label: { Label("Conforme — installer", systemImage: "checkmark") }
                            .buttonStyle(GradientButtonStyle()).disabled(r.busy)
                        Button("Non conforme") { r.confirmDMGWindow(false) }.disabled(r.busy)
                    }
                }
            }
        }
    }

    @ViewBuilder private var installRecordNotice: some View {
        if r.installedForSelection, let rec = r.installRecord {
            Notice(tone: .success, symbol: "checkmark.seal.fill", title: "Installation vérifiée",
                   message: "\(rec.app)\n\(r.product) \(rec.values["VERSION"] ?? "") build \(rec.values["BUILD"] ?? "") — \(rec.date)")
        } else if let rec = r.installRecord, rec.status == "ko", rec.values["PRODUCT"] == r.product {
            Notice(tone: .failure, symbol: "xmark.octagon.fill", title: "Dernière installation en échec : \(EngineEvent.title(ofError: rec.errorCode))",
                   message: "\(rec.error)\n\(rec.date)")
        } else {
            Notice(tone: .neutral, symbol: "info.circle.fill", title: "Aucune installation vérifiée de cette sélection",
                   message: "Les tests de lancement (avec et sans Internet) seront « Non exécuté » tant qu'elle n'est pas installée ici.")
        }
    }

    private var permissionsCard: some View {
        Card("Autorisations macOS", symbol: "lock.shield.fill", accent: 3, trailing: {
            Button { r.refreshPermissions(.recheck) } label: { Label("Revérifier", systemImage: "arrow.clockwise") }
                .controlSize(.small)
        }) {
            ForEach(PermissionKind.allCases, id: \.self) { k in
                permissionRow(k)
                if k != PermissionKind.allCases.last { Divider() }
            }
            if r.ax.restartAdvised || r.screen.restartAdvised {
                VStack(alignment: .leading, spacing: 6) {
                    Notice(tone: .action, symbol: "arrow.triangle.2.circlepath", title: "Relance de l'app peut-être nécessaire",
                           message: "Toujours non accordé après votre passage dans Réglages Système. Si « Test Installer 4D » y est déjà coché, macOS n'applique l'accès (Enregistrement de l'écran surtout) qu'après une relance de l'app.")
                    Button("Relancer l'app") { r.relaunch() }.controlSize(.small).disabled(r.busy)
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("Coche verte uniquement quand macOS confirme l'accès à l'outil qui agit sur 4D (vérification dans un nouveau processus). Ouvrir les Réglages ou afficher une demande n'est jamais compté comme un accord.")
                if !r.permissionProcess.isEmpty {
                    Text("Vérifié par : \(r.permissionProcess)\(r.permissionCheckedAt.map { " — \($0.formatted(date: .omitted, time: .standard))" } ?? "")")
                        .lineLimit(2).truncationMode(.middle).textSelection(.enabled)
                }
            }
            .font(.caption).foregroundStyle(Color.subtle).fixedSize(horizontal: false, vertical: true)
            ForEach(Array(r.identityNotes.enumerated()), id: \.offset) { _, n in
                Label { Text(n.1).fixedSize(horizontal: false, vertical: true) } icon: {
                    Image(systemName: n.0 == .success ? "checkmark.shield.fill" : "exclamationmark.shield.fill")
                }
                .font(.caption).foregroundStyle(n.0.fg)
            }
        }
        .animation(spring, value: r.ax)
        .animation(spring, value: r.screen)
    }

    private func permissionRow(_ k: PermissionKind) -> some View {
        let t = r.tracker(k)
        return VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .center, spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(k.title).font(.system(size: 13, weight: .semibold))
                    Text(k.purpose).font(.caption).foregroundStyle(Color.subtle).fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 6)
                PermissionPill(state: t.state)
            }
            HStack(spacing: 8) {
                Button("Demander l'accès") { r.requestPermission(k) }
                    .disabled(t.state == .granted || t.state == .checking)
                    .help("Affiche la demande de macOS. L'accès n'est compté qu'une fois confirmé par macOS.")
                Button { r.openSettings(k) } label: { Label("Ouvrir les Réglages", systemImage: "gearshape") }
                Spacer()
            }
            .controlSize(.small)
        }
    }

    private var prereqCard: some View {
        Card("Prérequis", symbol: "checklist", accent: 0, trailing: {
            Button { r.refreshPrereqs() } label: { Label("Actualiser", systemImage: "arrow.clockwise") }.controlSize(.small)
        }) {
            ForEach(r.prereqs) { p in
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(p.title).font(.system(size: 12.5, weight: .semibold))
                        Text(p.detail).font(.caption).foregroundStyle(Color.subtle).fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 6)
                    if let a = p.action { Button(a) { r.prereqAction(p.id) }.controlSize(.small).disabled(r.busy) }
                    Pill(label: p.state.label, symbol: p.state.symbol, tone: p.state.tone, spinning: p.state == .checking, compact: true)
                }
            }
            .animation(spring, value: r.prereqs)
        }
    }

    private func language(_ l: String) -> Binding<Bool> {
        Binding(get: { r.selectedLanguages.contains(l) },
                set: { if $0 { r.selectedLanguages.insert(l) } else { r.selectedLanguages.remove(l) } })
    }

    private var testsCard: some View {
        Card("Langues et tests", symbol: "globe", accent: 1) {
            HStack(spacing: 6) {
                ForEach(r.languages, id: \.self) { Toggle($0, isOn: language($0)).toggleStyle(ChipToggleStyle()) }
            }
            Text("4D est lancé dans chaque langue cochée (langue par application) : la langue de macOS ne change pas.")
                .font(.caption).foregroundStyle(Color.subtle).fixedSize(horizontal: false, vertical: true)
            Divider()
            Toggle("Test témoin (dossier Components renommé)", isOn: $r.testControl)
            Toggle("Composants depuis GitHub (4D 21 et +)", isOn: Binding(get: { r.testGitHub && r.githubSupported }, set: { r.testGitHub = $0 }))
                .disabled(!r.githubSupported)
            if !r.githubSupported {
                Text("Non disponible en 4D \(r.majorVersion ?? 0) : le test sera N/A.").font(.caption).foregroundStyle(Color.subtle)
            }
            Divider()
            Text("Lancement de 4D").font(.system(size: 12.5, weight: .semibold))
            Text("Trois lignes distinctes : lancement avec Internet, ticket de notarisation agrafé (stapler, contrôle statique) et lancement réel sans Internet. Le hors-ligne n'est réussi que si 4D installé démarre et que son projet de test écrit sa preuve, Internet étant vérifié absent avant et après par plusieurs sondes (HTTPS, TCP par adresse IP, DNS, route).")
                .font(.caption).foregroundStyle(Color.subtle).fixedSize(horizontal: false, vertical: true)
            Toggle("Test sans Internet automatique (pare-feu pf)", isOn: $r.netAuto)
            Text(r.netAuto
                 ? "Activé : au lancement de la checklist, une confirmation puis le mot de passe administrateur (fenêtre de macOS, jamais vu ni enregistré par l'outil). Pendant chaque test sans Internet seulement (5 min au plus), tout le trafic est bloqué par le pare-feu pf, puis rétabli automatiquement, même si l'app se ferme. Wi-Fi, câble et réglages réseau ne sont pas modifiés. Les sessions à distance (TeamViewer, partage d'écran) sont coupées pendant ce temps. Sans accord : coupure manuelle demandée."
                 : "Désactivé (par défaut) : le test vous demande de couper vous-même Wi-Fi, câble et VPN, puis de les rétablir. Rien n'est modifié sur le Mac par l'outil.")
                .font(.caption).foregroundStyle(Color.subtle).fixedSize(horizontal: false, vertical: true)
            Divider()
            if let v = r.icFixedVersion {
                Label("Plugin 4D Internet Commands de référence (\(v)) : toujours testé", systemImage: "checkmark.seal").font(.caption)
            }
            Toggle("Zips I.C. supplémentaires", isOn: $r.testIC).disabled(r.icFiles.isEmpty)
            ForEach(r.icFiles, id: \.self) { Text($0).font(.caption).foregroundStyle(Color.subtle) }
            HStack {
                Button("Ajouter des zips I.C.…") { r.addICZips() }.controlSize(.small)
                if !r.icFiles.isEmpty { Button("Vider") { r.clearIC() }.controlSize(.small) }
            }
        }
        .disabled(r.busy)
    }

    // ---------- checklist ----------
    private var runCard: some View {
        Card("Checklist", symbol: "play.circle.fill", accent: 2, trailing: {
            HStack(spacing: 6) {
                Button { NSWorkspace.shared.open(URL(fileURLWithPath: r.reportPath)) } label: { Label("Rapport", systemImage: "doc.text") }
                    .disabled(r.reportPath.isEmpty)
                Button { NSWorkspace.shared.open(r.kit) } label: { Label("Dossier", systemImage: "folder") }
            }
            .controlSize(.small)
        }) {
            HStack(spacing: 12) {
                if r.running {
                    Button(role: .destructive) { r.stop() } label: { Label("Arrêter", systemImage: "stop.fill") }
                    VStack(alignment: .leading, spacing: 4) {
                        Text(r.progressText.isEmpty ? "En cours…" : r.progressText).font(.caption.weight(.semibold)).foregroundStyle(Tone.progress.fg)
                        GradientProgress(value: nil)
                    }
                } else {
                    Button { r.run() } label: { Label("Lancer la checklist", systemImage: "play.fill") }
                        .buttonStyle(GradientButtonStyle()).keyboardShortcut(.defaultAction).disabled(!r.canRun)
                    Spacer()
                }
            }
            if !r.running {
                ForEach(r.runBlockers, id: \.self) { b in
                    Label(b, systemImage: "exclamationmark.circle").font(.caption).foregroundStyle(Tone.warning.fg)
                }
                if r.runBlockers.isEmpty && !r.installedForSelection {
                    Label("Pas d'installation vérifiée : les tests de lancement seront « Non exécuté ». Utilisez « Installer et vérifier ».",
                          systemImage: "info.circle").font(.caption).foregroundStyle(Tone.info.fg).fixedSize(horizontal: false, vertical: true)
                }
            }
            if r.restoreNeeded {
                Button("Restaurer la langue macOS d'origine (ancienne version du kit)") { r.restoreLocale() }.disabled(r.busy)
            }
            Text(r.status).font(.caption).foregroundStyle(Color.subtle).textSelection(.enabled).lineLimit(3)
        }
    }

    private var shownLanguages: [String] { r.languages.filter { r.rowsByLang[$0] != nil } }

    private var resultsCard: some View {
        let file = r.rowsByLang[r.viewLanguage] ?? r.rowsByLang[shownLanguages.first ?? ""]
        let rows = file?.rows ?? []
        return Card("Résultats", symbol: "list.bullet.rectangle.portrait.fill", accent: 3, trailing: {
            if shownLanguages.count > 1 {
                Picker("Langue", selection: $r.viewLanguage) { ForEach(shownLanguages, id: \.self) { Text($0) } }
                    .pickerStyle(.segmented).labelsHidden().frame(maxWidth: 260)
            }
        }) {
            if !r.staleNote.isEmpty {
                Notice(tone: .info, symbol: "arrow.uturn.backward.circle.fill", title: "Résultats effacés", message: r.staleNote)
                    .transition(.opacity)
            }
            if let f = file {
                resultsContext(f)
                FlowRow(spacing: 6) {
                    ForEach(ResultStatus.allCases.sorted { $0.rank > $1.rank }, id: \.self) { s in
                        let n = f.count(s)
                        if n > 0 { Pill(label: "\(n) \(s.label)", symbol: s.symbol, tone: s.tone, compact: true) }
                    }
                }
            }
            if rows.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: r.running ? "hourglass" : "tray").font(.system(size: 26)).foregroundStyle(Brand.gradient)
                    Text(r.running ? "En cours… les lignes apparaissent au fur et à mesure." : "Les résultats de la checklist s'afficheront ici.")
                        .font(.callout).foregroundStyle(Color.subtle)
                }
                .frame(maxWidth: .infinity, minHeight: 120)
            } else {
                ScrollView {
                    LazyVStack(spacing: 6) {
                        ForEach(rows) { row in
                            ResultRowView(row: row, expanded: ui.expanded.contains(row.id)) {
                                if ui.expanded.contains(row.id) { ui.expanded.remove(row.id) } else { ui.expanded.insert(row.id) }
                            }
                            .transition(.asymmetric(insertion: .opacity.combined(with: .move(edge: .bottom)), removal: .opacity))
                        }
                    }
                    .padding(.bottom, 4)
                    .animation(spring, value: rows.map(\.id))
                    .animation(spring, value: ui.expanded)
                }
            }
        }
    }

    private func resultsContext(_ f: ResultFile) -> some View {
        let h = f.headers
        let product = [h["PRODUCT"], h["VERSION"], h["BUILD"].map { "build \($0)" }].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " ")
        return VStack(alignment: .leading, spacing: 2) {
            Text("\(product.isEmpty ? "Produit inconnu" : product) — \(h["PLATFORM"] ?? "") — \(h["LANG"] ?? r.viewLanguage) — \(h["DATE"] ?? "")")
                .font(.caption.weight(.semibold))
            if let inst = h["INSTALLED"], !inst.isEmpty {
                Text("Application testée : \(inst)").font(.caption2).foregroundStyle(Color.subtle).lineLimit(1).truncationMode(.middle)
            }
            if let run = h["RUN"] { Text("Exécution \(run)").font(.caption2).foregroundStyle(Color.subtle) }
        }
        .textSelection(.enabled)
    }

    private var logCard: some View {
        Card("Journal", symbol: "text.alignleft", accent: 0, trailing: {
            Button { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(r.log, forType: .string) } label: {
                Label("Copier", systemImage: "doc.on.doc")
            }
            .controlSize(.small).disabled(r.log.isEmpty)
        }) {
            ScrollViewReader { proxy in
                ScrollView {
                    Text(r.log.isEmpty ? " " : r.log)
                        .font(.system(size: 10.5, design: .monospaced))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                        .padding(8)
                    Color.clear.frame(height: 1).id("end")
                }
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.logBackground))
                .onChange(of: r.log.count) { _ in proxy.scrollTo("end", anchor: .bottom) }
            }
            .frame(maxHeight: .infinity)
        }
    }
}

struct ResultRowView: View {
    let row: CheckRow
    let expanded: Bool
    let toggle: () -> Void

    private var long: Bool { !row.showsFullDetail && (row.detail.count > 220 || row.detail.filter { $0 == "\n" }.count > 2 || !row.path.isEmpty) }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .center, spacing: 10) {
                StatusPill(status: row.status).frame(minWidth: 128, alignment: .leading)
                Text(row.action).font(.system(size: 12.5, weight: .semibold)).lineLimit(2)
                Spacer(minLength: 6)
                if !row.date.isEmpty { Text(row.date).font(.caption2.monospacedDigit()).foregroundStyle(Color.subtle) }
                if long {
                    Button(action: toggle) { Image(systemName: expanded ? "chevron.up.circle.fill" : "chevron.down.circle") }
                        .buttonStyle(.borderless).help(expanded ? "Réduire" : "Afficher le détail complet")
                }
            }
            if !row.detail.isEmpty {
                Text(row.detail).font(.caption).foregroundStyle(.primary.opacity(0.88))
                    .lineLimit(expanded || row.showsFullDetail ? nil : 3).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
            }
            if (expanded || row.showsFullDetail) && !row.path.isEmpty {
                Label(row.path, systemImage: "folder").font(.caption2).foregroundStyle(Color.subtle).textSelection(.enabled)
            }
        }
        .padding(.vertical, 8).padding(.leading, 13).padding(.trailing, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.logBackground))
        .overlay(alignment: .leading) {
            RoundedRectangle(cornerRadius: 2).fill(row.status.tone.fg).frame(width: 4).padding(.vertical, 7).padding(.leading, 3)
        }
    }
}

// language chips: selected = gradient, check mark AND label (never colour alone)
struct ChipToggleStyle: ToggleStyle {
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        Button { configuration.isOn.toggle() } label: {
            HStack(spacing: 4) {
                Image(systemName: configuration.isOn ? "checkmark.circle.fill" : "circle").font(.system(size: 10.5, weight: .bold))
                configuration.label.font(.system(size: 12, weight: .semibold))
            }
            .foregroundStyle(configuration.isOn ? Color.white : Color.primary)
            .padding(.horizontal, 10).padding(.vertical, 5)
            .background {
                if configuration.isOn { Brand.veiled.clipShape(Capsule()) } else { Capsule().fill(Color.logBackground) }
            }
            .overlay(Capsule().strokeBorder(configuration.isOn ? Color.clear : Color.cardStroke, lineWidth: 1))
            .opacity(enabled ? 1 : 0.55)
            .animation(.easeOut(duration: 0.18), value: configuration.isOn)
        }
        .buttonStyle(.plain)
        .accessibilityValue(configuration.isOn ? "coché" : "non coché")
    }
}

// simple wrapping row (pills)
struct FlowRow: Layout {
    var spacing: CGFloat = 6
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, line: CGFloat = 0, maxX: CGFloat = 0
        for s in subviews {
            let d = s.sizeThatFits(.unspecified)
            if x > 0 && x + d.width > width { x = 0; y += line + spacing; line = 0 }
            x += d.width + spacing; line = max(line, d.height); maxX = max(maxX, x - spacing)
        }
        return CGSize(width: proposal.width ?? maxX, height: y + line)
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, line: CGFloat = 0
        for s in subviews {
            let d = s.sizeThatFits(.unspecified)
            if x > bounds.minX && x + d.width > bounds.maxX { x = bounds.minX; y += line + spacing; line = 0 }
            s.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(d))
            x += d.width + spacing; line = max(line, d.height)
        }
    }
}

extension Text {
    func gridLabel() -> some View { self.font(.system(size: 12, weight: .medium)).foregroundStyle(Color.subtle).gridColumnAlignment(.trailing) }
}

extension View {
    // cards slide in one after the other at launch (nothing when Reduce Motion is on)
    func entrance(_ index: Int, _ shown: Bool) -> some View {
        self.opacity(shown ? 1 : 0).offset(y: shown ? 0 : 14)
            .animation(.spring(response: 0.5, dampingFraction: 0.85).delay(Double(index) * 0.05), value: shown)
    }
}

// ---------- demo state: offscreen rendering of the interface (--snapshot), never used by a normal launch ----------
extension Runner {
    static func demo(busy: Bool, watchEnd: String? = nil) -> Runner {
        let r = Runner(demo: true)
        let dmg = r.downloadsDir.appendingPathComponent("4D 21.2 LTS Mac.dmg").path
        r.dmgPath = dmg
        r.dmgApps = [DMGApp(name: "4D", version: "21.2", build: "100629", bundleID: "com.4d.4d", relativePath: "4D 21.2/4D.app"),
                     DMGApp(name: "4D Server", version: "21.2", build: "100629", bundleID: "com.4d.4dserver", relativePath: "4D 21.2/4D Server.app"),
                     DMGApp(name: "4D Volume Desktop", version: "21.2", build: "100629", bundleID: "com.4d.4dvolumedesktop", relativePath: "4D 21.2/4D Volume Desktop.app")]
        r.dmgState = .read
        r.version = "21.2"; r.build = "100629"; r.platform = "macOS ARM"
        r.dmgSize = 1_288_490_188
        r.dmgSHA = "9F2C4E1A7B3D5C6E8F0A1B2C3D4E5F60718293A4B5C6D7E8F9012345678ABCDE"
        let now = Date().timeIntervalSince1970
        r.candidates = DownloadCandidate.parse("""
            CANDIDATE\t\(dmg)\t1288490188\tcomplete\tofficial\tproduct-download.4d.com\t\(Int(now - 600))
            CANDIDATE\t\(r.downloadsDir.path)/4D 21.3 LTS Mac.dmg.download\t402653184\tpartial\tofficial\tproduct-download.4d.com\t\(Int(now - 60))
            """)
        if busy { // watch in progress: the browser download is listed while it is being received
            r.watch.start(at: Date(timeIntervalSinceNow: -120))
            _ = r.watch.apply(.ok(r.candidates), now: Date())
        }
        if let end = watchEnd { // end states of the watch, driven through the real state machine
            r.watch.start(at: Date(timeIntervalSinceNow: -120), limit: end == "timeout" ? 60 : 7200)
            _ = r.watch.apply(.ok(r.candidates), now: Date())
            switch end {
            case "found":
                r.candidates = DownloadCandidate.parse("""
                    CANDIDATE\t\(dmg)\t1288490188\tcomplete\tofficial\tproduct-download.4d.com\t\(Int(now - 600))
                    CANDIDATE\t\(r.downloadsDir.path)/4D 21.3 LTS Mac.dmg\t1290012345\tcomplete\tofficial\tproduct-download.4d.com\t\(Int(now - 4))
                    """)
                _ = r.watch.apply(.ok(r.candidates), now: Date())
            case "failed":
                let out = ProcessOutput(output: "ERROR\tACCESS\tfolder not readable: \(r.downloadsDir.path)\n", status: 1, timedOut: false, launchError: nil)
                for _ in 0..<DownloadWatch.failuresBeforeError {
                    _ = r.watch.apply(DownloadCandidate.scanResult(out, folder: r.downloadsDir.path), now: Date())
                }
            default:
                _ = r.watch.apply(.ok(r.candidates), now: Date())
            }
        }
        r.installRecord = InstallRecord.parse("STATUS\tok\nDATE\t2026-10-22 16:40:12\nPRODUCT\t4D\nVERSION\t21.2\nBUILD\t100629\nPLATFORM\tmacOS ARM\nDMG\t\(dmg)\nAPP\t/Applications/4D 21.2/4D.app\n")
        r.ax.apply(.granted)
        r.screen.userRequested(); r.screen.apply(.denied, afterUserReturn: false); r.screen.apply(.denied)
        r.permissionProcess = "/Applications/Test Installer 4D.app/Contents/Helpers/about_check (PID 4242)"
        r.permissionCheckedAt = Date()
        r.signing = SigningInfo(kind: .adhoc, identifier: "com.4d.qa.testinstaller4d", requirement: "cdhash H\"…\"")
        r.prereqs = [Prereq(id: "rosetta", title: "Rosetta", state: .ok, detail: "installé (test Rosetta automatique, open --arch x86_64)"),
                     Prereq(id: "clt", title: "Command Line Tools", state: .info, detail: "absents : facultatifs, file / codesign sont utilisés à la place", action: "Installer…"),
                     Prereq(id: "net", title: "Réseau (test hors ligne)", state: .ok, detail: "vous coupez le réseau quand le test le demande ; l'absence d'Internet est vérifiée par plusieurs sondes"),
                     Prereq(id: "github", title: "API GitHub", state: busy ? .checking : .warn, detail: busy ? "vérification…" : "quota de l'API épuisé jusqu'à 17:05 : le test attendra (15 min max)")]
        let rows = """
            #RUN\t20261022-164512-4242
            #DATE\t2026-10-22 16:45:12
            #PRODUCT\t4D
            #VERSION\t21.2
            #BUILD\t100629
            #PLATFORM\tmacOS ARM
            #LANG\tEN
            #INSTALLED\t/Applications/4D 21.2/4D.app
            Installation of 4D\tok\tInstalled and verified: 4D 21.2 build 100629\\nSHA-256 9F2C…ABCDE\t16:45:20\t/Applications/4D 21.2/4D.app
            Version number\tok\tAbout box: 4D v21.2 build 21.100629\t16:46:02\t/Applications/4D 21.2/4D.app
            Execution of application (with Internet)\tok\tStarted: proof file written by QA_Exec after 6 s (PID 5120)\t16:46:40\t/Applications/4D 21.2/4D.app
            Notarization ticket (stapling)\tok\txcrun stapler validate: ticket stapled to the application and to the disk image\t16:46:44\t/Applications/4D 21.2/4D.app
            Execution of application (without Internet)\taction\tWITHOUT Internet: not executed - Internet is still reachable after the cut: HTTPS apple.com 200; TCP 17.253.144.10:443 open; DNS ok; default route en0\t16:47:30\t/Applications/4D 21.2/4D.app
            Execution in 'Rosetta' mode\tundetermined\tNo proof of start within 90 s: a dialog may block 4D (screenshot attached)\t16:49:02\t/Applications/4D 21.2/4D.app
            Load of components\tko\tComponent 4D NetKit not loaded: error -9767\t16:49:40\t/Applications/4D 21.2/4D.app
            ReadMe\tmanual\tReadMe opened: check the wording\t16:50:01\t
            Download last 4D I.C.\tnotrun\tNo additional zip selected\t16:50:02\t
            Check if FAT application\tna\tNot applicable to 4D Volume Desktop only\t16:50:03\t
            """
        r.rowsByLang = ["EN": ResultFile.parse(rows), "FR": ResultFile.parse(rows.replacingOccurrences(of: "#LANG\tEN", with: "#LANG\tFR"))]
        r.viewLanguage = "EN"
        r.selectedLanguages = ["EN", "FR"]
        r.reportPath = "/tmp/rapport.html"
        r.log = "== Checklist 4D 21.2 build 100629 — macOS ARM — exécution 20261022-164512-4242 ==\n\n===== EN (1/2) =====\n• Installation of 4D: ok\n• Execution of application (with Internet): proof file written after 6 s\n• Execution of application (without Internet): Internet still reachable (4 probes)\n"
        if busy {
            r.running = true
            r.progressText = "Checklist FR (2/2)"
            r.status = "Checklist FR (2/2) en cours… 4D va s'ouvrir plusieurs fois, ne fermez pas cette fenêtre."
        } else {
            r.status = "Terminé – rapport : /tmp/rapport.html"
        }
        return r
    }
}

// ---------- entry point ----------
@main
enum AppMain {
    @MainActor static func main() {
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--snapshot"), i + 1 < args.count {
            exit(Snapshot.render(Array(args[(i + 1)...])))
        }
        TestInstaller4DApp.main()
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        BundleIcon.applyToDock()
    }
}

struct TestInstaller4DApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var r = Runner()
    var body: some Scene {
        WindowGroup("Test Installer 4D") { ContentView(r: r) }
            .defaultSize(width: 1240, height: 860)
            .commands { CommandGroup(replacing: .newItem) {} }
    }
}

// --snapshot <file.png> [light|dark] [width height] [busy] [found|failed|timeout] [prepare|results|log]
enum Snapshot {
    @MainActor static func render(_ a: [String]) -> Int32 {
        let path = a[0]
        let dark = a.contains("dark")
        let nums = a.compactMap { Double($0) }
        let w = nums.count >= 2 ? nums[0] : 1240, h = nums.count >= 2 ? nums[1] : 860
        let pane = Pane.allCases.first { a.contains(String(describing: $0)) }
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        let appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        let r = Runner.demo(busy: a.contains("busy"), watchEnd: ["found", "failed", "timeout"].first { a.contains($0) })
        let root = ContentView(r: r, animateIn: false, forcedPane: pane).environment(\.colorScheme, dark ? .dark : .light)
        let host = NSHostingView(rootView: root)
        host.appearance = appearance
        let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: w, height: h), styleMask: [.titled], backing: .buffered, defer: false)
        win.appearance = appearance
        win.contentView = host
        host.frame = NSRect(x: 0, y: 0, width: w, height: h)
        host.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 1.5))
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return 2 }
        appearance?.performAsCurrentDrawingAppearance { host.cacheDisplay(in: host.bounds, to: rep) }
        guard let png = rep.representation(using: .png, properties: [:]) else { return 2 }
        do { try png.write(to: URL(fileURLWithPath: path)) } catch { return 3 }
        print(path)
        return 0
    }
}
