package app.thisdog.gassi

import app.thisdog.i18n.L
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import app.thisdog.crypto.Sealing
import app.thisdog.data.Account
import app.thisdog.data.Api
import app.thisdog.data.Kinds
import app.thisdog.model.Avatar
import app.thisdog.model.FriendKey
import app.thisdog.model.LatLng
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.launch
import kotlinx.serialization.Serializable
import kotlinx.serialization.builtins.serializer
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonElement
import java.util.Base64

/**
 * Hundefreunde: Rudel, die sich während einer Runde auf der Karte sehen (wie Friends.swift).
 *
 * Alles, was zum Freund geht, ist mit dem Schlüssel dieser Freundschaft verschlüsselt (Steckbrief, Standort);
 * der Server reicht nur Pakete weiter. Den Standort gibt es nur, solange eine Runde läuft.
 * Die Mitteilung „geht in eurer Nähe los“ braucht ein stilles Wecken per Push und kommt mit FCM.
 */
class Friends(private val account: Account, private val scope: CoroutineScope, private val notes: Notes = Notes.Memory()) {
    /** Kleine Notizen dieses Geräts (wann der Steckbrief zuletzt ging); auf Android in SharedPreferences. */
    interface Notes {
        fun get(key: String): String?
        fun put(key: String, value: String?)
        class Memory : Notes { private val m = mutableMapOf<String, String>(); override fun get(key: String) = m[key]; override fun put(key: String, value: String?) { if (value == null) m.remove(key) else m[key] = value } }
    }

    data class Friend(val pack: Int, val invite: String, val name: String, val photo: Bitmap?, val photoJpeg: String?)
    data class Spot(val pack: Int, val at: LatLng, val updatedAt: Long)
    /** Ein Freund hat eingecheckt (die letzten drei Stunden). */
    data class Visit(val pack: Int, val place: String, val at: LatLng, val time: Long)

    @Serializable private data class Card(val name: String, val photo: String? = null)
    @Serializable private data class Position(val lat: Double, val lng: Double)
    @Serializable private data class CheckInBlob(val name: String, val lat: Double, val lng: Double, val at: Double)

    var list by mutableStateOf<List<Friend>>(emptyList()); private set
    var live by mutableStateOf<List<Spot>>(emptyList()); private set
    var visits by mutableStateOf<List<Visit>>(emptyList()); private set
    var message by mutableStateOf<String?>(null)

    private val api get() = account.api
    private val store get() = account.store
    private val me get() = store.packID
    private var lastSent = 0L
    private var walkStarted: Long? = null
    private val json = Json { ignoreUnknownKeys = true; explicitNulls = false }

    private fun key(f: Friend) = store.friendKey(f.invite)?.let { Sealing.decodeKey(it.key) }

    private fun <T> seal(value: T, ser: kotlinx.serialization.KSerializer<T>, key: ByteArray, context: String) =
        Sealing.sealBlob(json.encodeToString(ser, value).toByteArray(), key, context)

    private fun <T> open(blob: String, ser: kotlinx.serialization.KSerializer<T>, key: ByteArray, context: String): T? =
        runCatching { json.decodeFromString(ser, String(Sealing.openBlob(blob, key, context))) }.getOrNull()

    // Freunde

    @Serializable private data class ListItem(val pack: Int, val invite: String, val card: String? = null)
    @Serializable private data class ListAnswer(val friends: List<ListItem> = emptyList())

    suspend fun load() {
        val me = me ?: return
        if (!account.signedIn) return
        val a = runCatching { json.decodeFromJsonElement(ListAnswer.serializer(), api.get("friends.php", mapOf("action" to "list", "pack" to "$me"))) }.getOrNull() ?: return
        list = a.friends.map { item ->
            val k = store.friendKey(item.invite)?.let { Sealing.decodeKey(it.key) }
            val card = if (k != null && item.card != null) open(item.card, Card.serializer(), k, Sealing.friendContext("card", item.pack, me)) else null
            val bytes = card?.photo?.let { runCatching { Base64.getDecoder().decode(it) }.getOrNull() }
            Friend(item.pack, item.invite, card?.name?.ifEmpty { null } ?: L.t("Hund"), bytes?.let { BitmapFactory.decodeByteArray(it, 0, it.size) }, card?.photo)
        }
        refreshCardsIfNeeded()
    }

    @Serializable private data class PackBody(val pack: Int)
    @Serializable private data class InviteAnswer(val url: String, val invite: String)

