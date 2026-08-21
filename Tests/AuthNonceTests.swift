import Foundation
import XCTest
@testable import SalahBuddy

/// v4 auth-layer tests: the OIDC nonce and the SQLSTATE → copy table.
///
/// Both are pure by design, which is the whole reason they were split out of
/// `AuthService`/`CircleService`: the nonce rule and the error table are the
/// two things that can only otherwise be checked against a live server, ten
/// minutes at a time.
final class AuthNonceTests: XCTestCase {

    // MARK: - sha256Hex

    /// The published SHA-256 vectors. If these drift, `signInWithIdToken`
    /// starts failing with "Nonces mismatch" and nothing else explains why.
    func testSHA256KnownVectors() {
        XCTAssertEqual(Nonce.sha256Hex(""),
                       "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
        XCTAssertEqual(Nonce.sha256Hex("abc"),
                       "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        XCTAssertEqual(Nonce.sha256Hex("hello"),
                       "2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824")
        XCTAssertEqual(Nonce.sha256Hex("The quick brown fox jumps over the lazy dog"),
                       "d7a8fbb307d7809469ca9abcb0082e4f8d5651e46d3cdb762d02d0bf37c9e592")
    }

    /// GoTrue compares against Go's `fmt.Sprintf("%x", ...)` — 64 characters,
    /// lowercase. An uppercase digest is a silent, total sign-in failure.
    func testSHA256IsLowercaseHexOf64Characters() {
        let hex: String = Nonce.sha256Hex(Nonce.random())
        XCTAssertEqual(hex.count, 64)
        XCTAssertEqual(hex, hex.lowercased())
        let hexAlphabet = Set("0123456789abcdef")
        XCTAssertTrue(hex.allSatisfy { hexAlphabet.contains($0) })
    }

    func testSHA256IsStableAndInputSensitive() {
        XCTAssertEqual(Nonce.sha256Hex("salaam"), Nonce.sha256Hex("salaam"))
        XCTAssertNotEqual(Nonce.sha256Hex("salaam"), Nonce.sha256Hex("salaaM"))
    }

    /// UTF-8, not UTF-16 or whatever the platform fancies — the server hashes
    /// bytes, so a multi-byte nonce has to agree byte for byte.
    func testSHA256HashesUTF8Bytes() {
        // Written as an escape so the expectation can't shift with however this
        // file happens to normalise a composed character on disk.
        XCTAssertEqual(Nonce.sha256Hex("\u{00E9}"),
                       "4a99557e4033c3539de2eb65472017cad5f9557f7a0625a09f1c3f6e2ba69c4c")
    }

    // MARK: - random

    func testAlphabetIsSixtyFourUnreservedCharacters() {
        // 64 exactly, so byte → index carries no modulo bias.
        XCTAssertEqual(Nonce.alphabet.count, 64)
        XCTAssertEqual(Set(Nonce.alphabet).count, 64, "the alphabet must not repeat a character")

        // RFC 3986 unreserved: nothing here ever needs percent-encoding on its
        // way through a provider's authorize URL.
        let unreserved = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        for character in Nonce.alphabet {
            XCTAssertTrue(unreserved.contains(character), "\(character) is not unreserved")
        }
    }

    func testRandomHonoursLengthAndAlphabet() {
        let allowed = Set(Nonce.alphabet)

        let standard: String = Nonce.random()
        XCTAssertEqual(standard.count, 32, "the default nonce length")
        XCTAssertTrue(standard.allSatisfy { allowed.contains($0) })

        for length in [1, 8, 43, 128] {
            let nonce: String = Nonce.random(length: length)
            XCTAssertEqual(nonce.count, length)
            XCTAssertTrue(nonce.allSatisfy { allowed.contains($0) })
        }
    }

    /// A zero-length nonce would be sent as "" and GoTrue treats an absent
    /// nonce as a different case entirely — so the floor is one character.
    func testRandomNeverReturnsAnEmptyString() {
        XCTAssertEqual(Nonce.random(length: 0).count, 1)
        XCTAssertEqual(Nonce.random(length: -5).count, 1)
    }

    /// Not a randomness test — just proof we aren't returning a constant.
    func testRandomDoesNotRepeatItself() {
        var seen = Set<String>()
        for _ in 0..<200 {
            seen.insert(Nonce.random())
        }
        XCTAssertEqual(seen.count, 200)
    }

    /// The rule itself, spelled out as a test: the provider gets the HASH, and
    /// Supabase gets the RAW value. They must never be the same string.
    func testHashedNonceDiffersFromRawNonce() {
        let raw: String = Nonce.random()
        let hashed: String = Nonce.sha256Hex(raw)
        XCTAssertNotEqual(raw, hashed)
        XCTAssertEqual(hashed, Nonce.sha256Hex(raw), "the pair has to be reproducible")
    }

    // MARK: - CircleError: the SQLSTATE table

    func testEverySQLStateMapsToItsError() {
        XCTAssertEqual(CircleError.from(sqlState: "SB400"), .badRequest)
        XCTAssertEqual(CircleError.from(sqlState: "SB401"), .notSignedIn)
        XCTAssertEqual(CircleError.from(sqlState: "SB403"), .notAllowed)
        XCTAssertEqual(CircleError.from(sqlState: "SB409"), .circleFull)
        XCTAssertEqual(CircleError.from(sqlState: "SB410"), .alreadyInACircle)
        XCTAssertEqual(CircleError.from(sqlState: "SB429"), .tooManyAttempts)
    }

    /// SB404 is raised for two different situations and only the hint tells
    /// them apart — `join_circle` sends `unknown_code`, `rename_circle` and
    /// `record_nudge` send `no_circle`.
    func testSB404SplitsOnItsHint() {
        XCTAssertEqual(CircleError.from(sqlState: "SB404", hint: "unknown_code"), .unknownCode)
        XCTAssertEqual(CircleError.from(sqlState: "SB404", hint: "no_circle"), .notInACircle)
        XCTAssertEqual(CircleError.from(sqlState: "SB404"), .unknownCode,
                       "a hintless SB404 is the code path a person actually types into")
    }

    /// The hint only ever disambiguates SB404 — it must not steer any other code.
    func testHintIsIgnoredForOtherCodes() {
        XCTAssertEqual(CircleError.from(sqlState: "SB409", hint: "no_circle"), .circleFull)
        XCTAssertEqual(CircleError.from(sqlState: "SB410", hint: "unknown_code"), .alreadyInACircle)
    }

    func testUnknownSQLStateKeepsTheRawMessageForLogsOnly() {
        let mapped: CircleError = CircleError.from(sqlState: "SB999", message: "boom")
        XCTAssertEqual(mapped, .unknown("boom"))
        XCTAssertEqual(mapped.debugDetail, "boom")
        XCTAssertFalse(mapped.message.contains("boom"), "a raw server string never reaches a person")

        XCTAssertEqual(CircleError.from(sqlState: nil), .unknown(nil))
        XCTAssertEqual(CircleError.from(sqlState: "23505", message: "duplicate key"),
                       .unknown("duplicate key"))
    }

    // MARK: - CircleError: transport

    func testTransportFailuresAreReassuringRatherThanAlarming() {
        let codes: [URLError.Code] = [.notConnectedToInternet, .networkConnectionLost,
                                      .timedOut, .cannotFindHost, .dataNotAllowed]
        for code in codes {
            let mapped: CircleError = CircleError.from(URLError(code))
            XCTAssertEqual(mapped, .offline)
            XCTAssertTrue(mapped.isOffline)
        }

        // The same failure arriving as a plain NSError still has to land here.
        let bridged = NSError(domain: NSURLErrorDomain, code: -1009, userInfo: nil)
        XCTAssertEqual(CircleError.from(bridged), .offline)
    }

    func testAlreadyMappedErrorsPassThroughUnchanged() {
        XCTAssertEqual(CircleError.from(CircleError.circleFull), .circleFull)
        XCTAssertEqual(CircleError.from(CircleError.unknown("kept")), .unknown("kept"))
    }

    // MARK: - CircleError: the copy itself

    func testEveryCaseHasDistinctIdentityAndRealCopy() {
        let all: [CircleError] = [.notSignedIn, .unknownCode, .notInACircle, .circleFull,
                                  .alreadyInACircle, .tooManyAttempts, .notAllowed,
                                  .badRequest, .offline, .unknown(nil)]
        XCTAssertEqual(Set(all.map { $0.id }).count, all.count)
        for error in all {
            XCTAssertFalse(error.title.isEmpty, "\(error.id) has no title")
            XCTAssertFalse(error.message.isEmpty, "\(error.id) has no message")
            XCTAssertEqual(error.errorDescription ?? "", error.message)
            XCTAssertEqual(error.failureReason ?? "", error.title)
        }
    }

    /// House rule: the palette has no red and the copy has no blame. Nothing
    /// here should read like a scolding or a stack trace.
    func testCopyStaysInTheAppsVoice() {
        let all: [CircleError] = [.notSignedIn, .unknownCode, .notInACircle, .circleFull,
                                  .alreadyInACircle, .tooManyAttempts, .notAllowed,
                                  .badRequest, .offline, .unknown("SQLSTATE SB999")]
        let banned: [String] = ["error", "failed", "invalid", "SQLSTATE", "null"]
        for error in all {
            let text: String = (error.title + " " + error.message).lowercased()
            for word in banned {
                XCTAssertFalse(text.contains(word.lowercased()),
                               "\(error.id) says \"\(word)\" out loud")
            }
        }
    }

    func testOnlyTheOfflineCaseClaimsToBeOffline() {
        XCTAssertTrue(CircleError.offline.isOffline)
        XCTAssertFalse(CircleError.circleFull.isOffline)
        XCTAssertNil(CircleError.circleFull.debugDetail)
    }

    // MARK: - The profile-mirror fingerprint

    /// SPEC-V4 §1's "profile syncs on sign-in" has to survive two things the
    /// in-memory retry flag could not: a sign-in that happened with no signal,
    /// and a name or gender edited in Settings afterwards. Both are "the
    /// fingerprint moved", so every field that syncs must move it — and a
    /// different account must never inherit the previous one's "already synced".
    func testEveryFieldThatSyncsChangesTheFingerprint() {
        let user = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
        let other = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
        let base = LocalIdentity(name: "Haashim", avatarEmoji: "😄", memberKind: "brother")

        let baseline: String = base.syncFingerprint(userID: user)
        XCTAssertEqual(baseline, base.syncFingerprint(userID: user))

        var renamed: LocalIdentity = base
        renamed.name = "Haashim A"
        XCTAssertNotEqual(renamed.syncFingerprint(userID: user), baseline)

        var reFaced: LocalIdentity = base
        reFaced.avatarEmoji = "🌙"
        XCTAssertNotEqual(reFaced.syncFingerprint(userID: user), baseline)

        var reKinded: LocalIdentity = base
        reKinded.memberKind = "sister"
        XCTAssertNotEqual(reKinded.syncFingerprint(userID: user), baseline)

        XCTAssertNotEqual(base.syncFingerprint(userID: other), baseline)
    }

    /// A nil emoji and an empty one are the same absence, but a name that
    /// merely LOOKS like two fields joined must not collide with the real
    /// thing — the separator is a control character precisely so no name can
    /// contain it.
    func testFingerprintDoesNotCollideAcrossFieldBoundaries() {
        let user = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
        let split = LocalIdentity(name: "A", avatarEmoji: "B", memberKind: nil)
        let joined = LocalIdentity(name: "A B", avatarEmoji: nil, memberKind: nil)
        XCTAssertNotEqual(split.syncFingerprint(userID: user),
                          joined.syncFingerprint(userID: user))

        let nilEmoji = LocalIdentity(name: "A", avatarEmoji: nil, memberKind: nil)
        let emptyEmoji = LocalIdentity(name: "A", avatarEmoji: "", memberKind: nil)
        XCTAssertEqual(nilEmoji.syncFingerprint(userID: user),
                       emptyEmoji.syncFingerprint(userID: user))
    }
}
