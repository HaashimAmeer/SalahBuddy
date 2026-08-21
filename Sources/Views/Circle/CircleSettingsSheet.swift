import SwiftUI

// The two sheets that write a circle's identity — creating one, and editing or
// leaving the one you're in. They live together because they are the same form
// twice (`CircleIdentityEditor`), and a name field that drifts apart between
// "start" and "rename" is the kind of thing nobody notices until it looks odd.

// MARK: - Create

/// First stop after signing in with no circle yet (SPEC-V4 §2). The creator is
/// just member #1 — there is no admin role — so this asks for nothing but a
/// name and a face.
struct CreateCircleSheet: View {
    @EnvironmentObject private var circleService: CircleService
    @Environment(\.dismiss) private var dismiss

    @State private var name: String = ""
    @State private var emoji: String = CircleIdentityEditor.defaultEmoji
    @State private var notice: CircleNotice?
    @State private var isCreating: Bool = false

    var body: some View {
        VStack(spacing: 0) {
            SheetGrabber()
            ScrollView {
                VStack(spacing: 18) {
                    headerBlock
                    CircleIdentityEditor(name: $name, emoji: $emoji)
                    if let notice {
                        CircleNoticeCard(notice: notice)
                    }
                    ChunkyButton(title: isCreating ? "Creating…" : "Create it",
                                 color: Theme.green,
                                 isEnabled: !isCreating) {
                        Task { await create() }
                    }
                    footnote
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 28)
            }
            .scrollBounceBehavior(.basedOnSize)
        }
        .frame(maxWidth: .infinity)
        .background(Theme.bg)
    }

    private var headerBlock: some View {
        VStack(spacing: 8) {
            Text("✨")
                .font(.system(size: 38))
            Text("Start your circle")
                .font(Theme.sans(22, .bold))
                .foregroundStyle(Theme.inkDeep)
            Text("Give it a name your friends will recognise. Anyone in the circle can change it later.")
                .font(Theme.sans(14, .medium))
                .foregroundStyle(Theme.inkMuted)
                .multilineTextAlignment(.center)
                .lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.top, 6)
    }

    private var footnote: some View {
        Text("You'll get a six-character code to share. Eight people fit, you included.")
            .font(Theme.sans(12, .medium))
            .foregroundStyle(Theme.inkMuted)
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
    }

    @MainActor
    private func create() async {
        notice = nil
        isCreating = true
        defer { isCreating = false }
        do {
            try await circleService.createCircle(name: name, emoji: emoji)
            dismiss()
        } catch {
            notice = CircleNotice(CircleError.from(error))
        }
    }
}

// MARK: - Settings (rename + leave)

/// Everything a member can do to the circle itself. Renaming is open to
/// everyone (§2 keeps the group flat) and leaving is the only exit — v4 has no
/// removing of other people, by design.
struct CircleSettingsSheet: View {
    @EnvironmentObject private var circleService: CircleService
    @Environment(\.dismiss) private var dismiss

    @State private var name: String = ""
    @State private var emoji: String = CircleIdentityEditor.defaultEmoji
    @State private var notice: CircleNotice?
    @State private var isSaving: Bool = false
    @State private var isLeaving: Bool = false
    @State private var confirmingLeave: Bool = false

    private var circle: RemoteCircle? { circleService.snapshot.circle }

    var body: some View {
        VStack(spacing: 0) {
            SheetGrabber()
            ScrollView {
                VStack(spacing: 18) {
                    headerBlock
                    CircleIdentityEditor(name: $name, emoji: $emoji)
                    if let notice {
                        CircleNoticeCard(notice: notice)
                    }
                    saveButton
                    Divider().padding(.vertical, 4)
                    leaveSection
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 28)
            }
            .scrollBounceBehavior(.basedOnSize)
        }
        .frame(maxWidth: .infinity)
        .background(Theme.bg)
        .onAppear { adoptCurrentCircle() }
    }

    // MARK: Header

    private var headerBlock: some View {
        VStack(spacing: 6) {
            Text(circle?.emoji ?? CircleIdentityEditor.defaultEmoji)
                .font(.system(size: 38))
            Text(circle?.name ?? "Your Circle")
                .font(Theme.sans(22, .bold))
                .foregroundStyle(Theme.inkDeep)
                .multilineTextAlignment(.center)
            Text(memberLine)
                .font(Theme.sans(13, .medium))
                .foregroundStyle(Theme.inkMuted)
        }
        .padding(.top, 6)
    }

    private var memberLine: String {
        let count: Int = circleService.snapshot.members.count
        if count == 1 { return "Just you so far" }
        return "\(count) of \(RemoteCircle.maxMembers) here"
    }

    // MARK: Save

    private var saveButton: some View {
        ChunkyButton(title: isSaving ? "Saving…" : "Save changes",
                     color: Theme.green,
                     isEnabled: hasChanges && !isSaving && !isLeaving) {
            Task { await save() }
        }
    }

