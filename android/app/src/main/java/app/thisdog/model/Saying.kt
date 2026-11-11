package app.thisdog.model

import app.thisdog.i18n.L

/**
 * Ein Spruch für den Tag: zum Schmunzeln, ohne Zahlen und ohne Erwartungen.
 * Wechselt um Mitternacht und läuft der Reihe nach durch; dieselbe Liste wie auf iOS (`Home/Saying.swift`).
 */
object Saying {
    val all: List<String> get() = listOf(
        L.t("Laternen sind die sozialen Medien der Hunde."),
        L.t("Hunde lesen auch Zeitung. Nur eben am Baum."),
        L.t("Wer „G-A-S-S-I“ buchstabiert, wird trotzdem durchschaut."),
        L.t("Der Kühlschrank geht auf, der Hund steht schon da. Die Physik kann das nicht erklären."),
        L.t("Ein Eichhörnchen ist kein Notfall. Erklär das mal dem Hund."),
        L.t("Gras schmeckt nicht. Probieren muss man es trotzdem."),
        L.t("Hundehaare auf dem Sofa sind Deko."),
        L.t("Der Hund weiß, wann Wochenende ist. Niemand weiß, woher."),
        L.t("Pfoten abputzen ist ein Spiel, das nur einer gewinnt."),
        L.t("Leckerlis in der Jackentasche: die Währung jeder Runde."),
        L.t("Ein müder Hund ist ein glücklicher Hund. Ein müder Mensch manchmal auch."),
        L.t("Das Sofa gehört allen. Theoretisch."),
        L.t("Ein Hund kennt nur zwei Uhrzeiten: jetzt und Fressen."),
        L.t("Hunde träumen. Vermutlich von Wurst."),
        L.t("Dreimal im Kreis drehen, dann hinlegen. Ein uraltes Ritual."),
        L.t("Matsch ist nur Erde mit Persönlichkeit."),
        L.t("Wer beim Gassigehen nie stehen bleibt, verpasst die Hälfte. Sagt der Hund."),
        L.t("Ballwerfen ist Ausdauertraining. Für den Arm."),
        L.t("Es klingelt. Der Hund war schneller als die Klingel."),
        L.t("„Ich hab heute noch gar nichts bekommen.“ Der Hund, nach dem Abendessen."),
        L.t("Wer den Hund badet, wird mitgebadet."),
        L.t("Kleine Hunde wissen nicht, dass sie klein sind. Gut so."),
        L.t("Große Hunde halten sich für Schoßhunde. Auch gut so."),
        L.t("In der Hundewelt kennt jeder jeden. Nur die Menschen heißen „der von Bello“."),
        L.t("Fünf Minuten weg gewesen? Begrüßung wie nach fünf Jahren."),
        L.t("Gähnen steckt an, sogar zwischen Hund und Mensch."),
        L.t("Eine Hundenase riecht etwa zehntausendmal feiner als deine. Der Mülleimer weiß das."),
        L.t("Der Hundeblick ist kein Zufall. Hunde haben dafür eigens einen Muskel über dem Auge."),
        L.t("Ein Stock ist nie nur ein Stock."),
        L.t("Jede Pfütze ist eine Einladung. Nicht jede muss man annehmen."),
        L.t("Regen ist nur Wetter. Für den Hund jedenfalls."),
        L.t("Die Leine verbindet zwei, die beide glauben, sie würden führen."),
        L.t("Schwanzwedeln ist ehrlicher als jedes Like."),
        L.t("Kein Hund hat je gesagt: „Heute bleiben wir lieber drin.“"),
        L.t("Der beste Platz im Bett ist genau da, wo du gerade liegen wolltest."),
        L.t("Ein Hund vergisst nie, wo mal ein Leckerli lag. Vor drei Jahren."),
        L.t("Hunde zählen nicht Schritte. Sie zählen Gerüche."),
        L.t("Die Runde ist dieselbe wie gestern. Für die Nase ist alles neu."),
        L.t("Ein Hund hört „Wurst“ durch zwei geschlossene Türen."),
        L.t("Sitz, Platz, Bleib. Das vierte Kommando, „Leckerli“, gibt der Hund."),
    )

    fun of(day: Day): String {
        val list = all
        val n = Day(java.time.LocalDate.of(2026, 1, 1)).daysUntil(day)
        return list[((n % list.size) + list.size) % list.size]
    }
}
