import Foundation

/// Sends a request and returns the raw answer. The real one is a hardened `URLSession`;
/// tests use a fixture transport.
protocol HTTPTransport {
    func data(for request: URLRequest) async throws -> (Data, URLResponse)
}

extension URLSession: HTTPTransport {}

/// The only way a provider reaches the network. It calls nothing but the provider's declared
/// hosts, over HTTPS (plain HTTP only for `localhost` and `127.0.0.1`), keeps nothing on disk,
/// follows no redirects and logs nothing.
struct HTTPClient {
    /// No disk cache, cookies or credential store: requests carry keys and OAuth tokens, and the
    /// shared session's cache writes request headers, Authorization included, to ~/Library/Caches.
    /// Redirects are refused so a key is only ever sent to the host it was meant for.
    static let hardenedSession: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil
        configuration.timeoutIntervalForRequest = 10
        configuration.timeoutIntervalForResource = 15
        return URLSession(configuration: configuration, delegate: NoRedirects(), delegateQueue: nil)
    }()

    private final class NoRedirects: NSObject, URLSessionTaskDelegate {
        func urlSession(
            _ session: URLSession,
            task: URLSessionTask,
            willPerformHTTPRedirection response: HTTPURLResponse,
            newRequest request: URLRequest,
            completionHandler: @escaping (URLRequest?) -> Void
        ) {
            completionHandler(nil)
        }
    }

    let allowedHosts: [String]
    let transport: HTTPTransport

    init(allowedHosts: [String], transport: HTTPTransport = HTTPClient.hardenedSession) {
        self.allowedHosts = allowedHosts.map { $0.lowercased() }
        self.transport = transport
    }

    /// Throws `.hostNotAllowed` unless the URL is HTTPS to a declared host, or HTTP to localhost.
    func check(_ url: URL) throws {
        guard let host = url.host?.lowercased(), let scheme = url.scheme?.lowercased() else {
            throw ProviderError.hostNotAllowed(url.absoluteString)
        }
        let isLoopback = host == "localhost" || host == "127.0.0.1"
        guard scheme == "https" || (scheme == "http" && isLoopback) else {
            throw ProviderError.hostNotAllowed("\(scheme)://\(host)")
        }
        let declared = allowedHosts.contains { pattern in
            if pattern.hasPrefix("*.") { return host.hasSuffix(String(pattern.dropFirst(1))) }
            return host == pattern
        }
        guard declared else { throw ProviderError.hostNotAllowed(host) }
    }

    /// A 2xx answer: its body and its headers (read-only, names in lowercase), for providers that
    /// page with a `Link` header or read rate-limit headers.
    struct Response {
        let body: Data
        let status: Int
        let headers: [String: String]

        func header(_ name: String) -> String? { headers[name.lowercased()] }
    }

    /// Sends the request and returns the body of a 2xx answer. See `response(for:)`.
    func send(_ request: URLRequest) async throws -> Data {
        try await response(for: request).body
    }

    /// Sends the request and returns a 2xx answer with its headers. Other statuses become typed
    /// errors: 401 `notSignedIn`, 402 `paymentRequired`, 403 `expired`, 404 `notFound`, 429
    /// `rateLimited`, 5xx `network`, the rest `unexpectedResponse`. Messages name the status,
    /// never the request's headers.
    func response(for request: URLRequest) async throws -> Response {
        guard let url = request.url else { throw ProviderError.notConfigured("No URL") }
        try check(url)
        var request = request
        request.cachePolicy = .reloadIgnoringLocalCacheData
        if request.timeoutInterval > 15 { request.timeoutInterval = 15 }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await transport.data(for: request)
        } catch let error as ProviderError {
            throw error
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as URLError where error.code == .timedOut {
            throw ProviderError.timedOut
        } catch let error as URLError where error.code == .cancelled {
            throw CancellationError()
        } catch {
            throw ProviderError.network(error.localizedDescription)
        }

        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let host = url.host ?? "the provider"
        switch status {
        case 200..<300:
            var headers: [String: String] = [:]
            for (name, value) in (response as? HTTPURLResponse)?.allHeaderFields ?? [:] {
                if let name = name as? String, let value = value as? String { headers[name.lowercased()] = value }
            }
            return Response(body: data, status: status, headers: headers)
        case 401:
            throw ProviderError.notSignedIn("\(host) rejected the key or sign-in (HTTP 401).")
        case 402:
            throw ProviderError.paymentRequired("\(host) answered HTTP 402: the account is out of credit, or its plan doesn't include this.")
        case 403:
            throw ProviderError.expired("\(host) refused access (HTTP 403). The key may be expired or lack permission.")
        case 404:
            throw ProviderError.notFound("\(host) answered HTTP 404: it doesn't know what was asked for.")
        case 429:
            let retry = (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Retry-After").flatMap(TimeInterval.init)
            throw ProviderError.rateLimited(retryAfter: retry)
        case 500..<600:
            throw ProviderError.network("\(host) answered HTTP \(status).")
        default:
            throw ProviderError.unexpectedResponse("\(host) answered HTTP \(status).")
        }
    }

    /// A GET with the given headers.
    func get(_ url: URL, headers: [String: String] = [:]) async throws -> Data {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 10)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        return try await send(request)
    }

    /// A GET whose JSON answer must be an object.
    func getJSON(_ url: URL, headers: [String: String] = [:]) async throws -> JSONValue {
        let data = try await get(url, headers: headers)
        guard let value = try? JSONValue(data: data) else {
            throw ProviderError.unexpectedResponse("\(url.host ?? "The provider") did not answer with JSON.")
        }
        return value
    }
}
