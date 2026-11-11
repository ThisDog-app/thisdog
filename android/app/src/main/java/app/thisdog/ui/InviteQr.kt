package app.thisdog.ui

import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.Text
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.FilterQuality
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.core.content.FileProvider
import app.thisdog.i18n.L
import com.google.mlkit.vision.barcode.BarcodeScannerOptions
import com.google.mlkit.vision.barcode.BarcodeScanning
import com.google.mlkit.vision.barcode.common.Barcode
import com.google.mlkit.vision.common.InputImage
import kotlinx.coroutines.launch
import kotlinx.coroutines.suspendCancellableCoroutine
import java.io.File
import kotlin.coroutines.resume

/**
 * Die Einladung zum Abscannen: Das andere Telefon richtet die Kamera darauf und ist im Rudel – ohne E-Mail,
 * ohne Passwort. Der QR-Code enthält den ganzen Link samt Schlüssel hinter dem `#`.
 */
@Composable
fun InviteCard(url: String, role: String? = null, onOther: (() -> Unit)? = null) {
    val p = LocalPalette.current; val context = LocalContext.current
    Column(Modifier.fillMaxWidth().clip(RoundedCornerShape(24.dp)).background(p.surface).padding(18.dp),
        horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(14.dp)) {
        role?.let { Text(if (it == "sitter") L.t("Einladung als Hundesitter") else L.t("Einladung als Besitzer"), fontWeight = FontWeight.SemiBold, fontSize = 17.sp, color = p.ink) }
        val bmp = remember(url) { qrBitmap(url, 720).asImageBitmap() }
        Image(bmp, L.t("QR-Code der Einladung"), Modifier.size(220.dp).clip(RoundedCornerShape(16.dp)).background(Color.White).padding(10.dp), filterQuality = FilterQuality.None)
        Text(L.t("Mit der Kamera des anderen Telefons scannen, oder in ThisDog unter „Einladung scannen“."), fontSize = 15.sp, color = p.ink2, textAlign = TextAlign.Center)
        Button({ share(context, L.t("Mit diesem Link kommst du in unser Rudel bei ThisDog. Er gilt sieben Tage.\n%1\$s", url), L.t("Komm in mein Rudel bei ThisDog")) },
            Modifier.fillMaxWidth().height(50.dp), shape = RoundedCornerShape(50), colors = ButtonDefaults.buttonColors(containerColor = p.accent, contentColor = Color.White)) {
            LineIcon(Sym.SHARE, Color.White, 20.dp); Spacer(Modifier.width(8.dp)); Text(L.t("Link teilen"), fontWeight = FontWeight.SemiBold)
        }
        Text(L.t("Gilt sieben Tage, für alle, die du damit einlädst."), fontSize = 13.sp, color = p.ink3, textAlign = TextAlign.Center)
        onOther?.let { Text(L.t("Andere Einladung"), color = p.accent, fontSize = 15.sp, fontWeight = FontWeight.Medium, modifier = Modifier.clickable(onClick = it)) }
    }
}

/**
 * Eine Einladung abscannen: ein Foto mit der Kamera, ML Kit sucht darin einen QR-Code (auf dem Telefon, nichts geht
 * hinaus). Gibt die Funktion zum Starten zurück; `onLink` bekommt den gefundenen thisdog.app-Link.
 */
@Composable
fun rememberInviteScanner(onLink: (String) -> Unit, onMessage: (String) -> Unit): () -> Unit {
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    var pending by remember { mutableStateOf<android.net.Uri?>(null) }
    val camera = rememberLauncherForActivityResult(ActivityResultContracts.TakePicture()) { ok ->
        val uri = pending
        if (!ok || uri == null) return@rememberLauncherForActivityResult
        scope.launch {
            val image = runCatching { InputImage.fromFilePath(context, uri) }.getOrNull()
            val found = image?.let { scanQr(it) }?.firstOrNull { it.startsWith("https://thisdog.app/") }
            runCatching { context.contentResolver.delete(uri, null, null) }
            if (found != null) onLink(found)
            else onMessage(L.t("Kein ThisDog-QR-Code erkannt. Halt das Telefon etwas weiter weg und ruhig, dann noch einmal."))
        }
    }
    return {
        val dir = File(context.cacheDir, "fotos").apply { mkdirs() }
        val uri = FileProvider.getUriForFile(context, "app.thisdog.fotos", File(dir, "einladung-${System.currentTimeMillis()}.jpg"))
        pending = uri
        camera.launch(uri)
    }
}

private suspend fun scanQr(image: InputImage): List<String> = suspendCancellableCoroutine { c ->
    val scanner = BarcodeScanning.getClient(BarcodeScannerOptions.Builder().setBarcodeFormats(Barcode.FORMAT_QR_CODE).build())
    scanner.process(image)
        .addOnSuccessListener { list -> c.resume(list.mapNotNull { it.rawValue }) }
        .addOnFailureListener { c.resume(emptyList()) }
        .addOnCompleteListener { scanner.close() }
}
