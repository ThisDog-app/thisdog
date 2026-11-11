package app.thisdog

import app.thisdog.data.DogStore
import app.thisdog.model.*

/** Vorführdaten wie `-beispiel` auf iOS: Stella, Zwergpudel, 16 Monate, 6 kg, ein paar Termine. */
object Beispiel {
    fun seed(s: DogStore) {
        if (s.events.isNotEmpty()) return
        val t = Day.today()
        listOf(
            DogEvent(title = "Entwurmung", start = t.addingDays(12).addingMonths(-3).iso, repetition = "quarterly"),
            DogEvent(title = "Tierarzt: Impfung Tollwut", start = t.addingDays(2).iso, time = "10:30", notes = "Impfpass mitnehmen"),
            DogEvent(title = "Krallen schneiden", start = t.addingDays(-9).iso, repetition = "monthly"),
            DogEvent(title = "Hundeschule", start = t.addingDays(6).iso, time = "09:00", repetition = "weekly"),
            DogEvent(title = "Urlaub an der Ostsee", start = t.addingDays(20).iso, end = t.addingDays(26).iso),
            DogEvent(title = "Zeckenschutz", start = t.iso, repetition = "monthly"),
        ).forEach { s.save(it) }
        s.save(DogProfile(name = "Stella", breed = "Zwergpudel", sex = "f", birthdate = t.addingMonths(-16).iso, targetWeightKg = 6.0,
            vetName = "Tierarztpraxis am Augarten", vetPhone = "+43 1 234 56 78", ownerName = "Alex", ownerPhone = "+43 660 123 45 67",
            chip = "040098100123456", allergies = "Verträgt kein Huhn", tracker = true))
        // Drei Runden durch den Augarten in Wien, für „Letzte Runden“ und die Woche (wie seedExamples auf iOS).
        listOf(Triple(0, 1.0, 38.0), Triple(1, 0.8, 31.0), Triple(3, 1.2, 47.0)).forEach { (back, scale, minutes) ->
            val coords = (0..40).map { i ->
                val a = i / 40.0 * 2 * Math.PI
                LatLng(48.2236 + 0.0042 * scale * kotlin.math.sin(a), 16.3760 + 0.0056 * scale * kotlin.math.cos(a) * (1 + 0.15 * kotlin.math.sin(3 * a)))
            }
            val start = System.currentTimeMillis() - back * 86_400_000L - 3 * 3_600_000L
            s.save(Walk(Walk.newID(), start.toDouble(), start + minutes * 60_000, minutes * 60, Track.length(coords), Polyline.encode(coords)))
        }
        listOf(-10 to 4.2, -8 to 4.9, -6 to 5.4, -4 to 5.7, -2 to 5.9, 0 to 6.0).forEach { (m, kg) -> s.saveWeight(kg, t.addingMonths(m)) }
        s.save(Vaccination(newHealthID("vaccinations"), "Tollwut", t.addingMonths(-9).iso, t.addingMonths(3).iso))
        s.save(Vaccination(newHealthID("vaccinations"), "SHPPi", t.addingMonths(-11).iso, t.addingDays(25).iso))
        s.save(Deworming(newHealthID("deworming"), "Milbemax", t.addingMonths(-2).iso, t.addingDays(12).iso))
        s.save(HealthNote(d = t.addingDays(-1).iso, time = "07:40", tags = listOf("Erbrochen"), text = "Morgens Gras gefressen, danach einmal erbrochen. Mittags wieder munter."))
        s.save(HealthNote(d = t.addingDays(-16).iso, tags = listOf("Zecke"), text = "Am Hals entfernt, Stelle leicht gerötet."))
    }

