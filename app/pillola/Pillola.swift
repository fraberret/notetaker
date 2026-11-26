// La pillola sul bordo destro dello schermo: pannello senza bordi, non attivante, sopra tutte le finestre.
// Stessi stati, misure e colori della pillola di Hammerspoon (hammerspoon/init.lua, "aspetto").
import AppKit

enum StatoPillola: String, CaseIterable {
    case riposo, sopra, ascolto, trascrivo, domanda, call, callSopra
}

enum ZonaPillola { case fondo, detta, registraCall, si, no, stop }

private enum Col {
    static let fondo = NSColor(calibratedRed: 0.07, green: 0.07, blue: 0.09, alpha: 0.95)
    static let bordo = NSColor(calibratedWhite: 1, alpha: 0.12)
    static let testo = NSColor(calibratedWhite: 1, alpha: 0.96)
    static let tenue = NSColor(calibratedWhite: 1, alpha: 0.55)
    static let barra = NSColor(calibratedRed: 0.90, green: 0.92, blue: 1.0, alpha: 0.95)
    static let rosso = NSColor(calibratedRed: 1.0, green: 0.30, blue: 0.30, alpha: 1)
    static let blu = NSColor(calibratedRed: 0.35, green: 0.62, blue: 1.0, alpha: 1)
    static let verde = NSColor(calibratedRed: 0.20, green: 0.76, blue: 0.46, alpha: 1)
    static let grigio = NSColor(calibratedWhite: 1, alpha: 0.14)
    static let lingua = NSColor(calibratedRed: 0.10, green: 0.10, blue: 0.12, alpha: 0.72)
}

private let fraseDomanda = "Call rilevata, vuoi registrare?"
private let nBarre = 13

private func font(_ size: CGFloat, grassetto: Bool = false) -> NSFont {
    grassetto ? .monospacedDigitSystemFont(ofSize: size, weight: .semibold) : .systemFont(ofSize: size)
}

private func larghezzaTesto(_ t: String, _ size: CGFloat, grassetto: Bool = false) -> CGFloat {
    ceil((t as NSString).size(withAttributes: [.font: font(size, grassetto: grassetto)]).width) + 4
}

/// Misure di ogni stato (larghezza, altezza) e colore dello sfondo.
private func misure(_ s: StatoPillola) -> (CGFloat, CGFloat, NSColor) {
    switch s {
    case .riposo: return (10, 54, Col.lingua)
    case .sopra: return (34, 100, Col.fondo)
    case .ascolto: return (26, 108, Col.fondo)
    case .trascrivo: return (26, 64, Col.fondo)
    case .domanda: return (40 + larghezzaTesto(fraseDomanda, 13) + 12 + 46 + 6 + 46 + 10, 46, Col.fondo)
    case .call: return (24, 72, Col.fondo)
    case .callSopra: return (146, 40, Col.fondo)
    }
}

private final class Pannello: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

final class Pillola {
    private(set) var stato: StatoPillola = .riposo
    /// Livello della voce 0…1 per le onde (lo aggiorna la cattura).
    var livello: Double = 0
    var maniLibere = false
    var inizioCall: Date?
    var clic: ((ZonaPillola) -> Void)?
    var clicDestro: (() -> Void)?
    /// Avvisato a ogni cambio di stato (per stato-pillola.json).
    var cambiato: ((StatoPillola) -> Void)?

    private let pannello: Pannello
    private let vista: VistaPillola
    private var fondoAttuale = CGSize(width: 10, height: 54)
    private var transizione: Timer?
    private var animazione: Timer?
    private var osservatori: [NSObjectProtocol] = []

