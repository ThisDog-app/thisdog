package app.thisdog.data

import java.io.IOException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import kotlinx.serialization.KSerializer
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import okhttp3.Cookie
import okhttp3.CookieJar
import okhttp3.HttpUrl
import okhttp3.HttpUrl.Companion.toHttpUrl
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody

/** Die Schnittstelle unter thisdog.app/api – dieselben Aufrufe wie Api.swift. Angemeldet wird über das Sitzungs-Cookie. */
class Api(private val base: String = "https://thisdog.app/api/", private val cookies: CookieStore = CookieStore.Memory()) {
    sealed class Failure(msg: String) : Exception(msg) {
        object NotSignedIn : Failure("not_signed_in")
        object Offline : Failure("offline")
        class Server(val code: String) : Failure(code)
    }

    /** Wo das Sitzungs-Cookie liegt (auf dem Gerät in den Einstellungen, im Test im Speicher). */
    interface CookieStore {
        fun load(): List<Cookie>
        fun save(c: List<Cookie>)
        class Memory : CookieStore { private var c = listOf<Cookie>(); override fun load() = c; override fun save(c: List<Cookie>) { this.c = c } }
    }

    private val client = OkHttpClient.Builder()
        .cookieJar(object : CookieJar {
            override fun saveFromResponse(url: HttpUrl, cookies: List<Cookie>) {
                val keep = this@Api.cookies.load().filterNot { old -> cookies.any { it.name == old.name } } + cookies
                this@Api.cookies.save(keep.filter { it.expiresAt > System.currentTimeMillis() })
            }
            override fun loadForRequest(url: HttpUrl) = this@Api.cookies.load().filter { it.matches(url) }
        })
        .callTimeout(java.time.Duration.ofSeconds(20))
        .build()

    suspend fun get(path: String, query: Map<String, String> = emptyMap()): JsonElement = send(path, query, null)

    /** Ein Bild mit weiteren Feldern als multipart/form-data (Fotos von Orten). */
    suspend fun upload(path: String, query: Map<String, String>, fields: Map<String, String>, file: String, jpeg: ByteArray): JsonElement = withContext(Dispatchers.IO) {
        val form = okhttp3.MultipartBody.Builder().setType(okhttp3.MultipartBody.FORM).apply {
            fields.forEach { (k, v) -> addFormDataPart(k, v) }
            addFormDataPart(file, "foto.jpg", jpeg.toRequestBody("image/jpeg".toMediaType()))
        }.build()
        val url = (base + path).toHttpUrl().newBuilder().apply { query.forEach { (k, v) -> addQueryParameter(k, v) } }.build()
        val response = try { client.newBuilder().callTimeout(java.time.Duration.ofSeconds(60)).build().newCall(Request.Builder().url(url).post(form).build()).execute() } catch (e: IOException) { throw Failure.Offline }
        response.use { r ->
            val text = r.body.string()
            if (r.code == 401) throw Failure.NotSignedIn
            if (r.code !in 200..299) throw Failure.Server(runCatching { ThisDogJson.parseToJsonElement(text).jsonObject["error"]?.jsonPrimitive?.content }.getOrNull() ?: "status_${r.code}")
            ThisDogJson.parseToJsonElement(text)
        }
    }

    /** Ein Bild laden (Fotos von Orten), mit der Sitzung – eigene, noch nicht freigegebene Fotos brauchen sie. */
    suspend fun bytes(url: String): ByteArray? = withContext(Dispatchers.IO) {
        runCatching { client.newCall(Request.Builder().url(url).build()).execute().use { if (it.isSuccessful) it.body.bytes() else null } }.getOrNull()
    }

    suspend fun <B> post(path: String, query: Map<String, String> = emptyMap(), body: B, serializer: KSerializer<B>): JsonElement =
        send(path, query, ThisDogJson.encodeToString(serializer, body))

    suspend fun post(path: String, query: Map<String, String> = emptyMap(), body: JsonElement): JsonElement =
        send(path, query, ThisDogJson.encodeToString(JsonElement.serializer(), body))

