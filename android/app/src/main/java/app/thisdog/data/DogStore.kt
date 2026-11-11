package app.thisdog.data

import app.thisdog.i18n.L
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import app.thisdog.model.*
import java.io.File
import kotlinx.serialization.KSerializer
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive

/** Gemeinsame Einstellungen für JSON: unbekannte Felder (neuere Fassungen) stören nicht, Vorgaben werden geschrieben. */
val ThisDogJson = Json { ignoreUnknownKeys = true; encodeDefaults = true; explicitNulls = false; coerceInputValues = true }

/** Eine Art im Abgleich mit ihrem Format – wie `static kind` der Swift-Typen. */
class Kind<T : SyncedItem>(val name: String, val serializer: KSerializer<T>)

object Kinds {
    val event = Kind(DogEvent.KIND, DogEvent.serializer())
    val walk = Kind(Walk.KIND, Walk.serializer())
    val profile = Kind(DogProfile.KIND, DogProfile.serializer())
    val weight = Kind(WeightEntry.KIND, WeightEntry.serializer())
    val vaccination = Kind(Vaccination.KIND, Vaccination.serializer())
    val deworming = Kind(Deworming.KIND, Deworming.serializer())
    val medication = Kind(Medication.KIND, Medication.serializer())
    val settings = Kind(ToolSettings.KIND, ToolSettings.serializer())
    val favorite = Kind(FavoriteFood.KIND, FavoriteFood.serializer())
    val checks = Kind(TipChecks.KIND, TipChecks.serializer())
    val avatar = Kind(Avatar.KIND, Avatar.serializer())
    val friendKey = Kind(FriendKey.KIND, FriendKey.serializer())
    val checkIn = Kind(app.thisdog.gassi.CheckIn.KIND, app.thisdog.gassi.CheckIn.serializer())
    val note = Kind(HealthNote.KIND, HealthNote.serializer())
    val all: List<Kind<out SyncedItem>> = listOf(event, walk, profile, weight, vaccination, deworming, medication, settings, favorite, checks, avatar, friendKey, checkIn, note)
    fun byName(n: String) = all.firstOrNull { it.name == n }
}

/** Ein Datensatz im Abgleich – dasselbe Format wie auf iOS und auf dem Server. `payload == null` ist ein Grabstein. */
@Serializable
data class SyncRecord(val kind: String, val id: String, val updatedAt: Double, val by: Int? = null, val payload: JsonElement? = null)

/**
 * Die Daten des Hundes auf diesem Gerät, mit derselben Abgleichs-Logik wie DogStore.swift:
 * das Jüngere gewinnt, Löschungen reisen als Grabsteine, offene Änderungen bleiben offen, bis der Server sie hat.
 */
class DogStore(private val file: File, private val now: () -> Double = { System.currentTimeMillis().toDouble() }) {
    companion object {
        /** Was beim Beitreten dem Rudel den Vortritt lässt. */
        val YIELDING = setOf("${DogProfile.KIND}:profile", "${Avatar.KIND}:${Avatar.DOG}", "${ToolSettings.KIND}:settings", "${TipChecks.KIND}:checks")
    }

    var items by mutableStateOf<Map<String, Map<String, SyncedItem>>>(emptyMap()); private set
    var graves by mutableStateOf<Map<String, Double>>(emptyMap()); private set
    var packID by mutableStateOf<Int?>(null); private set
    var rev by mutableStateOf(0); private set
    var dirty by mutableStateOf<Set<String>>(emptySet()); private set
    var changedBy by mutableStateOf<Map<String, Int>>(emptyMap()); private set

    /** Nur bei Änderungen auf diesem Gerät – sie lösen einen Abgleich aus, eingehende nicht. */
    var onLocalChange: () -> Unit = {}

    init { load() }

    // MARK: Lesen

    @Suppress("UNCHECKED_CAST")
    fun <T : SyncedItem> list(k: Kind<T>): List<T> = items[k.name]?.values?.map { it as T }.orEmpty()

