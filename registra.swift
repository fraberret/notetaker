// registra: registra l'audio di sistema (la call) e il microfono su due file separati.
// Uso: registra <cartella-di-uscita>
// Si ferma con SIGINT o SIGTERM e chiude i file in modo pulito.
// Scrive: sistema.caf, microfono.caf, inizio.json (istante del primo campione di ciascuna traccia).
//
// Audio di sistema: ScreenCaptureKit. Microfono: AVAudioEngine, in due modi.
// Durante una chiamata WhatsApp (o con un'altra app che usa la modalità voce, voice processing) macOS
// passa alle altre app un microfono quasi muto (picco 0,0003 contro 0,002-0,016 del rumore di una stanza)
// e il microfono di ScreenCaptureKit non manda niente (call del 27/11/2026). Solo chi usa anche lui la
// modalità voce riceve la voce vera. La modalità voce però abbassa le altre app (-8 dB misurati anche con
// il ducking al minimo), quindi: si parte col microfono normale e si passa alla modalità voce solo se il
// microfono resta sotto la soglia del muto per 3 secondi. I buchi (passaggio, cuffie attaccate) si
// riempiono di silenzio, così la traccia resta allineata a quella di sistema.
// "MICROFONO MUTO" nel log se non arriva audio per 10 s, se è zero assoluto per 20 s o se la modalità
// voce non parte quando serve: l'app lo legge e avvisa.

import AVFoundation
import CoreMedia
import Foundation
import ScreenCaptureKit

func log(_ s: String) {
    FileHandle.standardError.write((s + "\n").data(using: .utf8)!)
}

