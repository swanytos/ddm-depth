import AVFoundation
import SwiftUI
import UIKit

struct ContentView: View {
    @StateObject private var camera = Camera()
    @StateObject private var sender = Sender()
    @AppStorage("host") private var host = "192.168.129.102"
    @AppStorage("port") private var port = "9999"
    @AppStorage("quality") private var quality = 0.7
    @AppStorage("filter") private var filterDepth = true
    @AppStorage("preview") private var showPreview = true
    @State private var running = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text("DDM Depth").font(.title2).bold()

                if showPreview {
                    PreviewView(session: camera.session)
                        .frame(height: 240)
                        .frame(maxWidth: .infinity)
                        .background(Color.black)
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                }

                Group {
                    Text("IP du PC")
                    TextField("192.168.x.x", text: $host)
                        .keyboardType(.numbersAndPunctuation)
                        .textFieldStyle(.roundedBorder)
                        .autocorrectionDisabled(true)
                    Text("Port")
                    TextField("9999", text: $port)
                        .keyboardType(.numberPad)
                        .textFieldStyle(.roundedBorder)
                }
                .disabled(running)

                Toggle("Profondeur lissée (trous bouchés)", isOn: $filterDepth).disabled(running)
                Toggle("Aperçu à l'écran", isOn: $showPreview)
                VStack(alignment: .leading) {
                    Text("Qualité JPEG : \(Int(quality * 100)) %")
                    Slider(value: $quality, in: 0.3...0.95, step: 0.05)
                        .onChange(of: quality) { value in camera.setQuality(value) }
                }

                Button(action: toggle) {
                    Text(running ? "Arrêter" : "Démarrer")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(running ? Color.red : Color.blue)
                        .foregroundColor(.white)
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text("Caméra : \(camera.status) — \(String(format: "%.0f", camera.fps)) im/s")
                    Text("Réseau : \(sender.state)")
                    Text("Envoyé : \(String(format: "%.0f", sender.sentFps)) im/s, \(String(format: "%.0f", sender.kbps)) Ko/s")
                    Text(camera.info).foregroundColor(.secondary)
                }
                .font(.footnote)

                Text("Garde l'app ouverte au premier plan pendant l'envoi. Sur le PC : Lanceur > Tracking > Vue iPhone.")
                    .font(.footnote)
                    .foregroundColor(.secondary)
            }
            .padding()
        }
        .onAppear {
            let s = sender
            camera.canSend = { [weak s] in s?.canSend() ?? false }
            camera.onPacket = { [weak s] data in s?.send(data) }
        }
    }

    private func toggle() {
        if running {
            camera.stop()
            sender.stop()
            UIApplication.shared.isIdleTimerDisabled = false
        } else {
            sender.start(host: host.trimmingCharacters(in: .whitespaces), port: UInt16(port) ?? 9999)
            camera.start(filterDepth: filterDepth, jpegQuality: quality)
            UIApplication.shared.isIdleTimerDisabled = true
        }
        running.toggle()
    }
}

final class PreviewUIView: UIView {
    override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
    var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
}

struct PreviewView: UIViewRepresentable {
    let session: AVCaptureSession

    func makeUIView(context: Context) -> PreviewUIView {
        let view = PreviewUIView()
        view.previewLayer.session = session
        view.previewLayer.videoGravity = .resizeAspect
        return view
    }

    func updateUIView(_ uiView: PreviewUIView, context: Context) {}
}
