// Call: domanda quando un'app di call usa il microfono, registrazione col comando `call`, scorciatoie globali.
// Stesso comportamento della pillola di Hammerspoon (controlloMic, avviaCall, fermaCall).
import AppKit
import Carbon.HIToolbox

/// Registrazione in corso secondo il file `stato` del comando call (pid, cartella, nome), come `call stato`.
struct StatoCall {
    let cartella: URL
    let nome: String
    let inizio: Date?

    static func leggi(_ file: URL = Percorsi.fileStato) -> StatoCall? {
        guard let t = try? String(contentsOf: file, encoding: .utf8) else { return nil }
        let righe = t.components(separatedBy: "\n")
        guard righe.count >= 2, let pid = Int32(righe[0].trimmingCharacters(in: .whitespaces)), kill(pid, 0) == 0,
              !righe[1].isEmpty else { return nil }
        let cartella = URL(fileURLWithPath: righe[1])
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        return StatoCall(cartella: cartella, nome: righe.count > 2 ? righe[2] : "", inizio: f.date(from: cartella.lastPathComponent))
    }
}

final class GestoreCall {
    static let scadenzaDomanda: TimeInterval = 30

    private let pillola: Pillola
    private let suoni: Suoni
    private let impostazioni: () -> Impostazioni
    private let dettaturaOccupata: () -> Bool
    private(set) var inCorso = false
    private(set) var inizio: Date?
    private(set) var nome = ""
    /// Avvisato quando la call parte o si ferma (menu, stato-pillola.json).
    var cambiato: (() -> Void)?

    private var micDa: Date?
    private var micIgnora = false
    private var domandaScade: Date?
    private var controllo: Timer?
    private var microfonoAvvisato: URL?

    init(pillola: Pillola, suoni: Suoni, impostazioni: @escaping () -> Impostazioni,
         dettaturaOccupata: @escaping () -> Bool) {
        self.pillola = pillola
        self.suoni = suoni
        self.impostazioni = impostazioni
        self.dettaturaOccupata = dettaturaOccupata
    }

    /// Stato iniziale (una call già in registrazione all'avvio) e controllo del microfono ogni 2 s.
    func avvia() {
        if let s = StatoCall.leggi() {
            inCorso = true
            inizio = s.inizio ?? Date()
            nome = s.nome
            pillola.inizioCall = inizio
            pillola.mostra(.call)
            cambiato?()
        }
        let t = Timer(timeInterval: 2, repeats: true) { [weak self] _ in self?.controllaMicrofono() }
        RunLoop.main.add(t, forMode: .common)
        controllo = t
    }

    func cartellaCorrente() -> URL? {
        inCorso ? StatoCall.leggi()?.cartella : nil
    }

    // MARK: domanda

    private func controllaMicrofono() {
        controllaMicrofonoDellaCall()
        if dettaturaOccupata() || pillola.stato == .trascrivo || inCorso { micDa = nil; return }
        let inUso = DispositiviAudio.predefinitoIngresso().map(DispositiviAudio.inUso) ?? false
        if !inUso {
            micDa = nil
            micIgnora = false
            if pillola.stato == .domanda { pillola.mostra(.riposo) }
            return
        }
        if pillola.stato == .domanda {
            if let s = domandaScade, Date() > s { micIgnora = true; pillola.mostra(.riposo) }
            return
        }
        let imp = impostazioni()
        guard !micIgnora, imp.domandaCall, pillola.stato == .riposo || pillola.stato == .sopra else { return }
        let da = micDa ?? Date()
        micDa = da
        guard Date().timeIntervalSince(da) >= Double(imp.secondiDomanda), trovaAppCall() != nil else { return }
        domandaScade = Date().addingTimeInterval(Self.scadenzaDomanda)
        suoni.suona("domanda")
        pillola.mostra(.domanda)
    }

    /// Durante la call: se `registra` scrive "MICROFONO MUTO" nel suo log, avviso una volta per call
    /// (call del 27/11/2026: 30 minuti senza la voce di chi registra, senza alcun avviso).
    private func controllaMicrofonoDellaCall() {
        guard let cartella = StatoCall.leggi()?.cartella, cartella != microfonoAvvisato,
              let log = try? String(contentsOf: cartella.appendingPathComponent("registra.log"), encoding: .utf8),
              log.contains("MICROFONO MUTO") else { return }
        microfonoAvvisato = cartella
        suoni.suona("domanda")
        Avviso.mostra("Attenzione: la tua voce non si sta registrando, solo quella dell'altra persona. "
                      + "Controlla il microfono in Impostazioni di Sistema > Suono > Ingresso.", secondi: 12)
    }

