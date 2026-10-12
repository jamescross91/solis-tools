import CryptoKit
import Foundation

public enum HubIdentityError: Error, LocalizedError, Sendable, Equatable {
    case notProven

    public var errorDescription: String? {
        "The hub found on this network could not prove it is yours, so the token was not sent to it."
    }
}

/// Checks that the hub at an address holds this client's token before the
/// token is sent there.
///
/// Anything on the LAN can advertise `_solis-hub._tcp` with any hub ID, and the
/// LAN path is plain HTTP, so a Bonjour result alone is no reason to hand it
/// the token. GET /v1/identity answers a fresh random nonce with an HMAC keyed
/// by the token, which only a hub that already has the token can produce.
public enum HubIdentity {
    public static func proof(token: String, nonce: String) -> String {
        let key = SymmetricKey(data: Data(token.utf8))
        let code = HMAC<SHA256>.authenticationCode(
            for: Data("solis-hub-identity:\(nonce)".utf8), using: key
        )
        return code.map { String(format: "%02x", $0) }.joined()
    }

    static func randomNonce() -> String {
        var generator = SystemRandomNumberGenerator()
        return (0..<16).map { _ in String(format: "%02x", UInt8.random(in: 0...255, using: &generator)) }
            .joined()
    }

    private struct Answer: Decodable {
        let proof: String
    }

    /// Throws HubIdentityError.notProven unless the hub answers correctly. The
    /// request carries no token, so a failed check gives nothing away.
    public static func verify(
        _ endpoint: HubEndpoint,
        auth: HubAuth,
        transport: any HubHTTPTransport = URLSessionHTTPTransport(),
        timeout: TimeInterval = 2
    ) async throws {
        let nonce = randomNonce()
        var request = URLRequest(url: endpoint.httpURL(path: "/v1/identity", query: [("nonce", nonce)]))
        request.timeoutInterval = timeout
        request.cachePolicy = .reloadIgnoringLocalCacheData
        let (data, response) = try await transport.fetch(request)
        guard response.statusCode == 200,
              let answer = try? JSONDecoder().decode(Answer.self, from: data),
              answer.proof == proof(token: auth.token, nonce: nonce)
        else {
            throw HubIdentityError.notProven
        }
    }

    /// The check, only for the endpoints that need it.
    static func verifyIfNeeded(
        _ endpoint: HubEndpoint, auth: HubAuth, transport: any HubHTTPTransport, timeout: TimeInterval
    ) async throws {
        guard endpoint.requiresProof else { return }
        try await verify(endpoint, auth: auth, transport: transport, timeout: timeout)
    }
}
