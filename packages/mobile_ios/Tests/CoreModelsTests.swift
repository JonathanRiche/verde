import XCTest
@testable import VerdeApp

final class CoreModelsTests: XCTestCase {
    func testFlatEventExplicitNullsDefaultsAndWideIntegers() throws {
        let event = Event.secure_store_value(EventSecureStoreValue(
            now_ms: 9007199254740993, wall_time_ms: 0,
            effect_id: "fixture:1", generation: "18446744073709551615",
            key: "vc/1/fixture/credential", value_base64: nil, error: nil
        ))
        let data = try JSONEncoder().encode(event)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(json["type"] as? String, "secure_store_value")
        XCTAssertEqual(json["api_version"] as? Int, 1)
        XCTAssertTrue(json["value_base64"] is NSNull)
        XCTAssertTrue(json["error"] is NSNull)
        guard case .secure_store_value(let decoded) = try JSONDecoder().decode(Event.self, from: data) else {
            return XCTFail("wrong tag")
        }
        XCTAssertEqual(decoded.now_ms, 9007199254740993)
        XCTAssertEqual(decoded.generation, "18446744073709551615")
    }

    func testEffectBatchQueryAndUnknownFields() throws {
        let data = Data(#"{"api_version":1,"revision":"18446744073709551615","effects":[{"type":"secure_store_get","effect_id":"fixture:1","generation":"0","key":"vc/1/fixture/profile","future":true},{"type":"state_changed","effect_id":"fixture:2","generation":"0","revision":"18446744073709551615","scopes":["hosts"]}]}"#.utf8)
        let batch = try JSONDecoder().decode(EffectBatch.self, from: data)
        XCTAssertEqual(batch.revision, "18446744073709551615")
        XCTAssertEqual(batch.effects.count, 2)
        let roundTrip = try JSONDecoder().decode(EffectBatch.self, from: JSONEncoder().encode(batch))
        guard case .secure_store_get(let effect) = roundTrip.effects[0] else { return XCTFail("wrong tag") }
        XCTAssertEqual(effect.key, "vc/1/fixture/profile")
        let queryData = Data(#"{"api_version":1,"revision":"0","data":{"items":[],"loading":false,"stale":false,"incomplete_scopes":[],"error":null},"error":null,"future":1}"#.utf8)
        let query = try JSONDecoder().decode(HomeQuery.self, from: queryData)
        XCTAssertEqual(query.data?.items.count, 0)
        XCTAssertNil(query.error)
    }

    func testExplicitNullOverridesNonNullDefault() throws {
        let error = try JSONDecoder().decode(LocalError.self, from: Data(#"{"code":"fixture","message":"Fixture","delivery":null}"#.utf8))
        XCTAssertNil(error.delivery)
        XCTAssertEqual(error.domain, "input")
    }

    func testUnsignedSeedAndUnknownTag() throws {
        let data = Data(#"{"api_version":1,"host_id":"fixture","label":"Fixture","https_url":null,"wss_url":null,"client_revision":1,"session_nonce":"00000000000000000000000000000000","jitter_seed":18446744073709551615}"#.utf8)
        let config = try JSONDecoder().decode(Config.self, from: data)
        XCTAssertEqual(config.jitter_seed, UInt64.max)
        let decoded = try JSONDecoder().decode(Config.self, from: JSONEncoder().encode(config))
        XCTAssertEqual(decoded.jitter_seed, UInt64.max)
        XCTAssertThrowsError(try JSONDecoder().decode(Effect.self, from: Data(#"{"type":"future_effect"}"#.utf8)))
    }
}
