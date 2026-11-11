# kotlinx.serialization und MapLibre bringen eigene Regeln mit; hier nur, was R8 sonst entfernt.
# Die Datensätze werden über ihre Serializer gelesen – die Klassen selbst müssen erhalten bleiben.
-keepclassmembers @kotlinx.serialization.Serializable class app.thisdog.** {
    *** Companion;
    kotlinx.serialization.KSerializer serializer(...);
}
