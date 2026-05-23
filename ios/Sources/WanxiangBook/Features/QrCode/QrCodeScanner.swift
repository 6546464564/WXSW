//
//  QrCodeScanner.swift
//  万象书屋 iOS · 二维码扫描 + 生成 (M2.9.6 + M2.9.7)
//
//  扫描: AVCaptureMetadataOutput
//  生成: CIFilter CIQRCodeGenerator
//

import SwiftUI
import AVFoundation
import CoreImage.CIFilterBuiltins

// MARK: - 扫描

struct QrCodeScannerView: UIViewControllerRepresentable {
    let onResult: (String) -> Void

    func makeUIViewController(context: Context) -> ScannerVC {
        let vc = ScannerVC()
        vc.onResult = onResult
        return vc
    }

    func updateUIViewController(_ uiViewController: ScannerVC, context: Context) {}

    final class ScannerVC: UIViewController, AVCaptureMetadataOutputObjectsDelegate {
        var onResult: ((String) -> Void)?
        private var session: AVCaptureSession?

        override func viewDidLoad() {
            super.viewDidLoad()
            view.backgroundColor = .black
            setupCamera()
        }

        private func setupCamera() {
            guard let device = AVCaptureDevice.default(for: .video),
                  let input = try? AVCaptureDeviceInput(device: device) else {
                showError("无法访问相机")
                return
            }
            let session = AVCaptureSession()
            session.addInput(input)
            let output = AVCaptureMetadataOutput()
            session.addOutput(output)
            output.setMetadataObjectsDelegate(self, queue: .main)
            output.metadataObjectTypes = [.qr]

            let preview = AVCaptureVideoPreviewLayer(session: session)
            preview.frame = view.bounds
            preview.videoGravity = .resizeAspectFill
            view.layer.addSublayer(preview)

            self.session = session
            DispatchQueue.global(qos: .userInitiated).async {
                session.startRunning()
            }
        }

        func metadataOutput(_ output: AVCaptureMetadataOutput,
                            didOutput metadataObjects: [AVMetadataObject],
                            from connection: AVCaptureConnection) {
            guard let obj = metadataObjects.first as? AVMetadataMachineReadableCodeObject,
                  let str = obj.stringValue else { return }
            session?.stopRunning()
            onResult?(str)
        }

        private func showError(_ msg: String) {
            let container = UIView(frame: view.bounds)
            container.autoresizingMask = [.flexibleWidth, .flexibleHeight]

            let stack = UIStackView()
            stack.axis = .vertical
            stack.alignment = .center
            stack.spacing = 12
            stack.translatesAutoresizingMaskIntoConstraints = false

            let icon = UIImageView(image: UIImage(systemName: "camera.fill"))
            icon.tintColor = .systemGray
            icon.contentMode = .scaleAspectFit
            icon.translatesAutoresizingMaskIntoConstraints = false
            icon.widthAnchor.constraint(equalToConstant: 48).isActive = true
            icon.heightAnchor.constraint(equalToConstant: 48).isActive = true

            let label = UILabel()
            label.text = msg
            label.textColor = .white
            label.font = .systemFont(ofSize: 16, weight: .medium)
            label.textAlignment = .center

            let hint = UILabel()
            hint.text = "请检查相机权限或使用带摄像头的设备"
            hint.textColor = .systemGray
            hint.font = .systemFont(ofSize: 13)
            hint.textAlignment = .center
            hint.numberOfLines = 0

            stack.addArrangedSubview(icon)
            stack.addArrangedSubview(label)
            stack.addArrangedSubview(hint)
            container.addSubview(stack)
            NSLayoutConstraint.activate([
                stack.centerXAnchor.constraint(equalTo: container.centerXAnchor),
                stack.centerYAnchor.constraint(equalTo: container.centerYAnchor),
                stack.leadingAnchor.constraint(greaterThanOrEqualTo: container.leadingAnchor, constant: 32),
            ])
            view.addSubview(container)
        }
    }
}

struct QrCodeScannerScreen: View {
    let onResult: (String) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            QrCodeScannerView { result in
                onResult(result)
                dismiss()
            }
            .ignoresSafeArea()
            .navigationTitle("扫码")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("取消") { dismiss() }
                }
            }
        }
    }
}

// MARK: - 生成

enum QrCodeGenerator {
    /// 生成二维码图片
    static func generate(_ text: String, scale: CGFloat = 8) -> UIImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        filter.correctionLevel = "H"
        guard let out = filter.outputImage else { return nil }
        let scaled = out.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let ctx = CIContext()
        guard let cg = ctx.createCGImage(scaled, from: scaled.extent) else { return nil }
        return UIImage(cgImage: cg)
    }
}
