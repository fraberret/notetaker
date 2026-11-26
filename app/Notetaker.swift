// Notetaker: finestra dell'app. Avvia il motore locale (app/server.py), mostra l'interfaccia
// in una WKWebView e chiude il motore quando l'app esce.
// Si compila con app/build.sh.

import AppKit
import WebKit

let BASE = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config/trascrittore")

final class Delegato: NSObject, NSApplicationDelegate, NSWindowDelegate, WKNavigationDelegate, WKUIDelegate,
    WKDownloadDelegate {
    var finestra: NSWindow!
    var web: WKWebView!
    var motore: Process?
    var indirizzo: URL?
    var errori = Data()
    let coda = DispatchQueue(label: "notetaker.motore")
    var pillola: Pillola!
    var suoni: Suoni!

    func applicationDidFinishLaunching(_ n: Notification) {
        NSApp.appearance = NSAppearance(named: .darkAqua)
        creaMenu()
        creaFinestra()
        avviaMotore()
        pillola = Pillola()
        suoni = Suoni(cartella: Percorsi.suoni)
        suoni.aggiorna(Impostazioni.leggi(try? Data(contentsOf: Percorsi.dati.appendingPathComponent("impostazioni.json"))))
        pillola.mostra(.riposo)
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
            avvisoEdEsci("Non riesco ad avviare il motore: \(error.localizedDescription)")
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
                    self.avvisoEdEsci("Il motore del Notetaker non è partito entro 10 secondi.\n\n"
                        + (motivo.isEmpty ? "Nessun messaggio di errore." : String(motivo.suffix(1200))))
                }
            }
        }
    }

    func avvisoEdEsci(_ testo: String) {
        let a = NSAlert()
        a.messageText = "Notetaker non si avvia"
        a.informativeText = testo
        a.alertStyle = .critical
        a.runModal()
        NSApp.terminate(nil)
    }

    func fermaMotore() {
        guard let p = motore, p.isRunning else { return }
        p.terminate()
        let limite = Date().addingTimeInterval(2)
        while p.isRunning && Date() < limite { usleep(50_000) }
        if p.isRunning { kill(p.processIdentifier, SIGKILL) }
    }

    func applicationWillTerminate(_ n: Notification) { fermaMotore() }
    func applicationShouldTerminateAfterLastWindowClosed(_ s: NSApplication) -> Bool { true }
    func applicationShouldHandleReopen(_ s: NSApplication, hasVisibleWindows: Bool) -> Bool {
        finestra.makeKeyAndOrderFront(nil)
        return true
    }

    // MARK: finestra

    func creaFinestra() {
        let config = WKWebViewConfiguration()
        config.mediaTypesRequiringUserActionForPlayback = []
        config.websiteDataStore = .nonPersistent()
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
        if !finestra.setFrameUsingName("Notetaker") { finestra.center() }
        finestra.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
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
