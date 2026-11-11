package app.thisdog.data

import app.thisdog.i18n.L
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import app.thisdog.crypto.Sealing
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.boolean
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive

/**
 * Anmeldung, Rudel und Abgleich – wie Account.swift. Ein Konto entsteht ohne E-Mail für dieses Telefon, sobald es
 * gebraucht wird (Einladung, Rudel, Notfallpass). Eine Adresse kann man freiwillig hinzufügen – dann geht es per Code
 * oder Link aus der Mail, auch auf einem neuen Telefon.
 * Jeder Datensatz geht Ende-zu-Ende verschlüsselt an den Server; den Schlüssel haben nur die Geräte des Rudels.
 */
class Account(val api: Api, val store: DogStore, private val keys: KeyVault, private val scope: CoroutineScope) {
    sealed interface State {
        object Unknown : State; object SignedOut : State
        data class LinkSent(val email: String) : State
        /** `email` ist null bei einem Konto nur für dieses Telefon. */
        data class SignedIn(val email: String?) : State
    }

    var state by mutableStateOf<State>(State.Unknown); private set
    var packs by mutableStateOf<List<Pack>>(emptyList()); private set
    var me by mutableStateOf<Int?>(null); private set
    var syncing by mutableStateOf(false); private set
    var lastSync by mutableStateOf<Long?>(null); private set
    var lastError by mutableStateOf<String?>(null); private set
    var keyMissing by mutableStateOf(false); private set
    var joinMessage by mutableStateOf<String?>(null)
    /** Zählt hoch, wenn ein Link ankommt; die App zeigt dann das Rudel-Fenster mit Anmeldung oder Ergebnis. */
    var linkArrived by mutableStateOf(0)
    /** Zählt hoch, wenn eine Einladung als Hundefreund ankommt; die App wechselt dann zu Gassi. */
    var friendArrived by mutableStateOf(0)
    /** Eine Einladung wird gerade eingelöst (Konto anlegen, beitreten, abgleichen). */
    var joining by mutableStateOf(false); private set
    /** Angemeldet ohne E-Mail, und eine Adresse ist unterwegs: Der Code aus der Mail hängt sie an dieses Konto. */
    var addingEmail by mutableStateOf<String?>(null)

    private var pendingInvite: String? = null
    private var pendingKey: ByteArray? = null
    /** Die Hundefreunde dieses Rudels; Graph setzt sie, weil sie eigene Einstellungen brauchen. */
    lateinit var friends: app.thisdog.gassi.Friends
    private val syncLock = Mutex()
    private var pendingSync: Job? = null

    val currentPack get() = packs.firstOrNull { it.id == store.packID } ?: packs.firstOrNull()
    val signedIn get() = state is State.SignedIn
    /** Angemeldet, aber ohne E-Mail: Abmelden hieße, nie wieder hineinzukommen. */
    val deviceOnly get() = (state as? State.SignedIn)?.email == null && signedIn

    // MARK: Anmelden

    /** Nur zum Ansehen (Debug, Extra `rudeldemo`): ein Rudel mit Alex (Besitzer) und Anna (Hundesitterin), ohne Server. */
    var demo = false; private set
    fun demoPack() {
        demo = true
        val all = NotifyKind.keys
        packs = listOf(Pack(1, listOf(Member(1, "Alex", 1_755_000_000, "owner", all, all), Member(2, "Anna", 1_756_000_000, "sitter", all, listOf("notfall"))), true))
        me = 1
        state = State.SignedIn("alex@example.org")
    }

    suspend fun refresh() {
        if (demo) return
        // Ohne Verbindung oder bei einem Fehler des Servers bleibt der Zustand, wie er ist (beim Start: unbekannt) –
        // abgemeldet ist nur, wen der Server nicht kennt. Der nächste Abgleich fragt dann noch einmal.
        try { checkSession() } catch (e: Exception) { return }
        // Während eine Einladung eingelöst wird, nichts dazwischenfunken: Ein Laden der Rudel vor dem Beitritt legte
        // ein leeres eigenes an.
        if (signedIn && !joining) { loadPacks(); sync() }
    }

    /** Fragt den Server, wer angemeldet ist. Wirft bei Netz- und Serverfehlern; nur „nicht angemeldet“ meldet ab. */
    private suspend fun checkSession() {
        val m = try { ThisDogJson.decodeFromJsonElement(Me.serializer(), api.get("auth.php", mapOf("action" to "me"))) }
            catch (e: Api.Failure.NotSignedIn) { Me(signedIn = false) }
        // Eine Antwort von vor dem Anlegen des Kontos (Einladung) meldete es sonst wieder ab.
        if (m.signedIn) state = State.SignedIn(m.email)
        else if (state !is State.LinkSent && !joining) state = State.SignedOut
    }

