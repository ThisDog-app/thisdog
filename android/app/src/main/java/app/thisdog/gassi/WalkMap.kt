package app.thisdog.gassi

import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.Paint
import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.statusBars
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.toArgb
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.viewinterop.AndroidView
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleEventObserver
import androidx.lifecycle.compose.LocalLifecycleOwner
import app.thisdog.model.LatLng
import app.thisdog.ui.LocalPalette
import app.thisdog.ui.Sym
import org.maplibre.android.MapLibre
import org.maplibre.android.camera.CameraUpdateFactory
import org.maplibre.android.geometry.LatLngBounds
import org.maplibre.android.maps.MapLibreMap
import org.maplibre.android.maps.MapView
import org.maplibre.android.maps.Style
import org.maplibre.android.style.expressions.Expression
import org.maplibre.android.style.layers.CircleLayer
import org.maplibre.android.style.layers.LineLayer
import org.maplibre.android.style.layers.Property
import org.maplibre.android.style.layers.PropertyFactory.*
import org.maplibre.android.style.layers.SymbolLayer
import org.maplibre.android.style.sources.GeoJsonSource
import org.maplibre.geojson.Feature
import org.maplibre.geojson.FeatureCollection
import org.maplibre.geojson.LineString
import org.maplibre.geojson.Point
import org.maplibre.android.geometry.LatLng as MapPoint

/** Ein befreundeter Hund auf der Karte: Name, Bild als Bitmap (rund) und wo er gerade ist. */
data class FriendSpot(val id: String, val name: String, val at: LatLng, val photo: Bitmap?)

/**
 * Die Karte (wie WalkMap.swift): OpenFreeMap im ruhigen Stil „Positron“, damit die Runde die einzige laute
 * Linie ist. Die Strecke endet am aktuellen Standort in einem Punkt – die Linie aus dem Logo.
 * OpenFreeMap braucht weder Schlüssel noch Konto und setzt keine Cookies.
 */
