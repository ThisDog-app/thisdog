package app.thisdog

import app.thisdog.data.Account
import app.thisdog.data.Api
import app.thisdog.data.DogStore
import app.thisdog.data.KeyVault
import java.io.File
import java.net.ServerSocket
import java.nio.file.Files
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/** Anmeldung und Abgleich ohne Server: was ein Netzfehler nicht anrichten darf. */
class AccountTest {
    /** Ohne Verbindung beim Start ist man nicht abgemeldet – der Zustand bleibt offen, bis der Server antwortet. */
    @Test fun offlineStaysUnknown() = runBlocking {
        val port = ServerSocket(0).use { it.localPort }   // gleich wieder frei: Verbindung abgelehnt
        val store = DogStore(File(Files.createTempDirectory("konto").toFile(), "thisdog.json"))
        val a = Account(Api("http://127.0.0.1:$port/api/"), store, KeyVault.Memory(), CoroutineScope(Dispatchers.IO))
        a.refresh()
        assertEquals(Account.State.Unknown, a.state)
        a.sync()
        assertEquals(Account.State.Unknown, a.state)
    }

    /** Fiel beim Abgleich etwas heraus (versiegelt, nicht zu öffnen), bleibt die Revision stehen. */
    @Test fun revisionStaysWhenSkipped() {
        assertEquals(4, Account.nextRev(4, 9, skipped = true))
        assertEquals(9, Account.nextRev(4, 9, skipped = false))
    }

    /** Eine volle Seite (`more`): Erst nach der letzten Seite gilt der Abgleich als gelungen, und alles ist da. */
    @Test fun syncPullsAllPages() = runBlocking {
        val key = app.thisdog.crypto.Sealing.newKey()
        fun rec(id: String) = Account.seal(app.thisdog.data.SyncRecord("event", id, 1.0,
            payload = kotlinx.serialization.json.buildJsonObject { put("id", kotlinx.serialization.json.JsonPrimitive(id)); put("title", kotlinx.serialization.json.JsonPrimitive(id)); put("start", kotlinx.serialization.json.JsonPrimitive("2026-11-10")) }), 1, key)
        val sinces = mutableListOf<Int>()
        val server = okhttp3.mockwebserver.MockWebServer()
        server.dispatcher = object : okhttp3.mockwebserver.Dispatcher() {
            override fun dispatch(request: okhttp3.mockwebserver.RecordedRequest): okhttp3.mockwebserver.MockResponse {
                val path = request.path ?: ""
                val json = app.thisdog.data.ThisDogJson
                val body = when {
                    "auth.php" in path -> """{"signedIn":true,"email":"a@example.org"}"""
                    "pack.php" in path -> """{"me":1,"packs":[{"id":1,"members":[],"sealed":true}]}"""
                    else -> {
                        val since = json.parseToJsonElement(request.body.readUtf8()).let { (it as kotlinx.serialization.json.JsonObject)["since"].toString().toInt() }
                        synchronized(sinces) { sinces += since }
                        val (records, rev, more) = if (since < 5) Triple(listOf(rec("evt_a")), 5, true) else Triple(listOf(rec("evt_b")), 7, false)
                        """{"pack":1,"rev":$rev,"more":$more,"records":${json.encodeToString(kotlinx.serialization.builtins.ListSerializer(app.thisdog.data.SyncRecord.serializer()), records)}}"""
                    }
                }
                return okhttp3.mockwebserver.MockResponse().setBody(body)
            }
        }
        server.start()
        try {
            val store = DogStore(File(Files.createTempDirectory("seiten").toFile(), "thisdog.json"))
            val keys = KeyVault.Memory().apply { setPackKey(key, 1) }
            val a = Account(Api(server.url("/api/").toString()), store, keys, CoroutineScope(Dispatchers.IO))
            a.refresh()
            assertEquals(7, store.rev)
            assertEquals(setOf("evt_a", "evt_b"), store.events.map { it.id }.toSet())
            assertTrue(a.sync())
            assertEquals(listOf(0, 5, 7), sinces)
        } finally { server.shutdown() }
    }
}
