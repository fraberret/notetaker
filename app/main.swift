// Avvio dell'app: il delegato sta in Notetaker.swift.
import AppKit

let app = NSApplication.shared
let delegato = Delegato()
app.delegate = delegato
app.setActivationPolicy(.accessory)  // diventa .regular quando si apre la finestra
app.run()
