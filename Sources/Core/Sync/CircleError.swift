import Foundation
import Supabase

/// Every way a real-circle operation can fail, said the way a friend would say
/// it.
///
/// The backend RPCs (`backend/supabase/migrations/20260821000400_rpcs.sql`)
/// raise custom SQLSTATEs rather than returning status codes, precisely so the
/// client can tell "that code doesn't exist" from "that circle is full"
/// without parsing English out of a Postgres message. supabase-swift surfaces
/// them as `PostgrestError`, whose `code` IS the SQLSTATE and whose `hint`
/// carries the disambiguator the server attached.
///
/// `SB404` is the one code that means two different things — an invite code
/// nobody owns (`hint: unknown_code`) and "you aren't in a circle at all"
/// (`hint: no_circle`) — so the hint is read, not guessed at.
///
/// The SQLSTATE mapping deliberately lives behind a plain
/// `from(sqlState:hint:message:)` that takes strings: it keeps the whole table
/// testable without a network, a server, or the SDK.
enum CircleError: Error, Equatable, Identifiable {
    /// SB401 — the RPC ran without a session.
    case notSignedIn
    /// SB404 + `unknown_code`.
    case unknownCode
    /// SB404 + `no_circle`.
    case notInACircle
    /// SB409 — the membership trigger refused an eighth seat.
    case circleFull
    /// SB410 — one circle at a time.
    case alreadyInACircle
    /// SB429 — the join-attempt meter is spent for this hour.
    case tooManyAttempts
    /// SB403 — the row exists but isn't yours to touch.
    case notAllowed
    /// SB400 — the request itself didn't add up (a stale day key, self-nudge…).
    case badRequest
    /// No usable connection. Never a dead end: the outbox keeps the write.
    case offline
    /// Anything we have no specific words for. The payload is for logs only —
    /// a raw server string never reaches a person.
    case unknown(String?)

    // MARK: - Mapping

    /// The authoritative SQLSTATE table. Pure, so the tests can walk every row.
    static func from(sqlState: String?, hint: String? = nil,
                     message: String? = nil) -> CircleError {
        switch sqlState {
        case "SB400":
            return .badRequest
        case "SB401":
            return .notSignedIn
        case "SB403":
            return .notAllowed
        case "SB404":
            // Two meanings, one code — see the type note above.
            if hint == "no_circle" { return .notInACircle }
            return .unknownCode
        case "SB409":
            return .circleFull
        case "SB410":
            return .alreadyInACircle
        case "SB429":
            return .tooManyAttempts
        default:
            return .unknown(message)
        }
    }

    /// The entry point call sites use: whatever came back, turned into copy.
    static func from(_ error: any Error) -> CircleError {
        if let already = error as? CircleError {
            return already
        }
        if CircleError.isTransportFailure(error) {
            return .offline
        }
        if let postgrest = error as? PostgrestError {
            return CircleError.from(sqlState: postgrest.code,
                                    hint: postgrest.hint,
                                    message: postgrest.message)
        }
        if let auth = error as? AuthError, auth == .sessionMissing {
            return .notSignedIn
        }
        return .unknown(error.localizedDescription)
    }

    /// Any URLSession-level failure counts as offline: a dropped connection, a
    /// DNS miss and a timeout all want the same reassurance, and the app's
    /// answer to all three is identical — keep the mirror, keep the queue.
    private static func isTransportFailure(_ error: any Error) -> Bool {
        if error is URLError { return true }
        return (error as NSError).domain == NSURLErrorDomain
    }

    // MARK: - Copy

    /// Stable identity so a SwiftUI `.alert(item:)` can present one.
    var id: String {
        switch self {
        case .notSignedIn:      return "notSignedIn"
        case .unknownCode:      return "unknownCode"
        case .notInACircle:     return "notInACircle"
        case .circleFull:       return "circleFull"
        case .alreadyInACircle: return "alreadyInACircle"
        case .tooManyAttempts:  return "tooManyAttempts"
        case .notAllowed:       return "notAllowed"
        case .badRequest:       return "badRequest"
        case .offline:          return "offline"
        case .unknown:          return "unknown"
        }
    }

    var title: String {
        switch self {
        case .notSignedIn:      return "Sign in first"
        case .unknownCode:      return "We couldn't find that circle"
        case .notInACircle:     return "You're not in a circle yet"
        case .circleFull:       return "That circle is full"
        case .alreadyInACircle: return "You're already in a circle"
        case .tooManyAttempts:  return "Too many tries just now"
        case .notAllowed:       return "That didn't go through"
        case .badRequest:       return "That didn't look right"
        case .offline:          return "You're offline"
        case .unknown:          return "Something went sideways"
        }
    }

    var message: String {
        switch self {
        case .notSignedIn:
            return "Your circle lives on real devices, so we need to know who you are. "
                 + "Nothing about your prayers leaves this phone until you join one."
        case .unknownCode:
            return "Double-check the six characters — codes never contain I, O, 0 or 1, "
                 + "so those are usually a 1 for an L or an O for a zero."
        case .notInACircle:
            return "Create one, or ask a friend to send you their six-character code."
        case .circleFull:
            return "A circle holds eight people — five photos a day is an intimate thing. "
                 + "Ask them to start a second one with you."
        case .alreadyInACircle:
            return "You can be in one at a time. Leave your current circle first — "
                 + "your streak, XP and photos stay on this phone either way."
        case .tooManyAttempts:
            return "Give it a few minutes, then try the code again."
        case .notAllowed:
            return "Something in the circle has changed since this screen loaded. "
                 + "Refresh and give it another go."
        case .badRequest:
            return "Something didn't add up on our side. Try again in a moment."
        case .offline:
            return "No worries — everything's saved here, and it'll sync itself the "
                 + "moment you're back online."
        case .unknown:
            return "That didn't go through. Give it another try in a moment."
        }
    }

    /// True when nothing is actually wrong except the network — the caller
    /// should keep its mirror and its queue rather than undoing anything.
    var isOffline: Bool {
        if case .offline = self { return true }
        return false
    }

    /// The raw server text, for logs only. Never rendered.
    var debugDetail: String? {
        if case .unknown(let detail) = self { return detail }
        return nil
    }
}

extension CircleError: LocalizedError {
    var errorDescription: String? { message }
    var failureReason: String? { title }
}
