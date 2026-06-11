import SwiftUI
import UIKit

/// Placeholder stub — components agent implements per SPEC-V2 §3:
/// UIImagePickerController(.camera) wrapper; if camera unavailable
/// (simulator) show fallback UI with "Use a demo photo"
/// (PhotoStore.demoImage) and a PHPicker option.
struct CameraCaptureView: View {
    let onCapture: (UIImage) -> Void
    let onCancel: () -> Void

    var body: some View {
        EmptyView()
    }
}
