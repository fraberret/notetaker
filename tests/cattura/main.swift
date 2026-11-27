import AVFoundation
import Foundation
let mic = CommandLine.arguments[1] == "-" ? "" : CommandLine.arguments[1]
let f = URL(fileURLWithPath: NSTemporaryDirectory() + "prova-cattura.wav")
let c = Cattura(file: f, microfono: mic)
var primo = false, errore = false
c.primoAudio = { primo = true; print("PRIMO AUDIO dopo", String(format: "%.2f", Date().timeIntervalSince(t0)), "s") }
c.errore = { errore = true; print("ERRORE della cattura") }
let t0 = Date()
c.avvia()
RunLoop.main.run(until: Date().addingTimeInterval(4))
c.ferma { dim in print("ferma: byte", dim, "primo", primo, "errore", errore); exit(0) }
RunLoop.main.run(until: Date().addingTimeInterval(3))
print("ferma non ha risposto"); exit(1)
