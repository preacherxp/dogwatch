import CommonCrypto
import Foundation
import Security

// Electron "Safe Storage": how Electron apps (Cursor, Devin Desktop) encrypt values they keep in
// their own files. The app keeps a random password in the login Keychain under
// "<App> Safe Storage"; the value is the Chromium "v10" format: the bytes "v10", then AES-128-CBC
// with a key derived by PBKDF2-HMAC-SHA1 from that password (salt "saltysalt", 1003 rounds,
// 16 bytes) and an IV of 16 spaces, PKCS#7 padded.
//
// Format reference, read 2026-11-19: Chromium `components/os_crypt/sync/os_crypt_mac.mm`
// (https://source.chromium.org/chromium/chromium/src/+/main:components/os_crypt/sync/os_crypt_mac.mm).
//
// Reading another app's Keychain item shows a macOS prompt naming that item. So:
// - only a provider whose user turned on an explicit setting (off by default) may call this;
// - a denied prompt becomes `ProviderError.accessDenied`, which the store doesn't retry on its
//   timer, so the prompt is never repeated in a loop;
// - the password is held in memory for one decryption and never stored, logged or shown.

/// Reads another app's Safe Storage password from the login Keychain. The real one may show a
/// Keychain prompt; tests use a fake.
protocol SafeStoragePasswordReading {
    /// The password, or throws `.accessDenied` (prompt denied), `.notSignedIn` (no such item).
    func password(service: String, account: String) throws -> String
}

/// The login Keychain, read in this process so the prompt and any "Always Allow" name Dogwatch.
struct KeychainSafeStoragePasswordReader: SafeStoragePasswordReading {
    func password(service: String, account: String) throws -> String {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            guard let data = result as? Data, let password = String(data: data, encoding: .utf8), !password.isEmpty else {
                throw ProviderError.notSignedIn("\(service) is empty.")
            }
            return password
        case errSecUserCanceled, errSecAuthFailed, errSecInteractionNotAllowed:
            throw ProviderError.accessDenied("Keychain access to “\(service)” was denied. Press Refresh to be asked once more, or turn the setting off.")
        case errSecItemNotFound:
            throw ProviderError.notSignedIn("“\(service)” is not in your login Keychain.")
        default:
            throw ProviderError.accessDenied("The Keychain refused to read “\(service)” (\(status)).")
        }
    }
}

enum ElectronSafeStorage {
    static let versionPrefix = Data("v10".utf8)
    static let salt = Data("saltysalt".utf8)
    static let rounds: UInt32 = 1003
    static let keyLength = kCCKeySizeAES128
    static let iv = Data(repeating: 0x20, count: kCCBlockSizeAES128)

    /// The AES key Chromium derives from a Safe Storage password.
    static func key(from password: String) -> Data? {
        var key = Data(count: keyLength)
        let passwordBytes = Array(password.utf8)
        let status = key.withUnsafeMutableBytes { keyBuffer in
            salt.withUnsafeBytes { saltBuffer in
                CCKeyDerivationPBKDF(
                    CCPBKDFAlgorithm(kCCPBKDF2),
                    passwordBytes.map { Int8(bitPattern: $0) }, passwordBytes.count,
                    saltBuffer.bindMemory(to: UInt8.self).baseAddress, salt.count,
                    CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA1), rounds,
                    keyBuffer.bindMemory(to: UInt8.self).baseAddress, keyLength
                )
            }
        }
        return status == kCCSuccess ? key : nil
    }

    /// Decrypts a "v10" value. nil when it isn't one, or the password is wrong (bad padding).
    static func decrypt(_ value: Data, password: String) -> Data? {
        guard value.starts(with: versionPrefix), let key = key(from: password) else { return nil }
        let ciphertext = value.dropFirst(versionPrefix.count)
        guard !ciphertext.isEmpty, ciphertext.count % kCCBlockSizeAES128 == 0 else { return nil }
        return crypt(CCOperation(kCCDecrypt), Data(ciphertext), key: key)
    }

    /// Encrypts in the same format. Dogwatch never writes another app's data; this exists so tests
    /// can build sample values without a real app's key.
    static func encrypt(_ plaintext: Data, password: String) -> Data? {
        guard let key = key(from: password), let ciphertext = crypt(CCOperation(kCCEncrypt), plaintext, key: key) else { return nil }
        return versionPrefix + ciphertext
    }

    private static func crypt(_ operation: CCOperation, _ input: Data, key: Data) -> Data? {
        var output = Data(count: input.count + kCCBlockSizeAES128)
        let outputCapacity = output.count
        var written = 0
        let status = output.withUnsafeMutableBytes { outputBuffer in
            input.withUnsafeBytes { inputBuffer in
                key.withUnsafeBytes { keyBuffer in
                    iv.withUnsafeBytes { ivBuffer in
                        CCCrypt(
                            operation, CCAlgorithm(kCCAlgorithmAES), CCOptions(kCCOptionPKCS7Padding),
                            keyBuffer.baseAddress, key.count, ivBuffer.baseAddress,
                            inputBuffer.baseAddress, input.count,
                            outputBuffer.baseAddress, outputCapacity, &written
                        )
                    }
                }
            }
        }
        guard status == kCCSuccess else { return nil }
        return output.prefix(written)
    }
}
