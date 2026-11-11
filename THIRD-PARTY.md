# Fremde Bestandteile, Daten und ausgenommene Inhalte

Der Code von ThisDog steht unter der Apache License 2.0 (`LICENSE`). Diese Datei listet, was nicht
darunter fällt oder eigene Bedingungen mitbringt: Schrift, Bibliotheken, Daten und Dienste, Marken, Fotos
und KI-erzeugte Bilder.

## Schrift: Bricolage Grotesque

Copyright 2022 The Bricolage Grotesque Project Authors (<https://github.com/ateliertriay/bricolage>),
lizenziert unter der **SIL Open Font License 1.1**. Der Lizenztext liegt in
[`ios/ThisDog/Resources/Fonts/OFL.txt`](ios/ThisDog/Resources/Fonts/OFL.txt) und gilt für alle Kopien
unten. Die WOFF2-Dateien sind Teilmengen (lateinische Zeichen) und damit abgeleitete Fassungen unter
derselben Lizenz.

Die Schrift liegt bzw. wird ausgeliefert in:

| Ort | Form |
|---|---|
| `ios/ThisDog/Resources/Fonts/BricolageGrotesque.ttf` | TTF in der iOS-App (mit `OFL.txt`) |
| `android/app/src/main/res/font/bricolage.ttf` | TTF in der Android-App |
| `public/fonts/bricolage-grotesque-latin.woff2` | Web, benutzt von `rudel.php`, `freund.php`, `notfall.php`, `rechtliches/stil.css`; außerdem Eingabe für `appstore/quelle/pano.py` |
| `website/media/bricolage.woff2` | Web, benutzt von `website/src/og.html` |
| `website/index.html` | dieselbe WOFF2 als Base64 (`data:font/woff2`), eingebettet von `website/build.sh` |
| `public/index.html` | Kopie von `website/index.html` (über `website/ausliefern.sh`), ebenfalls mit Base64-Schrift |

## Bibliotheken der Android-App

Aus `android/app/build.gradle.kts`, `android/build.gradle.kts` und dem Gradle-Wrapper:

| Bibliothek | Lizenz |
|---|---|
| AndroidX: Compose (BOM, `material3`, `ui`, `ui-tooling`, `ui-tooling-preview`), `activity-compose`, `browser`, `lifecycle-runtime-compose` | Apache-2.0 |
| Kotlin, `kotlinx-serialization-json`, `kotlinx-coroutines-android` / `-test` | Apache-2.0 |
| OkHttp, MockWebServer (nur Tests) | Apache-2.0 |
| ZXing `core` (QR-Codes) | Apache-2.0 |
| MapLibre Native für Android (`org.maplibre.gl:android-sdk`) | BSD-2-Clause |
| **Google ML Kit** `barcode-scanning`, `image-labeling` | **proprietär**, [ML Kit Terms](https://developers.google.com/ml-kit/terms); die Modelle laufen auf dem Gerät |
| JUnit 4 (nur Tests) | EPL-1.0 |
| Android Gradle Plugin, Kotlin-Gradle-Plugins, Gradle-Wrapper (`gradle-wrapper.jar`) | Apache-2.0 (nur beim Bauen) |

ML Kit ist als einziger Teil nicht quelloffen. Wer eine vollständig freie Fassung bauen will, muss den
Food-Check (Strichcode und Bilderkennung) in `android/app/src/main/java/app/thisdog/ui/FoodScanner.kt`
ersetzen oder abschalten.

Die iOS- und watchOS-Apps nutzen nur Apple-Frameworks, keine fremden Pakete.

### Material Symbols

Frühere Fassungen der Android-App enthielten eine verkleinerte Schrift aus Google **Material Symbols**
(Apache-2.0). Sie ist nicht mehr dabei (die App nutzt eigene Icons aus `ios/ThisDog/Assets.xcassets`),
steckt aber noch in älteren Commits. Der Lizenztext liegt deshalb weiter in
[`android/app/LIZENZ-material-symbols.txt`](android/app/LIZENZ-material-symbols.txt).

### Server und Werkzeuge

- `public/admin-orte.php` lädt zur Laufzeit MapLibre GL JS von unpkg.com (BSD-3-Clause); nichts davon liegt im Repository.
- `server/orte-import.py` braucht `osmium` (pyosmium, BSD-2-Clause), das auf dem Server installiert wird.

## Daten und Dienste

| Quelle | Lizenz / Bedingungen | Wo |
|---|---|---|
| **OpenStreetMap** | © OpenStreetMap-Mitwirkende, [ODbL 1.0](https://www.openstreetmap.org/copyright) | Ziele für die Gassirunde: monatlicher Import von Geofabrik-Auszügen (`server/orte-import.py` → `places.sqlite`), außerhalb davon Overpass (`public/api/places.php`). Quellenangabe in beiden Apps („Aus OpenStreetMap“) und in `public/rechtliches/datenschutz.html`. |
| **Stadt Wien – data.wien.gv.at** | [CC BY 4.0](https://creativecommons.org/licenses/by/4.0/) | Hundezonen, Hundeverbotszonen, Trinkbrunnen in Wien (`server/orte-import.py`). Quellenangabe in den Apps („ergänzt mit Daten der Stadt Wien (CC BY 4.0)“). |
| **Open Food Facts** | Datenbank [ODbL 1.0](https://world.openfoodfacts.org/terms-of-use) | Strichcode im Food-Check, zur Laufzeit direkt aus der App abgefragt. Quellenangabe im Food-Check. |
| **OpenFreeMap** | Kacheln frei nutzbar; Kartendaten © OpenMapTiles, © OpenStreetMap-Mitwirkende | Karte der Android-App (`WalkMap.kt`) und von `public/admin-orte.php`; die Quellenangabe zeigt MapLibre auf der Karte. |
| **Valhalla beim FOSSGIS** (`valhalla1.openstreetmap.de`) | frei nutzbar nach Bedingungen des Betreibers; Daten © OpenStreetMap-Mitwirkende | Fußwege, über `public/api/route.php` |
| **MET Norway** (`api.met.no`) | [CC BY 4.0 / NLOD 2.0](https://api.met.no/doc/License) | Temperatur für die Hitzewarnung in der Android-App; Quellenangabe „Wetterdaten: MET Norway“. |
| **Apple WeatherKit** | Apple-Bedingungen, Hinweis auf Apple Wetter Pflicht | Hitzewarnung in der iOS-App (`ios/ThisDog/Gassi/Heat.swift`) |
| **Google Cloud Vision** | Google-Cloud-Bedingungen, eigener API-Schlüssel | optionale Bilderkennung auf dem Server (`public/api/photo-analyze.php`) |

Die Inhalte in `foods.json`, `tips.json` und `public_events.json` sind eigene Texte; Quellen für die
Einstufung neuer Lebensmittel stehen in `quellen/lebensmittel/`.

## Marken, Logos und Fotos

**Nicht unter der Apache-Lizenz.** Die Lizenz gewährt ohnehin keine Rechte an Namen und Marken
(Abschnitt 6); darüber hinaus sind die folgenden Inhalte ausdrücklich von ihr ausgenommen, alle Rechte
vorbehalten:

- die Namen **„ThisDog“** und **„Stella“**,
- das Logo (der Pudel) und die App-Icons:
  - `ios/ThisDog/Assets.xcassets/AppIcon.appiconset/`, `ios/ThisDog/Assets.xcassets/StellaMark.imageset/`
  - `ios/ThisDogWatch/Assets.xcassets/AppIcon.appiconset/`
  - `android/app/src/main/res/drawable/ic_launcher_foreground.xml`, `ic_launcher_monochrome.xml`,
    `stella_mark.xml`, `android/app/src/main/res/mipmap-anydpi/ic_launcher.xml`
  - `public/icons/v2/`
  - `website/media/stella-mark.svg` (auch eingebettet in `website/index.html` und `public/index.html`)
- die Fotos des Hundes, darunter `public/media/stella.jpg` und `website/media/stella.jpg`,
- alle übrigen Bilder, Bildschirmaufnahmen und Videos in `public/media/`, `website/media/` (etwa
  `hund.jpg`, `ipad-hund.jpg`, `iphone-hund.jpg`) und `appstore/`: Sie zeigen den Hund, seinen Namen, das
  Logo und die Marke; dazu die Bilder für geteilte Links (`og.jpg`, `og-runde.jpg`).

**Forks brauchen einen eigenen Namen und eigene Icons** und dürfen nicht den Eindruck erwecken, die
offizielle App zu sein. Wie man Kennungen und Domain austauscht, steht im README unter „Eigene Fassung“.

### Gerätebilder von Apple

`public/media/rahmen-*.webp`, `website/media/rahmen-*.webp` und `website/media/maske-*.webp` (die Masken
auch als Base64 in `website/index.html` und `public/index.html`) stammen aus Xcodes DeviceKit. Sie
gehören Apple und sind nicht unter der Apache-Lizenz. Im öffentlichen Repository fehlen sie deshalb, ebenso
die Bilder, in die sie schon eingebrannt sind (`appstore/bilder/*.png`, `appstore/vorschau-*.jpg`,
`*/media/og*.jpg`); die Webseite zeigt die Bildschirmfotos dort ohne Gerätrahmen. Wer sie braucht, erzeugt sie mit Xcode selbst.

## KI-erzeugte Bilder

Mit **Google Gemini** erzeugt:

- die Bilder zu den Ratgeber-Tipps: `quellen/img-tips/*`, `public/img/tips/**` (WebP-Fassungen) und
  `ios/ThisDog/Resources/Tips/`,
- die Vorlage der Zeichen in `quellen/icons/aus-bild/` (maschinell nachgezeichnet, siehe
  `quellen/icons/aus-bild/LIESMICH.md`).

Sie werden ohne jede Gewähr bereitgestellt („as is“). Ob und wem an solchen Bildern Rechte zustehen, ist
nicht eindeutig geklärt; soweit das unklar ist, sind sie von der Lizenzgewährung ausgenommen. Wer sie
weiterverwendet, prüft das selbst.
