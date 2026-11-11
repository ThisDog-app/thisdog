import Foundation

/// Wie heiß der Belag gerade ist und was das für die Pfoten heißt. Liegt in App, Watch und Widgets.
///
/// Eine Wärmebilanz statt einer Sommertabelle: Die Sonne heizt (Sonnenstand aus Ort und Uhrzeit, gedämpft durch
/// Wolken), Wind und Ausstrahlung kühlen. Abgestimmt auf die bekannten Messreihen an klaren Sommermittagen
/// (25 °C Luft → gut 50 °C Belag); im Herbst, bei Wolken oder nachts liegt der Belag nahe an der Luft.
enum Asphalt {
    /// Das Wetter, aus dem gerechnet wird.
    struct Conditions: Codable, Sendable, Equatable {
        /// Lufttemperatur in °C.
        var air: Double
        /// Bewölkung 0…1.
        var cloud: Double
        /// Wind in m/s (Messhöhe 10 m).
        var wind: Double
        var lat: Double
        var lon: Double
    }

    /// Anteil der Sonnenstrahlung, den der Belag schluckt (dunkler Asphalt).
    static let absorption = 0.95
    /// Anteil, der in den Boden abfließt statt die Oberfläche zu wärmen.
    static let intoGround = 0.35

    static func surface(_ c: Conditions, at date: Date) -> Double {
        // Der Belag hinkt der Sonne nach: Mittel aus jetzt und vor einer Stunde (morgens kühler, nachmittags wärmer).
        let sun = (irradiance(c, at: date) + irradiance(c, at: date.addingTimeInterval(-3600))) / 2
        let heating = absorption * (1 - intoGround) * sun
        // Ausstrahlung zum Himmel; Wolken halten sie zurück.
        let longwave = 90 * (1 - 0.8 * min(1, max(0, c.cloud)))
        // Wärmeabgabe an die Luft: Wind in Bodennähe etwa halb so stark wie in 10 m, dazu Strahlung.
        let exchange = 5.7 + 3.8 * max(0, c.wind) * 0.5 + 5.5
        return c.air + max(-4, (heating - longwave) / exchange)
    }

    /// Sonnenstrahlung auf den Boden in W/m²: klarer Himmel nach Haurwitz, Wolken nach Kasten und Czeplak.
    static func irradiance(_ c: Conditions, at date: Date) -> Double {
        let s = sin(sunElevation(lat: c.lat, lon: c.lon, at: date) * .pi / 180)
        guard s > 0.01 else { return 0 }
        let clear = 1098 * s * exp(-0.057 / s)
        return clear * (1 - 0.75 * pow(min(1, max(0, c.cloud)), 3.4))
    }

    /// Sonnenhöhe in Grad (Näherung, auf wenige Zehntelgrad genau; wie auf Android).
    static func sunElevation(lat: Double, lon: Double, at date: Date) -> Double {
        let rad = Double.pi / 180
        let d = date.timeIntervalSince1970 / 86400 + 2440587.5 - 2451545.0
        let g = (357.529 + 0.98560028 * d).truncatingRemainder(dividingBy: 360) * rad
        let q = (280.459 + 0.98564736 * d).truncatingRemainder(dividingBy: 360)
        let l = (q + 1.915 * sin(g) + 0.020 * sin(2 * g)) * rad
        let e = (23.439 - 0.00000036 * d) * rad
        let dec = asin(sin(e) * sin(l))
        let ra = atan2(cos(e) * sin(l), cos(l))
        let gmst = (18.697374558 + 24.06570982441908 * d).truncatingRemainder(dividingBy: 24)
        let ha = (gmst * 15 + lon) * rad - ra
        let la = lat * rad
        return asin(sin(la) * sin(dec) + cos(la) * cos(dec) * cos(ha)) / rad
    }

    /// „bedeckt, Sonne tief“ – woher der Wert kommt, in wenigen Worten.
    static func reason(_ c: Conditions, at date: Date) -> String {
        let h = sunElevation(lat: c.lat, lon: c.lon, at: date)
        if h <= 0 { return String(localized: "Sonne untergegangen") }
        let sky = c.cloud >= 0.75 ? String(localized: "bedeckt") : c.cloud >= 0.35 ? String(localized: "teils bewölkt") : String(localized: "sonnig")
        if h < 20 { return String(localized: "\(sky), Sonne tief") }
        if h > 45 { return String(localized: "\(sky), Sonne hoch") }
        return sky
    }

    enum Paws: String, Codable, Sendable {
        case ok, warn, bad
        var label: String {
            switch self {
            case .ok: String(localized: "Sicher")
            case .warn: String(localized: "Vorsicht")
            case .bad: String(localized: "Nicht laufen")
            }
        }
    }

    /// Ab etwa 52 °C entstehen bei Kontakt binnen einer Minute Schäden an den Ballen; ab 43 °C wird es knapp.
    static func paws(surface: Double) -> Paws { surface >= 52 ? .bad : surface >= 43 ? .warn : .ok }

    /// Die Warnung vor dem Losgehen: nur, wenn es knapp wird.
    static func warning(_ c: Conditions, at date: Date) -> Paws? {
        let p = paws(surface: surface(c, at: date))
        return p == .ok ? nil : p
    }

    static func advice(_ p: Paws) -> String {
        switch p {
        case .ok: String(localized: "Unbedenklich. Trotzdem kurz mit dem Handrücken prüfen.")
        case .warn: String(localized: "Grenzbereich. Schattenroute wählen, Mittagshitze meiden.")
        case .bad: String(localized: "Zu heiß. Die Ballen können verbrennen: auf Gras ausweichen oder in die kühlen Stunden verlegen.")
        }
    }
}