    /**
     * Sorgt für ein Konto: Ist niemand angemeldet, legt der Server eines ohne E-Mail für dieses Telefon an.
     * Gibt zurück, ob es neu ist.
     */
    suspend fun ensureAccount(): Boolean {
        // Bleibt offen, ob schon jemand angemeldet ist, kein zweites Konto anlegen – der Fehler geht an den Aufrufer.
        if (state == State.Unknown) checkSession()
        if (signedIn) return false
        val a = api.post("auth.php", mapOf("action" to "start"), JsonObject(emptyMap())).jsonObject
        state = State.SignedIn(a["email"]?.jsonPrimitive?.takeIf { it.isString }?.content)
        return true
    }

    /** Ein eigenes Rudel, bereit zum Einladen: anlegen (falls nötig), alles hochladen, Schlüssel erzeugen. */
    suspend fun ensureOwnPack() {
        val fresh = ensureAccount()
        if (fresh || packs.isEmpty()) {
            loadPacks()
            store.markAllChanged()
            sync()
        }
    }

    suspend fun requestLink(email: String) {
        api.post("auth.php", mapOf("action" to "request"), obj("email" to email, "app" to true, "hasData" to store.events.isNotEmpty()))
        // Mit Konto ohne Adresse bleibt man angemeldet; der Code hängt die Adresse dann an dieses Konto.
        if (signedIn) addingEmail = email else state = State.LinkSent(email)
    }

    suspend fun confirm(secret: String) {
        val a = api.post("auth.php", mapOf("action" to "confirm"), obj("t" to secret)).jsonObject
        state = State.SignedIn(a["email"]?.jsonPrimitive?.content ?: "")
        afterSignIn()
    }

    suspend fun enterCode(code: String) {
        addingEmail?.let { email ->
            api.post("auth.php", mapOf("action" to "code"), obj("email" to email, "code" to code))
            addingEmail = null
            // Gehörte die Adresse schon einem anderen Konto, ist man jetzt dort: Rudel neu laden.
            refresh()
            return
        }
        val email = (state as? State.LinkSent)?.email ?: return
        api.post("auth.php", mapOf("action" to "code"), obj("email" to email, "code" to code))
        state = State.SignedIn(email)
        afterSignIn()
    }

    suspend fun signOut() {
        runCatching { api.post("auth.php", mapOf("action" to "logout"), JsonObject(emptyMap())) }
        state = State.SignedOut; packs = emptyList(); keyMissing = false; store.resetSync()
    }

    fun startOver() { if (addingEmail != null) addingEmail = null else state = State.SignedOut }

    /** Konto löschen: auf dem Server E-Mail, Anmeldungen, Gerätekennungen und Rudel ohne weitere Mitglieder. */
    suspend fun deleteAccount() {
        api.post("auth.php", mapOf("action" to "delete"), JsonObject(emptyMap()))
        packs.forEach { keys.removePackKey(it.id) }
        state = State.SignedOut; packs = emptyList(); keyMissing = false; store.resetSync()
    }

    /** Eine gescannte oder eingefügte Adresse wie einen geöffneten Link behandeln. */
    fun open(url: String): Boolean {
        val u = runCatching { java.net.URI(url.trim()) }.getOrNull() ?: return false
        if (u.host != "thisdog.app") return false
        return open(u.rawPath ?: return false, u.rawFragment)
    }

    /** Ein App-Link: thisdog.app/anmelden/<Geheimnis>, /rudel/<Geheimnis>#k=…, /freund/<Geheimnis>#k=…. */
    fun open(path: String, fragment: String?): Boolean {
        val parts = path.trim('/').split('/')
        if (parts.size != 2) return false
        val secret = parts[1]
        when (parts[0]) {
            "anmelden" -> scope.launch { runCatching { confirm(secret) }.onFailure { joinMessage = message(it) } }
            "rudel" -> {
                pendingKey = Sealing.keyFromFragment(fragment)
                // Ohne Konto entsteht eins für dieses Telefon – keine E-Mail, kein Code. Beigetreten wird vor dem
                // ersten Laden der Rudel, sonst legte der Server erst noch ein leeres eigenes an.
                joining = true; joinMessage = null
                scope.launch {
                    try { ensureAccount(); acceptInvite(secret) }
                    catch (e: Exception) { joinMessage = message(e); pendingInvite = secret }
                    finally { joining = false }
                }
            }
            "freund" -> {
                val key = Sealing.keyFromFragment(fragment)
                if (key == null) friends.message = L.t("Dieser Link ist unvollständig. Bitte um einen neuen.")
                else scope.launch {
                    runCatching { if (!signedIn) ensureOwnPack(); friends.accept(secret, key) }.onFailure { friends.message = message(it) }
                }
                friendArrived++
                return true
            }
            else -> return false
        }
        linkArrived++
        return true
    }

