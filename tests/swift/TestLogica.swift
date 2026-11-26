// Prove della logica pura: tasto di dettatura, pulizia del testo, app di call, impostazioni, multipart.
import Foundation

/// Timer finti: scattano solo quando la prova fa avanzare il tempo.
final class PianificatoreFinto: Pianificatore {
    final class Voce: Annullabile {
        let quando: Double
        let f: () -> Void
        var annullato = false
        init(_ q: Double, _ f: @escaping () -> Void) { quando = q; self.f = f }
        func annulla() { annullato = true }
    }
    var ora = 0.0
    var voci: [Voce] = []
    func dopo(_ s: Double, _ f: @escaping () -> Void) -> Annullabile {
        let v = Voce(ora + s, f)
        voci.append(v)
        return v
    }
    func avanza(a t: Double) {
        while let v = voci.filter({ !$0.annullato && $0.quando <= t }).min(by: { $0.quando < $1.quando }) {
            voci.removeAll { $0 === v }
            ora = v.quando
            v.f()
        }
        ora = t
    }
}

/// Azioni finte: annotano le chiamate e simulano lo stato della registrazione.
final class AzioniFinte: AzioniTasto {
    var registrando = false
    var maniLibere = false
    var chiamate: [String] = []
    func avviaCattura() { chiamate.append("avvia") }
    func annullaCattura() { chiamate.append("annulla") }
    func conferma(maniLibere m: Bool) {
        chiamate.append("conferma(\(m))")
        registrando = true
        maniLibere = m
    }
    func fine(annulla: Bool) {
        chiamate.append("fine(\(annulla))")
        registrando = false
        maniLibere = false
    }
}

func nuovoTasto() -> (TastoDettatura, AzioniFinte, PianificatoreFinto) {
    let a = AzioniFinte(), p = PianificatoreFinto()
    return (TastoDettatura(azioni: a, pianificatore: p), a, p)
}

func testTasto() {
    // Tenuto oltre 0,3 s: dettatura finché è giù.
    do {
        let (t, a, p) = nuovoTasto()
        t.premuto(ora: 0)
        p.avanza(a: 0.31)
        verifica(a.chiamate == ["avvia", "conferma(false)"], "tenuto: \(a.chiamate)")
        p.avanza(a: 1); t.rilasciato(ora: 1)
        verifica(a.chiamate.last == "fine(false)", "tenuto, rilascio: \(a.chiamate)")
    }
    // Tocco singolo: la cattura si butta dopo la finestra del doppio tocco.
    do {
        let (t, a, p) = nuovoTasto()
        t.premuto(ora: 0)
        p.avanza(a: 0.1); t.rilasciato(ora: 0.1)
        p.avanza(a: 0.9)
        verifica(a.chiamate == ["avvia", "annulla"], "tocco singolo: \(a.chiamate)")
    }
    // Doppio tocco: mani libere; un altro tocco finisce e il suo rilascio non fa nulla.
    do {
        let (t, a, p) = nuovoTasto()
        t.premuto(ora: 0)
        p.avanza(a: 0.1); t.rilasciato(ora: 0.1)
        p.avanza(a: 0.3); t.premuto(ora: 0.3)
        p.avanza(a: 0.4); t.rilasciato(ora: 0.4)
        p.avanza(a: 1.5)
        verifica(a.chiamate.contains("conferma(true)"), "doppio tocco conferma: \(a.chiamate)")
        verifica(!a.chiamate.contains("annulla"), "doppio tocco senza annulla: \(a.chiamate)")
        verifica(!a.chiamate.contains("conferma(false)"), "doppio tocco non è tenuto: \(a.chiamate)")
        verifica(a.registrando && a.maniLibere, "doppio tocco: mani libere attive")
        p.avanza(a: 2); t.premuto(ora: 2)
        verifica(a.chiamate.last == "fine(false)", "tocco che chiude le mani libere: \(a.chiamate)")
        let n = a.chiamate.count
        p.avanza(a: 2.1); t.rilasciato(ora: 2.1)
        p.avanza(a: 3.5)
        verifica(a.chiamate.count == n, "rilascio dopo la chiusura: nessuna chiamata \(a.chiamate)")
    }
    // Fn + altro tasto mentre si detta col tasto tenuto: annullata.
    do {
        let (t, a, p) = nuovoTasto()
        t.premuto(ora: 0)
        p.avanza(a: 0.31)
        t.altroTasto()
        verifica(a.chiamate.last == "fine(true)", "Fn+tasto in dettatura: \(a.chiamate)")
    }
    // Fn + altro tasto prima della conferma: cattura buttata, niente conferma.
    do {
        let (t, a, p) = nuovoTasto()
        t.premuto(ora: 0)
        p.avanza(a: 0.1); t.altroTasto()
        p.avanza(a: 0.5)
        verifica(a.chiamate.contains("annulla"), "Fn+tasto prima: annulla \(a.chiamate)")
        verifica(!a.chiamate.contains { $0.hasPrefix("conferma") }, "Fn+tasto prima: niente conferma \(a.chiamate)")
    }
    // Altro tasto senza Fn giù: nulla.
    do {
        let (t, a, _) = nuovoTasto()
        t.altroTasto()
        verifica(a.chiamate.isEmpty, "altro tasto a riposo: \(a.chiamate)")
    }
    // Esc: consumato e annulla solo se si sta registrando.
    do {
        let (t, a, p) = nuovoTasto()
        verifica(t.esc() == false, "Esc a riposo non consumato")
        verifica(a.chiamate.isEmpty, "Esc a riposo: nessuna chiamata")
        t.premuto(ora: 0)
        p.avanza(a: 0.31)
        verifica(t.esc() == true, "Esc in registrazione consumato")
        verifica(a.chiamate.last == "fine(true)", "Esc in registrazione: \(a.chiamate)")
    }
    // Rilascio perso: una nuova pressione vale come rilascio + pressione.
    do {
        let (t, a, p) = nuovoTasto()
        t.premuto(ora: 0)
        p.avanza(a: 0.2); t.premuto(ora: 0.2)
        verifica(t.giu, "rilascio perso: tasto giù")
        verifica(a.chiamate.filter { $0 == "avvia" }.count == 2, "rilascio perso: due avvii \(a.chiamate)")
        p.avanza(a: 0.6)
        verifica(a.chiamate.last == "conferma(false)", "rilascio perso: poi tenuto \(a.chiamate)")
    }
    // Secondo tocco oltre 0,7 s dall'inizio del primo: non è doppio tocco.
    do {
        let (t, a, p) = nuovoTasto()
        t.premuto(ora: 0)
        p.avanza(a: 0.1); t.rilasciato(ora: 0.1)
        p.avanza(a: 0.8); t.premuto(ora: 0.8)
        p.avanza(a: 0.9); t.rilasciato(ora: 0.9)
        p.avanza(a: 2)
        verifica(!a.chiamate.contains("conferma(true)"), "tocchi lontani: niente mani libere \(a.chiamate)")
    }
    // Registro: al massimo 60 eventi.
    do {
        let (t, _, p) = nuovoTasto()
        for i in 0..<50 {
            let x = Double(i)
            p.avanza(a: x); t.premuto(ora: x)
            p.avanza(a: x + 0.5); t.rilasciato(ora: x + 0.5)
        }
        verifica(!t.registro.isEmpty && t.registro.count <= 60, "registro limitato: \(t.registro.count)")
    }
}

