package app.thisdog

import app.thisdog.data.Account
import app.thisdog.data.Api
import app.thisdog.data.DogStore
import app.thisdog.data.KeyVault
import app.thisdog.model.DogEvent
import java.io.File
import java.net.ServerSocket
import java.nio.file.Files
import java.util.concurrent.TimeUnit
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.runBlocking
import okhttp3.Cookie
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Assume.assumeTrue
import org.junit.Before
import org.junit.Test

/**
 * Die Android-Fassung gegen den echten Server (public/ mit `php -S`, Wegwerf-Datenbank):
 * Umzug auf Verschlüsselung, Einladung mit Schlüssel im Link, Abgleich in beide Richtungen.
 */
class ServerTest {
    private val php = listOf("/opt/homebrew/bin/php", "/usr/bin/php", "/usr/local/bin/php").firstOrNull { File(it).exists() }
    private val root = File("../../public").canonicalFile
    private lateinit var dir: File
    private lateinit var server: Process
    private var port = 0

    @Before fun start() {
        assumeTrue("php fehlt", php != null && root.exists())
        dir = Files.createTempDirectory("server").toFile()
        File(dir, "config.php").writeText("<?php return ['DATA_DIR' => '${dir.path}/daten', 'APP_URL' => 'https://thisdog.app'];")
        File(dir, "daten").mkdirs()
        sql("""foreach (["anna@example.org" => "sitzung-anna-0123456789", "ben@example.org" => "sitzung-ben-0123456789"] as ${'$'}m => ${'$'}s) {
            ${'$'}pdo->prepare("INSERT INTO accounts (email, created_at) VALUES (?, ?)")->execute([${'$'}m, time()]);
            ${'$'}id = (int) ${'$'}pdo->lastInsertId();
            ${'$'}pdo->prepare("INSERT INTO sessions (token_hash, account_id, created_at, expires_at, last_seen_at) VALUES (?, ?, ?, ?, ?)")->execute([secret_hash(${'$'}s), ${'$'}id, time(), time() + 3600, time()]); }""")
        port = ServerSocket(0).use { it.localPort }
        server = ProcessBuilder(php, "-S", "127.0.0.1:$port", "-t", root.path).apply { environment()["STELLA_CONFIG"] = "${dir.path}/config.php"; redirectErrorStream(true); redirectOutput(File(dir, "server.log")) }.start()
        Thread.sleep(700)
    }

    @After fun stop() { if (::server.isInitialized) server.destroy() }

    private fun sql(code: String): String {
        val p = ProcessBuilder(php, "-r", "require '${root.path}/api/lib-pack.php'; \$pdo = db(); $code").apply { environment()["STELLA_CONFIG"] = "${dir.path}/config.php"; redirectErrorStream(true) }.start()
        p.waitFor(20, TimeUnit.SECONDS)
        return p.inputStream.bufferedReader().readText()
    }

    private fun client(session: String): Triple<Account, DogStore, KeyVault> {
        val cookies = Api.CookieStore.Memory().also {
            it.save(listOf(Cookie.Builder().name("stella_session").value(session).hostOnlyDomain("127.0.0.1").path("/").expiresAt(System.currentTimeMillis() + 3_600_000).build()))
        }
        val store = DogStore(File(Files.createTempDirectory("geraet").toFile(), "thisdog.json"))
        val keys = KeyVault.Memory()
        return Triple(Account(Api("http://127.0.0.1:$port/api/", cookies), store, keys, CoroutineScope(Dispatchers.IO)), store, keys)
    }

    @Test fun encryptedPackBetweenTwoPhones() = runBlocking {
        val (anna, annaStore, _) = client("sitzung-anna-0123456789")
        annaStore.save(DogEvent(id = "evt_tierarzt", title = "Tierarzt", start = "2026-10-20"))
        anna.refresh()
        assertTrue(anna.signedIn)
        assertTrue("Annas Rudel ist verschlüsselt", anna.currentPack?.sealed == true)
        assertEquals("0", sql("echo \$pdo->query(\"SELECT COUNT(*) FROM pack_records WHERE payload LIKE '%Tierarzt%'\")->fetchColumn();").trim())
        assertEquals("1", sql("echo \$pdo->query(\"SELECT COUNT(*) FROM pack_records WHERE payload LIKE '{\\\"e\\\":%'\")->fetchColumn();").trim())

        val link = anna.invite().url
        assertTrue(link.contains("#k="))
        val (ben, benStore, benKeys) = client("sitzung-ben-0123456789")
        ben.refresh()
        val path = link.substringAfter("https://thisdog.app").substringBefore('#')
        ben.open(path, link.substringAfter('#'))
        Thread.sleep(2500)
        assertEquals("Ben sieht Annas Termin", "Tierarzt", benStore.event("evt_tierarzt")?.title)
        assertTrue(benKeys.packKey(anna.currentPack!!.id) != null)

        benStore.save(benStore.event("evt_tierarzt")!!.copy(title = "Tierarzt, 10:30"))
        ben.sync(); anna.sync()
        assertEquals("Anna sieht Bens Änderung", "Tierarzt, 10:30", annaStore.event("evt_tierarzt")?.title)
        assertEquals("0", sql("echo \$pdo->query(\"SELECT COUNT(*) FROM pack_records WHERE payload LIKE '%10:30%'\")->fetchColumn();").trim())
    }

