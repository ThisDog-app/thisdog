package app.thisdog.data

import app.thisdog.model.Avatar
import app.thisdog.model.Day
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive

/** Was auf der Seite hinter dem QR-Code steht – genau diese Felder gehen an den Server (wie EmergencySnapshot in Swift). */
@Serializable
data class EmergencySnapshot(
    val name: String = "", val breed: String = "", val sex: String = "", val age: String = "", val chip: String = "",
    val ownerName: String = "", val ownerPhone: String = "", val vetName: String = "", val vetPhone: String = "",
    val important: String = "", val meds: String = "", val note: String = "",
    val lostSince: String = "", val lostWhere: String = "", val lostNote: String = "",
) {
    companion object {
        fun from(s: DogStore): EmergencySnapshot {
            val p = s.profile; val today = Day.today()
            return EmergencySnapshot(p.name, p.breed, p.sexLabel ?: "", p.age() ?: "", p.chip, p.ownerName, p.ownerPhone, p.vetName, p.vetPhone, p.allergies,
                s.meds.filter { m -> Day.parse(m.to)?.let { it >= today } ?: true }.map { listOf(it.name, it.dose).filter(String::isNotEmpty).joinToString(", ") }.filter(String::isNotEmpty).joinToString("\n"),
                lostSince = p.lostSince, lostWhere = p.lostWhere, lostNote = p.lostNote)
        }
    }
}

@Serializable data class EmergencyStatus(val active: Boolean, val url: String? = null, val updatedAt: Int? = null, val views: Int? = null, val lastViewAt: Int? = null)

/** Notfallpass freigeben, aktualisieren, sperren (api/emergency.php). */
class Emergency(private val account: Account) {
    private val store get() = account.store
    private val pack get() = store.packID ?: 0

    suspend fun status() = ThisDogJson.decodeFromJsonElement(EmergencyStatus.serializer(), account.api.get("emergency.php", mapOf("action" to "status", "pack" to "$pack")))

    suspend fun publish(): EmergencyStatus {
        val card = ThisDogJson.encodeToJsonElement(EmergencySnapshot.serializer(), EmergencySnapshot.from(store))
        val photo = store.avatars.firstOrNull { it.id == Avatar.DOG }?.jpeg
        val body = JsonObject(buildMap { put("pack", JsonPrimitive(pack)); put("card", card); photo?.let { put("photo", JsonPrimitive(it)) } })
        return ThisDogJson.decodeFromJsonElement(EmergencyStatus.serializer(), account.api.post("emergency.php", mapOf("action" to "publish"), body))
    }

    suspend fun revoke() { account.api.post("emergency.php", mapOf("action" to "revoke"), JsonObject(mapOf("pack" to JsonPrimitive(pack)))) }
}
