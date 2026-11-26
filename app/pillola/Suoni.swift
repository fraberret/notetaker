// Suoni della pillola (suoni/*.wav): avvio, stop, blocco, incolla, annulla, domanda.
import AppKit

final class Suoni {
    private var suoni: [String: NSSound] = [:]
    private var attivi = true

    init(cartella: URL) {
        for n in ["avvio", "stop", "blocco", "incolla", "annulla", "domanda"] {
            suoni[n] = NSSound(contentsOf: cartella.appendingPathComponent("\(n).wav"), byReference: false)
        }
    }

    func aggiorna(_ i: Impostazioni) {
        attivi = i.suoni
        for s in suoni.values { s.volume = Float(i.volume) }
    }

    func suona(_ nome: String) {
        guard attivi, let s = suoni[nome] else { return }
        s.stop()
        s.play()
    }
}