    val events get() = list(Kinds.event)
    val walks get() = list(Kinds.walk)
    // Ältere Fassungen speicherten den Namen ungekürzt („Stella “ → „Stella s letzte Runde“).
    val profile get() = (list(Kinds.profile).firstOrNull() ?: DogProfile()).let { it.copy(name = it.name.trim()) }
    val hasProfile get() = profile.name.isNotEmpty()
    val weights get() = list(Kinds.weight)
    val vaccinations get() = list(Kinds.vaccination)
    val dewormings get() = list(Kinds.deworming)
    val meds get() = list(Kinds.medication)
    val notes get() = list(Kinds.note)
    val settings get() = list(Kinds.settings).firstOrNull() ?: ToolSettings()
    val favorites get() = list(Kinds.favorite)
    val checks get() = list(Kinds.checks).firstOrNull() ?: TipChecks()
    val avatars get() = list(Kinds.avatar)
    val checkIns get() = list(Kinds.checkIn)
    fun event(id: String) = events.firstOrNull { it.id == id }
    fun friendKey(invite: String) = list(Kinds.friendKey).firstOrNull { it.id == invite }

    /** Was in den Gesundheitsdaten fällig wird, aufsteigend. */
    val dues: List<HealthDue> get() {
        val out = mutableListOf<HealthDue>()
        for (v in vaccinations) Day.parse(v.next)?.let { out += HealthDue("due_${v.id}", v.name.ifEmpty { L.t("Impfung") }, L.t("Impfung"), Day.parse(v.date), it) }
        for (d in dewormings) Day.parse(d.next)?.let { out += HealthDue("due_${d.id}", d.product.ifEmpty { L.t("Entwurmung") }, L.t("Entwurmung"), Day.parse(d.date), it) }
        for (m in meds) Day.parse(m.to)?.let { out += HealthDue("due_${m.id}", m.name.ifEmpty { L.t("Medikament") }, L.t("Medikament endet"), Day.parse(m.from), it) }
        return out.sortedBy { it.due }
    }

    /** Fälligkeiten, die sich abhaken lassen (Impfung, Entwurmung). */
    val markableDueIds: Set<String> get() =
        (vaccinations.filter { it.next.isNotEmpty() }.map { "due_${it.id}" } + dewormings.filter { it.next.isNotEmpty() }.map { "due_${it.id}" }).toSet()

    /** Abhaken lässt sich, was sich wiederholt und in den nächsten zwei Wochen fällig ist oder überfällig. */
    fun canMarkDone(due: HealthDue, today: Day = Day.today()) = due.id in markableDueIds && today.daysUntil(due.due) <= 14

    /**
     * Impfung oder Entwurmung erledigt: ein neuer Eintrag von heute, der im bisherigen Abstand wieder fällig wird
     * (ohne bekannten Abstand: Impfung nach einem Jahr, Entwurmung nach drei Monaten). Der alte bleibt als Verlauf.
     */
    fun markDone(dueId: String, today: Day = Day.today()): Boolean {
        fun next(date: String, due: String, fallback: Day): String {
            val a = Day.parse(date); val b = Day.parse(due)
            return if (a != null && b != null && a < b) today.addingDays(a.daysUntil(b)).iso else fallback.iso
        }
        // Nur, was noch fällig ist: Ein zweiter Tipp (doppelt getippt, zwei im Rudel) legte sonst eine zweite Auffrischung an.
        vaccinations.firstOrNull { "due_${it.id}" == dueId && it.next.isNotEmpty() }?.let { v ->
            save(v.copy(next = ""))
            save(Vaccination(newHealthID("vaccinations"), v.name, today.iso, next(v.date, v.next, today.addingYears(1))))
            return true
        }
        dewormings.firstOrNull { "due_${it.id}" == dueId && it.next.isNotEmpty() }?.let { d ->
            save(d.copy(next = ""))
            save(Deworming(newHealthID("deworming"), d.product, today.iso, next(d.date, d.next, today.addingMonths(3))))
            return true
        }
        return false
    }

    fun changer(kind: String, id: String) = changedBy["$kind:$id"]

    // MARK: Schreiben

    fun <T : SyncedItem> upsert(k: Kind<T>, item: T) {
        val e = item.stamped(now())
        items = items + (k.name to (items[k.name].orEmpty() + (e.id to e)))
        val key = "${k.name}:${e.id}"
        graves = graves - key; dirty = dirty + key; changedBy = changedBy - key
        persist(); onLocalChange()
    }

    fun remove(k: Kind<*>, id: String) {
        items = items + (k.name to (items[k.name].orEmpty() - id))
        val key = "${k.name}:$id"
        graves = graves + (key to now()); dirty = dirty + key
        persist(); onLocalChange()
    }

