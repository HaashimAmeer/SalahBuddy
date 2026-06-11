import SwiftUI
import UIKit

/// The capture sheet flow around `CameraCaptureView`:
/// capture → jamaat-toggle confirm → PhotoStore.save → appState.log →
/// dismiss (the existing celebration overlay then fires on Today).
/// Owned by the home agent.
struct CameraFlowSheet: View {
    let target: CameraTarget

    @EnvironmentObject private var state: AppState
    @Environment(\.dismiss) private var dismiss

    @State private var captured: UIImage?

    var body: some View {
        ZStack {
            Theme.bg.ignoresSafeArea()

            if let image = captured {
                JamaatConfirmView(prayer: target.prayer,
                                  image: image,
                                  onPost: { jamaat in post(image, jamaat: jamaat) },
                                  onRetake: { captured = nil },
                                  onCancel: { dismiss() })
            } else {
                CameraCaptureView(onCapture: { captured = $0 },
                                  onCancel: { dismiss() })
            }
        }
        .interactiveDismissDisabled(captured != nil)
    }

    private func post(_ image: UIImage, jamaat: Bool) {
        // Photo-save failure (disk) must never lose the prayer: an empty
        // filename from PhotoStore.save is treated as "no photo".
        let saved = PhotoStore.save(image, dayKey: target.dayKey, prayer: target.prayer)
        let filename = saved.isEmpty ? nil : saved
        withAnimation(Theme.spring) {
            state.log(target.prayer, photoFilename: filename, jamaat: jamaat)
        }
        dismiss()
    }
}

// MARK: - Confirm step

/// Photo preview + optional "Prayed in jamaat 🕌" toggle (+5 XP) + post CTA.
struct JamaatConfirmView: View {
    let prayer: Prayer
    let image: UIImage
    let onPost: (Bool) -> Void
    let onRetake: () -> Void
    let onCancel: () -> Void

    @EnvironmentObject private var state: AppState

    @State private var jamaat = false

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(spacing: 18) {
                header

                preview

                jamaatToggle

                if let tier = state.potentialTier(for: prayer), tier.isInWindow {
                    Text("+\(tier.xp + (jamaat ? GameEngine.jamaatBonus : 0)) XP — \(tier.label)")
                        .font(Theme.sans(15, .bold))
                        .foregroundStyle(Theme.gold)
                        .animation(Theme.spring, value: jamaat)
                }

                ChunkyButton(title: "Post to your circle 🎉", color: Theme.green, isEnabled: true) {
                    onPost(jamaat)
                }

                Button(action: onRetake) {
                    Text("Retake photo")
                        .font(Theme.sans(14, .semibold))
                        .foregroundStyle(Theme.inkMuted)
                        .underline()
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 20)
            .padding(.top, 18)
            .padding(.bottom, 30)
        }
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("\(prayer.emoji) \(prayer.displayName)")
                    .font(Theme.sans(22, .bold))
                    .foregroundStyle(Theme.inkDeep)
                Text("Looking good — mashallah ✨")
                    .font(Theme.sans(13, .semibold))
                    .foregroundStyle(Theme.inkMuted)
            }
            Spacer(minLength: 8)
            Button(action: onCancel) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 26, weight: .semibold))
                    .foregroundStyle(Theme.inkMuted.opacity(0.5))
            }
            .buttonStyle(.plain)
        }
    }

    private var preview: some View {
        Image(uiImage: image)
            .resizable()
            .scaledToFill()
            .frame(maxWidth: .infinity)
            .frame(height: 360)
            .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
            .shadow(color: .black.opacity(0.05), radius: 10, x: 0, y: 2)
    }

    private var jamaatToggle: some View {
        HStack(spacing: 10) {
            Text("🕌")
                .font(.system(size: 22))
            VStack(alignment: .leading, spacing: 1) {
                Text("Prayed in jamaat")
                    .font(Theme.sans(15, .semibold))
                    .foregroundStyle(Theme.inkDeep)
                Text("+\(GameEngine.jamaatBonus) XP bonus")
                    .font(Theme.sans(12, .semibold))
                    .foregroundStyle(Theme.inkMuted)
            }
            Spacer(minLength: 8)
            Toggle("", isOn: $jamaat)
                .labelsHidden()
                .tint(Theme.green)
        }
        .padding(14)
        .cardStyle()
    }
}
