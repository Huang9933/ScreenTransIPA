import SwiftUI
import ReplayKit

@main
struct ScreenTransApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}

struct ContentView: View {
    @StateObject private var engine = TranslationEngine()

    var body: some View {
        NavigationView {
            ScrollView {
                VStack(spacing: 18) {
                    PiPPreviewContainer(layer: engine.sampleBufferLayer)
                        .frame(height: 130)
                        .cornerRadius(12)
                        .padding(.horizontal)

                    VStack(alignment: .leading, spacing: 10) {
                        Text("Cấu hình nhận diện chữ (OCR)")
                            .font(.headline)

                        Picker("Ngôn ngữ gốc", selection: $engine.sourceLang) {
                            Text("Tiếng Trung (Giản)").tag("zh-Hans")
                            Text("Tiếng Trung (Phồn)").tag("zh-Hant")
                            Text("Tiếng Anh").tag("en-US")
                            Text("Tiếng Nhật").tag("ja-JP")
                        }
                        .pickerStyle(.segmented)

                        Toggle("Chỉ quét nửa dưới màn hình", isOn: $engine.cropBottomOnly)
                            .font(.subheadline)
                    }
                    .padding()
                    .background(Color(.secondarySystemBackground))
                    .cornerRadius(12)
                    .padding(.horizontal)

                    VStack(spacing: 12) {
                        Button(action: {
                            engine.togglePiP()
                        }) {
                            Label("Bước 1: Bật / Tắt cửa sổ nổi PiP", systemImage: "pip.enter")
                                .font(.headline)
                                .frame(maxWidth: .infinity)
                                .padding()
                                .background(Color.blue)
                                .foregroundColor(.white)
                                .cornerRadius(12)
                        }

                        HStack {
                            BroadcastPickerRepresentable()
                                .frame(width: 50, height: 50)
                            Text("Bước 2: Bấm nút tròn bên trái -> Chọn 'ScreenTrans Broadcast' -> Bắt đầu truyền phát.")
                                .font(.footnote)
                                .foregroundColor(.secondary)
                        }
                        .padding(10)
                        .background(Color(.secondarySystemBackground))
                        .cornerRadius(12)
                    }
                    .padding(.horizontal)

                    VStack(alignment: .leading, spacing: 8) {
                        Text("Văn bản gốc vừa quét:")
                            .font(.caption.bold())
                            .foregroundColor(.secondary)
                        Text(engine.recognizedText)
                            .font(.footnote)
                            .frame(maxWidth: .infinity, alignment: .leading)

                        Divider()

                        Text("Bản dịch tiếng Việt:")
                            .font(.caption.bold())
                            .foregroundColor(.teal)
                        Text(engine.translatedText)
                            .font(.body.bold())
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .padding()
                    .background(Color(.secondarySystemBackground))
                    .cornerRadius(12)
                    .padding(.horizontal)
                }
                .padding(.vertical)
            }
            .navigationTitle("ScreenTrans iOS")
        }
    }
}

struct PiPPreviewContainer: UIViewRepresentable {
    let layer: AVSampleBufferDisplayLayer

    func makeUIView(context: Context) -> UIView {
        let view = PreviewHostView()
        view.displayLayer = layer
        view.layer.addSublayer(layer)
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        layer.frame = uiView.bounds
    }

    class PreviewHostView: UIView {
        weak var displayLayer: AVSampleBufferDisplayLayer?
        override func layoutSubviews() {
            super.layoutSubviews()
            displayLayer?.frame = bounds
        }
    }
}

struct BroadcastPickerRepresentable: UIViewRepresentable {
    func makeUIView(context: Context) -> RPSystemBroadcastPickerView {
        let picker = RPSystemBroadcastPickerView(frame: CGRect(x: 0, y: 0, width: 50, height: 50))
        picker.showsMicrophoneButton = false
        return picker
    }
    func updateUIView(_ uiView: RPSystemBroadcastPickerView, context: Context) {}
}