    fun save(e: DogEvent) = upsert(Kinds.event, e)
    fun deleteEvent(id: String) = remove(Kinds.event, id)
    fun save(w: Walk) = upsert(Kinds.walk, w)
    fun save(p: DogProfile) = upsert(Kinds.profile, p)
    fun save(v: Vaccination) = upsert(Kinds.vaccination, v)
    fun save(d: Deworming) = upsert(Kinds.deworming, d)
    fun save(m: Medication) = upsert(Kinds.medication, m)
    fun save(n: HealthNote) = upsert(Kinds.note, n)
    fun deleteNote(id: String) = remove(Kinds.note, id)
    fun save(t: ToolSettings) = upsert(Kinds.settings, t)

    /** Ein Gewicht je Tag; ein zweites am selben Tag ersetzt das erste. Das Profil folgt dem jüngsten. */
    fun saveWeight(kg: Double, day: Day = Day.today()) {
        upsert(Kinds.weight, WeightEntry(day.iso, kg))
        val latest = weights.maxByOrNull { it.d } ?: return
        if (latest.kg != profile.weightKg) save(profile.copy(weightKg = latest.kg))
    }

    fun isFavorite(f: Food) = favorites.any { it.name == f.name }
    fun toggleFavorite(f: Food) = if (isFavorite(f)) remove(Kinds.favorite, f.name) else upsert(Kinds.favorite, FavoriteFood(f.name))

    fun toggleCheck(tip: Tip, index: Int) {
        val c = checks
        val count = tip.checklist?.size ?: 0
        val list = (c.bySlug[tip.slug].orEmpty() + List(maxOf(0, count - (c.bySlug[tip.slug]?.size ?: 0))) { false }).toMutableList()
        if (index !in list.indices) return
        list[index] = !list[index]
        upsert(Kinds.checks, c.copy(bySlug = c.bySlug + (tip.slug to list)))
    }

    // MARK: Abgleich

    private fun stamp(key: String): Double? {
        val (kind, id) = split(key)
        return items[kind]?.get(id)?.u ?: graves[key]
    }

    private fun split(key: String): Pair<String, String> {
        val i = key.indexOf(':'); return if (i < 0) "" to key else key.substring(0, i) to key.substring(i + 1)
    }

    private val allKeys get() = items.flatMap { (kind, m) -> m.keys.map { "$kind:$it" } }

    /** Was seit dem letzten Abgleich geändert wurde, im Format des Servers. */
    @Suppress("UNCHECKED_CAST")
    fun outgoingRecords(): List<SyncRecord> = dirty.sorted().mapNotNull { key ->
        val (kind, id) = split(key)
        val k = Kinds.byName(kind) as Kind<SyncedItem>?
        val item = items[kind]?.get(id)
        if (k != null && item != null) SyncRecord(kind, id, item.u, payload = ThisDogJson.encodeToJsonElement(k.serializer, item))
        else graves[key]?.let { SyncRecord(kind, id, it, payload = null) }
    }

    /** Übernimmt, was der Server liefert; die jüngere Fassung gewinnt. Was gerade abgeschickt wurde, ist danach nicht mehr offen. */
    fun applyIncoming(records: List<SyncRecord>, newRev: Int, sent: List<SyncRecord>) {
        for (r in sent) { val key = "${r.kind}:${r.id}"; if (stamp(key) == r.updatedAt) dirty = dirty - key }
        for (r in records) merge(r)
        rev = newRev
        persist()
    }

    @Suppress("UNCHECKED_CAST")
    private fun merge(r: SyncRecord) {
        val k = (Kinds.byName(r.kind) ?: return) as Kind<SyncedItem>   // Arten, die diese Fassung nicht kennt, bleiben auf dem Server.
        val key = "${r.kind}:${r.id}"
        if (r.updatedAt < (stamp(key) ?: -1.0)) return
        // Fehlt `u` (Datensätze aus der Web-App), gilt der Zeitpunkt des Servers.
        val payload = (r.payload as? JsonObject)?.let { if ("u" in it) it else JsonObject(it + ("u" to JsonPrimitive(r.updatedAt))) } ?: r.payload
        val item = payload?.let { runCatching { ThisDogJson.decodeFromJsonElement(k.serializer, it) }.getOrNull() }
        if (item != null) {
            items = items + (r.kind to (items[r.kind].orEmpty() + (item.id to item.stamped(r.updatedAt))))
            graves = graves - key
        } else if (r.payload == null) {
            items = items + (r.kind to (items[r.kind].orEmpty() - r.id))
            graves = graves + (key to r.updatedAt)
        } else return
        dirty = dirty - key
        changedBy = if (r.by != null) changedBy + (key to r.by) else changedBy - key
    }

