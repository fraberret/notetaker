// whisper-server per la dettatura: acceso alla prima dettatura, spento dopo 15 minuti senza dettature.
// Se sulla porta risponde già un server (lasciato acceso da altri), si usa quello.
import Foundation

final class ServerWhisper {
    static let spegniDopo: TimeInterval = 15 * 60
    private var processo: Process?
    private var controllando = false
    private var timerSpegni: Timer?
    private let base = URL(string: "http://127.0.0.1:\(Percorsi.porta)")!
    private let sessione: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = 60
        c.timeoutIntervalForResource = 60
        return URLSession(configuration: c)
    }()

    func accendi() {
        rinviaSpegnimento()
        guard processo?.isRunning != true, !controllando else { return }
        controllando = true
        var r = URLRequest(url: base)
        r.timeoutInterval = 0.5
        sessione.dataTask(with: r) { [weak self] _, risposta, _ in
            DispatchQueue.main.async {
                guard let self else { return }
                self.controllando = false
                if risposta != nil { return }            // un server risponde già: si usa quello
                self.avviaProcesso()
            }
        }.resume()
    }

    private func avviaProcesso() {
        guard processo?.isRunning != true else { return }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: Percorsi.whisperServer)
        p.arguments = ["-m", Percorsi.modello.path, "-l", "it", "--host", "127.0.0.1", "--port", String(Percorsi.porta)]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do { try p.run(); processo = p } catch { NSLog("Notetaker: whisper-server non partito: \(error)") }
    }

    func rinviaSpegnimento() {
        timerSpegni?.invalidate()
        let t = Timer(timeInterval: Self.spegniDopo, repeats: false) { [weak self] _ in self?.spegni() }
        RunLoop.main.add(t, forMode: .common)
        timerSpegni = t
    }

    /// Spegne solo il server acceso da noi.
    func spegni() {
        timerSpegni?.invalidate(); timerSpegni = nil
        if let p = processo, p.isRunning { p.terminate() }
        processo = nil
    }

    /// Trascrive il WAV; se il server sta partendo riprova ogni secondo fino a 20 volte. `fatto` sul thread principale.
    func trascrivi(file: URL, prompt: String, tentativo: Int = 1, _ fatto: @escaping (String?) -> Void) {
        guard let audio = try? Data(contentsOf: file) else { return fatto(nil) }
        let confine = "notetaker-" + UUID().uuidString
        var r = URLRequest(url: base.appendingPathComponent("inference"))
        r.httpMethod = "POST"
        r.timeoutInterval = 60
        r.setValue("multipart/form-data; boundary=\(confine)", forHTTPHeaderField: "Content-Type")
        let corpo = corpoMultipart(audio: audio, prompt: prompt, confine: confine)
        sessione.uploadTask(with: r, from: corpo) { [weak self] dati, risposta, _ in
            let codice = (risposta as? HTTPURLResponse)?.statusCode ?? 0
            let testo = dati.flatMap { String(data: $0, encoding: .utf8) } ?? ""
            DispatchQueue.main.async {
                if codice == 200 && !testo.isEmpty { return fatto(testo) }
                guard let self, tentativo < 20 else { return fatto(nil) }
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                    self.trascrivi(file: file, prompt: prompt, tentativo: tentativo + 1, fatto)
                }
            }
        }.resume()
    }
}

/// Il pacchetto Python nt (dizionario, storico) con il Python del venv.
enum NtCli {
    /// `fatto` (sul thread principale) riceve l'uscita, o nil se esce con errore o supera `limite` secondi.
    static func esegui(_ arg: [String], input: String? = nil, limite: Double? = nil,
                       _ fatto: @escaping (String?) -> Void) {
        let p = Process()
        p.executableURL = Percorsi.python
        p.arguments = ["-m", "nt.cli"] + arg
        p.currentDirectoryURL = Percorsi.base
        let uscita = Pipe(), ingresso = Pipe()
        p.standardOutput = uscita
        p.standardError = FileHandle.nullDevice
        p.standardInput = input == nil ? FileHandle.nullDevice : ingresso
        var chiamato = false
        func una(_ v: String?) {
            DispatchQueue.main.async {
                guard !chiamato else { return }
                chiamato = true
                fatto(v)
            }
        }
        do { try p.run() } catch { return una(nil) }
        if let input {
            DispatchQueue.global().async {
                try? ingresso.fileHandleForWriting.write(contentsOf: Data(input.utf8))
                try? ingresso.fileHandleForWriting.close()
            }
        }
        DispatchQueue.global().async {
            let d = uscita.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            una(p.terminationStatus == 0 ? String(data: d, encoding: .utf8) : nil)
        }
        if let limite {
            // Oltre il limite si va avanti senza risposta; il processo finisce da solo (come con Hammerspoon).
            DispatchQueue.main.asyncAfter(deadline: .now() + limite) { una(nil) }
        }
    }
}