    private var hasChanges: Bool {
        guard let circle else { return false }
        let trimmed: String = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return false }
        return trimmed != circle.name || emoji != circle.emoji
    }

    // MARK: Leave

    @ViewBuilder
    private var leaveSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Leaving the circle")
                .font(Theme.sans(15, .bold))
                .foregroundStyle(Theme.inkDeep)
            Text("You'll go back to praying solo. Your streak, XP and photos stay on this phone — none of it goes anywhere.")
                .font(Theme.sans(13, .medium))
                .foregroundStyle(Theme.inkMuted)
                .lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)

            if confirmingLeave {
                leaveConfirm
            } else {
                Button {
                    withAnimation(Theme.spring) { confirmingLeave = true }
                } label: {
                    Text("Leave this circle")
                        .font(Theme.sans(14, .bold))
                        .foregroundStyle(Theme.amber)
                        .underline()
                }
                .buttonStyle(.plain)
                .disabled(isLeaving || isSaving)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .cardStyle()
    }

    private var leaveConfirm: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(leaveQuestion)
                .font(Theme.sans(13, .semibold))
                .foregroundStyle(Theme.inkMuted)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 12) {
                Button("Stay") {
                    withAnimation(Theme.spring) { confirmingLeave = false }
                }
                .font(Theme.sans(14, .bold))
                .foregroundStyle(Theme.green)
                .buttonStyle(.plain)

                Button {
                    Task { await leave() }
                } label: {
                    Text(isLeaving ? "Leaving…" : "Leave")
                        .font(Theme.sans(14, .bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                        .background(Capsule().fill(Theme.amber))
                }
                .buttonStyle(.plain)
                .disabled(isLeaving)
            }
        }
    }

    private var leaveQuestion: String {
        let title: String = circle?.name ?? "this circle"
        return "Leave \(title)? You can come back any time with the same code."
    }

    // MARK: Actions

    private func adoptCurrentCircle() {
        guard let circle else { return }
        name = circle.name
        emoji = circle.emoji
    }

    @MainActor
    private func save() async {
        notice = nil
        isSaving = true
        defer { isSaving = false }
        do {
            try await circleService.renameCircle(name: name, emoji: emoji)
            dismiss()
        } catch {
            notice = CircleNotice(CircleError.from(error))
        }
    }

    @MainActor
    private func leave() async {
        notice = nil
        isLeaving = true
        defer { isLeaving = false }
        do {
            try await circleService.leaveCircle()
            dismiss()
        } catch {
            notice = CircleSettingsSheet.leaveNotice(for: error)
            confirmingLeave = false
        }
    }

    /// Leaving is the ONE circle action that refuses to happen offline — a
    /// local-only leave would keep showing your friends a member who is gone,
    /// and would make your next join fail. So the generic "it'll sync itself"
    /// reassurance would be a lie here, and this says the true thing instead.
    private static func leaveNotice(for error: any Error) -> CircleNotice {
        let mapped: CircleError = CircleError.from(error)
        if mapped.isOffline {
            return CircleNotice(title: "You're offline",
                                message: "Leaving needs a moment of signal, so everyone else's phone hears about it too. Try again when you're back on — nothing has changed yet.")
        }
        // Same reason, different cause: an expired session can't tell the
        // server either, and the generic "sign in first" copy is written for
        // somebody who has never signed in at all.
        if mapped == .notSignedIn {
            return CircleNotice(title: "Sign in to leave",
                                message: "Your session has expired, and the rest of your circle needs to hear this from the server. Sign back in and leaving is one tap — nothing has changed yet.")
        }
        return CircleNotice(mapped)
    }
}

// MARK: - The shared name + emoji form

/// One form, two sheets. Kept deliberately small: a circle is a name and a
/// face, and asking for anything more at the moment someone starts one is how
/// you end up with nobody starting one.
private struct CircleIdentityEditor: View {
    @Binding var name: String
    @Binding var emoji: String

    static let defaultEmoji: String = "🤝"

    /// No red anywhere in the app, and that includes the faces on offer.
    private static let choices: [String] = ["🤝", "🌙", "✨", "🕌", "🌱", "☕️", "🏡", "📸", "🌤️", "🧭"]

    private static let columns: [GridItem] = Array(repeating: GridItem(.flexible(), spacing: 8),
                                                   count: 5)

    private static let nameLimit: Int = 24

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            fieldLabel("Circle name")
            nameField
            fieldLabel("Pick a face")
            emojiGrid
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardStyle()
    }

    private func fieldLabel(_ text: String) -> some View {
        Text(text)
            .font(Theme.sans(12, .bold))
            .foregroundStyle(Theme.inkMuted)
    }

    private var nameField: some View {
        TextField("Your Circle", text: $name)
            .font(Theme.sans(17, .semibold))
            .foregroundStyle(Theme.inkDeep)
            .textInputAutocapitalization(.words)
            .padding(.horizontal, 14)
            .padding(.vertical, 11)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Theme.bg)
            )
            .onChange(of: name) { _, newValue in
                if newValue.count > CircleIdentityEditor.nameLimit {
                    name = String(newValue.prefix(CircleIdentityEditor.nameLimit))
                }
            }
    }

    private var emojiGrid: some View {
        LazyVGrid(columns: CircleIdentityEditor.columns, spacing: 8) {
            ForEach(CircleIdentityEditor.choices, id: \.self) { choice in
                emojiChip(choice)
            }
        }
    }

    private func emojiChip(_ choice: String) -> some View {
        let selected: Bool = (choice == emoji)
        return Button {
            emoji = choice
        } label: {
            Text(choice)
                .font(.system(size: 22))
                .frame(maxWidth: .infinity)
                .frame(height: 42)
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(selected ? Theme.greenSoft : Theme.bg)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(selected ? Theme.green : Color.clear, lineWidth: 2)
                )
        }
        .buttonStyle(.plain)
    }
}
