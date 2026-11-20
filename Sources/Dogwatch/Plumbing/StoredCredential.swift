import Foundation

/// Reads a token another tool stored, exactly as stored. This is the only sanctioned way to use
/// another tool's login: never refresh it, rotate it, write it, start a login or open a browser.
/// An expired or missing token becomes "open <tool> to sign in again", before any request.
///
/// Why: refreshing a login outside its own tool can rotate the refresh token and sign that tool
/// out, and a failed refresh can make the tool delete its stored login.
enum StoredCredential {
    /// Treats tokens expiring within this many seconds as expired, so a request never races
    /// the expiry.
    static let margin: TimeInterval = 60

    /// The token at `tokenPath` in a JSON document, checked against the expiry at `expiryPath`
    /// (epoch seconds, epoch milliseconds or ISO 8601), or against a JWT's own `exp` claim.
    static func token(
        in json: JSONValue,
        tokenPath: String,
        expiryPath: String? = nil,
        tool: String,
        now: Date
    ) throws -> String {
        guard let token = json.value(at: tokenPath)?.stringValue, !token.isEmpty else {
            throw ProviderError.notSignedIn("\(tool) sign-in not found. Open \(tool) to sign in.")
        }
        let expiry = expiryPath.flatMap { DateParsing.date(json.value(at: $0)) } ?? jwtExpiry(token)
        if let expiry, expiry <= now.addingTimeInterval(margin) {
            throw ProviderError.expired("\(tool)'s sign-in has expired. Open \(tool) to sign in again.")
        }
        return token
    }

    /// Reads `file` (another tool's own credential file) and returns its token. A missing or
    /// unreadable file means the tool isn't signed in.
    static func token(
        file: URL,
        local: LocalTools,
        tokenPath: String,
        expiryPath: String? = nil,
        tool: String,
        now: Date
    ) throws -> String {
        guard local.fileExists(file), let data = try? local.read(file), let json = try? JSONValue(data: data) else {
            throw ProviderError.notSignedIn("\(tool) sign-in not found. Open \(tool) to sign in.")
        }
        return try token(in: json, tokenPath: tokenPath, expiryPath: expiryPath, tool: tool, now: now)
    }

    /// The `exp` claim of a JWT, decoded locally. nil when the token isn't a JWT.
    static func jwtExpiry(_ token: String) -> Date? {
        let parts = token.split(separator: ".")
        guard parts.count == 3 else { return nil }
        var payload = String(parts[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while payload.count % 4 != 0 { payload += "=" }
        guard let data = Data(base64Encoded: payload), let claims = try? JSONValue(data: data),
              let exp = claims["exp"]?.doubleValue
        else { return nil }
        return Date(timeIntervalSince1970: exp)
    }
}