    /** Ein Link zum Teilen: thisdog.app/freund/<Geheimnis>#k=<Schlüssel der Freundschaft>. */
    suspend fun invite(): String {
        val me = me ?: throw Api.Failure.NotSignedIn
        val a = json.decodeFromJsonElement(InviteAnswer.serializer(), api.post("friends.php", mapOf("action" to "invite"), PackBody(me), PackBody.serializer()))
        val key = Sealing.newKey()
        store.upsert(Kinds.friendKey, FriendKey(a.invite, Sealing.encodeKey(key)))
        account.sync()
        return a.url + "#k=" + Sealing.encodeKey(key)
    }

    @Serializable private data class AcceptBody(val pack: Int, val invite: String)
    @Serializable private data class AcceptAnswer(val friend: Int, val invite: String)

    suspend fun accept(secret: String, key: ByteArray) {
        val me = me
        if (!account.signedIn || me == null) { message = L.t("Melde dich im Rudel an, dann öffne den Link noch einmal."); return }
        try {
            val a = json.decodeFromJsonElement(AcceptAnswer.serializer(), api.post("friends.php", mapOf("action" to "accept"), AcceptBody(me, secret), AcceptBody.serializer()))
            store.upsert(Kinds.friendKey, FriendKey(a.invite, Sealing.encodeKey(key)))
            account.sync()
            notes.put(cardStampKey, null)
            load()
            message = null
        } catch (e: Api.Failure.Server) {
            message = when (e.code) {
                "invite_used" -> L.t("Diese Einladung wurde schon benutzt. Bitte um eine neue.")
                "invite_expired" -> L.t("Diese Einladung ist abgelaufen. Bitte um eine neue.")
                "own_pack" -> L.t("Das ist eine Einladung von deinem eigenen Hund.")
                else -> L.t("Diese Einladung gibt es nicht.")
            }
        } catch (e: Exception) {
            message = L.t("Keine Verbindung. Öffne den Link gleich noch einmal.")
        }
    }

    @Serializable private data class RemoveBody(val pack: Int, val friend: Int)

    suspend fun remove(f: Friend) {
        val me = me ?: return
        runCatching { api.post("friends.php", mapOf("action" to "remove"), RemoveBody(me, f.pack), RemoveBody.serializer()) }
        store.remove(Kinds.friendKey, f.invite)
        list = list.filter { it.pack != f.pack }; live = live.filter { it.pack != f.pack }
    }

    // Steckbrief

    private val cardStampKey get() = "freunde.steckbrief.${me ?: 0}"

    @Serializable private data class Blob(val friend: Int, val blob: String)
    @Serializable private data class BlobsBody(val pack: Int, val blobs: List<Blob>)

    /** Name und Foto des eigenen Hundes gehen verschlüsselt an jeden Freund – neu, wenn sich etwas geändert hat. */
    suspend fun refreshCardsIfNeeded() {
        val me = me ?: return
        if (!account.signedIn || list.isEmpty()) return
        val photo = store.avatars.firstOrNull { it.id == Avatar.DOG }?.jpeg
        val card = Card(store.profile.name, photo)
        val stamp = "${card.name}|${photo?.length ?: 0}|${photo?.takeLast(24) ?: ""}|${list.map { it.pack }.sorted()}"
        if (notes.get(cardStampKey) == stamp) return
        val blobs = list.mapNotNull { f -> key(f)?.let { Blob(f.pack, seal(card, Card.serializer(), it, Sealing.friendContext("card", me, f.pack))) } }
        if (blobs.isEmpty()) return
        if (runCatching { api.post("friends.php", mapOf("action" to "cards"), BlobsBody(me, blobs), BlobsBody.serializer()) }.isSuccess)
            notes.put(cardStampKey, stamp)
    }

    // Unterwegs

    @Serializable private data class PositionBody(val pack: Int, val started: Long, val blobs: List<Blob>)

    /** Ein Punkt der eigenen Runde – höchstens alle 20 Sekunden an die Freunde. */
    fun walked(here: LatLng, startedAtMillis: Long) {
        val me = me ?: return
        if (!account.signedIn || list.isEmpty()) return
        val now = System.currentTimeMillis()
        if (now - lastSent < INTERVAL_MS) return
        lastSent = now
        val started = startedAtMillis / 1000
        walkStarted = started
        val pos = Position(here.lat, here.lng)
        val blobs = list.mapNotNull { f -> key(f)?.let { Blob(f.pack, seal(pos, Position.serializer(), it, Sealing.friendContext("pos", me, f.pack))) } }
        scope.launch { runCatching { api.post("friends.php", mapOf("action" to "position"), PositionBody(me, started, blobs), PositionBody.serializer()) } }
    }