    /** Die Hundesitterin: kein Konto, keine E-Mail – Einladungslink öffnen genügt, auch mit dem Schlüssel als Zusatz. */
    @Test fun inviteWithoutAccount() = runBlocking {
        val (anna, annaStore, _) = client("sitzung-anna-0123456789")
        annaStore.save(DogEvent(id = "evt_tierarzt", title = "Tierarzt", start = "2026-10-20"))
        anna.refresh()
        val link = anna.invite().url
        val path = link.substringAfter("https://thisdog.app").substringBefore('#')

        val (sitter, sitterStore, sitterKeys) = client("")
        sitter.refresh()
        assertTrue("noch nicht angemeldet", !sitter.signedIn)
        sitter.open(path, link.substringAfter('#'))
        var waited = 0
        while ((sitter.joining || sitterStore.event("evt_tierarzt") == null) && waited < 50) { Thread.sleep(100); waited++ }
        assertTrue("Konto ohne E-Mail", sitter.signedIn && sitter.deviceOnly)
        assertEquals("Sitterin sieht Annas Termin", "Tierarzt", sitterStore.event("evt_tierarzt")?.title)
        assertEquals("nur Annas Rudel, kein leeres eigenes", 1, sitter.packs.size)
        assertTrue(sitterKeys.packKey(anna.currentPack!!.id) != null)

        // Ein zweiter Mensch mit demselben Link (gilt jetzt für mehrere), diesmal über die gescannte Adresse.
        val (second, secondStore, _) = client("")
        assertTrue(second.open(link))
        waited = 0
        while ((second.joining || secondStore.event("evt_tierarzt") == null) && waited < 50) { Thread.sleep(100); waited++ }
        assertEquals("Tierarzt", secondStore.event("evt_tierarzt")?.title)
        anna.loadPacks()
        assertEquals(3, anna.currentPack?.members?.size)
    }

    @Test fun rolesAndNotifications() = runBlocking {
        val (anna, annaStore, _) = client("sitzung-anna-0123456789")
        annaStore.save(DogEvent(id = "evt_rollen", title = "Hundeschule", start = "2026-11-12"))
        anna.refresh()
        assertTrue("Anna ist Besitzerin", anna.isOwner)
        val link = anna.invite("sitter").url

        val (sitter, sitterStore, _) = client("")
        assertTrue(sitter.open(link))
        var waited = 0
        while ((sitter.joining || sitterStore.event("evt_rollen") == null) && waited < 50) { Thread.sleep(100); waited++ }
        val me = sitter.currentPack!!.members.first { it.id == sitter.me }
        assertEquals("als Hundesitterin dabei", "sitter", me.role)
        assertTrue("will von sich aus nichts", me.notifies.isEmpty())
        assertTrue(!sitter.isOwner)

        // Hundesitter laden nicht ein und vergeben keine Rollen.
        assertEquals("not_owner", (runCatching { sitter.invite("sitter") }.exceptionOrNull() as? app.thisdog.data.Api.Failure.Server)?.code)
        assertEquals("not_owner", (runCatching { sitter.setRole("owner", me.id) }.exceptionOrNull() as? app.thisdog.data.Api.Failure.Server)?.code)

        // Sie wünscht sich Notfälle und Termine, Anna erlaubt nur Notfälle.
        sitter.setNotify(me.id, wanted = listOf("notfall", "termine"))
        anna.setNotify(me.id, allowed = listOf("notfall"))
        anna.loadPacks()
        val seen = anna.currentPack!!.members.first { it.id == me.id }
        assertEquals(listOf(app.thisdog.data.NotifyKind.NOTFALL), seen.notifies)
        assertEquals("not_yours", (runCatching { sitter.setNotify(anna.me!!, wanted = emptyList()) }.exceptionOrNull() as? app.thisdog.data.Api.Failure.Server)?.code)

        // Die letzte Besitzerin bleibt Besitzerin; Anna macht die Sitterin zur Besitzerin.
        assertEquals("last_owner", (runCatching { anna.setRole("sitter", anna.me!!) }.exceptionOrNull() as? app.thisdog.data.Api.Failure.Server)?.code)
        anna.setRole("owner", me.id)
        sitter.loadPacks()
        assertTrue(sitter.isOwner)
    }