@Composable
fun WalkMap(
    modifier: Modifier = Modifier,
    track: List<LatLng> = emptyList(),
    here: LatLng? = null,
    places: List<Place> = emptyList(),
    follows: Boolean = false,
    fallback: LatLng? = null,
    friends: List<FriendSpot> = emptyList(),
    /** Reicht die Karte bis unter die Statusleiste, rückt das Info-Symbol darunter. */
    underStatusBar: Boolean = false,
    /** Ein Ort wurde angetippt. */
    onSelect: ((Place) -> Unit)? = null,
    /** Der gerade gezeigte Ort ist hervorgehoben. */
    selected: String? = null,
    /** Hierhin stellt sich die Karte (ein angetippter Ort), mit diesem Zoom. */
    focus: LatLng? = null,
    focusZoom: Double = 15.6,
    /** Die Mitte der Karte nach jeder Bewegung (Ort eintragen). */
    onCenter: ((LatLng) -> Unit)? = null,
    /** Ändert sich dieser Wert, stellt sich die Karte auf die ganze Strecke oder das Revier. */
    fitKey: String? = null,
    /** Das Revier: die Orte, an denen der Hund war, je größer, desto öfter. */
    revier: List<Revier.Spot> = emptyList(),
    /** Was gerade verdeckt ist, in Dp: links, oben, rechts, unten. Die Karte richtet sich nach dem freien Teil aus. */
    padding: List<Float> = listOf(0f, 0f, 0f, 0f),
) {
    val context = LocalContext.current
    val p = LocalPalette.current
    val dark = isSystemInDarkTheme()
    val density = androidx.compose.ui.platform.LocalDensity.current
    val statusBar = WindowInsets.statusBars.getTop(density)
    val lifecycle = LocalLifecycleOwner.current.lifecycle
    val view = remember { MapLibre.getInstance(context); MapView(context).apply { onCreate(null) } }
    var map by remember { mutableStateOf<MapLibreMap?>(null) }
    var style by remember { mutableStateOf<Style?>(null) }
    var placed by remember { mutableStateOf(false) }
    /** Wo die Karte zuletzt auf den Standort gesetzt wurde. */
    var centered by remember { mutableStateOf<LatLng?>(null) }

    DisposableEffect(lifecycle) {
        val obs = LifecycleEventObserver { _, e ->
            when (e) {
                Lifecycle.Event.ON_START -> view.onStart(); Lifecycle.Event.ON_RESUME -> view.onResume()
                Lifecycle.Event.ON_PAUSE -> view.onPause(); Lifecycle.Event.ON_STOP -> view.onStop()
                else -> {}
            }
        }
        lifecycle.addObserver(obs)
        if (lifecycle.currentState.isAtLeast(Lifecycle.State.STARTED)) view.onStart()
        if (lifecycle.currentState.isAtLeast(Lifecycle.State.RESUMED)) view.onResume()
        onDispose { lifecycle.removeObserver(obs); view.onPause(); view.onStop(); view.onDestroy() }
    }

    LaunchedEffect(dark) {
        view.getMapAsync { m ->
            map = m
            m.uiSettings.isLogoEnabled = false
            m.uiSettings.isRotateGesturesEnabled = false
            m.uiSettings.isTiltGesturesEnabled = false
            // Oben links: Rechts kann das Panel liegen, unten das Blatt.
            m.uiSettings.setAttributionTintColor(p.ink3.toArgb())
            m.uiSettings.attributionGravity = android.view.Gravity.TOP or android.view.Gravity.START
            m.setStyle(Style.Builder().fromUri(if (dark) "https://tiles.openfreemap.org/styles/dark" else "https://tiles.openfreemap.org/styles/positron")) { s ->
                val accent = p.accent.toArgb(); val ink = p.ink.toArgb(); val white = android.graphics.Color.WHITE
                s.addSource(GeoJsonSource("strecke")); s.addSource(GeoJsonSource("start")); s.addSource(GeoJsonSource("ziele"))
                s.addSource(GeoJsonSource("freunde")); s.addSource(GeoJsonSource("hier"))
                s.addLayer(LineLayer("strecke", "strecke").withProperties(lineColor(accent), lineWidth(5f), lineCap(Property.LINE_CAP_ROUND), lineJoin(Property.LINE_JOIN_ROUND)))
                s.addLayer(CircleLayer("start", "start").withProperties(circleRadius(6f), circleColor(white), circleStrokeColor(accent), circleStrokeWidth(3f)))
                s.addLayer(CircleLayer("ziele", "ziele").withProperties(circleRadius(5f), circleColor(white), circleStrokeWidth(1.6f),
                    circleStrokeColor(Expression.switchCase(Expression.get("hundezone"), Expression.color(accent), Expression.color(ink)))))
                s.addSource(GeoJsonSource("revier"))
                s.addLayer(CircleLayer("revier", "revier").withProperties(circleRadius(Expression.get("r")), circleColor(accent), circleOpacity(Expression.get("o")), circleStrokeColor(white), circleStrokeWidth(2f)))
                s.addSource(GeoJsonSource("auswahl"))
                s.addLayer(CircleLayer("auswahl", "auswahl").withProperties(circleRadius(15f), circleColor(accent)))
                // Das Icon des gewählten Ortes: im Strich des Logos, weiß auf Mandarine.
                s.addImage("ort-hund", iconBitmap(context, Sym.PAW)); s.addImage("ort-park", iconBitmap(context, Sym.PARK))
                s.addLayer(SymbolLayer("auswahl-icon", "auswahl").withProperties(iconImage(Expression.get("icon")), iconAllowOverlap(true), iconIgnorePlacement(true)))
                s.addLayer(SymbolLayer("freunde", "freunde").withProperties(iconImage(Expression.get("bild")), iconAllowOverlap(true), iconIgnorePlacement(true)))
                s.addLayer(CircleLayer("hier-hof", "hier").withProperties(circleRadius(22f), circleColor(accent), circleOpacity(0.16f)))
                s.addLayer(CircleLayer("hier", "hier").withProperties(circleRadius(8f), circleColor(accent), circleStrokeColor(white), circleStrokeWidth(3f)))
                style = s
            }
        }
    }

    LaunchedEffect(map, statusBar) { map?.uiSettings?.setAttributionMargins(24, 24 + if (underStatusBar) statusBar else 0, 0, 0) }

    // Inhalte nachführen.
    // Antippen eines Ortes; die Mitte nach jeder Bewegung.
    val currentPlaces by rememberUpdatedState(places)
    val select by rememberUpdatedState(onSelect)
    val center by rememberUpdatedState(onCenter)
    LaunchedEffect(map) {
        val m = map ?: return@LaunchedEffect
        m.addOnMapClickListener { point ->
            val hit = m.queryRenderedFeatures(m.projection.toScreenLocation(point), "ziele", "auswahl").firstOrNull()
            val id = hit?.getStringProperty("id")
            val p = currentPlaces.firstOrNull { it.id == id }
                ?: if (hit != null) currentPlaces.minByOrNull { app.thisdog.model.Track.distance(LatLng(point.latitude, point.longitude), it.coordinate) } else null
            if (p != null) { select?.invoke(p); true } else false
        }
        m.addOnCameraIdleListener { m.cameraPosition.target?.let { t -> center?.invoke(LatLng(t.latitude, t.longitude)) } }
    }

    /** Jede Fahrt nennt den verdeckten Teil mit: Eine folgende Bewegung bricht sonst das Nachführen ab. */
    fun toPoint(point: MapPoint, zoom: Double) = density.density.let { d ->
        CameraUpdateFactory.newCameraPosition(org.maplibre.android.camera.CameraPosition.Builder().target(point).zoom(zoom)
            .padding((padding[0] * d).toDouble(), (padding[1] * d).toDouble(), (padding[2] * d).toDouble(), (padding[3] * d).toDouble()).build())
    }

    // Was das Blatt oder Panel verdeckt, zählt nicht zur Karte.
    LaunchedEffect(map, padding) {
        val m = map ?: return@LaunchedEffect
        val d = density.density
        m.animateCamera(CameraUpdateFactory.paddingTo((padding[0] * d).toDouble(), (padding[1] * d).toDouble(), (padding[2] * d).toDouble(), (padding[3] * d).toDouble()), 250)
    }

    LaunchedEffect(style, track.size, here, places, friends, selected, revier) {
        val s = style ?: return@LaunchedEffect
        val pts = track.map { Point.fromLngLat(it.lng, it.lat) }
        (s.getSource("strecke") as? GeoJsonSource)?.setGeoJson(if (pts.size > 1) FeatureCollection.fromFeature(Feature.fromGeometry(LineString.fromLngLats(pts))) else FeatureCollection.fromFeatures(emptyList()))
        (s.getSource("start") as? GeoJsonSource)?.setGeoJson(FeatureCollection.fromFeatures(listOfNotNull(pts.firstOrNull()?.let { Feature.fromGeometry(it) })))
        (s.getSource("ziele") as? GeoJsonSource)?.setGeoJson(FeatureCollection.fromFeatures(places.map {
            Feature.fromGeometry(Point.fromLngLat(it.lon, it.lat)).apply { addBooleanProperty("hundezone", it.isDogZone); addStringProperty("id", it.id) }
        }))
        (s.getSource("auswahl") as? GeoJsonSource)?.setGeoJson(FeatureCollection.fromFeatures(places.filter { it.id == selected }.map { Feature.fromGeometry(Point.fromLngLat(it.lon, it.lat)).apply { addStringProperty("icon", if (it.isDogZone) "ort-hund" else "ort-park") } }))
        val most = maxOf(1, revier.maxOfOrNull { it.visits } ?: 1)
        (s.getSource("revier") as? GeoJsonSource)?.setGeoJson(FeatureCollection.fromFeatures(revier.map {
            val part = it.visits.toFloat() / most
            Feature.fromGeometry(Point.fromLngLat(it.at.lng, it.at.lat)).apply { addNumberProperty("r", 6 + 13 * part); addNumberProperty("o", .35f + .6f * part) }
        }))
        friends.forEach { f -> s.addImage("freund-${f.id}", friendMarker(context, f, p.accent.toArgb(), p.soft.toArgb())) }
        (s.getSource("freunde") as? GeoJsonSource)?.setGeoJson(FeatureCollection.fromFeatures(friends.map {
            Feature.fromGeometry(Point.fromLngLat(it.at.lng, it.at.lat)).apply { addStringProperty("bild", "freund-${it.id}") }
        }))
        (s.getSource("hier") as? GeoJsonSource)?.setGeoJson(FeatureCollection.fromFeatures(listOfNotNull(here?.let { Feature.fromGeometry(Point.fromLngLat(it.lng, it.lat)) })))
    }

    // Worauf sich die Karte einstellt: das Revier oder die ganze Strecke. Fällt das weg, zurück zum Standort.
    val fit = if (revier.isNotEmpty()) revier.map { it.at } else track.takeIf { it.size > 1 }.orEmpty()
    LaunchedEffect(map, fitKey) {
        val m = map ?: return@LaunchedEffect
        if (fitKey != null && fit.isNotEmpty()) {
            val spread = fit.size > 1 && fit.any { it != fit[0] }
            if (spread) {
                // Etwas Luft drumherum, auch bei einer ganz kurzen Runde (wie WalkMap.rect auf iOS).
                val lats = fit.map { it.lat }; val lngs = fit.map { it.lng }
                val airLat = (lats.max() - lats.min()) * .25 + .0012; val airLng = (lngs.max() - lngs.min()) * .25 + .0018
                val b = LatLngBounds.Builder().include(MapPoint(lats.max() + airLat, lngs.max() + airLng)).include(MapPoint(lats.min() - airLat, lngs.min() - airLng)).build()
                // Die ganze Strecke im freien Teil der Karte, nicht hinter Blatt oder Panel.
                val d = density.density
                m.animateCamera(CameraUpdateFactory.newLatLngBounds(b, (padding[0] * d).toInt(), (padding[1] * d).toInt(), (padding[2] * d).toInt(), (padding[3] * d).toInt()), 500)
            } else m.animateCamera(toPoint(MapPoint(fit[0].lat, fit[0].lng), 14.5), 500)
            placed = true; centered = null
        } else if (placed && centered == null) {
            (here ?: fallback)?.let { m.animateCamera(toPoint(MapPoint(it.lat, it.lng), 13.8), 500); centered = it }
        }
    }

    // Kamera: unterwegs folgt sie dem Standort, danach zeigt sie die ganze Runde.
    LaunchedEffect(map, here, follows, focus) {
        val m = map ?: return@LaunchedEffect
        when {
            focus != null -> { m.animateCamera(toPoint(MapPoint(focus.lat, focus.lng), focusZoom), 500); placed = true; centered = focus }
            fitKey != null -> {}
            !follows && track.size > 1 && !placed -> {
                val b = LatLngBounds.Builder().apply { track.forEach { include(MapPoint(it.lat, it.lng)) } }.build()
                m.moveCamera(CameraUpdateFactory.newLatLngBounds(b, 120)); placed = true
            }
            follows && here != null -> m.animateCamera(toPoint(MapPoint(here.lat, here.lng), 16.3), 600)
            // Vor der Runde: auf den Standort setzen – und noch einmal, wenn er sich deutlich verschoben hat.
            here != null && track.isEmpty() && (centered?.let { app.thisdog.model.Track.distance(it, here) > 300 } ?: true) -> {
                m.moveCamera(toPoint(MapPoint(here.lat, here.lng), 13.8)); placed = true; centered = here
            }
            fallback != null && !placed -> m.moveCamera(toPoint(MapPoint(fallback.lat, fallback.lng), 13.8))
        }
    }

    AndroidView({ view }, modifier)
}