    init() {
        pannello = Pannello(contentRect: NSRect(x: 0, y: 0, width: 10, height: 54),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        pannello.level = .statusBar
        pannello.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        pannello.isOpaque = false
        pannello.backgroundColor = .clear
        pannello.hasShadow = true
        pannello.hidesOnDeactivate = false
        pannello.isFloatingPanel = true
        pannello.becomesKeyOnlyIfNeeded = true
        vista = VistaPillola(frame: NSRect(x: 0, y: 0, width: 10, height: 54))
        pannello.contentView = vista
        vista.pillola = self

        let ws = NSWorkspace.shared.notificationCenter
        osservatori.append(ws.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil,
                                          queue: .main) { [weak self] _ in self?.riposiziona() })
        osservatori.append(NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            guard let s = self else { return }
            s.fondoAttuale = CGSize(width: 10, height: 54)
            s.mostra(s.stato)
        })
    }

    // MARK: stati

    func mostra(_ s: StatoPillola) {
        animazione?.invalidate(); animazione = nil
        stato = s
        let (w, h, colore) = misure(s)
        passa(to: CGSize(width: w, height: h), colore: colore)
        cambiato?(s)
    }

    /// Passaggio animato: lo sfondo si allarga o si stringe verso il bordo destro, poi compare il contenuto.
    private func passa(to nuovo: CGSize, colore: NSColor) {
        transizione?.invalidate(); transizione = nil
        let da = fondoAttuale
        let grande = CGSize(width: max(nuovo.width, da.width), height: max(nuovo.height, da.height))
        pannello.setFrame(cornice(grande), display: false)
        vista.contenuto = false
        vista.coloreFondo = colore
        vista.fondo = da
        vista.needsDisplay = true
        pannello.orderFrontRegardless()
        let t0 = CACurrentMediaTime(), durata = 0.16
        let t = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] timer in
            guard let self else { timer.invalidate(); return }
            let p = min(1, (CACurrentMediaTime() - t0) / durata)
            let e = 1 - pow(1 - p, 3)
            self.vista.fondo = CGSize(width: da.width + (nuovo.width - da.width) * e,
                                      height: da.height + (nuovo.height - da.height) * e)
            self.vista.needsDisplay = true
            if p >= 1 {
                timer.invalidate(); self.transizione = nil
                self.fondoAttuale = nuovo
                self.pannello.setFrame(self.cornice(nuovo), display: false)
                self.vista.fondo = nuovo
                self.vista.contenuto = true
                self.vista.preparaStato(self.stato)
                self.vista.needsDisplay = true
                self.avviaAnimazione()
            }
            self.pannello.invalidateShadow()
        }
        RunLoop.main.add(t, forMode: .common)
        transizione = t
    }

    private func avviaAnimazione() {
        let fps: Double
        switch stato {
        case .ascolto, .trascrivo: fps = 30
        case .call: fps = 20
        case .callSopra: fps = 1
        default: return
        }
        let t = Timer(timeInterval: 1 / fps, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.vista.passo(self.stato)
            self.vista.needsDisplay = true
        }
        RunLoop.main.add(t, forMode: .common)
        animazione = t
    }

    // MARK: posizione

    /// Bordo destro, centro verticale dello schermo in cui si lavora.
    private func cornice(_ d: CGSize) -> NSRect {
        let s = schermoAttivo().visibleFrame
        return NSRect(x: s.maxX - d.width - 8, y: floor(s.midY - d.height / 2), width: d.width, height: d.height)
    }

    func riposiziona() {
        guard transizione == nil else { return }
        pannello.setFrame(cornice(fondoAttuale), display: true)
    }

    /// Schermo che contiene la finestra in primo piano dell'app attiva; se non si trova, quello principale.
    private func schermoAttivo() -> NSScreen {
        let schermi = NSScreen.screens
        guard let principale = schermi.first else { return NSScreen.main! }
        guard let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier,
              let lista = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
                as? [[String: Any]] else { return principale }
        for w in lista {
            guard (w[kCGWindowOwnerPID as String] as? Int32) == pid, (w[kCGWindowLayer as String] as? Int) == 0,
                  let b = w[kCGWindowBounds as String] as? NSDictionary,
                  let r = CGRect(dictionaryRepresentation: b), r.width > 50, r.height > 50 else { continue }
            // Coordinate di CoreGraphics: origine in alto a sinistra dello schermo principale.
            let centro = NSPoint(x: r.midX, y: principale.frame.maxY - r.midY)
            return schermi.first { $0.frame.contains(centro) } ?? principale
        }
        return principale
    }

    // MARK: mouse

    fileprivate func entrato() {
        if stato == .riposo { mostra(.sopra) } else if stato == .call { mostra(.callSopra) }
    }

    fileprivate func uscito() {
        if stato == .sopra { mostra(.riposo) } else if stato == .callSopra { mostra(.call) }
    }

    fileprivate func premuto(_ zona: ZonaPillola, destro: Bool) {
        if destro {
            if stato != .domanda { clicDestro?() }
            return
        }
        clic?(zona)
    }

    // MARK: prove

    /// PNG del contenuto della pillola (senza permessi di registrazione dello schermo).
    func foto(_ url: URL) {
        guard let rep = vista.bitmapImageRepForCachingDisplay(in: vista.bounds) else { return }
        vista.cacheDisplay(in: vista.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
    }

    /// Testo del tempo della call: mm:ss, oppure h:mm:ss oltre l'ora.
    static func tempo(da inizio: Date?, ora: Date = Date()) -> String {
        let s = max(0, Int(ora.timeIntervalSince(inizio ?? ora)))
        if s >= 3600 { return String(format: "%d:%02d:%02d", s / 3600, (s % 3600) / 60, s % 60) }
        return String(format: "%02d:%02d", s / 60, s % 60)
    }
}

