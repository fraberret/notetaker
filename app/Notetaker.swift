// Notetaker: app sempre accesa con icona nella barra dei menu e pillola sul bordo dello schermo.
// Avvia il motore locale (app/server.py), mostra l'interfaccia in una WKWebView quando si apre la finestra
// e chiude il motore quando l'app esce (Cmd+Q). Chiudere la finestra la nasconde e basta.
// Si compila con app/build.sh.

import AppKit
import Carbon.HIToolbox
import ServiceManagement
import WebKit

let BASE = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config/trascrittore")

final class Delegato: NSObject, NSApplicationDelegate, NSWindowDelegate, WKNavigationDelegate, WKUIDelegate,
    WKDownloadDelegate, WKScriptMessageHandler, NSMenuDelegate {
    var finestra: NSWindow!
    var web: WKWebView!
    var motore: Process?
    var indirizzo: URL?
    var errori = Data()
    let coda = DispatchQueue(label: "notetaker.motore")
    var pillola: Pillola!
    var suoni: Suoni!
    var comandi: Comandi?
    var urlInAttesa: [URL] = []
    var barra: NSStatusItem!
    var voceAccessibilita: NSMenuItem!
    var voceDetta: NSMenuItem!
    var voceCall: NSMenuItem!
    var timerAccessibilita: Timer?
    var lanciataAlLogin = false
    var imp = Impostazioni()
    var osservatore: Osservatore?
    let whisper = ServerWhisper()
    var dettatura: Dettatura!
    var tasto: TastoDettatura!
    var tastiera: Tastiera!
    var call: GestoreCall!
    var scorciatoie: Scorciatoie!
    var voceStatoCall: NSMenuItem!
    var orologioMenu: Timer?

    func applicationWillFinishLaunching(_ n: Notification) {
        NSAppleEventManager.shared().setEventHandler(self, andSelector: #selector(apriURL(_:risposta:)),
                                                     forEventClass: AEEventClass(kInternetEventClass),
                                                     andEventID: AEEventID(kAEGetURL))
        controllaLancioAlLogin()
    }

    func applicationDidFinishLaunching(_ n: Notification) {
        NSApp.appearance = NSAppearance(named: .darkAqua)
        controllaLancioAlLogin()
        creaMenu()
        creaBarra()
        creaFinestra()
        avviaMotore()
        pillola = Pillola()
        suoni = Suoni(cartella: Percorsi.suoni)
        leggiImpostazioni()
        creaDettatura()
        let c = Comandi(pillola: pillola)
        comandi = c
        pillola.cambiato = { _ in c.scriviStato() }
        pillola.clicDestro = { [weak self] in self?.apriFinestra() }
        pillola.clic = { [weak self] zona in self?.clicPillola(zona) }
        call = GestoreCall(pillola: pillola, suoni: suoni, impostazioni: { [unowned self] in self.imp },
                           dettaturaOccupata: { [unowned self] in self.dettatura.occupata })
        call.cambiato = { [weak self] in self?.aggiornaMenuCall(); c.scriviStato() }
        dettatura.senzaIncollaFino = { c.senzaIncollaFino }
        dettatura.cambiato = { c.scriviStato() }
        c.detta = { [weak self] in self?.dettatura.iniziaManiLibere() }
        c.fine = { [weak self] in self?.dettatura.fine(annulla: false) }
        c.annulla = { [weak self] in self?.dettatura.fine(annulla: true) }
        c.extra = { [weak self] in
            guard let self else { return [:] }
            return ["ultimoIncollato": self.dettatura.ultimoIncollato ?? NSNull(), "registroTasto": self.tasto.registro,
                    "callInCorso": self.call.inCorso, "tastieraAttiva": self.tastiera.attiva, "eventiTastiera": self.tastiera.eventi,
                    "accessibilita": AXIsProcessTrusted(), "registrazioneSchermo": CGPreflightScreenCaptureAccess()]
        }
        pillola.mostra(.riposo)
        call.avvia()
        creaScorciatoie()
        controllaAccessibilita()
        urlInAttesa.forEach(c.gestisci)
        urlInAttesa = []
        registraAlLoginLaPrimaVolta()
        if !lanciataAlLogin { apriFinestra() }
    }

    // MARK: dettatura

    func leggiImpostazioni() {
        imp = Impostazioni.leggi(try? Data(contentsOf: Percorsi.dati.appendingPathComponent("impostazioni.json")))
        suoni.aggiorna(imp)
    }

    func creaDettatura() {
        dettatura = Dettatura(pillola: pillola, suoni: suoni, whisper: whisper, impostazioni: { [unowned self] in self.imp },
                              cartellaCall: { [weak self] in self?.call?.cartellaCorrente() })
        tasto = TastoDettatura(azioni: dettatura, pianificatore: PianificatoreVero())
        tastiera = Tastiera(tasto: tasto, quale: { [unowned self] in self.imp.tasto })
        // Impostazioni e dizionario cambiano dal Notetaker: valgono subito.
        osservatore = Osservatore(cartella: Percorsi.dati) { [weak self] nome in
            if nome == "impostazioni.json" { self?.leggiImpostazioni() }
            if nome == "dizionario.json" { self?.dettatura.aggiornaPrompt() }
        }
    }

    func clicPillola(_ zona: ZonaPillola) {
        switch pillola.stato {
        case .domanda:
            if zona == .si { DispatchQueue.main.async { self.call.avviaChiedendoNome() } }
            if zona == .no { call.rispostaNo() }
        case .call, .callSopra:
            if zona == .stop { call.ferma() }
        case .sopra where zona == .registraCall:
            DispatchQueue.main.async { self.call.avviaChiedendoNome() }   // pallino rosso sotto il microfono
        case .riposo, .sopra:
            if zona == .detta || zona == .fondo { dettatura.iniziaManiLibere() }   // dal clic: mani libere
        case .ascolto:
            dettatura.fine(annulla: false)
        case .trascrivo:
            break
        }
    }

    // MARK: call

    func creaScorciatoie() {
        scorciatoie = Scorciatoie()
        let mod = UInt32(controlKey | optionKey | cmdKey)
        scorciatoie.registra(codice: UInt32(kVK_ANSI_R), modificatori: mod) { [weak self] in
            DispatchQueue.main.async { self?.call.alterna() }
        }
        scorciatoie.registra(codice: UInt32(kVK_ANSI_N), modificatori: mod) { [weak self] in self?.apriFinestra() }
    }

    @objc func menuCall() { call.alterna() }

    func aggiornaMenuCall() {
        voceCall.title = call.inCorso ? "Ferma la call" : "Registra una call"
        voceStatoCall.isHidden = !call.inCorso
        aggiornaRigaCall()
    }

    func aggiornaRigaCall() {
        guard call.inCorso else { return }
        let chi = call.nome.isEmpty ? "" : " con \(call.nome)"
        voceStatoCall.title = "Registro la call\(chi) — \(Pillola.tempo(da: call.inizio))"
    }

    // Il tempo nel menu si aggiorna ogni secondo solo mentre il menu è aperto.
    func menuWillOpen(_ m: NSMenu) {
        aggiornaMenuCall()
        guard call.inCorso else { return }
        let t = Timer(timeInterval: 1, repeats: true) { [weak self] _ in self?.aggiornaRigaCall() }
        RunLoop.main.add(t, forMode: .common)
        orologioMenu = t
    }

    func menuDidClose(_ m: NSMenu) {
        orologioMenu?.invalidate()
        orologioMenu = nil
    }

    @objc func menuDetta() {
        if dettatura.registrando { dettatura.fine(annulla: false) } else { dettatura.iniziaManiLibere() }
    }

    /// Lanciata da macOS al login: niente finestra, solo icona e pillola. Gli elementi login di SMAppService
    /// non sempre passano il segnale di macOS: vale anche un avvio nei primi 3 minuti dall'accesso alla sessione.
    func controllaLancioAlLogin() {
        if let e = NSAppleEventManager.shared().currentAppleEvent, e.eventID == AEEventID(kAEOpenApplication),
           e.paramDescriptor(forKeyword: AEKeyword(keyAEPropData))?.enumCodeValue == OSType(keyAELaunchedAsLogInItem) {
            lanciataAlLogin = true
        }
        if let accesso = Self.accessoSessione(), Date().timeIntervalSince(accesso) < 180 { lanciataAlLogin = true }
    }

    /// Quando l'utente è entrato nella sessione grafica (riga "console" di utmpx).
    static func accessoSessione() -> Date? {
        let utente = NSUserName()
        var trovato: Date?
        setutxent()
        while let r = getutxent() {
            var v = r.pointee
            guard v.ut_type == USER_PROCESS else { continue }
            let riga = withUnsafeBytes(of: &v.ut_line) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
            let chi = withUnsafeBytes(of: &v.ut_user) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
            if riga == "console" && chi == utente {
                trovato = Date(timeIntervalSince1970: TimeInterval(v.ut_tv.tv_sec))
            }
        }
        endutxent()
        return trovato
    }

    @objc func apriURL(_ e: NSAppleEventDescriptor, risposta: NSAppleEventDescriptor) {
        guard let s = e.paramDescriptor(forKeyword: AEKeyword(keyDirectObject))?.stringValue, let u = URL(string: s)
        else { return }
        if let c = comandi { c.gestisci(u) } else { urlInAttesa.append(u) }
    }

    // MARK: barra dei menu

    func creaBarra() {
        barra = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let b = barra.button {
            b.image = NSImage(systemSymbolName: "waveform", accessibilityDescription: "Notetaker")
            b.image?.isTemplate = true
        }
        let m = NSMenu()
        m.delegate = self
        voceStatoCall = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        voceStatoCall.isEnabled = false
        voceStatoCall.isHidden = true
        voceAccessibilita = NSMenuItem(title: "Manca il permesso di Accessibilità: aprilo",
                                       action: #selector(apriAccessibilita), keyEquivalent: "")
        voceAccessibilita.target = self
        voceAccessibilita.isHidden = true
        m.addItem(voceAccessibilita)
        m.addItem(voceStatoCall)
        let apri = NSMenuItem(title: "Apri Notetaker", action: #selector(apriFinestra), keyEquivalent: "")
        apri.target = self
        m.addItem(apri)
        voceDetta = NSMenuItem(title: "Detta", action: #selector(menuDetta), keyEquivalent: "")
        voceDetta.target = self
        m.addItem(voceDetta)
        voceCall = NSMenuItem(title: "Registra una call", action: #selector(menuCall), keyEquivalent: "")
        voceCall.target = self
        m.addItem(voceCall)
        m.addItem(.separator())
        m.addItem(NSMenuItem(title: "Esci da Notetaker", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        barra.menu = m
    }

    /// Senza Accessibilità il tasto Fn non arriva: lo si dice nel menu e si ricontrolla ogni 5 s.
    func controllaAccessibilita() {
        let manca = !AXIsProcessTrusted() || !tastiera.avvia()
        voceAccessibilita.isHidden = !manca
        barra.button?.appearsDisabled = manca
        if manca && timerAccessibilita == nil {
            let t = Timer(timeInterval: 5, repeats: true) { [weak self] _ in self?.controllaAccessibilita() }
            RunLoop.main.add(t, forMode: .common)
            timerAccessibilita = t
        } else if !manca {
            timerAccessibilita?.invalidate(); timerAccessibilita = nil
        }
    }

    @objc func apriAccessibilita() {
        // Con la richiesta macOS aggiunge Notetaker all'elenco e mostra il suo avviso; poi si aprono le Impostazioni.
        _ = AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary)
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }

    @objc func apriFinestra() {
        NSApp.setActivationPolicy(.regular)
        finestra.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: avvio al login

    func registraAlLoginLaPrimaVolta() {
        let chiave = "alLoginImpostato"
        guard !UserDefaults.standard.bool(forKey: chiave) else { return }
        try? SMAppService.mainApp.register()
        UserDefaults.standard.set(true, forKey: chiave)
    }

    /// Ponte con la finestra: {azione: "alLogin", valore?: Bool} → window.statoAlLogin(attivo).
    func userContentController(_ u: WKUserContentController, didReceive m: WKScriptMessage) {
        guard let d = m.body as? [String: Any], d["azione"] as? String == "alLogin" else { return }
        let s = SMAppService.mainApp
        if let v = d["valore"] as? Bool {
            do { if v { try s.register() } else { try s.unregister() } } catch {
                NSLog("Notetaker: avvio al login non cambiato: \(error.localizedDescription)")
            }
        }
        web.evaluateJavaScript("window.statoAlLogin && window.statoAlLogin(\(s.status == .enabled))")
    }

    // MARK: motore

    func avviaMotore() {
        let p = Process()
        p.executableURL = BASE.appendingPathComponent("venv/bin/python")
        p.arguments = [BASE.appendingPathComponent("app/server.py").path]
        p.currentDirectoryURL = BASE
        var env = ProcessInfo.processInfo.environment
        env["PYTHONUNBUFFERED"] = "1"
        env["PATH"] = "/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        p.environment = env
        let uscita = Pipe(), err = Pipe()
        p.standardOutput = uscita
        p.standardError = err
        err.fileHandleForReading.readabilityHandler = { [weak self] h in
            let d = h.availableData
            self?.coda.async { self?.errori.append(d) }
        }
        var pronto = false
        let semaforo = DispatchSemaphore(value: 0)
        uscita.fileHandleForReading.readabilityHandler = { [weak self] h in
            guard let riga = String(data: h.availableData, encoding: .utf8), !pronto else { return }
            for r in riga.split(separator: "\n") where r.hasPrefix("PRONTO ") {
                let parti = r.split(separator: " ")
                if parti.count == 3, let porta = Int(parti[1]) {
                    var c = URLComponents(string: "http://127.0.0.1:\(porta)/")!
                    c.queryItems = [URLQueryItem(name: "g", value: String(parti[2]))]
                    self?.indirizzo = c.url
                    pronto = true
                    semaforo.signal()
                }
            }
        }
        p.terminationHandler = { _ in semaforo.signal() }
        do {
            try p.run()
        } catch {
            avvisoMotore("Non riesco ad avviare il motore: \(error.localizedDescription)")
            return
        }
        motore = p
        DispatchQueue.global().async {
            let esito = semaforo.wait(timeout: .now() + 10)
            DispatchQueue.main.async {
                if let url = self.indirizzo, esito == .success {
                    self.web.load(URLRequest(url: url))
                } else {
                    let motivo = self.coda.sync { String(data: self.errori, encoding: .utf8) ?? "" }
                    self.avvisoMotore("Il motore del Notetaker non è partito entro 10 secondi.\n\n"
                        + (motivo.isEmpty ? "Nessun messaggio di errore." : String(motivo.suffix(1200))))
                }
            }
        }
    }

    /// Il motore serve solo alla finestra: se non parte si avvisa, ma l'app resta accesa con pillola e dettatura.
    func avvisoMotore(_ testo: String) {
        let a = NSAlert()
        a.messageText = "La finestra del Notetaker non si avvia"
        a.informativeText = testo + "\n\nLa pillola e la dettatura funzionano lo stesso."
        a.alertStyle = .warning
        NSApp.activate(ignoringOtherApps: true)
        a.runModal()
    }

    func fermaMotore() {
        guard let p = motore, p.isRunning else { return }
        p.terminate()
        let limite = Date().addingTimeInterval(2)
        while p.isRunning && Date() < limite { usleep(50_000) }
        if p.isRunning { kill(p.processIdentifier, SIGKILL) }
    }

    func applicationWillTerminate(_ n: Notification) {
        whisper.spegni()
        fermaMotore()
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ s: NSApplication) -> Bool { false }
    func applicationShouldHandleReopen(_ s: NSApplication, hasVisibleWindows: Bool) -> Bool {
        apriFinestra()
        return false
    }

    /// Chiudere la finestra la nasconde: l'app resta accesa (icona nella barra e pillola) e sparisce dal Dock.
    func windowShouldClose(_ w: NSWindow) -> Bool {
        w.orderOut(nil)
        NSApp.setActivationPolicy(.accessory)
        return false
    }

    // MARK: finestra

    func creaFinestra() {
        let config = WKWebViewConfiguration()
        config.mediaTypesRequiringUserActionForPlayback = []
        config.websiteDataStore = .nonPersistent()
        config.userContentController.add(self, name: "notetaker")
        web = WKWebView(frame: .zero, configuration: config)
        web.navigationDelegate = self
        web.uiDelegate = self
        web.setValue(false, forKey: "drawsBackground")
        finestra = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 720),
                            styleMask: [.titled, .closable, .miniaturizable, .resizable],
                            backing: .buffered, defer: false)
        finestra.title = "Notetaker"
        finestra.minSize = NSSize(width: 900, height: 600)
        finestra.backgroundColor = NSColor(red: 0x12 / 255, green: 0x12 / 255, blue: 0x16 / 255, alpha: 1)
        finestra.contentView = web
        finestra.delegate = self
        finestra.setFrameAutosaveName("Notetaker")
        finestra.isReleasedWhenClosed = false
        if !finestra.setFrameUsingName("Notetaker") { finestra.center() }
    }

    func creaMenu() {
        let barra = NSMenu()
        let app = NSMenuItem(); barra.addItem(app)
        let mApp = NSMenu()
        mApp.addItem(withTitle: "Nascondi Notetaker", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        mApp.addItem(.separator())
        mApp.addItem(withTitle: "Esci da Notetaker", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        app.submenu = mApp
        let modifica = NSMenuItem(); barra.addItem(modifica)
        let mMod = NSMenu(title: "Modifica")
        mMod.addItem(withTitle: "Annulla", action: Selector(("undo:")), keyEquivalent: "z")
        mMod.addItem(withTitle: "Ripeti", action: Selector(("redo:")), keyEquivalent: "Z")
        mMod.addItem(.separator())
        mMod.addItem(withTitle: "Taglia", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        mMod.addItem(withTitle: "Copia", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        mMod.addItem(withTitle: "Incolla", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        mMod.addItem(withTitle: "Seleziona tutto", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        modifica.submenu = mMod
        let vista = NSMenuItem(); barra.addItem(vista)
        let mVista = NSMenu(title: "Vista")
        mVista.addItem(withTitle: "Ricarica", action: #selector(ricarica), keyEquivalent: "r")
        vista.submenu = mVista
        let fin = NSMenuItem(); barra.addItem(fin)
        let mFin = NSMenu(title: "Finestra")
        mFin.addItem(withTitle: "Chiudi", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        mFin.addItem(withTitle: "Contrai", action: #selector(NSWindow.miniaturize(_:)), keyEquivalent: "m")
        fin.submenu = mFin
        NSApp.mainMenu = barra
        NSApp.windowsMenu = mFin
    }

    @objc func ricarica() { web.reload() }

    // MARK: navigazione: dentro l'app solo il motore locale, il resto nel browser

    func locale(_ url: URL?) -> Bool {
        guard let u = url else { return false }
        return u.scheme == "blob" || u.scheme == "about" || (u.host == "127.0.0.1" && u.port == indirizzo?.port)
    }

    func webView(_ w: WKWebView, decidePolicyFor a: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        if a.shouldPerformDownload { return decisionHandler(.download) }
        if locale(a.request.url) { return decisionHandler(.allow) }
        if let u = a.request.url, ["http", "https", "obsidian", "mailto"].contains(u.scheme ?? "") {
            NSWorkspace.shared.open(u)
        }
        decisionHandler(.cancel)
    }

    func webView(_ w: WKWebView, decidePolicyFor r: WKNavigationResponse,
                 decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
        decisionHandler(r.canShowMIMEType ? .allow : .download)
    }

    func webView(_ w: WKWebView, createWebViewWith c: WKWebViewConfiguration, for a: WKNavigationAction,
                 windowFeatures f: WKWindowFeatures) -> WKWebView? {
        if let u = a.request.url, !locale(u) { NSWorkspace.shared.open(u) }
        return nil
    }

    func webViewWebContentProcessDidTerminate(_ w: WKWebView) { w.reload() }

    // MARK: download (Esporta): l'utente sceglie dove salvare

    func webView(_ w: WKWebView, navigationAction a: WKNavigationAction, didBecome d: WKDownload) { d.delegate = self }
    func webView(_ w: WKWebView, navigationResponse r: WKNavigationResponse, didBecome d: WKDownload) { d.delegate = self }

    func download(_ d: WKDownload, decideDestinationUsing r: URLResponse, suggestedFilename nome: String,
                  completionHandler: @escaping (URL?) -> Void) {
        let pannello = NSSavePanel()
        pannello.nameFieldStringValue = nome
        pannello.canCreateDirectories = true
        pannello.directoryURL = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first
        pannello.beginSheetModal(for: finestra) { esito in
            guard esito == .OK, let url = pannello.url else { return completionHandler(nil) }
            try? FileManager.default.removeItem(at: url)
            completionHandler(url)
        }
    }
}
