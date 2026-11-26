// Dettatura: cattura col tasto o col clic, trascrizione con whisper-server, dizionario (nt.cli), incolla.
// Stesso comportamento della pillola di Hammerspoon:
// - il microfono si accende alla pressione; suono e pillola "in ascolto" arrivano solo quando la cattura è
//   confermata (tasto tenuto o doppio tocco) e c'è il primo audio vero; una cattura non confermata si butta in silenzio;
// - se il dizionario non risponde entro 1,5 s si incolla il testo grezzo: la dettatura non dipende dal motore Python;
// - durante una call l'intervallo della dettatura si annota nella cartella della call.
import AppKit
import AVFoundation

/// Valore messo negli eventi di tastiera creati da noi (Cmd+V), così la nostra tastiera li ignora.
let marcaEventiNostri: Int64 = 0x4E54_4B52

final class Dettatura: AzioniTasto {
    static let audioMinimo = 16000           // byte: sotto mezzo secondo non si trascrive
    static let limiteDizionario = 1.5
    static let ritardoAppunti = 0.8

    private let pillola: Pillola
    private let suoni: Suoni
    private let whisper: ServerWhisper
    private let impostazioni: () -> Impostazioni
    private let cartellaCall: () -> URL?
    /// Fino a quando non si incolla (prove): letto da Comandi.
    var senzaIncollaFino: () -> Date? = { nil }
    /// Avvisato quando cambia qualcosa da scrivere in stato-pillola.json.
    var cambiato: (() -> Void)?
    private(set) var ultimoIncollato: String?

    private final class Stato {
        let cattura: Cattura
        let avvio: Date
        var confermata = false
        var pronta = false
        var segnalata = false
        init(_ c: Cattura) { cattura = c; avvio = Date() }
    }
    private var corrente: Stato?
    private var n = 0
    private(set) var maniLibere = false
    private var inizioDettatura: Date?
    private var appDettatura = ""
    private var prompt = ""

    var registrando: Bool { corrente?.confermata == true }
    var occupata: Bool { corrente != nil || pillola.stato == .trascrivo }

    init(pillola: Pillola, suoni: Suoni, whisper: ServerWhisper, impostazioni: @escaping () -> Impostazioni,
         cartellaCall: @escaping () -> URL?) {
        self.pillola = pillola
        self.suoni = suoni
        self.whisper = whisper
        self.impostazioni = impostazioni
        self.cartellaCall = cartellaCall
        aggiornaPrompt()
        if AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined {
            AVCaptureDevice.requestAccess(for: .audio) { _ in }
        }
    }

    /// Suggerimento iniziale per Whisper (frase d'esempio + termini del dizionario).
    func aggiornaPrompt() {
        NtCli.esegui(["prompt"]) { [weak self] out in
            if let out { self?.prompt = out.trimmingCharacters(in: .whitespacesAndNewlines) }
        }
    }

    // MARK: AzioniTasto

    func avviaCattura() {
        guard corrente == nil, pillola.stato != .trascrivo else { return }
        whisper.accendi()
        n += 1
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("dettatura-\(n).wav")
        let c = Cattura(file: file, microfono: impostazioni().microfono)
        let s = Stato(c)
        pillola.livello = 0
        c.livello = { [weak self] v in
            guard let self, self.corrente === s else { return }
            self.pillola.livello = self.pillola.livello * 0.35 + v * 0.65
        }
        c.primoAudio = { [weak self] in
            guard let self, self.corrente === s, !s.pronta else { return }
            s.pronta = true
            self.segnalaAscolto(s)
        }
        c.errore = { [weak self] in self?.erroreCattura(s) }
        corrente = s
        c.avvia()
    }

    func annullaCattura() {
        guard let s = corrente, !s.confermata else { return }
        corrente = nil
        s.cattura.butta()
    }

    func conferma(maniLibere libere: Bool) {
        if corrente == nil { avviaCattura() }
        guard let s = corrente, !s.confermata else { return }
        s.confermata = true
        maniLibere = libere
        inizioDettatura = s.avvio
        segnaDettaturaInCall(da: s.avvio, a: nil)
        appDettatura = NSWorkspace.shared.frontmostApplication?.localizedName ?? ""
        segnalaAscolto(s)
    }

    func fine(annulla: Bool) {
        guard let s = corrente else { return }
        if !s.confermata { annullaCattura(); return }
        corrente = nil
        maniLibere = false
        let durata = Date().timeIntervalSince(s.avvio)
        segnaDettaturaInCall(da: s.avvio, a: Date())
        if annulla { suoni.suona("annulla"); tornaARiposo() } else { suoni.suona("stop"); pillola.mostra(.trascrivo) }
        let app = appDettatura
        s.cattura.ferma { [weak self] dim in
            guard let self else { return }
            let file = s.cattura.file
            if annulla { try? FileManager.default.removeItem(at: file); return }
            if dim > Self.audioMinimo {
                self.trascrivi(file, app: app, durata: durata)
            } else {
                try? FileManager.default.removeItem(at: file)
                self.tornaARiposo()
            }
        }
    }

