package dev.verdeai.app

import dev.verdeai.core.CoreJson
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import okhttp3.HttpUrl
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody
import java.io.IOException
import java.util.concurrent.TimeUnit

/** Relay outcomes; exceptions never carry tokens, URLs or response bodies. */
internal class RelayException(val retryable: Boolean) : IOException("push_relay_failed")

internal enum class RelayDelete {
    /** 204, or 410 (already revoked): the capability is gone. */
    Deleted,
    /** 429, 503 or a transport failure: keep the capability and retry later. */
    Retry,
    /** Any other 4xx: the request cannot succeed as sent; stop retrying it. */
    Rejected,
}

/**
 * The C-02 push relay (verde-cloud `services/push-relay/README.md`). Public HTTPS with the
 * platform trust store; no TOFU pin. `send_token` is a bearer credential: it only ever travels in
 * a JSON body, never a URL, header or log.
 */
internal class PushRelay(private val base: HttpUrl, client: OkHttpClient = OkHttpClient()) {
    private val client = client.newBuilder()
        .followRedirects(false).followSslRedirects(false)
        .callTimeout(10, TimeUnit.SECONDS).connectTimeout(10, TimeUnit.SECONDS)
        .cache(null)
        .build()
    private val endpoint = base.newBuilder().addPathSegments("v1/register").build()

    /** `POST /v1/register {platform:"android",push_token}` → 201 `{send_token}`. */
    suspend fun register(pushToken: String): String = withContext(Dispatchers.IO) {
        val body = JsonObject(mapOf("platform" to JsonPrimitive("android"), "push_token" to JsonPrimitive(pushToken)))
        val request = Request.Builder().url(endpoint).header("Cache-Control", "no-store")
            .post(body.toString().toRequestBody(JSON)).build()
        try {
            client.newCall(request).execute().use { response ->
                if (response.code != 201) throw RelayException(retryable = response.code == 429 || response.code >= 500)
                val text = response.peekBody(MAX_RESPONSE).string()
                val token = try { CoreJson.parseToJsonElement(text).jsonObject["send_token"]?.jsonPrimitive?.content } catch (_: Exception) { null }
                if (token.isNullOrEmpty() || token.length > MAX_SEND_TOKEN || token.any { it.code !in 0x21..0x7e }) throw RelayException(retryable = true)
                token
            }
        } catch (e: RelayException) { throw e }
        catch (_: IOException) { throw RelayException(retryable = true) }
    }

    /** `DELETE /v1/register {send_token}` → 204; repeated deletion returns 410. */
    suspend fun unregister(sendToken: String): RelayDelete = withContext(Dispatchers.IO) {
        val body = JsonObject(mapOf("send_token" to JsonPrimitive(sendToken)))
        val request = Request.Builder().url(endpoint).header("Cache-Control", "no-store")
            .delete(body.toString().toRequestBody(JSON)).build()
        try {
            client.newCall(request).execute().use { response ->
                when (response.code) {
                    204, 410 -> RelayDelete.Deleted
                    429 -> RelayDelete.Retry
                    in 400..499 -> RelayDelete.Rejected
                    else -> RelayDelete.Retry
                }
            }
        } catch (_: IOException) { RelayDelete.Retry }
    }

    private companion object {
        val JSON = "application/json".toMediaType()
        const val MAX_RESPONSE = 8192L
        /** Matches the core's `push_register` bound. */
        const val MAX_SEND_TOKEN = 4096
    }
}
