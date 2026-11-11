package app.thisdog

import app.thisdog.gassi.*
import app.thisdog.model.LatLng
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/** Adressen (api/services.php): Dekodieren, Filter aus Chip und Suchtext, Website-Adressen. */
class ServiceTest {
    private val full = """{
      "services": [
        {"id": "node/123", "kind": "vet", "label": "Tierarzt", "name": "Tierklinik Praterstern",
         "lat": 48.2185, "lon": 16.3921, "street": "Praterstraße 12", "city": "1020 Wien",
         "phone": "+43 1 2345678", "website": "https://example.at", "hours": "Mo-Fr 08:00-18:00; Sa 09:00-12:00",
         "emergency": true},
        {"id": "way/7", "kind": "shop", "label": "Tierbedarf", "name": "Napf & Leine", "lat": 48.22, "lon": 16.37}
      ],
      "sponsor": {
         "id": 12, "place": "node/456", "kind": "groomer", "label": "Hundefriseur", "name": "Salon Struppi",
         "lat": 48.21, "lon": 16.38, "street": "Große Sperlgasse 7", "city": "1020 Wien", "phone": "+43 1 9876543",
         "website": "salon-struppi.at", "hours": "Di-Fr 10:00-18:00", "text": "Erste Pflege für Welpen gratis", "advertiser": "Struppi GmbH"
      },
      "covered": true
    }"""

    private fun sv(id: String, kind: String, name: String, label: String = kind, street: String? = null, lat: Double = 48.2, lon: Double = 16.4) =
        Service(id, kind, label, name, lat, lon, street)

    @Test fun decodesAllFields() {
        val a = ServiceFinder.decode(full)
        assertTrue(a.covered)
        assertEquals(2, a.list.size)
        val vet = a.list[0]
        assertEquals("node/123", vet.id)
        assertEquals("Praterstraße 12", vet.street); assertEquals("1020 Wien", vet.city)
        assertEquals("+43 1 2345678", vet.phone); assertEquals("https://example.at", vet.websiteURL)
        assertTrue(vet.emergency)
        assertEquals("Mo-Fr 08:00-18:00\nSa 09:00-12:00", vet.hoursText)
        assertEquals("tierarzt", vet.icon)
        assertEquals("Tierarzt · Praterstraße 12", vet.subtitle)
        assertNull(vet.ad)
        val ad = a.sponsor!!
        assertEquals("node/456", ad.id)
        assertEquals("groomer", ad.kind); assertEquals("schere", ad.icon)
        assertEquals(Service.Ad(12, "Erste Pflege für Welpen gratis", "Struppi GmbH"), ad.ad)
        assertEquals("https://salon-struppi.at", ad.websiteURL)
    }

    @Test fun decodesWithoutOptionalFields() {
        val a = ServiceFinder.decode("""{"services":[{"id":"n/1","kind":"bakery","label":"Bäckerei","name":"Anker","lat":48.1,"lon":16.2}],"sponsor":null,"covered":false}""")
        assertFalse(a.covered)
        assertNull(a.sponsor)
        val s = a.list.single()
        assertNull(s.street); assertNull(s.city); assertNull(s.phone); assertNull(s.website); assertNull(s.hours); assertNull(s.hoursText); assertNull(s.websiteURL)
        assertFalse(s.emergency)
        assertEquals("Bäckerei", s.subtitle)
        // Unbekannte Art: Stecknadel.
        assertEquals("pin", s.icon)
        // Sponsor ohne „place“, Text und Werbenden.
        val b = ServiceFinder.decode("""{"services":[],"sponsor":{"id":3,"kind":"cafe","label":"Hundefreundliches Lokal","name":"Café","lat":1.0,"lon":2.0}}""")
        assertEquals("anzeige/3", b.sponsor!!.id)
        assertEquals(Service.Ad(3, null, null), b.sponsor!!.ad)
        assertTrue(b.covered)
        // Ganz leer.
        assertEquals(Services(emptyList(), null, true), ServiceFinder.decode("{}"))
    }

