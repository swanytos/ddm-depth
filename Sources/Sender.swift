import Foundation
import Network

/// Client TCP vers le PC. Une seule image en vol : si l'envoi précédent n'est pas fini,
/// la caméra saute l'image au lieu de l'empiler (pas de retard qui s'accumule).
/// Reconnexion automatique toutes les secondes si le PC n'écoute pas encore.
final class Sender: ObservableObject {
    @Published var state = "Arrêté"
    @Published var sentFps: Double = 0
    @Published var kbps: Double = 0

    private let queue = DispatchQueue(label: "ddm.send", qos: .userInteractive)
    private let lock = NSLock()
    private var connection: NWConnection?
    private var connected = false
    private var inFlight = false
    private var running = false
    private var host = ""
    private var port: UInt16 = 9999
    private var statFrames = 0
    private var statBytes = 0
    private var statStart = CFAbsoluteTimeGetCurrent()

    func start(host: String, port: UInt16) {
        queue.async {
            self.running = true
            self.host = host
            self.port = port
            self.connect()
        }
    }

    func stop() {
        queue.async {
            self.running = false
            self.connection?.cancel()
            self.connection = nil
            self.setConnected(false)
            self.publish("Arrêté")
        }
    }

    /// Appelé depuis la file caméra.
    func canSend() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return connected && !inFlight
    }

    func send(_ data: Data) {
        lock.lock()
        inFlight = true
        lock.unlock()
        queue.async {
            guard let c = self.connection else {
                self.finishSend()
                return
            }
            c.send(content: data, completion: .contentProcessed { error in
                self.finishSend()
                if let error = error {
                    self.publish("Envoi interrompu : \(error.localizedDescription)")
                    self.reconnectSoon()
                } else {
                    self.count(bytes: data.count)
                }
            })
        }
    }

    // MARK: - Connexion

    private func connect() {
        guard running, let p = NWEndpoint.Port(rawValue: port) else { return }
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        let params = NWParameters(tls: nil, tcp: tcp)
        let c = NWConnection(host: NWEndpoint.Host(host), port: p, using: params)
        connection = c
        publish("Connexion à \(host):\(port)…")
        c.stateUpdateHandler = { [weak self] state in
            guard let self = self else { return }
            switch state {
            case .ready:
                self.setConnected(true)
                self.publish("Connecté à \(self.host):\(self.port)")
            case .waiting(let error):
                self.setConnected(false)
                self.publish("PC introuvable (\(error.localizedDescription)), nouvel essai…")
                self.reconnectSoon()
            case .failed(let error):
                self.setConnected(false)
                self.publish("Échec : \(error.localizedDescription)")
                self.reconnectSoon()
            case .cancelled:
                self.setConnected(false)
            default:
                break
            }
        }
        c.start(queue: queue)
    }

    private func reconnectSoon() {
        queue.async {
            self.connection?.stateUpdateHandler = nil
            self.connection?.cancel()
            self.connection = nil
            self.setConnected(false)
            self.queue.asyncAfter(deadline: .now() + 1) {
                if self.running && self.connection == nil { self.connect() }
            }
        }
    }

    private func setConnected(_ value: Bool) {
        lock.lock()
        connected = value
        if !value { inFlight = false }
        lock.unlock()
    }

    private func finishSend() {
        lock.lock()
        inFlight = false
        lock.unlock()
    }

    private func count(bytes: Int) {
        statFrames += 1
        statBytes += bytes
        let now = CFAbsoluteTimeGetCurrent()
        if now - statStart >= 1 {
            let dt = now - statStart
            let f = Double(statFrames) / dt
            let k = Double(statBytes) / dt / 1024
            statFrames = 0
            statBytes = 0
            statStart = now
            DispatchQueue.main.async {
                self.sentFps = f
                self.kbps = k
            }
        }
    }

    private func publish(_ text: String) {
        DispatchQueue.main.async { self.state = text }
    }
}
