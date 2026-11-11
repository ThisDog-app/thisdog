package app.thisdog.model

import kotlinx.serialization.Serializable
import kotlinx.serialization.Transient

/** Einstellungen der Rechner (Art „settings“, Kennung „settings“). */
@Serializable
data class ToolSettings(val meals: Int = 2, val feedBasis: String = "current", val kcalPer100g: Double = 350.0, override val u: Double = 0.0) : SyncedItem {
    @Transient override val id: String = "settings"
    override fun stamped(u: Double) = copy(u = u)
    companion object { const val KIND = "settings" }
}

/** Ein Bild für den Hund (`dog`) oder ein Rudelmitglied (`member-<Konto>`), JPEG als Base64. */
@Serializable
data class Avatar(override val id: String, val jpeg: String, override val u: Double = 0.0) : SyncedItem {
    override fun stamped(u: Double) = copy(u = u)
    companion object {
        const val KIND = "avatar"
        const val DOG = "dog"
        fun member(account: Int) = "member-$account"
    }
}

/** Der Schlüssel einer Hundefreundschaft, als Datensatz im Rudel (Kennung = die der Einladung). */
@Serializable
data class FriendKey(override val id: String, val key: String, override val u: Double = 0.0) : SyncedItem {
    override fun stamped(u: Double) = copy(u = u)
    companion object { const val KIND = "friendkey" }
}