    private suspend fun acceptInvite(secret: String) {
        try { join(secret); joinMessage = null } catch (e: Exception) { joinMessage = message(e) }
        pendingInvite = null
    }

    /** Den eigenen Namen im Rudel sichern, auch wenn der Bildschirm gerade schließt. */
    fun saveNameLater(name: String) {
        val mine = currentPack?.members?.firstOrNull { it.id == me }?.name
        if (name.isBlank() || name.trim() == mine) return
        scope.launch { setName(name.trim()) }
    }

    private suspend fun afterSignIn() {
        pendingInvite?.let { acceptInvite(it) }
        loadPacks()
        // Gerade in ein Rudel gekommen, das hier noch nie abgeglichen wurde: wie beim Beitreten – Profil und Hundebild
        // des Rudels gelten. Sonst überschriebe ein neues Gerät mit dem beim Einrichten Getippten alles.
        val joined = syncLock.withLock {
            val pack = store.packID
            if (pack != null && store.rev == 0) { store.joinPack(pack); true } else false
        }
        if (joined) { if (sync()) { store.claimUnanswered(); sync() } }
        else {
            // Alles, was vorher nur hier lag, geht beim ersten Abgleich ins Rudel.
            store.markAllChanged()
            sync()
        }
    }

    // MARK: Rudel

    suspend fun loadPacks() {
        val list = runCatching { ThisDogJson.decodeFromJsonElement(PackList.serializer(), api.get("pack.php", mapOf("action" to "list"))) }.getOrNull() ?: return
        packs = list.packs; me = list.me
        if (store.packID == null || packs.none { it.id == store.packID }) store.switchPack(packs.firstOrNull()?.id)
    }

    /** Der Einladungslink trägt den Rudel-Schlüssel hinter dem `#` – so kommt er beim neuen Mitglied an, ohne je beim Server zu liegen. */
    suspend fun invite(role: String = "owner"): Invite {
        val id = currentPack?.id ?: throw Api.Failure.NotSignedIn
        val key = packKey(id) ?: throw Api.Failure.Server("key_missing")
        val inv = ThisDogJson.decodeFromJsonElement(Invite.serializer(), api.post("pack.php", mapOf("action" to "invite"), obj("pack" to id, "role" to role)))
        // Damit „Einladungslinks ungültig machen“ gleich erscheint (openInvites).
        loadPacks()
        return inv.copy(url = inv.url + "#k=" + Sealing.encodeKey(key))
    }

    suspend fun join(secret: String) {
        val r = ThisDogJson.decodeFromJsonElement(JoinResult.serializer(), api.post("pack.php", mapOf("action" to "join"), obj("invite" to secret)))
        // Ein Schlüssel, der hier schon die Daten öffnet, bleibt: Ein Link mit einem alten Schlüssel überschriebe ihn sonst.
        pendingKey?.let { if (keys.packKey(r.pack) == null || keyMissing) keys.setPackKey(it, r.pack) }
        pendingKey = null
        // Schon dabei (eigener Link, zweites Gerät): nichts verwerfen, nur abgleichen.
        if (r.already && store.packID == r.pack) { sync(); return }
        // Was das Rudel schon hat (Profil, Hundebild), gilt; Termine, Runden und Einträge von hier wandern mit.
        // Erst wechseln, wenn ein laufender Abgleich fertig ist – seine Antwort gehört noch zum alten Rudel.
        syncLock.withLock { store.joinPack(r.pack) }
        loadPacks()
        // Erst wenn das Rudel geantwortet hat und sich alles öffnen ließ, ist klar, was es nicht hat.
        if (sync()) { store.claimUnanswered(); sync() }
    }

    /** Ein gemerkter Einladungslink (ohne Schlüssel) wieder mit dem Schlüssel des Rudels. */
    suspend fun withKey(url: String, pack: Int): String? = packKey(pack)?.let { url + "#k=" + Sealing.encodeKey(it) }