func testTesto() {
    verifica(pulisciTesto("Ehm, allora [musica] il preventivo (ride) è  pronto") == "allora il preventivo è pronto",
             "pulisci: \(pulisciTesto("Ehm, allora [musica] il preventivo (ride) è  pronto"))")
    verifica(pulisciTesto("uhm mmm") == "", "pulisci intercalari: '\(pulisciTesto("uhm mmm"))'")
    verifica(pulisciTesto("Mehmet ha chiamato") == "Mehmet ha chiamato", "pulisci parole intere")
    verifica(pulisciTesto("  ciao\n mondo ") == "ciao mondo", "pulisci spazi")
    verifica(pulisciNomeCall("  Bottega/Quercia: \"Luca\"  ") == "BottegaQuercia Luca",
             "nome call: \(pulisciNomeCall("  Bottega/Quercia: \"Luca\"  "))")
    verifica(pulisciNomeCall("  ") == "Interlocutore", "nome call vuoto")
    verifica(pulisciNomeCall("Marco, Giulia") == "Marco, Giulia", "nome call con virgola")
}

func testAppCall() {
    verifica(riconosciAppCall(titoliBrowser: ["Meet - abc-defg-hij"], bundleAperti: ["net.whatsapp.WhatsApp"]) == "Google Meet",
             "il browser vince")
    verifica(riconosciAppCall(titoliBrowser: ["Posta"], bundleAperti: ["net.whatsapp.WhatsApp"]) == "WhatsApp", "app aperta")
    verifica(riconosciAppCall(titoliBrowser: [], bundleAperti: []) == nil, "nessuna app di call")
    verifica(riconosciAppCall(titoliBrowser: ["Microsoft Teams - riunione"], bundleAperti: []) == "Teams", "Teams nel browser")
}

func testImpostazioni() {
    verifica(Impostazioni.leggi(nil) == Impostazioni(), "impostazioni predefinite")
    let i = Impostazioni.leggi(#"{"tasto":"option_destro","volume":0.2}"#.data(using: .utf8))
    verifica(i.tasto == "option_destro" && i.volume == 0.2 && i.suoni, "impostazioni lette: \(i)")
    let s = Impostazioni.leggi(#"{"tasto":"x","volume":"alto","suoni":1,"secondi_domanda":10,"domanda_call":false,"microfono":"USB"}"#.data(using: .utf8))
    verifica(s.tasto == "fn" && s.volume == 0.45, "impostazioni sbagliate → predefinite: \(s)")
    verifica(s.suoni == true, "suoni deve essere un sì/no, non un numero: \(s)")
    verifica(s.secondiDomanda == 10 && s.domandaCall == false && s.microfono == "USB", "altre impostazioni: \(s)")
    verifica(Impostazioni.leggi("non json".data(using: .utf8)) == Impostazioni(), "impostazioni illeggibili")
}

func testMultipart() {
    let corpo = corpoMultipart(audio: Data([1, 2, 3]), prompt: "Bottega Quercia", confine: "XYZ")
    let s = String(decoding: corpo, as: UTF8.self)
    verifica(s.contains("name=\"temperature\"\r\n\r\n0\r\n"), "multipart temperature")
    verifica(s.contains("name=\"response_format\"\r\n\r\ntext\r\n"), "multipart response_format")
    verifica(s.contains("name=\"prompt\"\r\n\r\nBottega Quercia\r\n"), "multipart prompt")
    verifica(s.contains("name=\"file\"; filename=\"audio.wav\""), "multipart file")
    verifica(s.hasSuffix("--XYZ--\r\n"), "multipart fine")
    verifica(corpo.range(of: Data([1, 2, 3])) != nil, "multipart audio")
}

func testLogica() {
    testTasto()
    testTesto()
    testAppCall()
    testImpostazioni()
    testMultipart()
}
