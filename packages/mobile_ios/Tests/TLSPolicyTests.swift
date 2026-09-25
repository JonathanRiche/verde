import XCTest
import Security
@testable import VerdeApp

private final class TrustSpace: URLProtectionSpace, @unchecked Sendable {
    let fixtureTrust: SecTrust
    init(_ trust: SecTrust) {
        fixtureTrust = trust
        super.init(host: "bridge.invalid", port: 443, protocol: "https", realm: nil,
                   authenticationMethod: NSURLAuthenticationMethodServerTrust)
    }
    required init?(coder: NSCoder) { fatalError("fixture_only") }
    override var serverTrust: SecTrust? { fixtureTrust }
}
private final class ChallengeSender: NSObject, URLAuthenticationChallengeSender {
    func use(_ credential: URLCredential, for challenge: URLAuthenticationChallenge) {}
    func continueWithoutCredential(for challenge: URLAuthenticationChallenge) {}
    func cancel(_ challenge: URLAuthenticationChallenge) {}
}

final class TLSPolicyTests: XCTestCase {
    private let pin = "M6eHc4YC-5fLSGdFbY2Aj3och0IY0RWvaIhL1Shp_w4"

    private func trust(anchored: Bool) throws -> SecTrust {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "bridge", withExtension: "cer"))
        let data = try Data(contentsOf: url)
        let cert = try XCTUnwrap(SecCertificateCreateWithData(nil, data as CFData))
        let rootURL = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "root", withExtension: "cer"))
        let root = try XCTUnwrap(SecCertificateCreateWithData(nil, try Data(contentsOf: rootURL) as CFData))
        var trust: SecTrust?
        XCTAssertEqual(SecTrustCreateWithCertificates([cert, root] as CFArray, SecPolicyCreateSSL(true, "bridge.invalid" as CFString), &trust), errSecSuccess)
        let result = try XCTUnwrap(trust)
        // A fixed date inside the fixture validity avoids clock-dependent tests.
        SecTrustSetVerifyDate(result, Date(timeIntervalSince1970: 1_800_000_000) as CFDate)
        SecTrustSetNetworkFetchAllowed(result, false)
        if anchored { SecTrustSetAnchorCertificates(result, [root] as CFArray) }
        return result
    }

    func testDERSPKIAndSystemTrust() throws {
        let fixture = try trust(anchored: true)
        var error: CFError?
        XCTAssertTrue(SecTrustEvaluateWithError(fixture, &error), String(describing: error))
        let inspected = TLSPolicy.inspect(fixture, host: "bridge.invalid")
        XCTAssertTrue(inspected.0); XCTAssertEqual(inspected.1, pin)
        XCTAssertFalse(TLSPolicy.inspect(try trust(anchored: false), host: "bridge.invalid").0)
        XCTAssertFalse(TLSPolicy.inspect(try trust(anchored: true), host: "other.invalid").0)
        XCTAssertNil(TLSPolicy.spki(certificate: Data([0x30, 0x84, 0xff, 0xff, 0xff, 0xff])))
    }

    func testDelegateRejectsMismatchAndUntrustedPinBeforeAuthorizingRequest() throws {
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        for (anchored, expected, allowed) in [(true, pin, true), (true, "changed", false), (false, pin, false)] {
            let effect = Effect.http_request(EffectHttpRequest(effect_id: "http", generation: "1", method: "POST",
                url: "https://bridge.invalid/api/rpc", headers: [], body_base64: "c2VjcmV0", timeout_ms: 1000,
                max_response_bytes: 256, tls: Tls(origin: "https://bridge.invalid", spki_sha256: expected)))
            let operation = SessionOperation(effect: effect, queue: DispatchQueue(label: "tls.fixture"), emit: { _ in }, ended: {})
            let challenge = URLAuthenticationChallenge(protectionSpace: TrustSpace(try trust(anchored: anchored)),
                proposedCredential: nil, previousFailureCount: 0, failureResponse: nil, error: nil, sender: ChallengeSender())
            var completed = false
            operation.urlSession(session, didReceive: challenge) { disposition, credential in
                completed = true
                XCTAssertEqual(disposition, allowed ? .useCredential : .cancelAuthenticationChallenge)
                XCTAssertEqual(credential != nil, allowed)
            }
            XCTAssertTrue(completed)
        }
    }

    func testOriginValidation() {
        XCTAssertNotNil(TLSPolicy.endpoint("wss://bridge.invalid/ws", origin: "https://bridge.invalid", websocket: true))
        for raw in ["http://bridge.invalid", "https://other.invalid", "https://bridge.invalid:444", "https://user@bridge.invalid", "https://bridge.invalid/#fragment"] {
            XCTAssertNil(TLSPolicy.endpoint(raw, origin: "https://bridge.invalid", websocket: false))
        }
    }
}