    private suspend fun send(path: String, query: Map<String, String>, body: String?): JsonElement = withContext(Dispatchers.IO) {
        val url = (base + path).toHttpUrl().newBuilder().apply { query.toSortedMap().forEach { (k, v) -> addQueryParameter(k, v) } }.build()
        val req = Request.Builder().url(url).apply {
            if (body != null) post(body.toRequestBody("application/json".toMediaType()))
        }.build()
        val response = try { client.newCall(req).execute() } catch (e: IOException) { throw Failure.Offline }
        response.use { r ->
            val text = r.body.string()
            if (r.code == 401) throw Failure.NotSignedIn
            if (r.code !in 200..299) {
                val code = runCatching { ThisDogJson.parseToJsonElement(text).jsonObject["error"]?.jsonPrimitive?.content }.getOrNull()
                throw Failure.Server(code ?: "status_${r.code}")
            }
            ThisDogJson.parseToJsonElement(text)
        }
    }
}

// MARK: Antworten

@Serializable data class Me(val signedIn: Boolean, val email: String? = null)
/**
 * Ein Mitglied im Rudel. `role`: „owner“ (Besitzer) oder „sitter“ (Hundesitter); ältere Server kennen keine Rollen,
 * dann Besitzer. `notifyAllowed` legen Besitzer fest, `notifyWanted` das Mitglied selbst.
 */
@Serializable data class Member(
    val id: Int, val name: String, val joinedAt: Int,
    val role: String? = null,
    val notifyAllowed: List<String>? = null,
    val notifyWanted: List<String>? = null,
) {
    val isOwner: Boolean get() = role != "sitter"
    val roleLabel: String get() = if (isOwner) app.thisdog.i18n.L.t("Besitzer") else app.thisdog.i18n.L.t("Hundesitter")
    /** Was es tatsächlich bekommt: erlaubt und gewollt. */
    val notifies: List<NotifyKind> get() = NotifyKind.entries.filter { (notifyAllowed ?: emptyList()).contains(it.key) && (notifyWanted ?: emptyList()).contains(it.key) }
}

/** Wofür es sichtbare Mitteilungen gibt (wie NOTIFY_KINDS auf dem Server). */
enum class NotifyKind(val key: String) {
    TERMINE("termine"), GESUNDHEIT("gesundheit"), TAGEBUCH("tagebuch"), NOTFALL("notfall");

    val title: String get() = when (this) {
        TERMINE -> app.thisdog.i18n.L.t("Termine")
        GESUNDHEIT -> app.thisdog.i18n.L.t("Gesundheit")
        TAGEBUCH -> app.thisdog.i18n.L.t("Tagebuch")
        NOTFALL -> app.thisdog.i18n.L.t("Notfall")
    }
    val detail: String get() = when (this) {
        TERMINE -> app.thisdog.i18n.L.t("Ein Termin wird eingetragen, geändert oder gelöscht.")
        GESUNDHEIT -> app.thisdog.i18n.L.t("Impfung, Entwurmung, Medikament oder Gewicht.")
        TAGEBUCH -> app.thisdog.i18n.L.t("Ein neuer Eintrag im Gesundheitstagebuch.")
        NOTFALL -> app.thisdog.i18n.L.t("Jemand öffnet den Notfallpass, oder der Hund ist entlaufen.")
    }
    companion object { val keys: List<String> get() = entries.map { it.key } }
}
/** `openInvites`: wie viele Einladungslinks noch gelten (nur für Besitzer von Belang; ältere Server: 0). */
@Serializable data class Pack(val id: Int, val members: List<Member>, val sealed: Boolean? = null, val openInvites: Int = 0)
@Serializable data class PackList(val me: Int, val packs: List<Pack>)
@Serializable data class Invite(val url: String, val expiresAt: Double)
@Serializable data class JoinResult(val pack: Int, val already: Boolean = false)
/** `more`: Die Seite war voll (5000 Datensätze), mit `since = rev` kommt der Rest. Ältere Server: false. */
@Serializable data class SyncResponse(val pack: Int? = null, val rev: Int, val records: List<SyncRecord>, val more: Boolean = false)
