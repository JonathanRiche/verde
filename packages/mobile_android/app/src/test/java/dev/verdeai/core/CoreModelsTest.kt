package dev.verdeai.core

import kotlinx.serialization.encodeToString
import kotlinx.serialization.decodeFromString
import kotlinx.serialization.json.*
import org.junit.Assert.*
import org.junit.Test

class CoreModelsTest {
    @Test fun eventEncodingUsesFlatTagsExplicitNullsAndDefaults() {
        val event: Event = EventSecureStoreValue(
            now_ms = 9007199254740993L, wall_time_ms = 0,
            effect_id = "fixture:1", generation = "18446744073709551615",
            key = "vc/1/fixture/credential", value_base64 = null, error = null
        )
        val json = CoreJson.parseToJsonElement(CoreJson.encodeToString(event)).jsonObject
        assertEquals("secure_store_value", json["type"]!!.jsonPrimitive.content)
        assertEquals(1L, json["api_version"]!!.jsonPrimitive.long)
        assertEquals(9007199254740993L, json["now_ms"]!!.jsonPrimitive.long)
        assertEquals(JsonNull, json["value_base64"])
        assertEquals(JsonNull, json["error"])
        assertEquals(event, CoreJson.decodeFromString<Event>(json.toString()))
    }

    @Test fun effectBatchAndQueryDecodeWithUnknownFieldsAndLargeCounters() {
        val batch = CoreJson.decodeFromString<EffectBatch>("""{"api_version":1,"revision":"18446744073709551615","effects":[{"type":"secure_store_get","effect_id":"fixture:1","generation":"0","key":"vc/1/fixture/profile","future":true},{"type":"state_changed","effect_id":"fixture:2","generation":"0","revision":"18446744073709551615","scopes":["hosts"]}]}""")
        assertEquals("18446744073709551615", batch.revision)
        assertTrue(batch.effects[0] is EffectSecureStoreGet)
        assertEquals(batch, CoreJson.decodeFromString<EffectBatch>(CoreJson.encodeToString(batch)))
        val query = CoreJson.decodeFromString<HomeQuery>("""{"api_version":1,"revision":"0","data":{"items":[],"loading":false,"stale":false,"incomplete_scopes":[],"error":null},"error":null,"future":1}""")
        assertTrue(query.data!!.items.isEmpty())
        assertNull(query.error)
    }

    @Test fun explicitNullOverridesNonNullDefault() {
        val error = CoreJson.decodeFromString<LocalError>("""{"code":"fixture","message":"Fixture","delivery":null}""")
        assertNull(error.delivery)
        assertEquals("input", error.domain)
    }

    @Test fun unsignedSeedDoesNotLosePrecision() {
        val config = CoreJson.decodeFromString<Config>("""{"api_version":1,"host_id":"fixture","label":"Fixture","https_url":null,"wss_url":null,"client_revision":1,"session_nonce":"00000000000000000000000000000000","jitter_seed":18446744073709551615}""")
        assertEquals(ULong.MAX_VALUE, config.jitter_seed)
        assertEquals(config, CoreJson.decodeFromString<Config>(CoreJson.encodeToString(config)))
    }

    @Test fun unknownEffectTagFailsInsteadOfDroppingWork() {
        assertThrows(Exception::class.java) {
            CoreJson.decodeFromString<Effect>("""{"type":"future_effect","effect_id":"fixture:1","generation":"0"}""")
        }
    }
}
