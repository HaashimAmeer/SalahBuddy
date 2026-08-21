import UIKit
import UserNotifications

/// The app's one UIKit delegate. It exists for exactly two reasons, both of
/// which SwiftUI has no equivalent for: APNs hands a device token to a
/// `UIApplicationDelegate` and nowhere else, and how a notification behaves
/// while the app is OPEN is a `UNUserNotificationCenterDelegate` decision.
///
/// **It does not own notifications.** `NotificationManager` owns every LOCAL
/// notification — prayer windows, last call, the break reminder — along with
/// their scheduling and their permission prompt, and nothing in this file
/// schedules, cancels or asks for anything. The division is: local is
/// `NotificationManager`'s, remote is `PushRegistrar`'s, and the two share one
/// permission (see `PushRegistrar.ensureAuthorized`).
///
/// That division is also why `presentationOptions(remote:)` exists rather than
/// a flat "always show a banner": setting a delegate at all changes the
/// foreground behaviour of the LOCAL notifications that were here first, and
/// v3.9's behaviour for those is what it should stay.
final class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {

    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?)
    -> Bool {
        // Must be set before launch finishes, or notifications that arrive
        // during launch are delivered with no delegate to ask.
        UNUserNotificationCenter.current().delegate = self
        // NOT `registerForRemoteNotifications()` here: §1 says a solo user
        // never needs an account, so the token is only ever asked for once a
        // real circle exists. `PushRegistrar.refresh(userID:hasCircle:)` is the
        // one place that decides, and `CircleStack` is the one place that calls
        // it.
        return true
    }

    // MARK: - APNs

    func application(_ application: UIApplication,
                     didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        // Converted here, while the value is still a plain `Data`: `hexToken`
        // is `nonisolated`, and a `String` is `Sendable`, so nothing
        // non-sendable crosses into the main actor below.
        let token: String = PushRegistrar.hexToken(from: deviceToken)
        Task { @MainActor in
            await PushRegistrar.shared.adoptDeviceToken(token)
        }
    }

    func application(_ application: UIApplication,
                     didFailToRegisterForRemoteNotificationsWithError error: any Error) {
        // Routine on a Simulator with no push service, and in the air. Recorded
        // rather than surfaced: every §6 push is garnish on something that has
        // already succeeded.
        let description: String = error.localizedDescription
        Task { @MainActor in
            PushRegistrar.shared.registrationFailed(description)
        }
    }

    // MARK: - UNUserNotificationCenterDelegate

    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification,
                                withCompletionHandler completionHandler:
                                    @escaping (UNNotificationPresentationOptions) -> Void) {
        // A push carries a `UNPushNotificationTrigger`; everything
        // `NotificationManager` schedules carries a
        // `UNTimeIntervalNotificationTrigger`. That is the honest test of "did
        // this come from the circle", and it does not depend on knowing that
        // class's identifier prefix.
        let isRemote: Bool = (notification.request.trigger is UNPushNotificationTrigger)
        completionHandler(AppDelegate.presentationOptions(remote: isRemote))
    }

    /// What to show while the app is in the FOREGROUND.
    ///
    /// Remote (a friend posted, someone joined, a nudge) is worth a banner: it
    /// is news from other people, and the whole point of §6 is that the circle
    /// feels live. Local gets `[]` — which is precisely what iOS did before
    /// this delegate existed, because a prayer reminder for the screen you are
    /// already looking at is a nag, and the Today tab is showing that same
    /// window anyway. Keeping v3.9's behaviour for v3.9's notifications is the
    /// whole reason this is a decision instead of a constant.
    ///
    /// Pure and `static` so it can be tested without conjuring a
    /// `UNNotification`, which has no public initialiser.
    static func presentationOptions(remote: Bool) -> UNNotificationPresentationOptions {
        // `.list` as well as `.banner`, so a banner missed while reading the
        // Today tab is still in Notification Centre afterwards.
        remote ? [.banner, .list, .sound] : []
    }
}