    /** Nach dem Anmelden: Alles, was bisher nur auf dem Gerät lag, gehört ins Rudel. */
    fun markAllChanged() { dirty = dirty + allKeys; persist() }

    /** Wechselt das Rudel. Mit `keepLocal` wandern die Daten mit (Beitreten), sonst bleibt das Gerät leer (Verlassen). */
    fun switchPack(id: Int?, keepLocal: Boolean = true) {
        packID = id; rev = 0; changedBy = emptyMap()
        if (keepLocal) dirty = dirty + allKeys else { items = emptyMap(); graves = emptyMap(); dirty = emptySet() }
        persist()
    }

    /**
     * Beitreten: Der Hund des Rudels ist der Hund. Profil, Hundebild, Einstellungen und Abgehaktes von hier gelten nur,
     * wenn das Rudel sie noch nicht hat – sonst überschriebe, wer beim Einrichten schnell den Namen getippt hat, das ganze
     * Profil der anderen. Alles andere wandert mit. Nach dem ersten Abgleich `claimUnanswered()` aufrufen.
     */
    fun joinPack(id: Int) {
        packID = id; rev = 0; changedBy = emptyMap()
        items = items.mapValues { (kind, m) -> m.mapValues { (itemId, item) -> if ("$kind:$itemId" in YIELDING) item.stamped(0.0) else item } }
        // Schlüssel von Hundefreundschaften gehören zum alten Rudel; im neuen öffnete sie niemand.
        dirty = (dirty + allKeys - YIELDING).filterNot { it.startsWith("${FriendKey.KIND}:") }.toSet()
        persist()
    }

    /** Was das Rudel beim Beitreten nicht hatte, gehört jetzt ihm. */
    fun claimUnanswered() {
        val t = now()
        val open = YIELDING.filter { key -> val (k, i) = split(key); items[k]?.get(i)?.u == 0.0 }
        items = items.mapValues { (kind, m) -> m.mapValues { (itemId, item) -> if ("$kind:$itemId" in open) item.stamped(t) else item } }
        dirty = dirty + open
        persist()
    }

    fun resetSync() { packID = null; rev = 0; dirty = emptySet(); changedBy = emptyMap(); persist() }

    // MARK: Datei

    @Serializable
    private data class Saved(
        val items: Map<String, List<JsonElement>> = emptyMap(), val graves: Map<String, Double> = emptyMap(),
        val packID: Int? = null, val rev: Int = 0, val dirty: Set<String> = emptySet(), val changedBy: Map<String, Int> = emptyMap(),
    )

    @Suppress("UNCHECKED_CAST")
    private fun persist() {
        val saved = Saved(
            items.mapValues { (kind, m) -> val k = Kinds.byName(kind) as Kind<SyncedItem>? ?: return@mapValues emptyList(); m.values.map { ThisDogJson.encodeToJsonElement(k.serializer, it) } },
            graves, packID, rev, dirty, changedBy)
        file.parentFile?.mkdirs()
        val tmp = File(file.path + ".neu")
        tmp.writeText(ThisDogJson.encodeToString(Saved.serializer(), saved))
        tmp.renameTo(file)
    }

    @Suppress("UNCHECKED_CAST")
    private fun load() {
        val saved = runCatching { ThisDogJson.decodeFromString(Saved.serializer(), file.readText()) }.getOrNull() ?: return
        items = saved.items.mapNotNull { (kind, list) ->
            val k = Kinds.byName(kind) as Kind<SyncedItem>? ?: return@mapNotNull null
            kind to list.mapNotNull { runCatching { ThisDogJson.decodeFromJsonElement(k.serializer, it) }.getOrNull() }.associateBy { it.id }
        }.toMap()
        graves = saved.graves; packID = saved.packID; rev = saved.rev; dirty = saved.dirty; changedBy = saved.changedBy
    }
}