    /** Ich bin Besitzer im aktuellen Rudel (ohne Rudel oder auf älteren Servern: ja). */
    val isOwner: Boolean get() = currentPack?.members?.firstOrNull { it.id == me }?.isOwner ?: true

    /** Rolle eines Mitglieds ändern – nur Besitzer. Wirft `Api.Failure.Server("last_owner" | "not_owner")`. */
    suspend fun setRole(role: String, of: Int) {
        val id = currentPack?.id ?: return
        api.post("pack.php", mapOf("action" to "role"), obj("pack" to id, "member" to of, "role" to role))
        loadPacks()
    }

    /** `allowed` dürfen nur Besitzer setzen, `wanted` nur man selbst; null lässt den Wert, wie er ist. */
    suspend fun setNotify(of: Int, allowed: List<String>? = null, wanted: List<String>? = null) {
        val id = currentPack?.id ?: return
        val body = buildMap<String, kotlinx.serialization.json.JsonElement> {
            put("pack", JsonPrimitive(id)); put("member", JsonPrimitive(of))
            allowed?.let { put("allowed", kotlinx.serialization.json.JsonArray(it.map(::JsonPrimitive))) }
            wanted?.let { put("wanted", kotlinx.serialization.json.JsonArray(it.map(::JsonPrimitive))) }
        }
        api.post("pack.php", mapOf("action" to "notify"), JsonObject(body))
        loadPacks()
    }

    suspend fun setName(name: String) {
        val id = currentPack?.id ?: return
        runCatching { api.post("pack.php", mapOf("action" to "name"), obj("pack" to id, "name" to name)) }
        loadPacks()
    }

    /**
     * Ein anderes Mitglied aus dem Rudel nehmen – nur Besitzer. Es verliert sofort den Zugang; was schon auf seinem
     * Telefon liegt, bleibt dort. Wirft `Api.Failure.Server("not_owner" | "use_leave" | "not_a_member")`.
     */
    suspend fun remove(member: Int) {
        val id = currentPack?.id ?: return
        api.post("pack.php", mapOf("action" to "remove"), obj("pack" to id, "member" to member))
        loadPacks()
    }

    /** Alle offenen Einladungslinks des aktuellen Rudels ungültig machen – nur Besitzer. Gibt zurück, wie viele es waren. */
    suspend fun revokeInvites(): Int {
        val id = currentPack?.id ?: return 0
        val r = api.post("pack.php", mapOf("action" to "revoke_invites"), obj("pack" to id)).jsonObject
        loadPacks()
        return r["revoked"]?.jsonPrimitive?.content?.toIntOrNull() ?: 0
    }

    suspend fun leave() {
        val id = currentPack?.id ?: return
        api.post("pack.php", mapOf("action" to "leave"), obj("pack" to id))
        keys.removePackKey(id)
        syncLock.withLock { store.switchPack(null, keepLocal = false) }
        loadPacks(); sync()
    }

    fun name(of: Int?): String? = if (of == null || of == me) null else currentPack?.members?.firstOrNull { it.id == of }?.name

    // MARK: Abgleich

    /** Nach einer Änderung kurz warten: Wer drei Felder ändert, löst einen Abgleich aus, nicht drei. */
    fun scheduleSync() {
        pendingSync?.cancel()
        pendingSync = scope.launch { delay(2000); sync() }
    }

    @Serializable private data class PushBody(val since: Int, val records: List<SyncRecord>)

    /** Der Wiederherstellungsschlüssel des aktuellen Rudels, falls dieses Gerät den Schlüssel hat. */
    fun recoveryCode(): String? = currentPack?.let { keys.packKey(it.id) }?.let(app.thisdog.crypto.RecoveryCode::encode)

    /**
     * Holt den Schlüssel mit dem Wiederherstellungsschlüssel zurück. Geprüft wird an den Daten des Rudels, bevor er
     * gespeichert wird: Mit dem falschen Schlüssel ließe sich sonst nichts mehr abgleichen.
     */
    suspend fun restore(code: String) {
        val pack = currentPack?.id ?: throw Api.Failure.Server("key_missing")
        val key = app.thisdog.crypto.RecoveryCode.decode(code) ?: throw app.thisdog.crypto.RecoveryCode.Failure.Invalid
        val r = ThisDogJson.decodeFromJsonElement(SyncResponse.serializer(),
            api.post("sync.php", mapOf("action" to "push", "pack" to "$pack"), PushBody(0, emptyList()), PushBody.serializer()))
        if (!app.thisdog.crypto.RecoveryCode.fits(key, r.records, pack)) throw app.thisdog.crypto.RecoveryCode.Failure.WrongPack
        keys.setPackKey(key, pack)
        keyMissing = false; lastError = null
        sync()
    }

