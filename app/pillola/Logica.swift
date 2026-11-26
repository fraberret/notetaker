// Logica pura della pillola (solo Foundation, testata da tests/test_swift.sh):
// tasto di dettatura, pulizia del testo, riconoscimento delle app di call, corpo della richiesta a Whisper.
import Foundation

// MARK: timer

protocol Annullabile { func annulla() }

protocol Pianificatore {
    /// Esegue `f` dopo `s` secondi sul thread principale, salvo annullamento.
    func dopo(_ s: Double, _ f: @escaping () -> Void) -> Annullabile
}

final class PianificatoreVero: Pianificatore {
    final class Voce: Annullabile {
        var timer: Timer?
        func annulla() { timer?.invalidate(); timer = nil }
    }
    func dopo(_ s: Double, _ f: @escaping () -> Void) -> Annullabile {
        let v = Voce()
        let t = Timer(timeInterval: s, repeats: false) { _ in v.timer = nil; f() }
        v.timer = t
        RunLoop.main.add(t, forMode: .common)
        return v
    }
}

// MARK: tasto di dettatura

/// Quello che il tasto fa fare alla dettatura.
protocol AzioniTasto: AnyObject {
    /// C'è una dettatura confermata in corso.
    var registrando: Bool { get }
    var maniLibere: Bool { get }
    /// Accende il microfono subito alla pressione (non fa nulla se è già acceso).
    func avviaCattura()
    /// Butta una cattura non confermata, senza suoni.
    func annullaCattura()
    /// La cattura diventa una dettatura (tasto tenuto o mani libere).
    func conferma(maniLibere: Bool)
    /// Fine della dettatura confermata: trascrive, oppure annulla.
    func fine(annulla: Bool)
}

/// Fn (o Option destro) tenuto = dettatura finché è giù; due tocchi = mani libere, un altro tocco finisce;
/// Esc annulla; Fn + altro tasto non è dettatura. Stesso comportamento della pillola di Hammerspoon.
final class TastoDettatura {
    static let tieni = 0.3
    static let doppio = 0.7

    private let azioni: AzioniTasto
    private let pianificatore: Pianificatore
    private(set) var giu = false
    private var da = 0.0                     // inizio della pressione; -1 = pressione che ha chiuso le mani libere
    private var ultimoTocco = -Double.infinity
    private var altro = false
    private var pressione = 0
    private var timerTieni: Annullabile?
    private var timerDoppio: Annullabile?
    private(set) var registro: [String] = []

    init(azioni: AzioniTasto, pianificatore: Pianificatore) {
        self.azioni = azioni
        self.pianificatore = pianificatore
    }

    private func annota(_ e: String, _ ora: Double? = nil) {
        let t = ora ?? Date().timeIntervalSince1970
        registro.append(String(format: "%.3f %@", t.truncatingRemainder(dividingBy: 1000), e))
        if registro.count > 60 { registro.removeFirst(registro.count - 60) }
    }

    func premuto(ora: Double) {
        annota("giù", ora)
        if giu {                              // macOS a volte perde il rilascio di un tocco rapidissimo
            annota("su perso: nuova pressione", ora)
            rilasciato(ora: ora)
        }
        giu = true
        da = ora
        altro = false
        pressione += 1
        if azioni.registrando && azioni.maniLibere {
            azioni.fine(annulla: false)
            da = -1
            annota("fine mani libere", ora)
            return
        }
        azioni.avviaCattura()                 // il microfono si accende subito
        let id = pressione
        timerTieni?.annulla()
        timerTieni = pianificatore.dopo(Self.tieni) { [weak self] in
            guard let s = self, s.pressione == id, s.giu, !s.altro, !s.azioni.registrando else { return }
            s.annota("confermata: tasto tenuto")
            s.azioni.conferma(maniLibere: false)
        }
    }

    func rilasciato(ora: Double) {
        guard giu else { return }
        giu = false
        annota("su", ora)
        if da < 0 { return }                  // pressione che ha chiuso le mani libere
        if azioni.registrando && !azioni.maniLibere {
            azioni.fine(annulla: altro)       // fine della dettatura col tasto tenuto
        } else if !altro && ora - da < Self.tieni {
            if da - ultimoTocco < Self.doppio {
                ultimoTocco = -Double.infinity
                annota("doppio tocco", ora)
                azioni.conferma(maniLibere: true)
            } else {
                ultimoTocco = da
                annota("primo tocco", ora)
                let id = pressione
                timerDoppio?.annulla()
                timerDoppio = pianificatore.dopo(Self.doppio) { [weak self] in
                    guard let s = self, s.pressione == id, !s.giu else { return }
                    s.annota("nessun secondo tocco")
                    s.azioni.annullaCattura()
                }
            }
        } else {
            azioni.annullaCattura()
        }
    }

