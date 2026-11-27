// Cattura del microfono per la dettatura: WAV PCM 16 bit, 16 kHz, mono, con il livello della voce per le onde.
// Tutto il lavoro sul motore audio sta su una coda sua, così il thread principale (tastiera, pillola) non aspetta.
import AVFoundation
import CoreAudio

enum DispositiviAudio {
    private static func indirizzo(_ sel: AudioObjectPropertySelector,
                                  _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal)
        -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: sel, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }

    static func predefinitoIngresso() -> AudioDeviceID? {
        var a = indirizzo(kAudioHardwarePropertyDefaultInputDevice)
        var id = AudioDeviceID(0)
        var n = UInt32(MemoryLayout<AudioDeviceID>.size)
        let r = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &a, 0, nil, &n, &id)
        return r == noErr && id != 0 ? id : nil
    }

    /// Dispositivi con almeno un canale di ingresso, con il loro nome.
    static func ingressi() -> [(AudioDeviceID, String)] {
        var a = indirizzo(kAudioHardwarePropertyDevices)
        var n: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &a, 0, nil, &n) == noErr else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: Int(n) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &a, 0, nil, &n, &ids) == noErr else { return [] }
        return ids.compactMap { id in
            var s = indirizzo(kAudioDevicePropertyStreams, kAudioObjectPropertyScopeInput)
            var dim: UInt32 = 0
            guard AudioObjectGetPropertyDataSize(id, &s, 0, nil, &dim) == noErr, dim > 0 else { return nil }
            var nome: Unmanaged<CFString>?
            var na = indirizzo(kAudioObjectPropertyName)
            var dn = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
            guard AudioObjectGetPropertyData(id, &na, 0, nil, &dn, &nome) == noErr, let v = nome?.takeRetainedValue()
            else { return nil }
            return (id, v as String)
        }
    }

    static func ingresso(nome: String) -> AudioDeviceID? {
        ingressi().first { $0.1 == nome }?.0
    }

    static func nome(_ id: AudioDeviceID) -> String {
        ingressi().first { $0.0 == id }?.1 ?? "predefinito"
    }

    /// Il microfono del Mac (trasporto "built-in" con canali di ingresso).
    static func integrato() -> AudioDeviceID? {
        ingressi().first { id, _ in
            var a = indirizzo(kAudioDevicePropertyTransportType)
            var t: UInt32 = 0
            var n = UInt32(MemoryLayout<UInt32>.size)
            return AudioObjectGetPropertyData(id, &a, 0, nil, &n, &t) == noErr && t == kAudioDeviceTransportTypeBuiltIn
        }?.0
    }

    /// Microfono da usare secondo l'impostazione (come Wispr Flow, 27/11/2026):
    /// "" = microfono del Mac, "auto" = quello predefinito del sistema (nil), un nome = quel dispositivo.
    /// Se il dispositivo scelto non c'è si usa il microfono del Mac, mai il predefinito: un paio di AirPods
    /// collegate da sole ma non indossate diventano il predefinito e non sentono niente.
    static func scelto(_ impostazione: String) -> AudioDeviceID? {
        switch impostazione {
        case "auto": return nil
        case "": return integrato()
        default: return ingresso(nome: impostazione) ?? integrato()
        }
    }

    /// Nome del microfono che si sta usando davvero, per gli avvisi.
    static func nomeInUso(_ impostazione: String) -> String {
        if let id = scelto(impostazione) { return nome(id) }
        return predefinitoIngresso().map(nome) ?? "predefinito"
    }

    /// Il dispositivo è in uso da qualche programma (anche da noi).
    static func inUso(_ id: AudioDeviceID) -> Bool {
        var a = indirizzo(kAudioDevicePropertyDeviceIsRunningSomewhere)
        var v: UInt32 = 0
        var n = UInt32(MemoryLayout<UInt32>.size)
        return AudioObjectGetPropertyData(id, &a, 0, nil, &n, &v) == noErr && v != 0
    }
}

final class Cattura {
    enum Errore: Error { case formato, file }

    let file: URL
    private let microfono: String
    /// Livello 0…1 di ogni blocco (sul thread principale).
    var livello: ((Double) -> Void)?
    /// Primo blocco con audio vero (sul thread principale).
    var primoAudio: (() -> Void)?
    /// Il microfono non parte o sparisce (sul thread principale).
    var errore: (() -> Void)?

    // Una coda per ogni cattura: se CoreAudio si blocca dentro un avvio (27/11/2026, cambio di microfono
    // con AirPods), le dettature dopo non restano in fila dietro quella bloccata.
    private let coda = DispatchQueue(label: "notetaker.cattura", qos: .userInteractive)
    private var motore: AVAudioEngine?
    private var scrittura: AVAudioFile?
    private var convertitore: AVAudioConverter?
    private var arrivato = false
    private var finita = false
    private var osservatore: NSObjectProtocol?
    private var riavvii = 0

    init(file: URL, microfono: String) {
        self.file = file
        self.microfono = microfono
    }

    /// Accende il microfono (in background). Gli errori arrivano con `errore`.
    func avvia() {
        coda.async { [self] in
            do { try avviaSullaCoda() } catch {
                NSLog("Notetaker: cattura non avviata: \(error)")
                pulisciSullaCoda()
                DispatchQueue.main.async { self.errore?() }
            }
        }
    }

