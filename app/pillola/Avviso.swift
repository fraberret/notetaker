// Avviso breve al centro dello schermo (come hs.alert): testo chiaro su fondo scuro, sparisce da solo.
import AppKit

enum Avviso {
    private static var pannello: NSPanel?
    private static var timer: Timer?

    static func mostra(_ testo: String, secondi: Double = 3) {
        timer?.invalidate()
        pannello?.orderOut(nil)
        let font = NSFont.systemFont(ofSize: 17, weight: .medium)
        let etichetta = NSTextField(wrappingLabelWithString: testo)
        etichetta.font = font
        etichetta.textColor = NSColor(calibratedWhite: 1, alpha: 0.96)
        etichetta.alignment = .center
        etichetta.preferredMaxLayoutWidth = 520
        let dim = etichetta.fittingSize
        let w = min(560, dim.width + 48), h = dim.height + 32
        let schermo = NSScreen.screens.first?.visibleFrame ?? .zero
        let p = NSPanel(contentRect: NSRect(x: schermo.midX - w / 2, y: schermo.minY + schermo.height * 0.22, width: w, height: h),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.level = .statusBar
        p.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.ignoresMouseEvents = true
        let fondo = NSView(frame: NSRect(x: 0, y: 0, width: w, height: h))
        fondo.wantsLayer = true
        fondo.layer?.backgroundColor = NSColor(calibratedRed: 0.07, green: 0.07, blue: 0.09, alpha: 0.95).cgColor
        fondo.layer?.cornerRadius = 14
        fondo.layer?.borderColor = NSColor(calibratedWhite: 1, alpha: 0.12).cgColor
        fondo.layer?.borderWidth = 1
        etichetta.frame = NSRect(x: (w - dim.width) / 2, y: (h - dim.height) / 2, width: dim.width, height: dim.height)
        fondo.addSubview(etichetta)
        p.contentView = fondo
        p.orderFrontRegardless()
        pannello = p
        let t = Timer(timeInterval: secondi, repeats: false) { _ in
            p.orderOut(nil)
            if pannello === p { pannello = nil }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }
}
