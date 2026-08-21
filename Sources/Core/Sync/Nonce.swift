import CryptoKit
import Foundation
import Security

/// The OIDC nonce, in the exact shape Supabase's GoTrue expects.
///
/// GoTrue (`internal/api/token_oidc.go`) computes `sha256hex(params.nonce)` and
/// compares that against the `nonce` claim inside the provider's ID token. So
/// the PROVIDER is handed the HASH and Supabase is handed the RAW string. Get
/// the two the wrong way round and every sign-in fails with "Nonces mismatch"
/// — a failure that looks like a misconfigured project rather than a one-line
/// client bug, which is why the rule is written down here next to the code.
///
/// Both functions are pure, so the rule is testable without a network, a
/// provider, or a device.
enum Nonce {

    /// Sixty-four unreserved URL characters (RFC 3986 §2.3 plus `-` and `_`).
    ///
    /// The size is the point: 256 is a whole multiple of 64, so a random byte
    /// maps onto an index with NO modulo bias and no rejection loop. A 62- or
    /// 63-character alphabet would quietly skew the first few letters.
    static let alphabet: [Character] =
        Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_")

    /// A cryptographically random nonce.
    ///
    /// Deliberately NOT `Int.random`: this value is the only thing standing
    /// between a replayed ID token and a session on someone else's account, so
    /// it comes from the system CSPRNG and nowhere else.
    static func random(length: Int = 32) -> String {
        let count: Int = max(1, length)
        var bytes = [UInt8](repeating: 0, count: count)
        let status: OSStatus = SecRandomCopyBytes(kSecRandomDefault, count, &bytes)
        if status != errSecSuccess {
            bytes = Nonce.csprngBytesFromUUIDs(count: count)
        }

        var result = ""
        result.reserveCapacity(count)
        let table: [Character] = Nonce.alphabet
        for byte in bytes {
            let index: Int = Int(byte) % table.count
            result.append(table[index])
        }
        return result
    }

    /// The lowercase hex SHA-256 GoTrue compares against — Go's
    /// `fmt.Sprintf("%x", sha256.Sum256(...))`, i.e. 64 characters, never
    /// uppercase. `String(format:)` is avoided so the output can't follow a
    /// locale.
    static func sha256Hex(_ input: String) -> String {
        let digest = SHA256.hash(data: Data(input.utf8))
        let digits: [Character] = Nonce.hexDigits
        var hex = ""
        hex.reserveCapacity(64)
        for byte in digest {
            hex.append(digits[Int(byte >> 4)])
            hex.append(digits[Int(byte & 0x0F)])
        }
        return hex
    }

    // MARK: - Internals

    private static let hexDigits: [Character] = Array("0123456789abcdef")

    /// Fallback for the (effectively impossible) case where the Keychain RNG
    /// refuses. `UUID()` is CSPRNG-backed too, so the nonce stays strong; what
    /// matters is that a failure here never silently downgrades us to a seeded
    /// PRNG, which would look identical and be worthless.
    private static func csprngBytesFromUUIDs(count: Int) -> [UInt8] {
        var out: [UInt8] = []
        out.reserveCapacity(count)
        while out.count < count {
            let u = UUID().uuid
            let sixteen: [UInt8] = [u.0, u.1, u.2, u.3, u.4, u.5, u.6, u.7,
                                    u.8, u.9, u.10, u.11, u.12, u.13, u.14, u.15]
            for byte in sixteen where out.count < count {
                out.append(byte)
            }
        }
        return out
    }
}
