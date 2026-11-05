import AVFoundation
import CoreImage
import ImageIO
import UIKit

/// Caméra avant TrueDepth : image couleur + profondeur synchronisées, encodées en un paquet par image.
///
/// Paquet (little-endian), 60 octets d'en-tête puis les données :
///   "DDMD" | u32 version=1 | u64 horodatage µs | u32 index
///   | u32 rgb_l | u32 rgb_h | u32 prof_l | u32 prof_h
///   | f32 fx | f32 fy | f32 cx | f32 cy   (pixels de l'image couleur, 0 = inconnu)
///   | u32 taille_jpeg | u32 taille_prof
///   | JPEG | profondeur float16 en mètres (prof_l * prof_h * 2 octets)
final class Camera: NSObject, ObservableObject, AVCaptureDataOutputSynchronizerDelegate {
    @Published var status = "Arrêtée"
    @Published var fps: Double = 0
    @Published var info = ""

    let session = AVCaptureSession()
    private let videoOutput = AVCaptureVideoDataOutput()
    private let depthOutput = AVCaptureDepthDataOutput()
    private var synchronizer: AVCaptureDataOutputSynchronizer?
    private let queue = DispatchQueue(label: "ddm.camera", qos: .userInteractive)
    private let ciContext = CIContext()
    private let colorSpace = CGColorSpaceCreateDeviceRGB()
    private var configured = false
    private var device: AVCaptureDevice?
    private var depthCandidates: [AVCaptureDevice.Format] = []
    private var quality: CGFloat = 0.7
    private var frameIndex: UInt32 = 0
    private var fpsCount = 0
    private var fpsStart = CFAbsoluteTimeGetCurrent()

    /// Appelé sur la file caméra : faut-il encoder cette image ? (faux si l'envoi précédent n'est pas fini)
    var canSend: () -> Bool = { false }
    /// Paquet prêt à envoyer.
    var onPacket: (Data) -> Void = { _ in }

    // MARK: - Commandes (appelées depuis l'interface)

    /// smallDepth : profondeur 320x240 au lieu de 640x480 (4x moins de données sur le Wi-Fi).
    func start(filterDepth: Bool, smallDepth: Bool, jpegQuality: Double) {
        queue.async {
            self.quality = CGFloat(jpegQuality)
            do {
                if !self.configured {
                    try self.configure()
                    self.configured = true
                }
                try self.selectDepthFormat(small: smallDepth)
                self.depthOutput.isFilteringEnabled = filterDepth
                self.session.startRunning()
                self.publish(status: "En marche")
            } catch {
                self.publish(status: "Erreur : \(error)")
            }
        }
    }

    func stop() {
        queue.async {
            self.session.stopRunning()
            self.publish(status: "Arrêtée")
        }
    }

    func setQuality(_ q: Double) {
        queue.async { self.quality = CGFloat(q) }
    }

    // MARK: - Configuration

    enum CamError: Error, CustomStringConvertible {
        case noTrueDepth, noDepthFormat, cannotAdd(String)
        var description: String {
            switch self {
            case .noTrueDepth: return "pas de caméra TrueDepth"
            case .noDepthFormat: return "pas de format 640x480 avec profondeur"
            case .cannotAdd(let what): return "impossible d'ajouter \(what)"
            }
        }
    }

    private func configure() throws {
        guard let device = AVCaptureDevice.default(.builtInTrueDepthCamera, for: .video, position: .front) else {
            throw CamError.noTrueDepth
        }
        let formats = device.formats.filter { f in
            let d = CMVideoFormatDescriptionGetDimensions(f.formatDescription)
            return d.width == 640 && d.height == 480 && !f.supportedDepthDataFormats.isEmpty
        }
        guard let format = formats.first else { throw CamError.noDepthFormat }
        let depthFormats = format.supportedDepthDataFormats
        let float16 = depthFormats.filter {
            CMFormatDescriptionGetMediaSubType($0.formatDescription) == kCVPixelFormatType_DepthFloat16
        }
        depthCandidates = (float16.isEmpty ? depthFormats : float16).sorted {
            CMVideoFormatDescriptionGetDimensions($0.formatDescription).width
                < CMVideoFormatDescriptionGetDimensions($1.formatDescription).width
        }
        self.device = device

        session.beginConfiguration()
        session.sessionPreset = .inputPriority
        let input = try AVCaptureDeviceInput(device: device)
        guard session.canAddInput(input) else { throw CamError.cannotAdd("l'entrée caméra") }
        session.addInput(input)

        videoOutput.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        videoOutput.alwaysDiscardsLateVideoFrames = true
        guard session.canAddOutput(videoOutput) else { throw CamError.cannotAdd("la sortie vidéo") }
        session.addOutput(videoOutput)

        depthOutput.alwaysDiscardsLateDepthData = true
        guard session.canAddOutput(depthOutput) else { throw CamError.cannotAdd("la sortie profondeur") }
        session.addOutput(depthOutput)
        depthOutput.connection(with: .depthData)?.isEnabled = true

        try device.lockForConfiguration()
        device.activeFormat = format
        if let df = depthCandidates.last { device.activeDepthDataFormat = df }
        device.unlockForConfiguration()
        session.commitConfiguration()

        synchronizer = AVCaptureDataOutputSynchronizer(dataOutputs: [videoOutput, depthOutput])
        synchronizer?.setDelegate(self, queue: queue)
    }