/// Microfono con AVAudioEngine: canale 0, convertito in mono float32 a 48 kHz.
final class Microfono {
    let url: URL
    let coda: DispatchQueue
    var engine: AVAudioEngine?
    var file: AVAudioFile?
    var inizio: Double?
    var scritti: Int64 = 0
    let formatoFile = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48000, channels: 1, interleaved: false)!
    var modalitaVoce = false
    var osservatore: NSObjectProtocol?
    var generazione = 0   // i buffer di un motore spento si scartano

    var avvio = Date()
    var ultimoBuffer: Date?
    var ultimoNonZero: Date?
    var mutoDa: Date?
    var avvisato = false
    var picchiCanali: [Float] = []
    var diagnosiScritta = false
    static let sogliaMuto: Float = 0.0008
    static let secondiPerPassare: Double = 3

    init(url: URL, coda: DispatchQueue) {
        self.url = url
        self.coda = coda
    }

    /// Sulla coda.
    func avvia(voce: Bool = false) {
        do {
            try prepara(voce: voce)
        } catch {
            if voce {
                log("Modalità voce non partita (\(error.localizedDescription)): resto col microfono normale")
                avvisa("la modalità voce non parte")
                do { try prepara(voce: false) } catch { log("Microfono non avviato: \(error.localizedDescription)") }
            } else {
                log("Microfono non avviato: \(error.localizedDescription)")
            }
        }
        avvio = Date()
        mutoDa = nil
    }

    private func prepara(voce: Bool) throws {
        let e = AVAudioEngine()
        let ingresso = e.inputNode
        if voce {
            try ingresso.setVoiceProcessingEnabled(true)
            if #available(macOS 14.0, *) {
                ingresso.voiceProcessingOtherAudioDuckingConfiguration =
                    AVAudioVoiceProcessingOtherAudioDuckingConfiguration(enableAdvancedDucking: false, duckingLevel: .min)
            }
            _ = e.outputNode
        }
        let formato = ingresso.outputFormat(forBus: 0)
        guard formato.sampleRate > 0, formato.channelCount > 0 else {
            throw NSError(domain: "registra", code: 3, userInfo: [NSLocalizedDescriptionKey: "Nessun microfono"])
        }
        let mono = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: formato.sampleRate, channels: 1, interleaved: false)!
        let conv = formato.sampleRate == formatoFile.sampleRate ? nil : AVAudioConverter(from: mono, to: formatoFile)
        generazione += 1
        let gen = generazione
        ingresso.installTap(onBus: 0, bufferSize: 4800, format: formato) { [weak self] buf, quando in
            self?.coda.async {
                guard let self = self, gen == self.generazione else { return }
                self.ricevi(buf, quando: quando, mono: mono, conv: conv)
            }
        }
        e.prepare()
        do {
            try e.start()
        } catch {
            ingresso.removeTap(onBus: 0)
            if voce { try? ingresso.setVoiceProcessingEnabled(false) }
            throw error
        }
        engine = e
        modalitaVoce = voce
        picchiCanali = Array(repeating: 0, count: Int(formato.channelCount))
        diagnosiScritta = false
        log("Microfono avviato: \(voce ? "modalità voce" : "normale"), \(formato.channelCount) canali a \(Int(formato.sampleRate)) Hz")
        // Cuffie attaccate o staccate: il motore si ferma e va rifatto, nello stesso modo.
        osservatore = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: e, queue: nil) { [weak self] _ in
            self?.coda.async {
                guard let self = self, gen == self.generazione else { return }
                log("Microfono cambiato: riavvio")
                let voce = self.modalitaVoce
                self.spegni()
                self.avvia(voce: voce)
            }
        }
    }

    private func avvisa(_ motivo: String) {
        guard !avvisato else { return }
        avvisato = true
        log("MICROFONO MUTO: \(motivo)")
    }

    private func ricevi(_ buf: AVAudioPCMBuffer, quando: AVAudioTime, mono: AVAudioFormat, conv: AVAudioConverter?) {
        guard let dati = buf.floatChannelData, buf.frameLength > 0 else { return }
        let n = Int(buf.frameLength)
        let adesso = Date()
        ultimoBuffer = adesso
        var picco: Float = 0
        for c in 0..<min(Int(buf.format.channelCount), picchiCanali.count) {
            var m: Float = 0
            for k in 0..<n { m = max(m, abs(dati[c][k])) }
            picchiCanali[c] = max(picchiCanali[c], m)
            if c == 0 { picco = m }
        }
        if picco > 0.00001 { ultimoNonZero = adesso }
        if !diagnosiScritta && adesso.timeIntervalSince(avvio) > 10 {
            diagnosiScritta = true
            log("Picchi del microfono nei primi 10 s (\(modalitaVoce ? "modalità voce" : "normale")), per canale: "
                + picchiCanali.map { String(format: "%.4f", $0) }.joined(separator: " "))
        }

        guard let m = AVAudioPCMBuffer(pcmFormat: mono, frameCapacity: AVAudioFrameCount(n)) else { return }
        m.frameLength = AVAudioFrameCount(n)
        m.floatChannelData![0].update(from: dati[0], count: n)
        var uscita = m
        if let conv = conv {
            let capienza = AVAudioFrameCount(Double(n) * formatoFile.sampleRate / mono.sampleRate) + 32
            guard let out = AVAudioPCMBuffer(pcmFormat: formatoFile, frameCapacity: capienza) else { return }
            var dato = false
            var errore: NSError?
            conv.convert(to: out, error: &errore) { _, stato in
                if dato { stato.pointee = .noDataNow; return nil }
                dato = true
                stato.pointee = .haveData
                return m
            }
            if errore != nil || out.frameLength == 0 { return }
            uscita = out
        }
        let t = quando.isHostTimeValid ? AVAudioTime.seconds(forHostTime: quando.hostTime)
                                       : CMClockGetTime(CMClockGetHostTimeClock()).seconds
        do {
            if file == nil {
                file = try AVAudioFile(forWriting: url, settings: formatoFile.settings,
                                       commonFormat: .pcmFormatFloat32, interleaved: false)
                inizio = t
            }
            // Buco di oltre 50 ms rispetto all'orologio (motore rifatto): silenzio per restare allineati.
            if let i0 = inizio {
                let atteso = Int64((t - i0) * formatoFile.sampleRate)
                var mancano = atteso - scritti
                while mancano > 2400 {
                    let k = AVAudioFrameCount(min(mancano, 48000))
                    if let z = AVAudioPCMBuffer(pcmFormat: formatoFile, frameCapacity: k) {
                        z.frameLength = k
                        memset(z.floatChannelData![0], 0, Int(k) * MemoryLayout<Float>.size)
                        try file?.write(from: z)
                        scritti += Int64(k)
                    }
                    mancano -= Int64(k)
                }
            }
            try file?.write(from: uscita)
            scritti += Int64(uscita.frameLength)
        } catch {
            log("Errore di scrittura del microfono: \(error)")
        }

        // Microfono normale quasi muto per 3 secondi: un'app di chiamata ha preso la modalità voce.
        if !modalitaVoce {
            if picco < Self.sogliaMuto {
                if mutoDa == nil { mutoDa = adesso }
                if let d = mutoDa, adesso.timeIntervalSince(d) >= Self.secondiPerPassare {
                    log("Microfono normale muto da \(Int(Self.secondiPerPassare)) s: passo alla modalità voce")
                    spegni()
                    avvia(voce: true)
                }
            } else {
                mutoDa = nil
            }
        }
    }

    /// Ogni secondo, sulla coda.
    func controlla() {
        let adesso = Date()
        if adesso.timeIntervalSince(ultimoBuffer ?? avvio) > 10 { avvisa("nessun audio dal microfono da 10 s") }
        if adesso.timeIntervalSince(ultimoNonZero ?? avvio) > 20 { avvisa("microfono a zero da 20 s") }
    }

    func spegni() {
        generazione += 1
        if let o = osservatore { NotificationCenter.default.removeObserver(o) }
        osservatore = nil
        if let e = engine {
            e.inputNode.removeTap(onBus: 0)
            e.stop()
            if modalitaVoce { try? e.inputNode.setVoiceProcessingEnabled(false) }
        }
        engine = nil
    }

    func chiudi() {
        spegni()
        file = nil
    }
}

