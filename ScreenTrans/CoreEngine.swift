import Foundation
import AVFoundation
import AVKit
import Vision
import Network
import UIKit

@MainActor
class TranslationEngine: NSObject, ObservableObject, AVPictureInPictureControllerDelegate, AVPictureInPictureSampleBufferPlaybackDelegate {
    @Published var recognizedText: String = "Chưa có dữ liệu màn hình..."
    @Published var translatedText: String = "Bấm 'Bước 1' mở khung PiP -> 'Bước 2' bật quét màn hình"
    @Published var isServerRunning: Bool = false
    @Published var sourceLang: String = "zh-Hans"
    @Published var cropBottomOnly: Bool = false

    let sampleBufferLayer = AVSampleBufferDisplayLayer()
    private var pipController: AVPictureInPictureController?
    private var audioPlayer: AVAudioPlayer?
    private var tcpListener: NWListener?
    private var lastOCRText: String = ""
    private var pipRefreshTimer: Timer?

    override init() {
        super.init()
        setupSilentAudioKeepAlive()
        setupPiP()
        startLocalTCPServer()
    }

    private func setupSilentAudioKeepAlive() {
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
            try session.setActive(true)

            let silentWavData = createSilentWAVData()
            audioPlayer = try AVAudioPlayer(data: silentWavData)
            audioPlayer?.numberOfLoops = -1
            audioPlayer?.volume = 0.01
            audioPlayer?.play()
        } catch {
            print("Silent Audio Error: \(error)")
        }
    }

    private func createSilentWAVData() -> Data {
        let sampleRate: Int32 = 8000
        let numSamples: Int32 = 8000
        let dataSize = numSamples * 2
        let fileSize = 36 + dataSize

        var data = Data()
        data.append("RIFF".data(using: .ascii)!)
        data.append(withUnsafeBytes(of: fileSize.littleEndian) { Data($0) })
        data.append("WAVEfmt ".data(using: .ascii)!)
        data.append(withUnsafeBytes(of: Int32(16).littleEndian) { Data($0) })
        data.append(withUnsafeBytes(of: Int16(1).littleEndian) { Data($0) })
        data.append(withUnsafeBytes(of: Int16(1).littleEndian) { Data($0) })
        data.append(withUnsafeBytes(of: sampleRate.littleEndian) { Data($0) })
        data.append(withUnsafeBytes(of: (sampleRate * 2).littleEndian) { Data($0) })
        data.append(withUnsafeBytes(of: Int16(2).littleEndian) { Data($0) })
        data.append(withUnsafeBytes(of: Int16(16).littleEndian) { Data($0) })
        data.append("data".data(using: .ascii)!)
        data.append(withUnsafeBytes(of: dataSize.littleEndian) { Data($0) })
        data.append(Data(count: Int(dataSize)))
        return data
    }

    private func setupPiP() {
        sampleBufferLayer.videoGravity = .resizeAspect
        renderTextToPiP(text: translatedText)

        if AVPictureInPictureController.isPictureInPictureSupported() {
            let contentSource = AVPictureInPictureController.ContentSource(
                sampleBufferDisplayLayer: sampleBufferLayer,
                playbackDelegate: self
            )
            pipController = AVPictureInPictureController(contentSource: contentSource)
            pipController?.delegate = self
            pipController?.canStartPictureInPictureAutomaticallyFromInline = true
        }

        pipRefreshTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self = self else { return }
                self.renderTextToPiP(text: self.translatedText)
            }
        }
    }

    func togglePiP() {
        guard let pip = pipController else { return }
        if pip.isPictureInPictureActive {
            pip.stopPictureInPicture()
        } else {
            pip.startPictureInPicture()
        }
    }

    func startLocalTCPServer() {
        do {
            let listener = try NWListener(using: .tcp, on: 9999)
            listener.newConnectionHandler = { [weak self] connection in
                connection.start(queue: .global(qos: .userInitiated))
                self?.receiveFramePacket(from: connection)
            }
            listener.start(queue: .global(qos: .userInitiated))
            isServerRunning = true
            tcpListener = listener
        } catch {
            print("Port 9999 Error: \(error)")
        }
    }

    nonisolated private func receiveFramePacket(from connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 4, maximumLength: 4) { [weak self] headerData, _, _, error in
            guard let header = headerData, header.count == 4, error == nil else {
                connection.cancel()
                return
            }
            let length = Int(header.withUnsafeBytes { $0.load(as: UInt32.self).bigEndian })
            guard length > 0 && length < 5_000_000 else {
                connection.cancel()
                return
            }
            connection.receive(minimumIncompleteLength: length, maximumLength: length) { imageData, _, _, imgError in
                connection.cancel()
                if let data = imageData, imgError == nil {
                    self?.performOCR(on: data)
                }
            }
        }
    }

    nonisolated private func performOCR(on imageData: Data) {
        guard let uiImage = UIImage(data: imageData),
              let cgImage = uiImage.cgImage else { return }

        Task { @MainActor in
            let currentLang = self.sourceLang
            let bottomOnly = self.cropBottomOnly

            Task.detached(priority: .userInitiated) {
                let request = VNRecognizeTextRequest { [weak self] req, _ in
                    guard let observations = req.results as? [VNRecognizedTextObservation] else { return }
                    let lines = observations.compactMap { $0.topCandidates(1).first?.string }
                    let fullText = lines.joined(separator: " ")
                        .trimmingCharacters(in: .whitespacesAndNewlines)

                    guard !fullText.isEmpty else { return }
                    Task { @MainActor in
                        self?.handleRecognizedText(fullText)
                    }
                }
                request.recognitionLevel = .accurate
                request.usesLanguageCorrection = true
                request.recognitionLanguages = [currentLang, "en-US"]
                if bottomOnly {
                    request.regionOfInterest = CGRect(x: 0.0, y: 0.0, width: 1.0, height: 0.55)
                }

                let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
                try? handler.perform([request])
            }
        }
    }

    private func handleRecognizedText(_ newText: String) {
        guard newText != lastOCRText else { return }
        lastOCRText = newText
        recognizedText = newText

        Task {
            if let result = await translateGoogleFree(text: newText) {
                self.translatedText = result
                self.renderTextToPiP(text: result)
            }
        }
    }

    private func translateGoogleFree(text: String) async -> String? {
        guard let encoded = text.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let url = URL(string: "https://translate.googleapis.com/translate_a/single?client=gtx&sl=auto&tl=vi&dt=t&q=\(encoded)") else {
            return nil
        }
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            if let json = try JSONSerialization.jsonObject(with: data) as? [Any],
               let sentences = json.first as? [[Any]] {
                let translated = sentences.compactMap { $0.first as? String }.joined()
                return translated
            }
        } catch {
            return "Lỗi kết nối mạng khi dịch..."
        }
        return nil
    }

    func renderTextToPiP(text: String) {
        let width = 640
        let height = 220
        let size = CGSize(width: width, height: height)

        let renderer = UIGraphicsImageRenderer(size: size)
        let image = renderer.image { ctx in
            UIColor(white: 0.08, alpha: 1.0).setFill()
            ctx.fill(CGRect(origin: .zero, size: size))

            UIColor.systemTeal.setStroke()
            let borderPath = UIBezierPath(rect: CGRect(origin: .zero, size: size).insetBy(dx: 3, dy: 3))
            borderPath.lineWidth = 4
            borderPath.stroke()

            let paragraph = NSMutableParagraphStyle()
            paragraph.alignment = .left
            paragraph.lineBreakMode = .byWordWrapping

            let fontSize: CGFloat = text.count > 140 ? 20 : (text.count > 70 ? 24 : 28)
            let attrs: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: fontSize, weight: .bold),
                .foregroundColor: UIColor.white,
                .paragraphStyle: paragraph
            ]

            let textRect = CGRect(x: 18, y: 14, width: width - 36, height: height - 28)
            (text as NSString).draw(in: textRect, withAttributes: attrs)
        }

        guard let sampleBuffer = createSampleBuffer(from: image) else { return }
        if sampleBufferLayer.status == .failed {
            sampleBufferLayer.flush()
        }
        sampleBufferLayer.enqueue(sampleBuffer)
    }

    private func createSampleBuffer(from image: UIImage) -> CMSampleBuffer? {
        guard let cgImage = image.cgImage else { return nil }
        let width = cgImage.width
        let height = cgImage.height

        var pixelBuffer: CVPixelBuffer?
        let attrs: [CFString: Any] = [
            kCVPixelBufferCGImageCompatibilityKey: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey: true,
            kCVPixelBufferIOSurfacePropertiesKey: [:] as [String: Any]
        ]

        CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32ARGB, attrs as CFDictionary, &pixelBuffer)
        guard let buffer = pixelBuffer else { return nil }

        CVPixelBufferLockBaseAddress(buffer, [])
        let context = CGContext(
            data: CVPixelBufferGetBaseAddress(buffer),
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue
        )
        context?.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
        CVPixelBufferUnlockBaseAddress(buffer, [])

        var formatDesc: CMVideoFormatDescription?
        CMVideoFormatDescriptionCreateForImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: buffer, formatDescriptionOut: &formatDesc)
        guard let desc = formatDesc else { return nil }

        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: 30),
            presentationTimeStamp: CMClockGetTime(CMClockGetHostTimeClock()),
            decodeTimeStamp: .invalid
        )

        var sampleBuffer: CMSampleBuffer?
        CMSampleBufferCreateReadyWithImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: buffer,
            formatDescription: desc,
            sampleTiming: &timing,
            sampleBufferOut: &sampleBuffer
        )
        return sampleBuffer
    }

    nonisolated func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController, setPlaying playing: Bool) {}
    nonisolated func pictureInPictureControllerTimeRangeForPlayback(_ pictureInPictureController: AVPictureInPictureController) -> CMTimeRange {
        return CMTimeRange(start: .negativeInfinity, duration: .positiveInfinity)
    }
    nonisolated func pictureInPictureControllerIsPlaybackPaused(_ pictureInPictureController: AVPictureInPictureController) -> Bool {
        return false
    }
    nonisolated func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController, didTransitionToRenderSize newRenderSize: CMVideoDimensions) {}
    nonisolated func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController, skipByInterval skipInterval: CMTime, completion completionHandler: @escaping () -> Void) {
        completionHandler()
    }
}
