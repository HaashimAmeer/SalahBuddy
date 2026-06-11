import SwiftUI
import UIKit
import AVFoundation
import PhotosUI

// Owned by the components agent.
/// Capture flow for a prayer post. Presents the real camera when available;
/// when the camera is missing (simulator) or permission is denied, shows a
/// friendly fallback with "Use a demo photo" (PhotoStore.demoImage) and a
/// photo-library picker — the flow never dead-ends (§6.2).
struct CameraCaptureView: View {
    let onCapture: (UIImage) -> Void
    let onCancel: () -> Void

    private enum Mode: Equatable {
        case deciding
        case camera
        case fallback(message: String)
    }

    @State private var mode: Mode = .deciding
    @State private var showLibraryPicker = false

    var body: some View {
        Group {
            switch mode {
            case .deciding:
                ZStack {
                    Theme.bg.ignoresSafeArea()
                    ProgressView()
                }
                .task { await decide() }

            case .camera:
                CameraPicker(
                    onCapture: onCapture,
                    onCancel: onCancel,
                    onUnavailable: {
                        mode = .fallback(message:
                            "The camera isn't available right now.")
                    })
                .ignoresSafeArea()

            case .fallback(let message):
                fallbackView(message: message)
            }
        }
        .sheet(isPresented: $showLibraryPicker) {
            LibraryPicker { image in
                showLibraryPicker = false
                if let image { onCapture(image) }
            }
            .ignoresSafeArea()
        }
    }

    // MARK: - Routing

    @MainActor
    private func decide() async {
        guard UIImagePickerController.isSourceTypeAvailable(.camera) else {
            mode = .fallback(message:
                "No camera here (hi, Simulator 👋) — pick another way to post.")
            return
        }
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            mode = .camera
        case .notDetermined:
            let granted = await AVCaptureDevice.requestAccess(for: .video)
            mode = granted
                ? .camera
                : .fallback(message:
                    "Camera access is off. You can enable it in Settings, or post another way.")
        default:   // .denied, .restricted
            mode = .fallback(message:
                "Camera access is off. You can enable it in Settings, or post another way.")
        }
    }

    // MARK: - Fallback UI (never dead-ends)

    private func fallbackView(message: String) -> some View {
        ZStack {
            Theme.bg.ignoresSafeArea()

            VStack(spacing: 0) {
                HStack {
                    Button {
                        onCancel()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 15, weight: .bold))
                            .foregroundStyle(Theme.inkMuted)
                            .padding(10)
                            .background(Circle().fill(Theme.surface))
                    }
                    Spacer()
                }
                .padding(.horizontal, 20)
                .padding(.top, 8)

                Spacer()

                VStack(spacing: 14) {
                    ZStack {
                        Circle()
                            .fill(Theme.greenSoft.opacity(0.7))
                            .frame(width: 92, height: 92)
                        Image(systemName: "camera.fill")
                            .font(.system(size: 34, weight: .semibold))
                            .foregroundStyle(Theme.green)
                        Image(systemName: "moon.stars.fill")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(Theme.gold)
                            .offset(x: 34, y: -32)
                    }

                    Text("No camera, no problem")
                        .font(Theme.sans(22, .bold))
                        .foregroundStyle(Theme.inkDeep)

                    Text(message)
                        .font(Theme.sans(15, .medium))
                        .foregroundStyle(Theme.inkMuted)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 32)
                }

                Spacer()

                VStack(spacing: 12) {
                    ChunkyButton(title: "Use a demo photo 🖼️",
                                 color: Theme.green, isEnabled: true) {
                        let seed = UInt64(bitPattern:
                            Int64(AppClock.now.timeIntervalSince1970 * 1000))
                        onCapture(PhotoStore.demoImage(seed: seed))
                    }

                    ChunkyButton(title: "Choose from library",
                                 color: Theme.qadaBlue, isEnabled: true) {
                        showLibraryPicker = true
                    }
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 28)
            }
        }
    }
}

// MARK: - UIImagePickerController (.camera) wrapper

private struct CameraPicker: UIViewControllerRepresentable {
    let onCapture: (UIImage) -> Void
    let onCancel: () -> Void
    let onUnavailable: () -> Void

    func makeUIViewController(context: Context) -> UIViewController {
        guard UIImagePickerController.isSourceTypeAvailable(.camera) else {
            // Mid-flight loss of the camera — bounce to fallback.
            DispatchQueue.main.async { onUnavailable() }
            return UIViewController()
        }
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.cameraCaptureMode = .photo
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: UIViewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let parent: CameraPicker
        init(_ parent: CameraPicker) { self.parent = parent }

        func imagePickerController(
            _ picker: UIImagePickerController,
            didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]
        ) {
            if let image = (info[.editedImage] ?? info[.originalImage]) as? UIImage {
                parent.onCapture(image)
            } else {
                parent.onCancel()
            }
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            parent.onCancel()
        }
    }
}

// MARK: - PHPicker wrapper (library option in the fallback)

private struct LibraryPicker: UIViewControllerRepresentable {
    /// Called with the chosen image, or nil if cancelled / load failed.
    let onPick: (UIImage?) -> Void

    func makeUIViewController(context: Context) -> PHPickerViewController {
        var config = PHPickerConfiguration()
        config.filter = .images
        config.selectionLimit = 1
        let picker = PHPickerViewController(configuration: config)
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: PHPickerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, PHPickerViewControllerDelegate {
        let parent: LibraryPicker
        init(_ parent: LibraryPicker) { self.parent = parent }

        func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
            guard let provider = results.first?.itemProvider,
                  provider.canLoadObject(ofClass: UIImage.self) else {
                parent.onPick(nil)
                return
            }
            provider.loadObject(ofClass: UIImage.self) { [parent] object, _ in
                DispatchQueue.main.async {
                    parent.onPick(object as? UIImage)
                }
            }
        }
    }
}

#if DEBUG
#Preview {
    CameraCaptureView(onCapture: { _ in }, onCancel: {})
}
#endif
