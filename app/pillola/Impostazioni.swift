// Impostazioni della pillola (dati/impostazioni.json, cambiate dal Notetaker), percorsi e osservatore dei file.
import Foundation

struct Impostazioni: Equatable {
    var tasto = "fn"              // "fn" oppure "option_destro"
    var suoni = true
    var volume = 0.45
    var microfono = ""            // vuoto = microfono predefinito
    var domandaCall = true
    var secondiDomanda = 6

    /// Legge il JSON; i valori mancanti o del tipo sbagliato restano quelli predefiniti.
    static func leggi(_ d: Data?) -> Impostazioni {
        var i = Impostazioni()
        guard let d, let v = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return i }
        func booleano(_ x: Any?) -> Bool? {
            guard let n = x as? NSNumber, CFGetTypeID(n) == CFBooleanGetTypeID() else { return nil }
            return n.boolValue
        }
        func numero(_ x: Any?) -> Double? {
            guard let n = x as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID() else { return nil }
            return n.doubleValue
        }
        if let t = v["tasto"] as? String, t == "fn" || t == "option_destro" { i.tasto = t }
        if let b = booleano(v["suoni"]) { i.suoni = b }
        if let n = numero(v["volume"]) { i.volume = max(0, min(1, n)) }
        if let m = v["microfono"] as? String { i.microfono = m }
        if let b = booleano(v["domanda_call"]) { i.domandaCall = b }
        if let n = numero(v["secondi_domanda"]) { i.secondiDomanda = max(1, Int(n.rounded())) }
        return i
    }
}

enum Percorsi {
    static let casa = FileManager.default.homeDirectoryForCurrentUser
    static let base = casa.appendingPathComponent(".config/trascrittore")
    static let ambiente = ProcessInfo.processInfo.environment
    /// CALL_DATI e CALL_STATO come il comando `call` e nt/, per le prove.
    static let dati = ambiente["CALL_DATI"].map { URL(fileURLWithPath: $0) } ?? base.appendingPathComponent("dati")
    static let fileStato = ambiente["CALL_STATO"].map { URL(fileURLWithPath: $0) } ?? base.appendingPathComponent("stato")
    static let python = base.appendingPathComponent("venv/bin/python")
    static let comandoCall = base.appendingPathComponent("call")
    static let suoni = base.appendingPathComponent("suoni")
    static let modello = casa.appendingPathComponent(".cache/whisper-cpp/ggml-large-v3-turbo-q5_0.bin")
    static let whisperServer = "/opt/homebrew/bin/whisper-server"
    static let porta = 8178
}

/// Avvisa quando cambia un file della cartella (impostazioni.json, dizionario.json).
/// Il Notetaker salva con un file temporaneo e una rinomina: si confrontano le date di modifica.
final class Osservatore {
    private let cartella: URL
    private let cambiato: (String) -> Void
    private var sorgente: DispatchSourceFileSystemObject?
    private var date: [String: Date] = [:]

    init(cartella: URL, cambiato: @escaping (String) -> Void) {
        self.cartella = cartella
        self.cambiato = cambiato
        date = leggiDate()
        let fd = open(cartella.path, O_EVTONLY)
        guard fd >= 0 else { return }
        let s = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .rename, .delete],
                                                          queue: .main)
        s.setEventHandler { [weak self] in self?.controlla() }
        s.setCancelHandler { close(fd) }
        s.resume()
        sorgente = s
    }

    deinit { sorgente?.cancel() }

    private func leggiDate() -> [String: Date] {
        let fm = FileManager.default
        var r: [String: Date] = [:]
        for n in (try? fm.contentsOfDirectory(atPath: cartella.path)) ?? [] where n.hasSuffix(".json") {
            if let d = try? fm.attributesOfItem(atPath: cartella.appendingPathComponent(n).path)[.modificationDate] as? Date {
                r[n] = d
            }
        }
        return r
    }

    private func controlla() {
        let nuove = leggiDate()
        for (n, d) in nuove where date[n] != d { cambiato(n) }
        date = nuove
    }
}