    /**
     * Gleicht das aktuelle Rudel ab. Läuft schon ein Abgleich, wartet dieser und kommt danach – nichts geht verloren.
     * Gibt zurück, ob das Rudel geantwortet hat und sich alles öffnen ließ.
     */
    suspend fun sync(): Boolean {
        // Beim Start ohne Verbindung blieb offen, ob jemand angemeldet ist: jetzt noch einmal fragen.
        if (state == State.Unknown && !demo) {
            if (runCatching { checkSession() }.isSuccess && signedIn && !joining) loadPacks()
        }
        return syncLock.withLock { syncLocked() }
    }

    private suspend fun syncLocked(): Boolean {
        val pack = store.packID ?: return false
        if (!signedIn) return false
        syncing = true
        try {
            val key = packKey(pack)
            // Inzwischen verlassen oder gewechselt (packKey lädt die Rudel neu): nichts mehr anwenden.
            if (store.packID != pack) return false
            if (key == null) { if (keyMissing) lastError = L.t("Auf diesem Gerät fehlt der Schlüssel des Rudels."); return false }
            val outgoing = store.outgoingRecords()
            val sealed = outgoing.map { seal(it, pack, key) }
            var r = ThisDogJson.decodeFromJsonElement(SyncResponse.serializer(),
                api.post("sync.php", mapOf("action" to "push", "pack" to "$pack"), PushBody(store.rev, sealed), PushBody.serializer()))
            var sent = outgoing
            var failed = false
            while (true) {
                // Inzwischen beigetreten, verlassen oder gewechselt: Die Antwort gehört zu einem anderen Rudel.
                if (store.packID != pack) return false
                val (opened, pageFailed) = open(r.records, pack, key)
                failed = failed || pageFailed
                // Ließ sich etwas nicht öffnen (anderer Schlüssel), bleibt die Revision stehen.
                store.applyIncoming(opened, nextRev(store.rev, r.rev, failed), sent)
                sent = emptyList()
                // Eine volle Seite: Der Rest kommt seitenweise nach (ab `r.rev`, auch wenn die Revision hier stehen
                // blieb). Erst danach ist der Abgleich vollständig – vorher schlösse „hat das Rudel nicht“ zu früh.
                if (!r.more || r.rev <= 0) break
                r = ThisDogJson.decodeFromJsonElement(SyncResponse.serializer(),
                    api.post("sync.php", mapOf("action" to "push", "pack" to "$pack"), PushBody(r.rev, emptyList()), PushBody.serializer()))
            }
            lastSync = System.currentTimeMillis()
            lastError = if (failed) L.t("Einige Daten im Rudel lassen sich mit dem Schlüssel dieses Geräts nicht öffnen.") else null
            return !failed
        } catch (e: Api.Failure.NotSignedIn) {
            state = State.SignedOut
        } catch (e: Api.Failure.Server) {
            if (e.code == "not_a_member") { if (store.packID == pack) store.switchPack(null, keepLocal = true); loadPacks() }
            else lastError = L.t("Abgleich nicht möglich, die Änderungen bleiben auf dem Gerät.")
        } catch (e: Exception) {
            lastError = L.t("Abgleich nicht möglich, die Änderungen bleiben auf dem Gerät.")
        } finally { syncing = false }
        return false
    }

