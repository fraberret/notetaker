// Comandi notetaker:// per le prove automatiche della pillola, e file stato-pillola.json che le prove leggono.
//   open -g "notetaker://senza-incolla?secondi=120"   sempre accettato: per N secondi la dettatura non incolla
//   e solo mentre quella scadenza è attiva:
//   notetaker://mostra?stato=domanda · notetaker://foto?file=/tmp/p.png · notetaker://detta · fine · annulla
// La scadenza è un orario e non un sì/no, così una prova dimenticata non blocca la dettatura.
import Foundation

final class Comandi {
    private let pillola: Pillola
    /// Fino a quando la dettatura non incolla (e i comandi di prova sono accettati).
    private(set) var senzaIncollaFino: Date?
    var detta: (() -> Void)?
    var fine: (() -> Void)?
    var annulla: (() -> Void)?
    /// Altri campi per stato-pillola.json (ultimoIncollato, registroTasto, callInCorso).
    var extra: (() -> [String: Any])?
    let fileStato = Percorsi.base.appendingPathComponent("stato-pillola.json")

    init(pillola: Pillola) { self.pillola = pillola }

    var inProva: Bool { (senzaIncollaFino ?? .distantPast) > Date() }

    func gestisci(_ url: URL) {
        guard url.scheme == "notetaker" else { return }
        let comando = url.host ?? ""
        var p: [String: String] = [:]
        for q in URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? [] { p[q.name] = q.value ?? "" }
        if comando == "senza-incolla" {
            let s = min(3600, max(0, Double(p["secondi"] ?? "") ?? 0))
            senzaIncollaFino = s > 0 ? Date().addingTimeInterval(s) : nil
        } else if inProva {
            switch comando {
            case "mostra": if let s = StatoPillola(rawValue: p["stato"] ?? "") { pillola.mostra(s) }
            case "foto": if let f = p["file"], f.hasPrefix("/") { pillola.foto(URL(fileURLWithPath: f)) }
            case "detta": detta?()
            case "fine": fine?()
            case "annulla": annulla?()
            default: break
            }
        }
        scriviStato()
    }

    func scriviStato() {
        var d: [String: Any] = ["stato": pillola.stato.rawValue,
                                "senzaIncollaFino": senzaIncollaFino.map { $0.timeIntervalSince1970 } ?? NSNull()]
        for (k, v) in extra?() ?? [:] { d[k] = v }
        guard let dati = try? JSONSerialization.data(withJSONObject: d, options: [.prettyPrinted, .sortedKeys]) else { return }
        try? dati.write(to: fileStato, options: .atomic)
    }
}
