import SwiftUI

/// Joining by code (SPEC-V4 §2, code-first).
///
/// The field never refuses a keystroke — `sanitizedCodeInput` quietly drops
/// what can't be part of a code and stops at six — but it never GUESSES
/// either. I, O, 0 and 1 are missing from the alphabet precisely because they
/// are the characters people misread, so silently "fixing" one would walk
/// somebody confidently into the wrong circle. The hint under the field says
/// so, which is cheaper than a wrong circle.
struct JoinCircleSheet: View {
    @EnvironmentObject private var circleService: CircleService
    @Environment(\.dismiss) private var dismiss

    @State private var code: String = ""
    @State private var notice: CircleNotice?
    @State private var isJoining: Bool = false
    @FocusState private var fieldFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            SheetGrabber()
            ScrollView {
                VStack(spacing: 18) {
                    headerBlock
                    codeField
                    hint
                    if let notice {
                        CircleNoticeCard(notice: notice)
                    }
                    joinButton
                    Spacer(minLength: 4)
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 28)
            }
            .scrollBounceBehavior(.basedOnSize)
        }
        .frame(maxWidth: .infinity)
        .background(Theme.bg)
        .onAppear { fieldFocused = true }
    }

    // MARK: - Pieces

    private var headerBlock: some View {
        VStack(spacing: 8) {
            Text("🤝")
                .font(.system(size: 38))
            Text("Join a circle")
                .font(Theme.sans(22, .bold))
                .foregroundStyle(Theme.inkDeep)
            Text("Type the six characters your friend sent you.")
                .font(Theme.sans(14, .medium))
                .foregroundStyle(Theme.inkMuted)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.top, 6)
    }

    private var codeField: some View {
        TextField("", text: $code)
            .font(.system(size: 30, weight: .heavy, design: .monospaced))
            .kerning(6)
            .foregroundStyle(Theme.inkDeep)
            .multilineTextAlignment(.center)
            .textInputAutocapitalization(.characters)
            .autocorrectionDisabled()
            .focused($fieldFocused)
            .padding(.vertical, 16)
            .frame(maxWidth: .infinity)
            .background(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(Theme.surface)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(isComplete ? Theme.green : Theme.mist.opacity(0.6),
                                  lineWidth: isComplete ? 2 : 1)
            )
            .onChange(of: code) { _, newValue in
                let cleaned: String = CircleService.sanitizedCodeInput(newValue)
                if cleaned != code { code = cleaned }
                if notice != nil { notice = nil }
            }
    }

    private var hint: some View {
        Text("Six characters — a code never has an I, O, 0 or 1 in it.")
            .font(Theme.sans(12, .medium))
            .foregroundStyle(Theme.inkMuted)
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var joinButton: some View {
        ChunkyButton(title: isJoining ? "Joining…" : "Join the circle",
                     color: Theme.green,
                     isEnabled: isComplete && !isJoining) {
            Task { await join() }
        }
    }

    private var isComplete: Bool {
        CircleService.normalizedJoinCode(code) != nil
    }

    // MARK: - Action

    @MainActor
    private func join() async {
        notice = nil
        isJoining = true
        defer { isJoining = false }
        fieldFocused = false
        do {
            try await circleService.joinCircle(code: code)
            dismiss()
        } catch {
            notice = CircleNotice(CircleError.from(error))
        }
    }
}