    @Test fun chipsOnlyForPresentKindsInFixedOrder() {
        val list = listOf(sv("1", "cafe", "A"), sv("2", "vet", "B"), sv("3", "vet", "C"), sv("4", "bakery", "D"))
        assertEquals(listOf(ServiceKind.VET, ServiceKind.CAFE), ServiceFilter.chips(list))
        // Der gesponserte Eintrag zählt mit.
        assertEquals(listOf(ServiceKind.VET, ServiceKind.GROOMER, ServiceKind.CAFE), ServiceFilter.chips(list, sv("9", "groomer", "S")))
        assertEquals(emptyList<ServiceKind>(), ServiceFilter.chips(emptyList()))
        assertEquals(listOf("vet", "groomer", "shop", "school", "shelter", "boarding", "cafe"), ServiceKind.entries.map { it.key })
        assertEquals(listOf("tierarzt", "schere", "laden", "pfeife", "herz", "haus", "tasse"), ServiceKind.entries.map { it.icon })
        assertEquals(listOf("Tierärzte", "Hundefriseure", "Tierbedarf", "Hundeschulen", "Tierheime", "Pensionen", "Lokale"), ServiceKind.entries.map { it.chip })
    }

    @Test fun filtersByChipAndQuery() {
        val list = listOf(sv("1", "vet", "Tierklinik Praterstern", "Tierarzt", "Praterstraße 12"),
            sv("2", "vet", "Dr. Huber", "Tierarzt", "Taborstraße 3"),
            sv("3", "shop", "Napf & Leine", "Tierbedarf", "Praterstraße 40"))
        assertEquals(listOf("1", "2", "3"), ServiceFilter.list(list, null, "").map { it.id })
        assertEquals(listOf("1", "2"), ServiceFilter.list(list, "vet", "  ").map { it.id })
        // Name, Art und Straße, Groß- und Kleinschreibung egal.
        assertEquals(listOf("1", "3"), ServiceFilter.list(list, null, "prater").map { it.id })
        assertEquals(listOf("1"), ServiceFilter.list(list, "vet", "PRATER").map { it.id })
        assertEquals(listOf("1", "2"), ServiceFilter.list(list, null, "tierarzt").map { it.id })
        assertEquals(listOf("2"), ServiceFilter.list(list, null, "huber").map { it.id })
        assertEquals(emptyList<Service>(), ServiceFilter.list(list, "shop", "huber"))
    }

    @Test fun sponsorOnlyWhenChipAndQueryFit() {
        val ad = sv("node/456", "groomer", "Salon Struppi", "Hundefriseur", "Große Sperlgasse 7")
        assertEquals(ad, ServiceFilter.sponsor(ad, null, ""))
        assertEquals(ad, ServiceFilter.sponsor(ad, "groomer", ""))
        assertNull(ServiceFilter.sponsor(ad, "vet", ""))
        assertEquals(ad, ServiceFilter.sponsor(ad, null, "struppi"))
        assertEquals(ad, ServiceFilter.sponsor(ad, "groomer", "friseur"))
        assertNull(ServiceFilter.sponsor(ad, null, "tierklinik"))
        assertNull(ServiceFilter.sponsor(null, null, ""))
    }

    @Test fun mergesSearchResultsByIdWithoutSponsor() {
        val here = LatLng(48.2, 16.4)
        val near = listOf(sv("a", "vet", "Nah", lat = 48.201), sv("b", "shop", "Mitte", lat = 48.21))
        val found = listOf(sv("b", "shop", "Mitte", lat = 48.21), sv("c", "vet", "Weit", lat = 48.3), sv("s", "groomer", "Sponsor", lat = 48.2))
        val ad = sv("s", "groomer", "Sponsor", lat = 48.2)
        assertEquals(listOf("a", "b", "c"), ServiceFilter.merge(near, found, ad, here).map { it.id })
        assertEquals(listOf("s", "a", "b", "c"), ServiceFilter.merge(near, found, null, here).map { it.id })
    }

    @Test fun websiteGetsHttps() {
        assertEquals("https://example.at", websiteURL("example.at"))
        assertEquals("https://example.at/praxis", websiteURL(" example.at/praxis "))
        assertEquals("https://example.at", websiteURL("https://example.at"))
        assertEquals("http://example.at", websiteURL("http://example.at"))
        assertEquals("HTTPS://Example.at", websiteURL("HTTPS://Example.at"))
        assertEquals("https://www.example.at", websiteURL("www.example.at"))
    }
}
