import Foundation

/// Ein Spruch für den Tag: zum Schmunzeln, ohne Zahlen und ohne Erwartungen.
/// Wechselt um Mitternacht und läuft der Reihe nach durch, damit sich nichts zu früh wiederholt.
/// Android nutzt dieselbe Liste in derselben Reihenfolge (`model/Saying.kt`).
enum Saying {
    static let all: [String] = [
        String(localized: "Laternen sind die sozialen Medien der Hunde."),
        String(localized: "Hunde lesen auch Zeitung. Nur eben am Baum."),
        String(localized: "Wer „G-A-S-S-I“ buchstabiert, wird trotzdem durchschaut."),
        String(localized: "Der Kühlschrank geht auf, der Hund steht schon da. Die Physik kann das nicht erklären."),
        String(localized: "Ein Eichhörnchen ist kein Notfall. Erklär das mal dem Hund."),
        String(localized: "Gras schmeckt nicht. Probieren muss man es trotzdem."),
        String(localized: "Hundehaare auf dem Sofa sind Deko."),
        String(localized: "Der Hund weiß, wann Wochenende ist. Niemand weiß, woher."),
        String(localized: "Pfoten abputzen ist ein Spiel, das nur einer gewinnt."),
        String(localized: "Leckerlis in der Jackentasche: die Währung jeder Runde."),
        String(localized: "Ein müder Hund ist ein glücklicher Hund. Ein müder Mensch manchmal auch."),
        String(localized: "Das Sofa gehört allen. Theoretisch."),
        String(localized: "Ein Hund kennt nur zwei Uhrzeiten: jetzt und Fressen."),
        String(localized: "Hunde träumen. Vermutlich von Wurst."),
        String(localized: "Dreimal im Kreis drehen, dann hinlegen. Ein uraltes Ritual."),
        String(localized: "Matsch ist nur Erde mit Persönlichkeit."),
        String(localized: "Wer beim Gassigehen nie stehen bleibt, verpasst die Hälfte. Sagt der Hund."),
        String(localized: "Ballwerfen ist Ausdauertraining. Für den Arm."),
        String(localized: "Es klingelt. Der Hund war schneller als die Klingel."),
        String(localized: "„Ich hab heute noch gar nichts bekommen.“ Der Hund, nach dem Abendessen."),
        String(localized: "Wer den Hund badet, wird mitgebadet."),
        String(localized: "Kleine Hunde wissen nicht, dass sie klein sind. Gut so."),
        String(localized: "Große Hunde halten sich für Schoßhunde. Auch gut so."),
        String(localized: "In der Hundewelt kennt jeder jeden. Nur die Menschen heißen „der von Bello“."),
        String(localized: "Fünf Minuten weg gewesen? Begrüßung wie nach fünf Jahren."),
        String(localized: "Gähnen steckt an, sogar zwischen Hund und Mensch."),
        String(localized: "Eine Hundenase riecht etwa zehntausendmal feiner als deine. Der Mülleimer weiß das."),
        String(localized: "Der Hundeblick ist kein Zufall. Hunde haben dafür eigens einen Muskel über dem Auge."),
        String(localized: "Ein Stock ist nie nur ein Stock."),
        String(localized: "Jede Pfütze ist eine Einladung. Nicht jede muss man annehmen."),
        String(localized: "Regen ist nur Wetter. Für den Hund jedenfalls."),
        String(localized: "Die Leine verbindet zwei, die beide glauben, sie würden führen."),
        String(localized: "Schwanzwedeln ist ehrlicher als jedes Like."),
        String(localized: "Kein Hund hat je gesagt: „Heute bleiben wir lieber drin.“"),
        String(localized: "Der beste Platz im Bett ist genau da, wo du gerade liegen wolltest."),
        String(localized: "Ein Hund vergisst nie, wo mal ein Leckerli lag. Vor drei Jahren."),
        String(localized: "Hunde zählen nicht Schritte. Sie zählen Gerüche."),
        String(localized: "Die Runde ist dieselbe wie gestern. Für die Nase ist alles neu."),
        String(localized: "Ein Hund hört „Wurst“ durch zwei geschlossene Türen."),
        String(localized: "Sitz, Platz, Bleib. Das vierte Kommando, „Leckerli“, gibt der Hund."),
    ]

    static func of(_ day: Day) -> String {
        let n = Day(2026, 1, 1).days(until: day)
        return all[((n % all.count) + all.count) % all.count]
    }
}
