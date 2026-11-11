package app.thisdog.ui

import app.thisdog.R

/** Erzeugt von android/tools/icons_aus_svg.py: der Name eines Icons wie auf iOS, das Drawable dazu. */
fun lineIconRes(name: String): Int = when (name) {
    "abzeichen" -> R.drawable.icon_abzeichen
    "ausruf" -> R.drawable.icon_ausruf
    "bank" -> R.drawable.icon_bank
    "beutel" -> R.drawable.icon_beutel
    "blatt" -> R.drawable.icon_blatt
    "chevron-links" -> R.drawable.icon_chevron_links
    "chevron-rechts" -> R.drawable.icon_chevron_rechts
    "drucker" -> R.drawable.icon_drucker
    "einstellungen" -> R.drawable.icon_einstellungen
    "flaeschchen" -> R.drawable.icon_flaeschchen
    "foto" -> R.drawable.icon_foto
    "funk" -> R.drawable.icon_funk
    "gassi" -> R.drawable.icon_gassi
    "glocke" -> R.drawable.icon_glocke
    "haken-kreis" -> R.drawable.icon_haken_kreis
    "haken" -> R.drawable.icon_haken
    "herz" -> R.drawable.icon_herz
    "heute" -> R.drawable.icon_heute
    "hund" -> R.drawable.icon_hund
    "kalender" -> R.drawable.icon_kalender
    "kamera" -> R.drawable.icon_kamera
    "karte" -> R.drawable.icon_karte
    "kompass" -> R.drawable.icon_kompass
    "kopieren" -> R.drawable.icon_kopieren
    "kreuz-kreis" -> R.drawable.icon_kreuz_kreis
    "kreuz" -> R.drawable.icon_kreuz
    "lampe" -> R.drawable.icon_lampe
    "lupe" -> R.drawable.icon_lupe
    "melden" -> R.drawable.icon_melden
    "muell" -> R.drawable.icon_muell
    "napf" -> R.drawable.icon_napf
    "notfall" -> R.drawable.icon_notfall
    "offline" -> R.drawable.icon_offline
    "ort" -> R.drawable.icon_ort
    "orten" -> R.drawable.icon_orten
    "park" -> R.drawable.icon_park
    "person-minus" -> R.drawable.icon_person_minus
    "person-plus" -> R.drawable.icon_person_plus
    "pin" -> R.drawable.icon_pin
    "plus" -> R.drawable.icon_plus
    "pruefung" -> R.drawable.icon_pruefung
    "rudel" -> R.drawable.icon_rudel
    "sauber" -> R.drawable.icon_sauber
    "schluessel" -> R.drawable.icon_schluessel
    "schreiben" -> R.drawable.icon_schreiben
    "sonne" -> R.drawable.icon_sonne
    "spritze" -> R.drawable.icon_spritze
    "stift" -> R.drawable.icon_stift
    "tablette" -> R.drawable.icon_tablette
    "teilen" -> R.drawable.icon_teilen
    "teilung" -> R.drawable.icon_teilung
    "tropfen" -> R.drawable.icon_tropfen
    "warnung" -> R.drawable.icon_warnung
    "wissen" -> R.drawable.icon_wissen
    "zaun" -> R.drawable.icon_zaun
    else -> error("Unbekanntes Icon: $name")
}