/** Rundes Bild mit weißem Rand und Akzentring – oder eine Pfote auf zarter Tönung. */
private fun friendMarker(context: android.content.Context, f: FriendSpot, accent: Int, soft: Int): Bitmap {
    val size = 120
    val out = Bitmap.createBitmap(size, size, Bitmap.Config.ARGB_8888)
    val c = Canvas(out); val paint = Paint(Paint.ANTI_ALIAS_FLAG)
    val r = size / 2f
    paint.color = accent; c.drawCircle(r, r, r, paint)
    paint.color = android.graphics.Color.WHITE; c.drawCircle(r, r, r - 5, paint)
    val inner = r - 13
    if (f.photo != null) {
        val shader = android.graphics.BitmapShader(Bitmap.createScaledBitmap(f.photo, (inner * 2).toInt(), (inner * 2).toInt(), true), android.graphics.Shader.TileMode.CLAMP, android.graphics.Shader.TileMode.CLAMP)
        c.save(); c.translate(r - inner, r - inner)
        paint.shader = shader; c.drawCircle(inner, inner, inner, paint); paint.shader = null
        c.restore()
    } else {
        paint.color = soft; c.drawCircle(r, r, inner, paint)
        // Ohne Foto eine Pfote, wie in der Liste.
        androidx.core.content.ContextCompat.getDrawable(context, app.thisdog.R.drawable.icon_hund)?.mutate()?.let { d ->
            val half = (inner * .62f).toInt()
            d.setTint(accent); d.setBounds(r.toInt() - half, r.toInt() - half, r.toInt() + half, r.toInt() + half); d.draw(c)
        }
    }
    return out
}

/** Ein Icon als weißes Bild für die Kartenebene. */
private fun iconBitmap(context: android.content.Context, name: String): Bitmap {
    val side = (20 * context.resources.displayMetrics.density).toInt()
    val out = Bitmap.createBitmap(side, side, Bitmap.Config.ARGB_8888)
    androidx.core.content.ContextCompat.getDrawable(context, app.thisdog.ui.lineIconRes(name))?.mutate()?.let { d ->
        d.setTint(android.graphics.Color.WHITE); d.setBounds(0, 0, side, side); d.draw(Canvas(out))
    }
    return out
}