    /**
     * Der Schlüssel des Rudels – vom Gerät, sonst (einmalig) neu angelegt. Neu angelegt wird nur, solange das Rudel
     * noch nicht verschlüsselt ist; vorher holt das Gerät alles, was im Klartext auf dem Server liegt.
     */
    suspend fun packKey(pack: Int): ByteArray? {
        keys.packKey(pack)?.let { keyMissing = false; return it }
        if (packs.firstOrNull { it.id == pack }?.sealed == true) { keyMissing = true; return null }
        return try {
            var since = store.rev
            var skipped = false
            // Seitenweise, bis alles Klartext-Vorhandene da ist – danach wird alles mit dem neuen Schlüssel hochgeladen.
            do {
                val r = ThisDogJson.decodeFromJsonElement(SyncResponse.serializer(),
                    api.post("sync.php", mapOf("action" to "push", "pack" to "$pack"), PushBody(since, emptyList()), PushBody.serializer()))
                // Inzwischen gewechselt: Die Antwort gehört nicht zu dem Rudel auf dem Gerät.
                if (store.packID != pack) return null
                val plain = r.records.filter { !Sealing.isSealed(it.payload) }
                // Fiel Versiegeltes heraus, bleibt die Revision stehen – sonst käme es mit dem Schlüssel nie wieder.
                skipped = skipped || plain.size < r.records.size
                store.applyIncoming(plain, nextRev(store.rev, r.rev, skipped), emptyList())
                since = r.rev
            } while (r.more && r.rev > 0)
            val granted = api.post("pack.php", mapOf("action" to "seal"), obj("pack" to pack)).jsonObject["granted"]?.jsonPrimitive?.boolean == true
            if (!granted) { keyMissing = true; return null }
            val key = Sealing.newKey()
            keys.setPackKey(key, pack)
            store.markAllChanged()
            keyMissing = false
            loadPacks()
            key
        } catch (e: Exception) { null }
    }

    companion object {
        /** Die Revision nach einem Abgleich: Fiel etwas heraus (versiegelt, nicht zu öffnen), bleibt die alte. */
        fun nextRev(current: Int, received: Int, skipped: Boolean) = if (skipped) current else received

        fun seal(r: SyncRecord, pack: Int, key: ByteArray): SyncRecord =
            r.payload?.let { r.copy(payload = Sealing.seal(it, key, Sealing.recordContext(pack, r.kind, r.id))) } ?: r

        /** Grabsteine bleiben, wie sie sind; was sich nicht öffnen lässt, fällt heraus; Klartext gilt nicht mehr. */
        fun open(records: List<SyncRecord>, pack: Int, key: ByteArray): Pair<List<SyncRecord>, Boolean> {
            var failed = false
            val out = records.mapNotNull { r ->
                val p = r.payload ?: return@mapNotNull r
                if (!Sealing.isSealed(p)) return@mapNotNull null
                try { r.copy(payload = Sealing.open(p, key, Sealing.recordContext(pack, r.kind, r.id))) } catch (e: Exception) { failed = true; null }
            }
            return out to failed
        }

        fun message(e: Throwable): String = when ((e as? Api.Failure.Server)?.code ?: if (e is Api.Failure.Offline) "offline" else if (e is app.thisdog.crypto.RecoveryCode.Failure.Invalid) "recovery_invalid" else if (e is app.thisdog.crypto.RecoveryCode.Failure.WrongPack) "recovery_pack" else "") {
            "recovery_invalid" -> L.t("Dieser Schlüssel stimmt nicht. Prüf jedes Zeichen noch einmal.")
            "recovery_pack" -> L.t("Dieser Schlüssel gehört zu einem anderen Rudel.")
            "offline" -> L.t("Keine Verbindung. Versuch es gleich noch einmal.")
            "bad_code" -> L.t("Der Code stimmt nicht.")
            "too_many_tries" -> L.t("Zu viele Versuche. Fordere einen neuen Link an.")
            "expired" -> L.t("Der Link ist abgelaufen. Fordere einen neuen an.")
            "rate_limited" -> L.t("Zu viele Anfragen. Warte ein paar Minuten.")
            "invalid_email" -> L.t("Diese Adresse stimmt nicht.")
            "invite_used" -> L.t("Diese Einladung wurde schon benutzt. Bitte um eine neue.")
            "invite_expired" -> L.t("Diese Einladung ist abgelaufen. Bitte um eine neue.")
            "invite_unknown" -> L.t("Diese Einladung gibt es nicht.")
            "pack_full" -> L.t("Das Rudel ist voll.")
            "key_missing" -> L.t("Auf diesem Gerät fehlt der Schlüssel des Rudels.")
            "not_owner" -> L.t("Das dürfen nur Besitzer.")
            "last_owner" -> L.t("Ein Rudel braucht mindestens einen Besitzer.")
            "use_code" -> L.t("Gib den Code aus der Mail hier in der App ein.")
            else -> L.t("Das hat nicht geklappt. Versuch es gleich noch einmal.")
        }

        private fun obj(vararg pairs: Pair<String, Any>) = JsonObject(pairs.associate { (k, v) ->
            k to when (v) { is Boolean -> JsonPrimitive(v); is Number -> JsonPrimitive(v); else -> JsonPrimitive(v.toString()) }
        })
    }
}
