package app.thisdog.ui

import android.content.Context
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.Canvas
import android.graphics.ImageDecoder
import android.graphics.Matrix
import android.media.ExifInterface
import android.net.Uri
import android.os.Build
import java.io.ByteArrayOutputStream
import java.io.InputStream
import kotlin.math.max
import kotlin.math.roundToInt

/**
 * Fotos aus Kamera und Galerie, für alle Stellen der App gleich: HEIC/HEIF und sehr große Bilder werden zuverlässig
 * gelesen, aufrecht gedreht (EXIF) und auf eine Höchstkante verkleinert. Hochgeladen wird immer ein JPEG, nie die
 * Rohdatei – der Server liest nur JPEG, PNG und WebP.
 */
object Pictures {
    /** Längste Kante für Fotos, die hochgeladen werden. */
    const val MAX_EDGE = 2000
    const val QUALITY = 85

    /** Liest ein Bild; `null`, wenn es sich nicht lesen lässt. */
    fun load(context: Context, uri: Uri, maxEdge: Int = MAX_EDGE): Bitmap? {
        val r = context.contentResolver
        return decode(maxEdge, { ImageDecoder.createSource(r, uri) }) { r.openInputStream(uri) }
    }

    /** Dasselbe für Bytes, etwa eine Datei aus dem eigenen Ordner. */
    fun load(bytes: ByteArray, maxEdge: Int = MAX_EDGE): Bitmap? =
        decode(maxEdge, { ImageDecoder.createSource(java.nio.ByteBuffer.wrap(bytes)) }) { bytes.inputStream() }

    /** Ein Foto zum Hochladen: höchstens [maxEdge] px, JPEG. */
    fun jpeg(context: Context, uri: Uri, maxEdge: Int = MAX_EDGE): ByteArray? = load(context, uri, maxEdge)?.let { jpeg(it) }

    fun jpeg(bitmap: Bitmap, quality: Int = QUALITY): ByteArray {
        // JPEG kennt keine Transparenz; durchsichtige Stellen (PNG) würden sonst schwarz.
        val opaque = if (bitmap.hasAlpha()) Bitmap.createBitmap(bitmap.width, bitmap.height, Bitmap.Config.ARGB_8888).also {
            Canvas(it).apply { drawColor(android.graphics.Color.WHITE); drawBitmap(bitmap, 0f, 0f, null) }
        } else bitmap
        return ByteArrayOutputStream().also { opaque.compress(Bitmap.CompressFormat.JPEG, quality, it) }.toByteArray()
    }

    private fun decode(maxEdge: Int, source: () -> ImageDecoder.Source, stream: () -> InputStream?): Bitmap? {
        // ImageDecoder (ab Android 9) kann HEIF, dreht nach EXIF und verkleinert schon beim Lesen.
        val modern = if (Build.VERSION.SDK_INT >= 28) runCatching {
            ImageDecoder.decodeBitmap(source()) { decoder, info, _ ->
                decoder.allocator = ImageDecoder.ALLOCATOR_SOFTWARE  // sonst lässt es sich nicht als JPEG schreiben
                val w = info.size.width; val h = info.size.height
                val k = maxEdge.toDouble() / max(w, h)
                if (k < 1) decoder.setTargetSize(max(1, (w * k).roundToInt()), max(1, (h * k).roundToInt()))
            }
        }.getOrNull() else null
        return (modern ?: runCatching { legacy(maxEdge, stream) }.getOrNull())?.let { fit(it, maxEdge) }
    }

    /** Ohne ImageDecoder: erst die Größe, dann grob verkleinert lesen (inSampleSize), dann nach EXIF drehen. */
    private fun legacy(maxEdge: Int, stream: () -> InputStream?): Bitmap? {
        val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
        stream()?.use { BitmapFactory.decodeStream(it, null, bounds) } ?: return null
        if (bounds.outWidth <= 0 || bounds.outHeight <= 0) return null
        var sample = 1
        while (max(bounds.outWidth, bounds.outHeight) / (sample * 2) >= maxEdge) sample *= 2
        val bmp = stream()?.use { BitmapFactory.decodeStream(it, null, BitmapFactory.Options().apply { inSampleSize = sample }) } ?: return null
        val orientation = runCatching { stream()?.use { ExifInterface(it).getAttributeInt(ExifInterface.TAG_ORIENTATION, ExifInterface.ORIENTATION_NORMAL) } }
            .getOrNull() ?: ExifInterface.ORIENTATION_NORMAL
        val m = Matrix()
        when (orientation) {
            ExifInterface.ORIENTATION_ROTATE_90 -> m.postRotate(90f)
            ExifInterface.ORIENTATION_ROTATE_180 -> m.postRotate(180f)
            ExifInterface.ORIENTATION_ROTATE_270 -> m.postRotate(270f)
            ExifInterface.ORIENTATION_FLIP_HORIZONTAL -> m.postScale(-1f, 1f)
            ExifInterface.ORIENTATION_FLIP_VERTICAL -> m.postScale(1f, -1f)
            ExifInterface.ORIENTATION_TRANSPOSE -> { m.postRotate(90f); m.postScale(-1f, 1f) }
            ExifInterface.ORIENTATION_TRANSVERSE -> { m.postRotate(270f); m.postScale(-1f, 1f) }
            else -> return bmp
        }
        return Bitmap.createBitmap(bmp, 0, 0, bmp.width, bmp.height, m, true)
    }

    /** Falls noch zu groß (etwa nach inSampleSize), genau auf die Höchstkante. */
    private fun fit(b: Bitmap, maxEdge: Int): Bitmap {
        val k = maxEdge.toDouble() / max(b.width, b.height)
        return if (k >= 1) b else Bitmap.createScaledBitmap(b, max(1, (b.width * k).roundToInt()), max(1, (b.height * k).roundToInt()), true)
    }
}