// MARK: disegno

private final class VistaPillola: NSView {
    weak var pillola: Pillola?
    var contenuto = false
    var coloreFondo = Col.lingua
    var fondo = CGSize(width: 10, height: 54)
    private var fase: CGFloat = 0
    private var altezze = [CGFloat](repeating: 3, count: nBarre)
    private var tracciamento: NSTrackingArea?

    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let t = tracciamento { removeTrackingArea(t) }
        let t = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                               owner: self, userInfo: nil)
        addTrackingArea(t)
        tracciamento = t
    }

    override func mouseEntered(with e: NSEvent) { pillola?.entrato() }
    override func mouseExited(with e: NSEvent) { pillola?.uscito() }

    override func mouseDown(with e: NSEvent) {
        let p = convert(e.locationInWindow, from: nil)
        pillola?.premuto(zona(p), destro: e.modifierFlags.contains(.control))
    }

    override func rightMouseDown(with e: NSEvent) { pillola?.premuto(.fondo, destro: true) }

    func preparaStato(_ s: StatoPillola) {
        fase = 0
        altezze = [CGFloat](repeating: 3, count: nBarre)
    }

    /// Un fotogramma di animazione.
    func passo(_ s: StatoPillola) {
        switch s {
        case .ascolto:
            fase += 0.28
            let w = bounds.width, liv = CGFloat(pillola?.livello ?? 0)
            for i in 0..<nBarre {
                let k = CGFloat(i + 1)
                let centro = 1 - abs(k - CGFloat(nBarre + 1) / 2) / (CGFloat(nBarre) / 2 + 1)
                let onda = 0.6 + 0.4 * sin(fase + k * 0.75)
                let meta = 3 + (w - 9) * liv * onda * (0.35 + 0.65 * centro)
                altezze[i] += (min(w - 8, meta) - altezze[i]) * 0.35
            }
        case .trascrivo: fase += 0.22
        case .call: fase += 0.12
        default: break
        }
    }

    /// Zona sotto il punto, nelle coordinate della vista (origine in alto a sinistra).
    func zona(_ p: NSPoint) -> ZonaPillola {
        guard let s = pillola?.stato, contenuto else { return .fondo }
        let w = bounds.width
        switch s {
        case .sopra: return p.y < 51 ? .detta : (p.y >= 52 ? .registraCall : .fondo)
        case .domanda:
            let xs = w - 46 - 6 - 46 - 10
            if NSRect(x: xs, y: 9, width: 46, height: 28).contains(p) { return .si }
            if NSRect(x: xs + 52, y: 9, width: 46, height: 28).contains(p) { return .no }
        case .call: if NSRect(x: 3, y: 42, width: 18, height: 18).contains(p) { return .stop }
        case .callSopra: if NSRect(x: 110, y: 6, width: 28, height: 28).contains(p) { return .stop }
        default: break
        }
        return .fondo
    }

    override func draw(_ r: NSRect) {
        NSColor.clear.set()
        bounds.fill()
        let W = bounds.width, H = bounds.height
        // Sfondo ancorato a destra e centrato in verticale.
        let f = NSRect(x: W - fondo.width + 0.5, y: (H - fondo.height) / 2 + 0.5,
                       width: fondo.width - 1, height: fondo.height - 1)
        let raggio = min(fondo.width, fondo.height) / 2
        let sfondo = NSBezierPath(roundedRect: f, xRadius: raggio, yRadius: raggio)
        coloreFondo.setFill(); sfondo.fill()
        Col.bordo.setStroke(); sfondo.lineWidth = 1; sfondo.stroke()
        guard contenuto, let p = pillola else { return }
        switch p.stato {
        case .riposo:
            rett(NSRect(x: 3.5, y: 18, width: 3, height: 18), Col.tenue, 1.5)
        case .sopra:
            microfono(17, 28, Col.testo, 1)
            rett(NSRect(x: 9, y: 51, width: 16, height: 1), Col.grigio)
            let anello = NSBezierPath(ovalIn: NSRect(x: 17 - 8, y: 74 - 8, width: 16, height: 16))
            anello.lineWidth = 1.6; Col.rosso.setStroke(); anello.stroke()
            cerchio(17, 74, 4.5, Col.rosso)
        case .ascolto:
            let raggioPunto: CGFloat = p.maniLibere ? 3.5 + 1.1 * (0.5 + 0.5 * sin(fase * 0.6)) : 4
            cerchio(W / 2, 15, raggioPunto, p.maniLibere ? Col.blu : Col.rosso)
            for i in 0..<nBarre {
                let a = altezze[i]
                rett(NSRect(x: W / 2 - a / 2, y: 28 + CGFloat(i) * 6, width: a, height: 2.5), Col.barra, 1.25)
            }
        case .trascrivo:
            for i in 1...3 {
                let v = 0.5 + 0.5 * sin(fase - CGFloat(i) * 0.9)
                let raggio = fase == 0 ? 3 : 2.2 + 1.3 * v
                let colore = fase == 0 ? Col.testo : NSColor(calibratedWhite: 1, alpha: 0.35 + 0.6 * v)
                cerchio(W / 2, H / 2 + CGFloat(i - 2) * 12, raggio, colore)
            }
        case .domanda:
            microfono(22, H / 2, Col.rosso, 0.85)
            let tw = larghezzaTesto(fraseDomanda, 13)
            testo(fraseDomanda, NSRect(x: 40, y: 0, width: tw, height: H), 13, false, .left)
            let xs = 40 + tw + 12
            rett(NSRect(x: xs, y: 9, width: 46, height: 28), Col.verde, 14)
            testo("Sì", NSRect(x: xs, y: 9, width: 46, height: 28), 13, true, .center)
            rett(NSRect(x: xs + 52, y: 9, width: 46, height: 28), Col.grigio, 14)
            testo("No", NSRect(x: xs + 52, y: 9, width: 46, height: 28), 13, true, .center)
        case .call:
            let alfa = fase == 0 ? 1 : 0.4 + 0.6 * (0.5 + 0.5 * sin(fase))
            cerchio(W / 2, 20, 4.5, Col.rosso.withAlphaComponent(alfa))
            rett(NSRect(x: 3, y: 42, width: 18, height: 18), Col.grigio, 9)
            rett(NSRect(x: 8.5, y: 47.5, width: 7, height: 7), Col.testo, 1.5)
        case .callSopra:
            cerchio(20, H / 2, 4.5, Col.rosso)
            testo("REC " + Pillola.tempo(da: p.inizioCall), NSRect(x: 32, y: 0, width: 76, height: H), 13, true, .left)
            rett(NSRect(x: 110, y: 6, width: 28, height: 28), Col.grigio, 14)
            rett(NSRect(x: 119, y: 15, width: 10, height: 10), Col.rosso, 2)
        }
    }

    private func rett(_ r: NSRect, _ c: NSColor, _ raggio: CGFloat = 0) {
        c.setFill()
        NSBezierPath(roundedRect: r, xRadius: raggio, yRadius: raggio).fill()
    }

    private func cerchio(_ x: CGFloat, _ y: CGFloat, _ r: CGFloat, _ c: NSColor) {
        c.setFill()
        NSBezierPath(ovalIn: NSRect(x: x - r, y: y - r, width: 2 * r, height: 2 * r)).fill()
    }

    /// Testo centrato in verticale nel rettangolo.
    private func testo(_ t: String, _ r: NSRect, _ size: CGFloat, _ grassetto: Bool, _ allinea: NSTextAlignment) {
        let par = NSMutableParagraphStyle(); par.alignment = allinea
        let f = font(size, grassetto: grassetto)
        let attr: [NSAttributedString.Key: Any] = [.font: f, .foregroundColor: Col.testo, .paragraphStyle: par]
        let h = ceil(f.ascender - f.descender)
        (t as NSString).draw(in: NSRect(x: r.minX, y: r.minY + (r.height - h) / 2, width: r.width, height: h),
                             withAttributes: attr)
    }

    /// Icona del microfono (centro cx, cy), come in init.lua.
    private func microfono(_ cx: CGFloat, _ cy: CGFloat, _ c: NSColor, _ k: CGFloat) {
        rett(NSRect(x: cx - 3.5 * k, y: cy - 8 * k, width: 7 * k, height: 11 * k), c, 3.5 * k)
        let arco = NSBezierPath()
        let ac = NSPoint(x: cx, y: cy - 1 * k), ar = 6 * k
        for g in stride(from: 0.0, through: 180.0, by: 6.0) {
            let a = CGFloat(g) * .pi / 180
            let pt = NSPoint(x: ac.x + ar * cos(a), y: ac.y + ar * sin(a))
            if g == 0 { arco.move(to: pt) } else { arco.line(to: pt) }
        }
        arco.lineWidth = 1.6 * k; arco.lineCapStyle = .round
        c.setStroke(); arco.stroke()
        rett(NSRect(x: cx - 0.8 * k, y: cy + 5 * k, width: 1.6 * k, height: 3 * k), c)
        rett(NSRect(x: cx - 3.5 * k, y: cy + 7.4 * k, width: 7 * k, height: 1.6 * k), c, 0.8 * k)
    }
}