    /// Un altro tasto premuto: se Fn è giù, non è una dettatura.
    func altroTasto() {
        guard giu else { return }
        altro = true
        annota("altro tasto")
        if azioni.registrando && !azioni.maniLibere { azioni.fine(annulla: true) } else { azioni.annullaCattura() }
    }

    /// Esc: annulla la dettatura in corso. Ritorna true se l'evento va consumato.
    func esc() -> Bool {
        guard azioni.registrando else { return false }
        annota("Esc")
        azioni.fine(annulla: true)
        return true
    }
}

// MARK: testo

private let intercalari = ["ehm", "ehmm", "uhm", "mmm", "ehh"]
private let reIntercalari: NSRegularExpression = {
    let parole = intercalari.flatMap { [$0, $0.prefix(1).uppercased() + $0.dropFirst()] }
    return try! NSRegularExpression(pattern: "(?<!\\p{L})(?:" + parole.joined(separator: "|") + ")(?!\\p{L}),?\\s*")
}()

private func sostituisci(_ t: String, _ re: NSRegularExpression, _ con: String = "") -> String {
    re.stringByReplacingMatches(in: t, range: NSRange(t.startIndex..., in: t), withTemplate: con)
}

private let reParentesi = try! NSRegularExpression(pattern: "\\[[^\\]]*\\]|\\([^)]*\\)")
private let reSpazi = try! NSRegularExpression(pattern: "\\s+")

/// Toglie le annotazioni di Whisper ([musica], (ride)), gli intercalari e gli spazi doppi.
func pulisciTesto(_ t: String) -> String {
    var s = sostituisci(t, reParentesi)
    s = sostituisci(s, reIntercalari)
    s = sostituisci(s, reSpazi, " ")
    return s.trimmingCharacters(in: .whitespacesAndNewlines)
}

/// Nome dell'interlocutore senza i caratteri vietati nei nomi dei file; vuoto = "Interlocutore".
func pulisciNomeCall(_ n: String) -> String {
    let vietati = Set("$`\"\\/:*?<>|#^[]")
    let s = String(n.filter { !vietati.contains($0) }).trimmingCharacters(in: .whitespacesAndNewlines)
    return s.isEmpty ? "Interlocutore" : s
}

// MARK: app di call

/// Browser in cui cercare una call dal titolo delle finestre.
let browserCall = ["Google Chrome", "Safari", "Arc", "Firefox", "Microsoft Edge", "Brave Browser"]
private let titoliCall = [("Meet", "Google Meet"), ("Zoom", "Zoom"), ("Microsoft Teams", "Teams"),
                          ("Teams", "Teams"), ("Whereby", "Whereby"), ("Jitsi", "Jitsi")]
private let appCall = [("us.zoom.xos", "Zoom"), ("com.microsoft.teams2", "Teams"), ("com.microsoft.teams", "Teams"),
                       ("com.apple.FaceTime", "FaceTime"), ("net.whatsapp.WhatsApp", "WhatsApp"),
                       ("com.tinyspeck.slackmacgap", "Slack"), ("com.hnc.Discord", "Discord"),
                       ("ru.keepcoder.Telegram", "Telegram"), ("com.cisco.webexmeetingsapp", "Webex")]

/// Nome dell'app di call aperta: prima i titoli delle finestre dei browser, poi le app.
func riconosciAppCall(titoliBrowser: [String], bundleAperti: Set<String>) -> String? {
    for t in titoliBrowser {
        for (parte, nome) in titoliCall where t.contains(parte) { return nome }
    }
    for (id, nome) in appCall where bundleAperti.contains(id) { return nome }
    return nil
}

// MARK: Whisper

/// Corpo multipart per /inference di whisper-server.
func corpoMultipart(audio: Data, prompt: String, confine: String) -> Data {
    var d = Data()
    func campo(_ nome: String, _ valore: String) {
        d.append("--\(confine)\r\nContent-Disposition: form-data; name=\"\(nome)\"\r\n\r\n\(valore)\r\n".data(using: .utf8)!)
    }
    d.append("--\(confine)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"audio.wav\"\r\nContent-Type: audio/wav\r\n\r\n"
        .data(using: .utf8)!)
    d.append(audio)
    d.append("\r\n".data(using: .utf8)!)
    campo("response_format", "text")
    campo("temperature", "0")
    campo("prompt", prompt)
    d.append("--\(confine)--\r\n".data(using: .utf8)!)
    return d
}

// MARK: livello della voce

/// Livello 0…1 per le onde della pillola da un RMS in decibel (−58 dB = silenzio, −20 dB = voce piena).
func livelloDaDecibel(_ db: Double) -> Double {
    guard db.isFinite else { return 0 }
    return max(0, min(1, (db + 58) / 38))
}