    /// Titoli delle finestre dei browser (servono i permessi di registrazione dello schermo) e app di call aperte.
    private func trovaAppCall() -> String? {
        var titoli: [String] = []
        if let lista = CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] {
            for w in lista {
                guard let app = w[kCGWindowOwnerName as String] as? String, browserCall.contains(app),
                      (w[kCGWindowLayer as String] as? Int) == 0, let t = w[kCGWindowName as String] as? String,
                      !t.isEmpty else { continue }
                titoli.append(t)
            }
        }
        let aperte = Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
        return riconosciAppCall(titoliBrowser: titoli, bundleAperti: aperte)
    }

    /// "No" sulla domanda: non richiedere finché il microfono non si libera.
    func rispostaNo() {
        micIgnora = true
        pillola.mostra(.riposo)
    }

    // MARK: registrazione

    func avviaChiedendoNome() {
        guard !inCorso else { return }
        let precedente = NSWorkspace.shared.frontmostApplication
        NSApp.activate(ignoringOtherApps: true)
        // Dopo la finestrella si torna all'app in cui si era (la call), non al Notetaker.
        defer { if let p = precedente, p != NSRunningApplication.current { p.activate() } }
        let a = NSAlert()
        a.messageText = "Trascrivi la call"
        a.informativeText = "Con chi è la call? (più persone: Marco, Giulia)"
        a.addButton(withTitle: "Avvia")
        a.addButton(withTitle: "Annulla")
        let campo = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        campo.placeholderString = "Nome"
        a.accessoryView = campo
        a.window.initialFirstResponder = campo
        guard a.runModal() == .alertFirstButtonReturn else {
            micIgnora = true
            pillola.mostra(.riposo)
            return
        }
        let n = pulisciNomeCall(campo.stringValue)
        Self.comando(["avvia", n]) { [weak self] esito in
            guard let self else { return }
            if esito.contains("avviata") {
                self.inCorso = true
                self.inizio = Date()
                self.nome = n
                self.pillola.inizioCall = self.inizio
                self.suoni.suona("blocco")
                self.pillola.mostra(.call)
                Avviso.mostra("Registro la call con \(n). Ricorda di chiedere il consenso.", secondi: 4)
            } else {
                Avviso.mostra(esito.isEmpty ? "La registrazione non è partita" : esito, secondi: 5)
                self.pillola.mostra(.riposo)
                if esito.contains("TCC") || esito.contains("Registrazione schermo") {
                    // Manca il permesso di registrare schermo e audio di sistema: si apre la pagina giusta.
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
                }
            }
            self.cambiato?()
        }
    }

    func ferma() {
        Self.comando(["ferma"]) { _ in }
        inCorso = false
        inizio = nil
        nome = ""
        pillola.inizioCall = nil
        micIgnora = true             // la call è ancora aperta: non riproporre finché il microfono non si libera
        suoni.suona("stop")
        pillola.mostra(.riposo)
        Avviso.mostra("Call fermata: trascrivo, ti arriva una notifica")
        cambiato?()
    }

    /// Ctrl+Option+Cmd+R e menu: ferma se si sta registrando (anche se partita da fuori), altrimenti chiede il nome.
    func alterna() {
        if inCorso || StatoCall.leggi() != nil { ferma() } else { avviaChiedendoNome() }
    }

    /// Esegue il comando `call` con gli argomenti; `fatto` riceve l'uscita sul thread principale.
    static func comando(_ arg: [String], _ fatto: @escaping (String) -> Void) {
        let p = Process()
        p.executableURL = Percorsi.comandoCall
        p.arguments = arg
        p.currentDirectoryURL = Percorsi.base
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = "/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        p.environment = env
        let uscita = Pipe()
        p.standardOutput = uscita
        p.standardError = uscita
        do { try p.run() } catch { return fatto("Non riesco a eseguire call: \(error.localizedDescription)") }
        DispatchQueue.global().async {
            let d = uscita.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            let t = String(data: d, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            DispatchQueue.main.async { fatto(t) }
        }
    }
}

/// Scorciatoie globali con Carbon (non servono permessi).
final class Scorciatoie {
    private var azioni: [UInt32: () -> Void] = [:]
    private var riferimenti: [EventHotKeyRef] = []
    private var gestore: EventHandlerRef?

    init() {
        var tipo = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let io = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(GetApplicationEventTarget(), { _, evento, io in
            var id = EventHotKeyID()
            GetEventParameter(evento, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil,
                              MemoryLayout<EventHotKeyID>.size, nil, &id)
            let s = Unmanaged<Scorciatoie>.fromOpaque(io!).takeUnretainedValue()
            s.azioni[id.id]?()
            return noErr
        }, 1, &tipo, io, &gestore)
    }

    func registra(codice: UInt32, modificatori: UInt32, _ f: @escaping () -> Void) {
        let n = UInt32(azioni.count + 1)
        var ref: EventHotKeyRef?
        let id = EventHotKeyID(signature: OSType(0x4E54_4B52), id: n)
        if RegisterEventHotKey(codice, modificatori, id, GetApplicationEventTarget(), 0, &ref) == noErr, let ref {
            azioni[n] = f
            riferimenti.append(ref)
        } else {
            NSLog("Notetaker: scorciatoia \(codice) già usata da un altro programma")
        }
    }
}
