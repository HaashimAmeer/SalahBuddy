import Foundation
import Network

/// v4: "is there a network right now", and nothing else.
///
/// `CircleSync` needs exactly two facts from the system: whether a drain is
/// worth attempting at all, and the moment connectivity comes BACK — which is
/// the cheapest possible trigger for "post the prayers you logged on the
/// plane". `NWPathMonitor` answers both; this wraps it so the answer arrives on
/// the main actor as a plain `Bool` that SwiftUI can observe.
///
/// v4 DECISION: **it starts OPTIMISTIC (`isOnline == true`).**
/// `NWPathMonitor` reports asynchronously, and on some launches its first
/// callback is late — or, in a unit-test/simulator process where nothing ever
/// starts it, never comes at all. Starting at `false` would mean the app
/// silently refuses to sync until the monitor speaks, turning a slow callback
/// into a permanently stuck queue. Starting at `true` means the worst case is
/// one attempt that fails with `.offline`, gets backed off, and retries — the
/// path the queue is built for anyway. A wrong optimistic answer costs one
/// request; a wrong pessimistic one costs the whole feature.
@MainActor
final class Reachability: ObservableObject {

    /// The app-wide monitor. Deliberately NOT used as a default argument
    /// anywhere: a default-value expression is a nonisolated context in Swift 5
    /// language mode, and naming a `@MainActor` static from one does not
    /// compile (the same trap `CircleService.sessionUserID()` documents).
    static let shared = Reachability()

    @Published private(set) var isOnline: Bool = true

    /// Fired on each offline → online transition only, never on the first
    /// callback that merely confirms we were online all along. `CircleSync`
    /// hangs a drain off it, and a drain per path update (Wi-Fi → cellular →
    /// Wi-Fi while walking out of a building) would be noise.
    var onRegainedConnection: (() -> Void)?

    /// Created on `start()` rather than in `init`: `NWPathMonitor` cannot be
    /// restarted after `cancel()`, so a fresh monitor per start is the only
    /// shape where stop-then-start is not a silent dead end.
    private var monitor: NWPathMonitor?

    private let queue: DispatchQueue = DispatchQueue(label: "org.amacvoters.salahbuddy.reachability")

    init() {}

    var isRunning: Bool { monitor != nil }

    func start() {
        guard monitor == nil else { return }
        let fresh = NWPathMonitor()
        monitor = fresh
        fresh.pathUpdateHandler = { [weak self] path in
            // The `Bool` is extracted HERE, before the hop: `NWPath` is a value
            // the handler is handed on its own queue, and only the answer needs
            // to cross to the main actor.
            let satisfied: Bool = (path.status == .satisfied)
            Task { @MainActor in
                self?.apply(online: satisfied)
            }
        }
        fresh.start(queue: queue)
    }

    /// Tear the monitor down. Safe to call twice, and `start()` afterwards
    /// builds a new one.
    func stop() {
        guard let monitor else { return }
        monitor.pathUpdateHandler = nil
        monitor.cancel()
        self.monitor = nil
    }

    /// Exposed for `CircleSync`'s tests and for the developer card: pretend the
    /// monitor said this. Never called by the monitor path itself.
    func setOnline(_ online: Bool) {
        apply(online: online)
    }

    private func apply(online: Bool) {
        guard online != isOnline else { return }
        isOnline = online
        guard online else { return }
        onRegainedConnection?()
    }
}
