import UIKit
import UserNotifications

/// The app's one UIKit delegate. Everything in it is here because SwiftUI has
/// no equivalent: APNs hands a device token to a `UIApplicationDelegate` and
/// nowhere else, and both halves of a notification's RECEIPT — how it behaves
/// while the app is open, and the fact that somebody tapped it — are
/// `UNUserNotificationCenterDelegate` decisions.
///
/// It decides nothing about either. A receipt is decoded down to its `kind`
/// (`PushKind`) and handed to `PushRegistrar`, which owns remote notifications;
/// what that costs the app is `CircleSync`'s business, and the answer is the
/// same one realtime gets — pull sooner.
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
        AppDelegate.signalReceipt(remote: isRemote, notification: notification)
        completionHandler(AppDelegate.presentationOptions(remote: isRemote))
    }

    /// The app was opened FROM a notification — the other half of a receipt,
    /// and the one that was missing entirely.
    ///
    /// `willPresent` only fires while the app is already in front. A push that
    /// lands on a locked phone and is tapped ten minutes later never went
    /// through it, so the tap was the app's first sight of the payload and it
    /// had nowhere to go. The foreground pull that follows a tap covers most of
    /// what this signals — but not all of it, and "most" is not a contract:
    /// this runs before the scene phase settles, and a notification tapped
    /// while the app is ALREADY foregrounded raises no foreground event at all.
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        let notification: UNNotification = response.notification
        let isRemote: Bool = (notification.request.trigger is UNPushNotificationTrigger)
        AppDelegate.signalReceipt(remote: isRemote, notification: notification)
        completionHandler()
    }

    /// Read the one field a push is allowed to say anything with, and hand it
    /// on. The `[AnyHashable: Any]` is decoded HERE, on the near side, for the
    /// reason `didRegisterForRemoteNotificationsWithDeviceToken` converts its
    /// token here: a `userInfo` dictionary is not `Sendable`, a `PushKind` is,
    /// and these callbacks are not guaranteed to arrive on the main actor.
    private static func signalReceipt(remote: Bool, notification: UNNotification) {
        let userInfo: [AnyHashable: Any] = notification.request.content.userInfo
        guard let kind: PushKind = AppDelegate.receivedKind(remote: remote,
                                                            userInfo: userInfo) else { return }
        Task { @MainActor in
            PushRegistrar.shared.remoteNotificationArrived(kind)
        }
    }

    /// What an arriving notification is worth telling the circle about.
    ///
    /// Pure and `static` for the same reason `presentationOptions` is: a
    /// `UNNotification` has no public initialiser, so the only way this decision
    /// is testable is if it never needs one.
    ///
    /// `remote: false` answers nil unconditionally. Everything
    /// `NotificationManager` schedules is a local prayer reminder, it carries no
    /// §6 payload, and a local notification must not be able to talk the app
    /// into a network round trip — the same division `presentationOptions`
    /// draws, drawn again where it decides something else.
    static func receivedKind(remote: Bool, userInfo: [AnyHashable: Any]) -> PushKind? {
        guard remote else { return nil }
        return PushKind(userInfo: userInfo)
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
