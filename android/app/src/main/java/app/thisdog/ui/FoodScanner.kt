package app.thisdog.ui

import android.net.Uri
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.PickVisualMediaRequest
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.core.content.FileProvider
import app.thisdog.data.Graph
import app.thisdog.i18n.L
import app.thisdog.model.Food
import app.thisdog.model.FoodPhoto
import app.thisdog.model.IngredientCheck
import app.thisdog.model.ScannedProduct
import com.google.mlkit.vision.barcode.BarcodeScannerOptions
import com.google.mlkit.vision.barcode.BarcodeScanning
import com.google.mlkit.vision.barcode.common.Barcode
import com.google.mlkit.vision.common.InputImage
import com.google.mlkit.vision.label.ImageLabeling
import com.google.mlkit.vision.label.defaults.ImageLabelerOptions
import kotlinx.coroutines.launch
import kotlinx.coroutines.suspendCancellableCoroutine
import java.io.File
import kotlin.coroutines.resume

/**
 * Kamera im Food-Check: Ein Foto mit Strichcode wird über die Zutaten geprüft, ein Foto vom Essen in der Liste
 * nachgeschlagen. Beides erkennt ML Kit auf dem Telefon; nur die Nummer des Strichcodes geht an Open Food Facts.
 */
@Composable
fun rememberFoodScanner(onTerms: (List<String>) -> Unit, onMessage: (String) -> Unit, onProduct: (ScannedProduct.Result) -> Unit): Pair<() -> Unit, () -> Unit> {
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    var pending by remember { mutableStateOf<Uri?>(null) }
    val handle: (Uri) -> Unit = { uri ->
        scope.launch {
            // Über Pictures gelesen: auch HEIC und sehr große Fotos, aufrecht gedreht.
            val bitmap = kotlinx.coroutines.withContext(kotlinx.coroutines.Dispatchers.Default) { Pictures.load(context, uri) }
            val image = bitmap?.let { runCatching { InputImage.fromBitmap(it, 0) }.getOrNull() }
                ?: return@launch onMessage(L.t("Dieses Foto ließ sich nicht laden. Versuch es mit einem anderen."))
            val code = scanBarcode(image)
            if (code != null) { onProduct(ScannedProduct.lookup(code)); return@launch }
            val terms = FoodPhoto.terms(labels(image))
            if (terms.isEmpty()) onMessage(L.t("Kein Essen erkannt. Versuch es näher und mit mehr Licht, oder tipp den Namen ins Suchfeld."))
            else onTerms(terms)
        }
    }
    val camera = rememberLauncherForActivityResult(ActivityResultContracts.TakePicture()) { ok -> if (ok) pending?.let(handle) }
    val library = rememberLauncherForActivityResult(ActivityResultContracts.PickVisualMedia()) { uri -> uri?.let(handle) }
    return {
        val dir = File(context.cacheDir, "fotos").apply { mkdirs() }
        val uri = FileProvider.getUriForFile(context, "app.thisdog.fotos", File(dir, "essen-${System.currentTimeMillis()}.jpg"))
        pending = uri
        camera.launch(uri)
    } to { library.launch(PickVisualMediaRequest(ActivityResultContracts.PickVisualMedia.ImageOnly)) }
}

private suspend fun scanBarcode(image: InputImage): String? = suspendCancellableCoroutine { c ->
    val scanner = BarcodeScanning.getClient(BarcodeScannerOptions.Builder()
        .setBarcodeFormats(Barcode.FORMAT_EAN_13, Barcode.FORMAT_EAN_8, Barcode.FORMAT_UPC_A, Barcode.FORMAT_UPC_E).build())
    scanner.process(image)
        .addOnSuccessListener { list -> c.resume(list.firstNotNullOfOrNull { it.rawValue }) }
        .addOnFailureListener { c.resume(null) }
        .addOnCompleteListener { scanner.close() }
}

private suspend fun labels(image: InputImage): List<Pair<String, Float>> = suspendCancellableCoroutine { c ->
    val labeler = ImageLabeling.getClient(ImageLabelerOptions.Builder().setConfidenceThreshold(0.4f).build())
    labeler.process(image)
        .addOnSuccessListener { list -> c.resume(list.map { it.text to it.confidence }) }
        .addOnFailureListener { c.resume(emptyList()) }
        .addOnCompleteListener { labeler.close() }
}