    /** `adressen`: Adressen rund um den Standort, mit einem gesponserten Hundefriseur (für den Reiter „Adressen“). */
    fun services(at: LatLng): app.thisdog.gassi.Services {
        fun s(n: Int, kind: String, label: String, name: String, dLat: Double, dLon: Double, street: String?, phone: String? = null, website: String? = null,
              hours: String? = null, emergency: Boolean = false) =
            app.thisdog.gassi.Service("beispiel/$n", kind, label, name, at.lat + dLat, at.lng + dLon, street, street?.let { "1020 Wien" }, phone, website, hours, emergency)
        val list = listOf(
            s(1, "vet", "Tierarzt", "Tierklinik Praterstern", .0021, .0032, "Praterstraße 12", "+43 1 2345678", "tierklinik-praterstern.example", "Mo-Fr 08:00-18:00; Sa 09:00-12:00", emergency = true),
            s(2, "shop", "Tierbedarf", "Fressnapf Taborstraße", -.0018, .0011, "Taborstraße 40", "+43 1 2160011", "https://example.at", "Mo-Sa 09:00-19:00"),
            s(3, "cafe", "Hundefreundliches Lokal", "Café Wurstel", .0035, -.0024, "Obere Augartenstraße 1"),
            s(4, "vet", "Tierarzt", "Tierarztpraxis am Augarten", .0052, -.0008, "Rauscherstraße 5", "+43 1 234 56 78", hours = "Mo-Fr 09:00-12:00,15:00-19:00"),
            s(5, "school", "Hundeschule", "Hundeschule Pfotenweg", -.0061, .0047, "Vorgartenstraße 120", website = "pfotenweg.example"),
            s(6, "groomer", "Hundefriseur", "Hundesalon Lockenpracht", .0071, .0062, "Heinestraße 22", "+43 660 1234567"),
            s(7, "boarding", "Hundepension", "Pension Bello", -.0102, -.0075, null),
            s(8, "shelter", "Tierheim", "Tierschutzhaus am Prater", -.0125, .0118, "Hauptallee 9"),
            s(9, "shop", "Tierbedarf", "Napf & Leine", .0093, -.0051, "Klosterneuburger Straße 15"),
        )
        val sponsor = app.thisdog.gassi.Service("node/456", "groomer", "Hundefriseur", "Salon Struppi", at.lat + .0028, at.lng - .0039, "Große Sperlgasse 7", "1020 Wien",
            "+43 1 9876543", "salon-struppi.example", "Di-Fr 10:00-18:00; Sa 09:00-14:00",
            ad = app.thisdog.gassi.Service.Ad(12, "Erste Pflege für Welpen gratis", "Struppi GmbH"))
        return app.thisdog.gassi.Services(list.sortedBy { Track.distance(at, it.coordinate) }, sponsor, true)
    }

    /** `vermisst`: Stella ist seit zwei Stunden weg (für den Steckbrief). */
    fun seedLost(s: app.thisdog.data.DogStore) {
        s.save(s.profile.copy(lostSince = LostDog.stamp(java.time.LocalDateTime.now().minusHours(2)), lostWhere = "Augarten, beim Spielplatz",
            lostNote = "Ängstlich, nicht rufen. Rotes Halsband."))
    }

    /** Check-ins an Wiener Orten der letzten Wochen, mit vier Sonntagen in Folge (wie seedCheckIns auf iOS). */
    fun seedCheckIns(store: app.thisdog.data.DogStore) {
        if (store.checkIns.isNotEmpty()) return
        fun place(id: String?, name: String, kind: String, lat: Double, lon: Double) =
            app.thisdog.gassi.Place(name, kind, if (kind == "dog_park") "Hundezone" else "Park", 0, lat, lon, serverID = id)
        val zone = place("way/305847888", "Hundezone Venediger-Au-Park", "dog_park", 48.2194, 16.3942)
        val others = listOf(place(null, "Venediger-Au-Park", "park", 48.2191, 16.3953), place(null, "Rosa-Jochmann-Park", "park", 48.2171, 16.3861),
            place(null, "Hundezone Prater - Laufberg", "dog_park", 48.2135, 16.4010), place(null, "Augarten", "park", 48.2253, 16.3762))
        val zone_ = java.time.ZoneId.systemDefault()
        val now = java.time.ZonedDateTime.now()
        val offsets = listOf(0, 1, 2, 4, 5, 7, 8, 9, 11, 12, 14, 15, 16, 18, 19, 21, 22, 23, 25, 26, 28, 30, 33)
        val days = offsets.map { now.minusDays(it.toLong()) }.toMutableList()
        var sunday = now.toLocalDate().with(java.time.temporal.TemporalAdjusters.previous(java.time.DayOfWeek.SUNDAY))
        repeat(4) { days += sunday.atStartOfDay(zone_); sunday = sunday.minusWeeks(1) }
        days.forEachIndexed { i, d ->
            val at = d.withHour(7 + i % 3).withMinute(10 + i % 40)
            val millis = minOf(at.toInstant().toEpochMilli(), System.currentTimeMillis() - 600_000)
            store.upsert(app.thisdog.data.Kinds.checkIn, app.thisdog.gassi.CheckIn.of(if (i < 23) zone else others[i % others.size], millis))
        }
        others.forEachIndexed { i, p -> store.upsert(app.thisdog.data.Kinds.checkIn, app.thisdog.gassi.CheckIn.of(p, now.minusDays(3L + i * 2).toInstant().toEpochMilli())) }
    }
}