    private func avviaSullaCoda() throws {
        let m = AVAudioEngine()
        let ingresso = m.inputNode
        // Si cambia dispositivo solo se serve: il cambio fa partire un "configuration changed" all'avvio.
        if var dev = DispositiviAudio.scelto(microfono), dev != DispositiviAudio.predefinitoIngresso(),
           let au = ingresso.audioUnit {
            AudioUnitSetProperty(au, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
                                 &dev, UInt32(MemoryLayout<AudioDeviceID>.size))
        }
        let formatoIn = ingresso.inputFormat(forBus: 0)
        guard formatoIn.sampleRate > 0, formatoIn.channelCount > 0,
              let formatoOut = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1,
                                             interleaved: false),
              let conv = AVAudioConverter(from: formatoIn, to: formatoOut) else { throw Errore.formato }
        conv.downmix = true
        let impostazioni: [String: Any] = [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 16000,
                                           AVNumberOfChannelsKey: 1, AVLinearPCMBitDepthKey: 16,
                                           AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false]
        let f: AVAudioFile
        do {
            f = try AVAudioFile(forWriting: file, settings: impostazioni, commonFormat: .pcmFormatFloat32,
                                interleaved: false)
        } catch { throw Errore.file }
        scrittura = f
        convertitore = conv
        motore = m
        ingresso.installTap(onBus: 0, bufferSize: 1024, format: formatoIn) { [weak self] buf, _ in
            self?.coda.async { self?.blocco(buf, formatoOut) }
        }
        osservatore = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: m,
                                                             queue: nil) { [weak self] _ in
            guard let self else { return }
            self.coda.async {
                guard !self.finita else { return }
                // Prima del primo audio è quasi sempre l'avvio stesso (cambio di dispositivo, cuffie): si
                // riaccende il microfono, al massimo due volte (27/11/2026: la dettatura non partiva più).
                if !self.arrivato && self.riavvii < 2 {
                    self.riavvii += 1
                    NSLog("Notetaker: microfono riconfigurato all'avvio, lo riaccendo (\(self.riavvii))")
                    self.spegniMotore()
                    do { try self.avviaSullaCoda(); return } catch {
                        NSLog("Notetaker: cattura non riavviata: \(error)")
                    }
                }
                NSLog("Notetaker: il microfono è cambiato durante la dettatura")
                self.pulisciSullaCoda()
                DispatchQueue.main.async { self.errore?() }
            }
        }
        m.prepare()
        try m.start()
    }

    private func blocco(_ buf: AVAudioPCMBuffer, _ formatoOut: AVAudioFormat) {
        guard !finita, let conv = convertitore, let f = scrittura, let dati = buf.floatChannelData else { return }
        let n = Int(buf.frameLength)
        guard n > 0 else { return }
        var somma: Float = 0, vero = false
        let c = dati[0]
        for i in 0..<n { let x = c[i]; somma += x * x; if x != 0 { vero = true } }
        let db = 20 * log10(Double(sqrt(somma / Float(n))))
        let v = livelloDaDecibel(db)
        let primo = vero && !arrivato
        if vero { arrivato = true }
        DispatchQueue.main.async {
            self.livello?(v)
            if primo { self.primoAudio?() }
        }
        let capacita = AVAudioFrameCount(Double(n) * 16000 / buf.format.sampleRate) + 32
        guard let out = AVAudioPCMBuffer(pcmFormat: formatoOut, frameCapacity: capacita) else { return }
        var dato = false
        var err: NSError?
        conv.convert(to: out, error: &err) { _, stato in
            if dato { stato.pointee = .noDataNow; return nil }
            dato = true
            stato.pointee = .haveData
            return buf
        }
        if err == nil, out.frameLength > 0 { try? f.write(from: out) }
    }

    /// Spegne il motore senza chiudere la cattura (per riaccenderlo).
    private func spegniMotore() {
        if let o = osservatore { NotificationCenter.default.removeObserver(o); osservatore = nil }
        if let m = motore {
            m.inputNode.removeTap(onBus: 0)
            m.stop()
        }
        motore = nil
    }

    private func pulisciSullaCoda() {
        finita = true
        if let o = osservatore { NotificationCenter.default.removeObserver(o); osservatore = nil }
        if let m = motore {
            m.inputNode.removeTap(onBus: 0)
            m.stop()
        }
        motore = nil
        convertitore = nil
        scrittura = nil          // chiude il file
    }

    /// Spegne il microfono e chiude il file; `fatto` riceve i byte scritti (sul thread principale).
    func ferma(_ fatto: @escaping (Int) -> Void) {
        coda.async { [self] in
            pulisciSullaCoda()
            let dim = (try? FileManager.default.attributesOfItem(atPath: file.path)[.size] as? Int) ?? 0
            DispatchQueue.main.async { fatto(dim) }
        }
    }

    /// Spegne il microfono e cancella il file.
    func butta() {
        coda.async { [self] in
            pulisciSullaCoda()
            try? FileManager.default.removeItem(at: file)
        }
    }
}