    /// Choisit la plus petite (small) ou la plus grande profondeur Float16 disponible.
    private func selectDepthFormat(small: Bool) throws {
        guard let device = device,
              let df = small ? depthCandidates.first : depthCandidates.last,
              device.activeDepthDataFormat != df else { return }
        session.beginConfiguration()
        try device.lockForConfiguration()
        device.activeDepthDataFormat = df
        device.unlockForConfiguration()
        session.commitConfiguration()
    }

    // MARK: - Images

    func dataOutputSynchronizer(_ synchronizer: AVCaptureDataOutputSynchronizer,
                                didOutput collection: AVCaptureSynchronizedDataCollection) {
        guard let v = collection.synchronizedData(for: videoOutput) as? AVCaptureSynchronizedSampleBufferData,
              !v.sampleBufferWasDropped,
              let d = collection.synchronizedData(for: depthOutput) as? AVCaptureSynchronizedDepthData,
              !d.depthDataWasDropped,
              let pixels = CMSampleBufferGetImageBuffer(v.sampleBuffer) else { return }

        countFps()
        guard canSend() else { return }   // l'envoi précédent n'est pas fini : on saute (latence minimale)

        var depth = d.depthData
        if depth.depthDataType != kCVPixelFormatType_DepthFloat16 {
            depth = depth.converting(toDepthDataType: kCVPixelFormatType_DepthFloat16)
        }
        let depthMap = depth.depthDataMap

        let image = CIImage(cvPixelBuffer: pixels)
        let options = [CIImageRepresentationOption(rawValue: kCGImageDestinationLossyCompressionQuality as String): quality]
        guard let jpeg = ciContext.jpegRepresentation(of: image, colorSpace: colorSpace, options: options) else { return }

        let rgbW = CVPixelBufferGetWidth(pixels)
        let rgbH = CVPixelBufferGetHeight(pixels)
        let dW = CVPixelBufferGetWidth(depthMap)
        let dH = CVPixelBufferGetHeight(depthMap)
        let depthBytes = copyDepth(depthMap, width: dW, height: dH)

        var fx: Float = 0, fy: Float = 0, cx: Float = 0, cy: Float = 0
        if let cal = depth.cameraCalibrationData {
            let m = cal.intrinsicMatrix
            let ref = cal.intrinsicMatrixReferenceDimensions
            if ref.width > 0 {
                let s = Float(rgbW) / Float(ref.width)
                fx = m.columns.0.x * s
                fy = m.columns.1.y * s
                cx = m.columns.2.x * s
                cy = m.columns.2.y * s
            }
        }

        let pts = CMSampleBufferGetPresentationTimeStamp(v.sampleBuffer)
        let micros = UInt64(max(0, CMTimeGetSeconds(pts)) * 1_000_000)
        frameIndex &+= 1

        var packet = Data(capacity: 60 + jpeg.count + depthBytes.count)
        packet.append(contentsOf: Array("DDMD".utf8))
        packet.appendLE(UInt32(1))
        packet.appendLE(micros)
        packet.appendLE(frameIndex)
        packet.appendLE(UInt32(rgbW))
        packet.appendLE(UInt32(rgbH))
        packet.appendLE(UInt32(dW))
        packet.appendLE(UInt32(dH))
        packet.appendLE(fx.bitPattern)
        packet.appendLE(fy.bitPattern)
        packet.appendLE(cx.bitPattern)
        packet.appendLE(cy.bitPattern)
        packet.appendLE(UInt32(jpeg.count))
        packet.appendLE(UInt32(depthBytes.count))
        packet.append(jpeg)
        packet.append(depthBytes)
        onPacket(packet)

        if frameIndex % 30 == 1 {
            let text = "couleur \(rgbW)x\(rgbH) | profondeur \(dW)x\(dH) | \(jpeg.count / 1024) Ko"
            DispatchQueue.main.async { self.info = text }
        }
    }

    private func copyDepth(_ map: CVPixelBuffer, width: Int, height: Int) -> Data {
        CVPixelBufferLockBaseAddress(map, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(map, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(map) else { return Data() }
        let rowBytes = CVPixelBufferGetBytesPerRow(map)
        let lineBytes = width * 2
        var out = Data(capacity: lineBytes * height)
        for row in 0..<height {
            out.append(base.advanced(by: row * rowBytes).assumingMemoryBound(to: UInt8.self), count: lineBytes)
        }
        return out
    }

    private func countFps() {
        fpsCount += 1
        let now = CFAbsoluteTimeGetCurrent()
        if now - fpsStart >= 1 {
            let value = Double(fpsCount) / (now - fpsStart)
            fpsCount = 0
            fpsStart = now
            DispatchQueue.main.async { self.fps = value }
        }
    }

    private func publish(status: String) {
        DispatchQueue.main.async { self.status = status }
    }
}

extension Data {
    mutating func appendLE<T: FixedWidthInteger>(_ value: T) {
        var v = value.littleEndian
        Swift.withUnsafeBytes(of: &v) { append(contentsOf: $0) }
    }
}