/** Die Antwort zu einem gescannten Produkt: Gesamturteil, auffällige Zutaten, Herkunft der Daten. */
@Composable
fun ProductSheet(result: ScannedProduct.Result, onDismiss: () -> Unit) {
    val p = LocalPalette.current
    AlertDialog(onDismissRequest = onDismiss, containerColor = p.paper,
        confirmButton = { TextButton(onDismiss) { Text(L.t("Fertig"), color = p.accent, fontWeight = FontWeight.SemiBold) } },
        text = {
            Column(Modifier.verticalScroll(rememberScrollState()), verticalArrangement = Arrangement.spacedBy(14.dp)) {
                when (result) {
                    ScannedProduct.Result.NotFound -> Text(L.t("Dieses Produkt ist bei Open Food Facts nicht verzeichnet. Schau auf die Zutatenliste: Xylit, Schokolade, Rosinen, Zwiebeln und Knoblauch sind für Hunde gefährlich."), color = p.ink)
                    ScannedProduct.Result.Offline -> Text(L.t("Gerade keine Verbindung. Ohne Internet lassen sich Strichcodes nicht nachschlagen."), color = p.ink)
                    is ScannedProduct.Result.Found -> ProductAnswer(result.product)
                }
            }
        })
}

@Composable
private fun ProductAnswer(product: ScannedProduct) {
    val p = LocalPalette.current
    val hits = remember(product) { IngredientCheck(Graph.content.foods).hits(product.ingredientTags, product.ingredientsText) }
    val verdict = hits.firstOrNull()?.verdict ?: Food.Verdict.WARN
    val color = verdictColor(verdict, p)
    Column(verticalArrangement = Arrangement.spacedBy(2.dp)) {
        Text(product.name ?: L.t("Unbekanntes Produkt"), fontFamily = Display, fontWeight = FontWeight.Bold, fontSize = 24.sp, color = p.ink)
        product.brand?.let { Text(it, fontSize = 14.sp, color = p.ink2) }
    }
    Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(12.dp)) {
        Box(Modifier.size(44.dp).clip(CircleShape).background(color), contentAlignment = Alignment.Center) {
            LineIcon(when (verdict) { Food.Verdict.OK -> Sym.CHECK; Food.Verdict.WARN -> Sym.ALERT; Food.Verdict.BAD -> Sym.CLOSE }, Color.White, 26.dp)
        }
        Text(when (hits.firstOrNull()?.verdict) {
            Food.Verdict.BAD -> L.t("Nicht geeignet")
            Food.Verdict.WARN -> L.t("Nur mit Vorsicht")
            else -> if (product.hasIngredients) L.t("Nichts Giftiges gefunden") else L.t("Zutaten unbekannt")
        }, fontFamily = DisplayNarrow, fontWeight = FontWeight.Bold, fontSize = 22.sp, color = color)
    }
    hits.forEach { h ->
        Column(Modifier.fillMaxWidth().clip(RoundedCornerShape(16.dp)).background(p.surface).padding(14.dp), verticalArrangement = Arrangement.spacedBy(4.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                Box(Modifier.size(9.dp).clip(CircleShape).background(verdictColor(h.verdict, p)))
                Text(h.name, fontWeight = FontWeight.SemiBold, color = p.ink)
            }
            Text(h.reason, fontSize = 14.sp, color = p.ink2)
        }
    }
    if (hits.isEmpty()) Text(if (product.hasIngredients)
        L.t("In den Zutaten steht nichts, was für Hunde giftig ist. Fertigprodukte sind trotzdem oft zu salzig, zu fett oder gewürzt – höchstens ausnahmsweise und wenig.")
        else L.t("Zu diesem Produkt sind keine Zutaten hinterlegt. Schau selbst auf die Packung: Xylit, Schokolade, Rosinen, Zwiebeln und Knoblauch sind für Hunde gefährlich."), color = p.ink)
    if (product.ingredientsText.isNotEmpty()) Column(verticalArrangement = Arrangement.spacedBy(2.dp)) {
        Text(L.t("Zutaten"), fontSize = 12.sp, fontWeight = FontWeight.SemiBold, color = p.ink3)
        Text(product.ingredientsText, fontSize = 12.sp, color = p.ink2)
    }
    Text(L.t("Produktdaten: Open Food Facts (ODbL). Die Angaben pflegen Freiwillige und können unvollständig sein."), fontSize = 11.sp, color = p.ink3)
}
