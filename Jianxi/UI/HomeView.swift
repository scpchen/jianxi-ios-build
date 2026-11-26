import SwiftUI
import AVFoundation
import UIKit

struct HomeView: View {
    @EnvironmentObject var model: AppModel
    @State private var showScanner = false
    @State private var renaming: SavedDevice?
    @State private var renameText = ""

    private func devices(_ kind: String) -> [SavedDevice] {
        model.savedDevices.filter { $0.kind == kind }
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                Button(action: { showScanner = true }) {
                    VStack(spacing: 8) {
                        Image(systemName: "qrcode.viewfinder")
                            .font(.system(size: 44))
                        Text("扫码识别设备")
                            .font(.system(size: 17, weight: .semibold))
                        Text("支持洗衣机 · 洗鞋机 · 烘干机 · 饮水机")
                            .font(.system(size: 12))
                            .opacity(0.85)
                    }
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 26)
                    .background(LinearGradient(gradient: Gradient(colors: [Color.accentColor, Color.accentColor.opacity(0.7)]), startPoint: .topLeading, endPoint: .bottomTrailing))
                    .cornerRadius(18)
                }
                VStack(alignment: .leading, spacing: 10) {
                    Text("手动输入").font(.system(size: 13, weight: .semibold)).foregroundColor(.secondary)
                    TextField("粘贴二维码内容，或直接输入设备 IMEI", text: $model.manualCode)
                        .autocapitalization(.none)
                        .disableAutocorrection(true)
                        .padding(12)
                        .background(Color(.secondarySystemBackground))
                        .cornerRadius(12)
                    Button("识别设备") { model.submitManualCode() }
                        .buttonStyle(SecondaryButtonStyle())
                }
                .card()
                ForEach([("laundry", "常用洗衣设备"), ("dryer", "常用烘干机"), ("water", "常用饮水机")], id: \.0) { kind, title in
                    if !devices(kind).isEmpty {
                        VStack(alignment: .leading, spacing: 10) {
                            Text(title).font(.system(size: 13, weight: .semibold)).foregroundColor(.secondary)
                            ForEach(devices(kind)) { record in
                                Button(action: { model.selectSavedDevice(record) }) {
                                    HStack {
                                        VStack(alignment: .leading, spacing: 3) {
                                            Text(record.note.isEmpty ? record.name : record.note)
                                                .font(.system(size: 15, weight: .medium))
                                                .foregroundColor(.primary)
                                            Text("\(record.key): \(record.value)")
                                                .font(.system(size: 11))
                                                .foregroundColor(.secondary)
                                        }
                                        Spacer()
                                        Image(systemName: "chevron.right")
                                            .font(.system(size: 12))
                                            .foregroundColor(.secondary)
                                    }
                                }
                                .contextMenu {
                                    Button("重命名") {
                                        renameText = record.note
                                        renaming = record
                                    }
                                    Button("删除") { model.deleteSavedDevice(record) }
                                }
                                if record.id != devices(kind).last?.id { Divider() }
                            }
                        }
                        .card()
                    }
                }
            }
            .padding(16)
        }
        .navigationTitle("简洗")
        .navigationBarItems(trailing: Text(model.phoneLabel).font(.system(size: 13)).foregroundColor(.secondary))
        .fullScreenCover(isPresented: $showScanner) {
            ScannerScreen { raw in
                showScanner = false
                model.scan(raw)
            } onCancel: {
                showScanner = false
            }
        }
        .sheet(item: $renaming) { record in
            VStack(spacing: 16) {
                Text("重命名设备").font(.system(size: 17, weight: .semibold))
                TextField("备注名称", text: $renameText)
                    .padding(12)
                    .background(Color(.secondarySystemBackground))
                    .cornerRadius(12)
                Button("保存") {
                    model.renameSavedDevice(record, note: renameText)
                    renaming = nil
                }
                .buttonStyle(PrimaryButtonStyle())
                Button("取消") { renaming = nil }
                    .buttonStyle(SecondaryButtonStyle())
            }
            .padding(24)
        }
    }
}

