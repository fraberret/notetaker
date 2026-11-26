// registra: registra l'audio di sistema (la call) e il microfono su due file separati.
// Uso: registra <cartella-di-uscita>
// Si ferma con SIGINT o SIGTERM e chiude i file in modo pulito.
// Scrive: sistema.caf, microfono.caf, inizio.json (istante del primo campione di ciascuna traccia).

import AVFoundation
import CoreMedia
import Foundation
import ScreenCaptureKit

func log(_ s: String) {
    FileHandle.standardError.write((s + "\n").data(using: .utf8)!)
}

final class Registratore: NSObject, SCStreamOutput, SCStreamDelegate {
    let cartella: URL
    var stream: SCStream?
    var fileSistema: AVAudioFile?
    var fileMicrofono: AVAudioFile?
    var inizioSistema: Double?
    var inizioMicrofono: Double?
    let coda = DispatchQueue(label: "registra.audio")

    init(cartella: URL) {
        self.cartella = cartella
    }

    func avvia() async throws {
        let contenuto = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        guard let schermo = contenuto.displays.first else {
            throw NSError(domain: "registra", code: 1, userInfo: [NSLocalizedDescriptionKey: "Nessuno schermo trovato"])
        }
        let filtro = SCContentFilter(display: schermo, excludingWindows: [])
        let config = SCStreamConfiguration()
        config.capturesAudio = true
        config.excludesCurrentProcessAudio = true
        config.captureMicrophone = true
        config.sampleRate = 48000
        config.channelCount = 1
        // Il video non serve: immagine minuscola e un fotogramma ogni tanto.
        config.width = 2
        config.height = 2
        config.minimumFrameInterval = CMTime(value: 1, timescale: 1)
        config.queueDepth = 5

        let s = SCStream(filter: filtro, configuration: config, delegate: self)
        try s.addStreamOutput(self, type: .screen, sampleHandlerQueue: coda)
        try s.addStreamOutput(self, type: .audio, sampleHandlerQueue: coda)
        try s.addStreamOutput(self, type: .microphone, sampleHandlerQueue: coda)
        try await s.startCapture()
        stream = s
        log("REGISTRAZIONE AVVIATA")
    }

    func ferma() async {
        if let s = stream {
            try? await s.stopCapture()
        }
        coda.sync {
            self.fileSistema = nil
            self.fileMicrofono = nil
            let info: [String: Any] = [
                "inizio_sistema": self.inizioSistema as Any,
                "inizio_microfono": self.inizioMicrofono as Any,
            ]
            if let dati = try? JSONSerialization.data(withJSONObject: info, options: [.prettyPrinted]) {
                try? dati.write(to: self.cartella.appendingPathComponent("inizio.json"))
            }
        }
        log("REGISTRAZIONE FERMATA")
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sb: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio || type == .microphone, sb.isValid else { return }
        guard let buffer = Self.pcm(da: sb) else { return }
        let tempo = CMSampleBufferGetPresentationTimeStamp(sb).seconds
        do {
            if type == .audio {
                if fileSistema == nil {
                    fileSistema = try AVAudioFile(forWriting: cartella.appendingPathComponent("sistema.caf"),
                                                  settings: buffer.format.settings)
                    inizioSistema = tempo
                }
                try fileSistema?.write(from: buffer)
            } else {
                if fileMicrofono == nil {
                    fileMicrofono = try AVAudioFile(forWriting: cartella.appendingPathComponent("microfono.caf"),
                                                    settings: buffer.format.settings)
                    inizioMicrofono = tempo
                }
                try fileMicrofono?.write(from: buffer)
            }
        } catch {
            log("Errore di scrittura: \(error)")
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        log("La registrazione si è interrotta: \(error.localizedDescription)")
        exit(2)
    }

    static func pcm(da sb: CMSampleBuffer) -> AVAudioPCMBuffer? {
        guard let fd = CMSampleBufferGetFormatDescription(sb),
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(fd),
              let formato = AVAudioFormat(streamDescription: asbd) else { return nil }
        let campioni = AVAudioFrameCount(CMSampleBufferGetNumSamples(sb))
        guard campioni > 0, let buf = AVAudioPCMBuffer(pcmFormat: formato, frameCapacity: campioni) else { return nil }
        buf.frameLength = campioni
        let stato = CMSampleBufferCopyPCMDataIntoAudioBufferList(
            sb, at: 0, frameCount: Int32(campioni), into: buf.mutableAudioBufferList)
        return stato == noErr ? buf : nil
    }
}

let argomenti = CommandLine.arguments
guard argomenti.count == 2 else {
    log("Uso: registra <cartella-di-uscita>")
    exit(64)
}
let cartella = URL(fileURLWithPath: argomenti[1], isDirectory: true)
try? FileManager.default.createDirectory(at: cartella, withIntermediateDirectories: true)

let registratore = Registratore(cartella: cartella)

signal(SIGINT, SIG_IGN)
signal(SIGTERM, SIG_IGN)
var sorgenti: [DispatchSourceSignal] = []
for segnale in [SIGINT, SIGTERM] {
    let s = DispatchSource.makeSignalSource(signal: segnale, queue: .main)
    s.setEventHandler {
        Task {
            await registratore.ferma()
            exit(0)
        }
    }
    s.resume()
    sorgenti.append(s)
}

Task {
    do {
        try await registratore.avvia()
    } catch {
        log("Impossibile avviare la registrazione: \(error.localizedDescription)")
        log("Controlla in Impostazioni di Sistema > Privacy e sicurezza: Registrazione schermo e audio di sistema, e Microfono.")
        exit(1)
    }
}

dispatchMain()