    /** Die Runde ist vorbei: Der Standort verschwindet sofort vom Server. */
    fun walkEnded() {
        lastSent = 0
        val me = me ?: return
        if (walkStarted == null) return
        walkStarted = null
        scope.launch { runCatching { api.post("friends.php", mapOf("action" to "stop"), PackBody(me), PackBody.serializer()) } }
    }

    @Serializable private data class LiveItem(val pack: Int, val blob: String, val updatedAt: Long)
    @Serializable private data class LiveAnswer(val live: List<LiveItem> = emptyList())

    /** Wo Freunde gerade unterwegs sind. */
    suspend fun refreshLive() {
        val me = me
        if (!account.signedIn || me == null || list.isEmpty()) { live = emptyList(); return }
        val a = runCatching { json.decodeFromJsonElement(LiveAnswer.serializer(), api.get("friends.php", mapOf("action" to "live", "pack" to "$me"))) }.getOrNull() ?: return
        live = a.live.mapNotNull { item ->
            val f = list.firstOrNull { it.pack == item.pack } ?: return@mapNotNull null
            val k = key(f) ?: return@mapNotNull null
            val p = open(item.blob, Position.serializer(), k, Sealing.friendContext("pos", item.pack, me)) ?: return@mapNotNull null
            Spot(item.pack, LatLng(p.lat, p.lng), item.updatedAt * 1000)
        }
    }

    // Check-ins

    /** Ein Check-in geht verschlüsselt an jeden Freund; der Server löscht ihn nach drei Stunden. */
    fun checkedIn(c: CheckIn) {
        val me = me ?: return
        if (!account.signedIn || list.isEmpty()) return
        val v = CheckInBlob(c.name, c.lat, c.lon, c.at)
        val blobs = list.mapNotNull { f -> key(f)?.let { Blob(f.pack, seal(v, CheckInBlob.serializer(), it, Sealing.friendContext("checkin", me, f.pack))) } }
        scope.launch { runCatching { api.post("friends.php", mapOf("action" to "checkin"), BlobsBody(me, blobs), BlobsBody.serializer()) } }
    }

    @Serializable private data class VisitItem(val pack: Int, val blob: String)
    @Serializable private data class VisitAnswer(val checkins: List<VisitItem> = emptyList())

    /** Wo Freunde in den letzten drei Stunden eingecheckt haben. */
    suspend fun refreshVisits() {
        val me = me
        if (!account.signedIn || me == null || list.isEmpty()) { visits = emptyList(); return }
        val a = runCatching { json.decodeFromJsonElement(VisitAnswer.serializer(), api.get("friends.php", mapOf("action" to "checkins", "pack" to "$me"))) }.getOrNull() ?: return
        visits = a.checkins.mapNotNull { item ->
            val f = list.firstOrNull { it.pack == item.pack } ?: return@mapNotNull null
            val k = key(f) ?: return@mapNotNull null
            val v = open(item.blob, CheckInBlob.serializer(), k, Sealing.friendContext("checkin", item.pack, me)) ?: return@mapNotNull null
            Visit(item.pack, v.name, LatLng(v.lat, v.lng), v.at.toLong())
        }
    }

    /** Freunde, die an diesem Ort eingecheckt haben. */
    fun visits(at: Place) = visits.filter { it.place == at.name || app.thisdog.model.Track.distance(it.at, at.coordinate) < 150 }

    /** Für Bildschirmfotos (`--ez freunde true`): zwei erfundene Hunde, einer gerade unterwegs in der Nähe. */
    fun seedDemo(here: LatLng) {
        list = listOf(Friend(9001, "demo-1", L.t("Bello"), null, null), Friend(9002, "demo-2", L.t("Luna"), null, null))
        live = listOf(Spot(9001, LatLng(here.lat + 0.0021, here.lng + 0.0017), System.currentTimeMillis()))
    }

    companion object {
        /** So oft geht unterwegs ein neuer Punkt an die Freunde, und so oft schaut Gassi, wer unterwegs ist. */
        const val INTERVAL_MS = 20_000L
    }
}