struct ScannerScreen: View {
    let onResult: (String) -> Void
    let onCancel: () -> Void
    @State private var showPhotos = false
    @State private var hint = "对准设备二维码，支持反色与低对比度码"

    var body: some View {
        ZStack {
            CameraScanner { raw in onResult(raw) }
                .ignoresSafeArea()
            VStack {
                HStack {
                    Button(action: onCancel) {
                        Image(systemName: "xmark")
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundColor(.white)
                            .padding(12)
                            .background(Color.black.opacity(0.5))
                            .clipShape(Circle())
                    }
                    Spacer()
                    Button(action: { showPhotos = true }) {
                        Image(systemName: "photo")
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundColor(.white)
                            .padding(12)
                            .background(Color.black.opacity(0.5))
                            .clipShape(Circle())
                    }
                }
                .padding(20)
                Spacer()
                RoundedRectangle(cornerRadius: 16)
                    .stroke(Color.white.opacity(0.8), lineWidth: 2)
                    .frame(width: 240, height: 240)
                Spacer()
                Text(hint)
                    .font(.system(size: 13))
                    .foregroundColor(.white)
                    .padding(.vertical, 10)
                    .padding(.horizontal, 16)
                    .background(Color.black.opacity(0.5))
                    .cornerRadius(12)
                    .padding(.bottom, 40)
            }
        }
        .sheet(isPresented: $showPhotos) {
            PhotoPicker { image in
                if let raw = decodeQR(from: image) {
                    onResult(raw)
                } else {
                    hint = "未在图片中识别到二维码，请换一张或直接扫码"
                }
            }
        }
    }
}

struct CameraScanner: UIViewControllerRepresentable {
    let onResult: (String) -> Void

    func makeUIViewController(context: Context) -> ScannerViewController {
        let controller = ScannerViewController()
        controller.onResult = onResult
        return controller
    }

    func updateUIViewController(_ controller: ScannerViewController, context: Context) {}
}

final class ScannerViewController: UIViewController, AVCaptureMetadataOutputObjectsDelegate {
    var onResult: ((String) -> Void)?
    private let session = AVCaptureSession()
    private var previewLayer: AVCaptureVideoPreviewLayer?
    private var delivered = false

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        guard let device = AVCaptureDevice.default(for: .video),
              let input = try? AVCaptureDeviceInput(device: device),
              session.canAddInput(input) else {
            let label = UILabel()
            label.text = "无法访问相机，请检查相机权限"
            label.textColor = .white
            label.textAlignment = .center
            label.frame = view.bounds
            label.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            view.addSubview(label)
            return
        }
        session.addInput(input)
        let output = AVCaptureMetadataOutput()
        guard session.canAddOutput(output) else { return }
        session.addOutput(output)
        output.setMetadataObjectsDelegate(self, queue: DispatchQueue.main)
        output.metadataObjectTypes = [.qr]
        let layer = AVCaptureVideoPreviewLayer(session: session)
        layer.videoGravity = .resizeAspectFill
        layer.frame = view.bounds
        view.layer.addSublayer(layer)
        previewLayer = layer
        DispatchQueue.global(qos: .userInitiated).async { [session] in
            session.startRunning()
        }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        previewLayer?.frame = view.bounds
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        DispatchQueue.global(qos: .userInitiated).async { [session] in
            session.stopRunning()
        }
    }

    func metadataOutput(_ output: AVCaptureMetadataOutput, didOutput metadataObjects: [AVMetadataObject], from connection: AVCaptureConnection) {
        guard !delivered else { return }
        for object in metadataObjects {
            if let readable = object as? AVMetadataMachineReadableCodeObject,
               readable.type == .qr, let value = readable.stringValue, !value.isEmpty {
                delivered = true
                onResult?(value)
                return
            }
        }
    }
}