final class Registratore: NSObject, SCStreamOutput, SCStreamDelegate {
    let cartella: URL
    var stream: SCStream?
    var fileSistema: AVAudioFile?
    var inizioSistema: Double?
    let coda = DispatchQueue(label: "registra.audio")
    lazy var microfono = Microfono(url: cartella.appendingPathComponent("microfono.caf"), coda: coda)
    var timer: DispatchSourceTimer?

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
        try await s.startCapture()
        stream = s
        coda.sync { microfono.avvia() }
        let t = DispatchSource.makeTimerSource(queue: coda)
        t.schedule(deadline: .now() + 1, repeating: 1)
        t.setEventHandler { [weak self] in self?.microfono.controlla() }
        t.resume()
        timer = t
        log("REGISTRAZIONE AVVIATA")
    }

    func ferma() async {
        if let s = stream {
            try? await s.stopCapture()
        }
        coda.sync {
            self.timer?.cancel()
            self.microfono.chiudi()
            self.fileSistema = nil
            let info: [String: Any] = [
                "inizio_sistema": self.inizioSistema as Any,
                "inizio_microfono": self.microfono.inizio as Any,
            ]
            if let dati = try? JSONSerialization.data(withJSONObject: info, options: [.prettyPrinted]) {
                try? dati.write(to: self.cartella.appendingPathComponent("inizio.json"))
            }
        }
        log("REGISTRAZIONE FERMATA")
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sb: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio, sb.isValid else { return }
        guard let buffer = Self.pcm(da: sb) else { return }
        let tempo = CMSampleBufferGetPresentationTimeStamp(sb).seconds
        do {
            if fileSistema == nil {
                fileSistema = try AVAudioFile(forWriting: cartella.appendingPathComponent("sistema.caf"),
                                              settings: buffer.format.settings)
                inizioSistema = tempo
            }
            try fileSistema?.write(from: buffer)
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
