// Tastiera globale: tasto di dettatura (Fn, keyCode 63, oppure Option destro, 61) ed Esc.
// Serve il permesso di Accessibilità. Gli eventi passano tutti tranne Esc quando annulla una dettatura.
import AppKit

final class Tastiera {
    private let tasto: TastoDettatura
    private let quale: () -> String
    private var tap: CFMachPort?
    private var sorveglia: Timer?
    /// Eventi ricevuti, per la diagnosi in stato-pillola.json.
    private(set) var eventi = 0

    /// La tastiera è agganciata e macOS la lascia accesa.
    var attiva: Bool { tap.map { CGEvent.tapIsEnabled(tap: $0) } ?? false }

    init(tasto: TastoDettatura, quale: @escaping () -> String) {
        self.tasto = tasto
        self.quale = quale
    }

    private var tastoAttuale: (codice: Int64, flag: CGEventFlags) {
        quale() == "option_destro" ? (61, .maskAlternate) : (63, .maskSecondaryFn)
    }

    /// false se macOS non concede la tastiera (manca Accessibilità).
    func avvia() -> Bool {
        guard tap == nil else { return true }
        let maschera = (1 << CGEventType.flagsChanged.rawValue) | (1 << CGEventType.keyDown.rawValue)
        let io = Unmanaged.passUnretained(self).toOpaque()
        guard let t = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                                        eventsOfInterest: CGEventMask(maschera), callback: { _, tipo, e, io in
            let s = Unmanaged<Tastiera>.fromOpaque(io!).takeUnretainedValue()
            return s.evento(tipo, e)
        }, userInfo: io) else { return false }
        tap = t
        CFRunLoopAddSource(CFRunLoopGetMain(), CFMachPortCreateRunLoopSource(nil, t, 0), .commonModes)
        CGEvent.tapEnable(tap: t, enable: true)
        return true
    }

    private var ora: Double { Date().timeIntervalSince1970 }

    private func evento(_ tipo: CGEventType, _ e: CGEvent) -> Unmanaged<CGEvent>? {
        eventi += 1
        switch tipo {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            if let t = tap { CGEvent.tapEnable(tap: t, enable: true) }   // macOS l'ha spento: si riaccende
            return Unmanaged.passUnretained(e)
        case .keyDown:
            if e.getIntegerValueField(.eventSourceUserData) == marcaEventiNostri { return Unmanaged.passUnretained(e) }
            if e.getIntegerValueField(.keyboardEventKeycode) == 53, tasto.esc() { return nil }   // Esc consumato
            tasto.altroTasto()
            return Unmanaged.passUnretained(e)
        case .flagsChanged:
            let t = tastoAttuale
            guard e.getIntegerValueField(.keyboardEventKeycode) == t.codice else { return Unmanaged.passUnretained(e) }
            if e.flags.contains(t.flag) {
                tasto.premuto(ora: ora)
                sorvegliaRilascio(t.flag)
            } else if tasto.giu {
                fermaSorveglianza()
                tasto.rilasciato(ora: ora)
            }
            return Unmanaged.passUnretained(e)
        default:
            return Unmanaged.passUnretained(e)
        }
    }

    /// Mentre il tasto è giù: se macOS perde il rilascio, lo si vede dallo stato reale dei tasti.
    private func sorvegliaRilascio(_ flag: CGEventFlags) {
        fermaSorveglianza()
        let t = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
            guard let self else { return }
            guard self.tasto.giu else { self.fermaSorveglianza(); return }
            if !CGEventSource.flagsState(.combinedSessionState).contains(flag) {
                self.fermaSorveglianza()
                self.tasto.rilasciato(ora: self.ora)
            }
        }
        RunLoop.main.add(t, forMode: .common)
        sorveglia = t
    }

    private func fermaSorveglianza() {
        sorveglia?.invalidate()
        sorveglia = nil
    }
}