    /// Dal clic sulla pillola o dal menu: mani libere.
    func iniziaManiLibere() {
        guard !registrando, pillola.stato != .trascrivo else { return }
        conferma(maniLibere: true)
    }

    // MARK: interno

    private func segnalaAscolto(_ s: Stato) {
        guard s === corrente, s.confermata, s.pronta, !s.segnalata else { return }
        s.segnalata = true
        suoni.suona(maniLibere ? "blocco" : "avvio")
        pillola.maniLibere = maniLibere
        pillola.mostra(.ascolto)
    }

    /// Il microfono non parte o sparisce: si torna a riposo con il suono "annulla", senza bloccare nulla.
    private func erroreCattura(_ s: Stato) {
        guard s === corrente else { return }
        corrente = nil
        maniLibere = false
        s.cattura.butta()
        guard s.confermata else { return }   // cattura non ancora confermata: si butta in silenzio
        segnaDettaturaInCall(da: s.avvio, a: Date())
        suoni.suona("annulla")
        tornaARiposo()
    }

    private func tornaARiposo() {
        pillola.mostra(cartellaCall() != nil ? .call : .riposo)
    }

    private func trascrivi(_ file: URL, app: String, durata: TimeInterval) {
        whisper.trascrivi(file: file, prompt: prompt) { [weak self] testo in
            try? FileManager.default.removeItem(at: file)
            guard let self else { return }
            self.whisper.rinviaSpegnimento()
            guard let testo else {
                Avviso.mostra("Dettatura: trascrizione non riuscita")
                self.tornaARiposo()
                return
            }
            let t = pulisciTesto(testo)
            if t.isEmpty { self.tornaARiposo() } else { self.finisciTesto(t, app: app, durata: durata) }
        }
    }

    /// Dizionario sul testo (al massimo 1,5 s, poi il grezzo), incolla, storico.
    private func finisciTesto(_ grezzo: String, app: String, durata: TimeInterval) {
        var fatto = false
        let chiudi: (String) -> Void = { [weak self] finale in
            guard let self, !fatto else { return }
            fatto = true
            self.tornaARiposo()
            if !finale.isEmpty { self.incolla(finale) }
            NtCli.esegui(["salva-dettatura", "--grezzo=" + grezzo, "--finale=" + finale, "--app=" + app,
                          "--durata=" + String(format: "%.1f", durata)]) { _ in }
        }
        NtCli.esegui(["applica"], input: grezzo, limite: Self.limiteDizionario) { out in
            let o = out?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            chiudi(o.isEmpty ? grezzo : o)
        }
    }

    /// Incolla dove c'è il cursore e rimette gli appunti di prima dopo 0,8 s.
    private func incolla(_ t: String) {
        ultimoIncollato = t
        defer { cambiato?() }
        if let fino = senzaIncollaFino(), fino > Date() { return }
        let pb = NSPasteboard.general
        let prima: [[NSPasteboard.PasteboardType: Data]] = (pb.pasteboardItems ?? []).map { item in
            var d: [NSPasteboard.PasteboardType: Data] = [:]
            for tipo in item.types { if let v = item.data(forType: tipo) { d[tipo] = v } }
            return d
        }
        pb.clearContents()
        pb.setString(t, forType: .string)
        let nostro = pb.changeCount
        let sorgente = CGEventSource(stateID: .combinedSessionState)
        for giu in [true, false] {
            if let e = CGEvent(keyboardEventSource: sorgente, virtualKey: 9, keyDown: giu) {
                e.flags = .maskCommand
                e.setIntegerValueField(.eventSourceUserData, value: marcaEventiNostri)
                e.post(tap: .cghidEventTap)
            }
        }
        suoni.suona("incolla")
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.ritardoAppunti) {
            // Si rimettono gli appunti di prima, anche se l'incolla non è andato (nessun campo di testo),
            // ma non se nel frattempo qualcuno ha copiato altro.
            guard !prima.isEmpty, pb.changeCount == nostro else { return }
            pb.clearContents()
            pb.writeObjects(prima.map { d in
                let item = NSPasteboardItem()
                for (tipo, v) in d { item.setData(v, forType: tipo) }
                return item
            })
        }
    }

    /// Durante una call: intervallo {da, a} in dettature-in-call.jsonl (a nullo = dettatura appena iniziata).
    private func segnaDettaturaInCall(da: Date, a: Date?) {
        guard let cartella = cartellaCall() else { return }
        let riga: [String: Any] = ["da": da.timeIntervalSince1970, "a": a.map { $0.timeIntervalSince1970 } ?? NSNull()]
        guard var d = try? JSONSerialization.data(withJSONObject: riga) else { return }
        d.append(0x0A)
        let f = cartella.appendingPathComponent("dettature-in-call.jsonl")
        if let h = try? FileHandle(forWritingTo: f) {
            defer { try? h.close() }
            _ = try? h.seekToEnd()
            try? h.write(contentsOf: d)
        } else {
            try? d.write(to: f)
        }
    }
}