    @Test fun memberWithoutRoleIsOwner() {
        val m = app.thisdog.data.ThisDogJson.decodeFromString(app.thisdog.data.Member.serializer(), """{"id":1,"name":"Alex","joinedAt":1}""")
        assertTrue(m.isOwner)
        assertTrue(m.notifies.isEmpty())
    }

    @Test fun recoveryCodeBringsTheDataBack() = runBlocking {
        val (anna, annaStore, _) = client("sitzung-anna-0123456789")
        annaStore.save(DogEvent(id = "evt_impfung", title = "Impfung", start = "2026-10-20"))
        anna.refresh(); anna.sync()
        val code = anna.recoveryCode()!!

        // Alle Telefone weg: ein neues Gerät, dasselbe Konto, kein Schlüssel.
        val (neu, neuStore, _) = client("sitzung-anna-0123456789")
        neu.refresh(); neu.sync()
        assertTrue(neu.keyMissing)
        assertTrue(neuStore.events.isEmpty())

        val fremd = app.thisdog.crypto.RecoveryCode.encode(app.thisdog.crypto.Sealing.newKey())
        val falsch = runCatching { neu.restore(fremd) }.exceptionOrNull()
        assertTrue(falsch is app.thisdog.crypto.RecoveryCode.Failure.WrongPack)
        assertTrue(neu.keyMissing)

        neu.restore(code)
        assertTrue(!neu.keyMissing)
        assertEquals("Impfung", neuStore.events.single().title)
    }

    @Test fun dogFriendsSeeEachOtherOnlyWhileWalking() = runBlocking {
        val (anna, annaStore, _) = client("sitzung-anna-0123456789")
        val (ben, benStore, _) = client("sitzung-ben-0123456789")
        for (a in listOf(anna, ben)) a.friends = app.thisdog.gassi.Friends(a, CoroutineScope(Dispatchers.IO))
        annaStore.upsert(app.thisdog.data.Kinds.profile, annaStore.profile.copy(name = "Stella"))
        benStore.upsert(app.thisdog.data.Kinds.profile, benStore.profile.copy(name = "Bello"))
        anna.refresh(); ben.refresh()
        assertTrue("zwei eigene Rudel", annaStore.packID != null && benStore.packID != null && annaStore.packID != benStore.packID)

        val link = anna.friends.invite()
        assertTrue(link.contains("/freund/") && link.contains("#k="))
        ben.open(link.substringAfter("https://thisdog.app").substringBefore('#'), link.substringAfter('#'))
        Thread.sleep(2500)
        assertEquals(null, ben.friends.message)
        anna.sync(); anna.friends.load(); ben.friends.load()
        // Der zweite load holt den Steckbrief, den der erste beim anderen ausgelöst hat.
        anna.friends.load(); ben.friends.load()
        assertEquals("Ben sieht Stella", listOf("Stella"), ben.friends.list.map { it.name })
        assertEquals("Anna sieht Bello", listOf("Bello"), anna.friends.list.map { it.name })

        anna.friends.walked(app.thisdog.model.LatLng(48.2214, 16.3851), System.currentTimeMillis())
        Thread.sleep(1500)
        ben.friends.refreshLive()
        assertEquals("Ben sieht Stella unterwegs", 1, ben.friends.live.size)
        assertEquals(48.2214, ben.friends.live[0].at.lat, 1e-9)
        assertEquals("Der Server kennt keine Koordinaten", "0", sql("echo \$pdo->query(\"SELECT COUNT(*) FROM friend_blobs WHERE blob LIKE '%48.22%'\")->fetchColumn();").trim())

        anna.friends.walkEnded()
        Thread.sleep(1500)
        ben.friends.refreshLive()
        assertTrue("Nach der Runde ist der Standort weg", ben.friends.live.isEmpty())

        val zone = app.thisdog.gassi.Place("Hundezone Augarten", "dog_park", "Hundezone", 0, 48.2253, 16.3762, serverID = "way/1")
        anna.friends.checkedIn(app.thisdog.gassi.CheckIn.of(zone))
        Thread.sleep(1500)
        ben.friends.refreshVisits()
        assertEquals("Ben sieht Stellas Check-in", listOf("Hundezone Augarten"), ben.friends.visits.map { it.place })
        assertEquals("Der Server kennt den Ort nicht", "0", sql("echo \$pdo->query(\"SELECT COUNT(*) FROM friend_blobs WHERE blob LIKE '%Augarten%'\")->fetchColumn();").trim())
    }
}
