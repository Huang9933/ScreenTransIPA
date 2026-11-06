import ReplayKit
import Network
import CoreImage
import UIKit
import ImageIO

class SampleHandler: RPBroadcastSampleHandler {
    private let ciContext = CIContext(options: [.useSoftwareRenderer: false])
    private var lastProcessTime: TimeInterval = 0
    private let throttleInterval: TimeInterval = 1.2

    override func broadcastStarted(withSetupInfo setupInfo: [String : NSObject]?) {
        lastProcessTime = 0
    }

    override func processSampleBuffer(_ sampleBuffer: CMSampleBuffer, with sampleBufferType: RPSampleBufferType) {
        guard sampleBufferType == .video else { return }

        let now = CACurrentMediaTime()
        guard now - lastProcessTime >= throttleInterval else { return }
        lastProcessTime = now

        autoreleasepool {
            guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
            var ciImage = CIImage(cvPixelBuffer: pixelBuffer)

            if let orientationAttachment = CMGetAttachment(sampleBuffer, key: RPVideoSampleOrientationKey as CFString, attachmentModeOut: nil) as? NSNumber,
               let orientation = CGImagePropertyOrientation(rawValue: orientationAttachment.uint32Value) {
                ciImage = ciImage.oriented(orientation)
            }

            let targetWidth: CGFloat = 720.0
            let scale = min(1.0, targetWidth / ciImage.extent.width)
            let scaledImage = ciImage.transformed(by: CGAffineTransform(scaleX: scale, y: scale))

            guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
                  let jpegData = ciContext.jpegRepresentation(
                    of: scaledImage,
                    colorSpace: colorSpace,
                    options: [kCGImageDestinationLossyCompressionQuality as CIImageRepresentationOption: 0.55]
                  ) else { return }

            sendFrameToMainApp(jpegData: jpegData)
        }
    }

    private func sendFrameToMainApp(jpegData: Data) {
        let connection = NWConnection(host: "127.0.0.1", port: 9999, using: .tcp)
        connection.stateUpdateHandler = { state in
            if case .ready = state {
                var length = UInt32(jpegData.count).bigEndian
                var packet = Data(bytes: &length, count: 4)
                packet.append(jpegData)

                connection.send(content: packet, completion: .contentProcessed { _ in
                    connection.cancel()
                })
            } else if case .failed = state {
                connection.cancel()
            }
        }
        connection.start(queue: .global(qos: .userInitiated))
    }
}
