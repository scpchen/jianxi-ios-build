import SwiftUI
import UIKit

extension View {
    func card() -> some View {
        self.padding(14)
            .background(Color(.secondarySystemBackground))
            .cornerRadius(16)
    }
}

struct PrimaryButtonStyle: ButtonStyle {
    var disabledLook = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 16, weight: .semibold))
            .foregroundColor(.white)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 13)
            .background(disabledLook ? Color.gray : Color.accentColor)
            .cornerRadius(14)
            .opacity(configuration.isPressed ? 0.75 : 1)
    }
}

struct SecondaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 14, weight: .medium))
            .foregroundColor(.accentColor)
            .padding(.vertical, 8)
            .padding(.horizontal, 14)
            .background(Color.accentColor.opacity(0.12))
            .cornerRadius(10)
            .opacity(configuration.isPressed ? 0.7 : 1)
    }
}

struct BusyOverlay: View {
    let text: String
    var body: some View {
        ZStack {
            Color.black.opacity(0.25).ignoresSafeArea()
            VStack(spacing: 12) {
                ProgressView()
                Text(text.isEmpty ? "请稍候" : text)
                    .font(.system(size: 14))
            }
            .padding(24)
            .background(Color(.systemBackground))
            .cornerRadius(16)
        }
    }
}

struct ToastView: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.system(size: 14))
            .foregroundColor(.white)
            .padding(.vertical, 10)
            .padding(.horizontal, 16)
            .background(Color.black.opacity(0.8))
            .cornerRadius(12)
            .padding(.horizontal, 24)
    }
}

struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }
    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}

struct PhotoPicker: UIViewControllerRepresentable {
    let onImage: (UIImage) -> Void
    @Environment(\.presentationMode) private var presentationMode

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .photoLibrary
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ controller: UIImagePickerController, context: Context) {}

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let parent: PhotoPicker
        init(_ parent: PhotoPicker) { self.parent = parent }
        func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            if let image = info[.originalImage] as? UIImage { parent.onImage(image) }
            parent.presentationMode.wrappedValue.dismiss()
        }
        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            parent.presentationMode.wrappedValue.dismiss()
        }
    }
}

func decodeQR(from image: UIImage) -> String? {
    guard let ciImage = CIImage(image: image) else { return nil }
    let detector = CIDetector(ofType: CIDetectorTypeQRCode, context: nil, options: [CIDetectorAccuracy: CIDetectorAccuracyHigh])
    let features = detector?.features(in: ciImage) ?? []
    for feature in features {
        if let qr = feature as? CIQRCodeFeature, let message = qr.messageString, !message.isEmpty {
            return message
        }
    }
    return nil
}

func formatTime(_ interval: Double) -> String {
    let formatter = DateFormatter()
    formatter.dateFormat = "MM-dd HH:mm"
    return formatter.string(from: Date(timeIntervalSince1970: interval))
}

func formatRemaining(_ seconds: Double) -> String {
    let total = Int(seconds)
    if total >= 3600 { return "\(total / 3600) 小时 \((total % 3600) / 60) 分" }
    if total >= 60 { return "\(total / 60) 分钟" }
    return "\(total) 秒"
}