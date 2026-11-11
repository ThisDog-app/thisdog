package app.thisdog.model

/**
 * Ein Datensatz, der abgeglichen wird. `u` ist der Zeitpunkt der letzten Änderung in Millisekunden.
 * Die Art („event“, „walk“ …) steht je Klasse im Begleitobjekt als `KIND`, wie `static kind` in Swift.
 */
interface SyncedItem {
    val id: String
    val u: Double
    fun stamped(u: Double): SyncedItem
}
