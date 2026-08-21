import AuthenticationServices
import SwiftUI

/// The one moment v4 asks for an account (SPEC-V4 §1).
///
/// The ask arrives after the app has already been completely useful with no
/// account at all, so the copy carries its whole justification in one honest
/// sentence: a circle lives on other people's phones, so it has to know who
/// you are — and nothing about your prayers leaves this phone until you join
/// one. Everything else on this screen is that promise, spelled out.
struct SignInSheet: View {
    @EnvironmentObject private var auth: AuthService
    @EnvironmentObject private var circleService: CircleService
    @Environment(\.dismiss) private var dismiss

    /// Apple's request is stamped with the HASHED nonce and hands back the RAW
    /// one; it is held here between `onRequest` and `onCompletion` because
    /// those are two separate callbacks of the same button.
    @State private var rawNonce: String = ""
    @State private var notice: CircleNotice?

    var body: some View {
        VStack(spacing: 0) {
            SheetGrabber()
            ScrollView {
                VStack(spacing: 18) {
                    headerBlock
                    promises
                    if let notice {
                        CircleNoticeCard(notice: notice)
                    }
                    buttons
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

    // MARK: - Copy

    private var headerBlock: some View {
        VStack(spacing: 8) {
            Text("👋")
                .font(.system(size: 40))
            Text("One quick sign-in")
                .font(Theme.sans(22, .bold))
                .foregroundStyle(Theme.inkDeep)
            Text("Your circle lives on real devices, so we need to know who you are. Nothing about your prayers leaves this phone until you join a circle.")
                .font(Theme.sans(14, .medium))
                .foregroundStyle(Theme.inkMuted)
                .multilineTextAlignment(.center)
                .lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.top, 6)
    }

    private struct Promise: Identifiable {
        let icon: String
        let title: String
        let detail: String
        var id: String { title }
    }

    /// Deliberately specific. "We respect your privacy" says nothing; naming
    /// the exact field that travels (your name) and the exact ones that don't
    /// (everything you've built) is the only version a person can check.
    private static let promiseItems: [Promise] = [
        Promise(icon: "person.text.rectangle",
                title: "Your name, and that's it",
                detail: "It's what your circle sees next to your squares."),
        Promise(icon: "iphone",
                title: "Your journey stays here",
                detail: "XP, streak, badges and every photo you've taken live on this phone."),
        Promise(icon: "figure.walk.departure",
                title: "Leave whenever you like",
                detail: "You're back to solo in a tap, with all of it intact."),
    ]

    private var promises: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(Self.promiseItems) { promise in
                promiseRow(promise)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardStyle()
    }

    private func promiseRow(_ promise: Promise) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: promise.icon)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Theme.green)
                .frame(width: 32, height: 32)
                .background(Circle().fill(Theme.greenSoft))
            VStack(alignment: .leading, spacing: 2) {
                Text(promise.title)
                    .font(Theme.sans(14, .bold))
                    .foregroundStyle(Theme.inkDeep)
                Text(promise.detail)
                    .font(Theme.sans(12, .medium))
                    .foregroundStyle(Theme.inkMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
    }

    private var footnote: some View {
        Text("Signing in doesn't join you to anything — you'll pick a circle next.")
            .font(Theme.sans(12, .medium))
            .foregroundStyle(Theme.inkMuted)
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: - Buttons

    private var buttons: some View {
        VStack(spacing: 12) {
            appleButton
            googleButton
            Button("Not now") { dismiss() }
                .font(Theme.sans(14, .semibold))
                .foregroundStyle(Theme.inkMuted)
                .buttonStyle(.plain)
                .padding(.top, 2)
        }
    }

    private var appleButton: some View {
        SignInWithAppleButton(.signIn) { request in
            // Hashed nonce to the provider, raw nonce back to us — stamped
            // together so the two halves cannot be swapped by a call site.
            rawNonce = AuthService.prepareAppleRequest(request)
        } onCompletion: { result in
            handleApple(result)
        }
        .signInWithAppleButtonStyle(.black)
        .frame(height: 52)
        .clipShape(Capsule())
        .disabled(auth.isWorking)
        .opacity(auth.isWorking ? 0.55 : 1)
    }

    private var googleButton: some View {
        Button {
            Task { await runGoogleSignIn() }
        } label: {
            googleLabel
        }
        .buttonStyle(.plain)
        .disabled(auth.isWorking)
        .opacity(auth.isWorking ? 0.55 : 1)
    }

    private var googleLabel: some View {
        HStack(spacing: 8) {
            Image(systemName: "g.circle.fill")
                .font(.system(size: 18, weight: .bold))
            Text("Continue with Google")
                .font(Theme.sans(16, .bold))
        }
        .foregroundStyle(Theme.inkDeep)
        .frame(maxWidth: .infinity)
        .frame(height: 52)
        .background(Capsule().fill(Theme.surface))
        .overlay(Capsule().strokeBorder(Theme.inkMuted.opacity(0.22), lineWidth: 1))
    }

    // MARK: - Sign-in

    private func handleApple(_ result: Result<ASAuthorization, Error>) {
        switch result {
        case .failure(let error):
            notice = CircleNotice.forSignIn(error)
        case .success(let authorization):
            guard let credential = authorization.credential as? ASAuthorizationAppleIDCredential else {
                notice = CircleNotice(CircleError.from(SignInError.missingIdentityToken))
                return
            }
            let nonce: String = rawNonce
            Task { await runAppleSignIn(credential: credential, rawNonce: nonce) }
        }
    }

    @MainActor
    private func runAppleSignIn(credential: ASAuthorizationAppleIDCredential,
                                rawNonce: String) async {
        notice = nil
        do {
            try await auth.signInWithApple(credential: credential, rawNonce: rawNonce)
            await finishSignIn()
        } catch {
            notice = CircleNotice.forSignIn(error)
        }
    }

    @MainActor
    private func runGoogleSignIn() async {
        notice = nil
        do {
            try await auth.signInWithGoogle()
            await finishSignIn()
        } catch {
            notice = CircleNotice.forSignIn(error)
        }
    }

    /// Sign-in changes who `CircleService` thinks we are, and only the service
    /// can turn that into a phase. `bootstrap()` adopts the session; the extra
    /// `refresh()` is what finds a circle this device has never mirrored —
    /// signing in on a NEW phone, where the membership exists only server-side.
    @MainActor
    private func finishSignIn() async {
        await circleService.bootstrap()
        if circleService.phase == .noCircle {
            await circleService.refresh()
        }
        dismiss()
    }
}

// MARK: - Shared sheet furniture

/// The little grey handle every SalahBuddy sheet wears.
struct SheetGrabber: View {
    var body: some View {
        Capsule()
            .fill(Theme.mist.opacity(0.6))
            .frame(width: 38, height: 5)
            .padding(.top, 10)
            .padding(.bottom, 4)
    }
}

/// Something the app needs to say, said gently. Amber, never red — a full
/// circle or a mistyped code is a fact about the world, not a scolding.
///
/// Shared by all four circle sheets: each one keeps its OWN notice in `@State`
/// rather than reading `CircleService.lastError`, so a complaint can't outlive
/// the screen that caused it.
struct CircleNotice: Identifiable, Equatable {
    var title: String
    var message: String

    var id: String { title + "|" + message }

    init(title: String, message: String) {
        self.title = title
        self.message = message
    }

    init(_ error: CircleError) {
        self.title = error.title
        self.message = error.message
    }

    /// nil when the person simply backed out of a provider sheet — a cancelled
    /// sign-in is not news, and a banner about it reads as an accusation.
    static func forSignIn(_ error: any Error) -> CircleNotice? {
        if let signIn = error as? SignInError, signIn == .cancelled { return nil }
        // ASAuthorizationError.canceled is 1001. Spelled as literals for the
        // same reason AuthService spells Google's: the Clang importer renames
        // NS_ERROR_ENUM types, and a wrong guess only fails on CI.
        let nsError = error as NSError
        if nsError.domain == "com.apple.AuthenticationServices.AuthorizationError",
           nsError.code == 1001 {
            return nil
        }
        return CircleNotice(CircleError.from(error))
    }
}

struct CircleNoticeCard: View {
    let notice: CircleNotice

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "info.circle.fill")
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(Theme.amber)
            VStack(alignment: .leading, spacing: 3) {
                Text(notice.title)
                    .font(Theme.sans(14, .bold))
                    .foregroundStyle(Theme.inkDeep)
                Text(notice.message)
                    .font(Theme.sans(12.5, .medium))
                    .foregroundStyle(Theme.inkMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Theme.amber.opacity(0.12))
        )
    }
}
