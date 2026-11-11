package app.thisdog.data

import android.content.Context
import app.thisdog.i18n.L
import app.thisdog.gassi.Friends
import app.thisdog.gassi.WalkRecorder
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import okhttp3.Cookie
import java.io.File

/** Was die App einmal hält: Speicher, Konto, Inhalte. */
object Graph {
    lateinit var store: DogStore; private set
    lateinit var account: Account; private set
    lateinit var content: Content; private set
    val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main)
    private var ready = false

    fun init(context: Context) {
        if (ready) return
        val app = context.applicationContext
        L.init(app)
        store = DogStore(File(app.filesDir, "thisdog.json"))
        content = Content(app)
        val prefs = app.getSharedPreferences("sitzung", Context.MODE_PRIVATE)
        val cookies = object : Api.CookieStore {
            override fun load(): List<Cookie> = prefs.getStringSet("cookies", emptySet()).orEmpty().mapNotNull { Cookie.parse(okhttp3.HttpUrl.Builder().scheme("https").host("thisdog.app").build(), it) }
            override fun save(c: List<Cookie>) { prefs.edit().putStringSet("cookies", c.map { it.toString() }.toSet()).apply() }
        }
        account = Account(Api(cookies = cookies), store, AndroidKeyVault(app), scope)
        val friendNotes = app.getSharedPreferences("freunde", Context.MODE_PRIVATE)
        account.friends = Friends(account, scope, object : Friends.Notes {
            override fun get(key: String) = friendNotes.getString(key, null)
            override fun put(key: String, value: String?) { friendNotes.edit().apply { if (value == null) remove(key) else putString(key, value) }.apply() }
        })
        store.onLocalChange = { account.scheduleSync() }
        WalkRecorder.onPoint = { here, started -> account.friends.walked(here, started) }
        WalkRecorder.onEnd = { account.friends.walkEnded() }
        ready = true
    }
}
