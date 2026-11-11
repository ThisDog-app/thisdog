# Übersetzen von ThisDog

Der deutsche Text ist auf beiden Systemen der Schlüssel. Fehlt eine Übersetzung, bleibt es Deutsch.
Vorgesehen sind Englisch (`en`) und Serbisch in lateinischer Schrift (`sr-Latn`). Kyrillisch geht mit unserer Schrift
Bricolage Grotesque nicht, sie hat keine kyrillischen Zeichen.

## iOS und Watch
- `ios/Shared/Localizable.xcstrings`: alle Texte. In Xcode öffnen, Sprache wählen, übersetzen. Neue Texte sammelt Xcode beim Bauen ein.
- `ios/ThisDog/InfoPlist.xcstrings`, `ios/ThisDogWatch/InfoPlist.xcstrings`: Texte der Systemabfragen.
- Im Code: `Text("…")` wird von selbst übersetzt. Texte außerhalb davon brauchen `String(localized: "…")`.
- Mehrzahl: die Zahl gehört in denselben Text (`"\(n) Tage"`), nie getrennt. Im Katalog „Vary by Plural“ wählen. Serbisch braucht drei Formen.
- Datum und Zahlen über `AppLocale.current`, nie fest `de_DE`.
- Ansehen: Startargumente `-AppleLanguages (sr-Latn) -AppleLocale sr_RS`.
- Wenn eine Sprache fertig ist: in `ios/project.yml` bei `CFBundleLocalizations` eintragen. Vorher nicht, der App Store zeigt sie sonst als unterstützt.

## Android
- `android/app/src/main/assets/i18n/<sprache>.json`. Vorlage erzeugen: `python3 tools/i18n/android_vorlage.py`.
- Im Code: `L.t("Noch %1\$d Tage", n)`. Mehrzahl in der Datei: `{"Noch %1$d Tage": {"one": "…", "few": "…", "other": "…"}}`.
- Neue Sprache: Datei anlegen; L findet sie von selbst. Wenn sie fertig ist, in `res/xml/locales_config.xml` eintragen.
- Ansehen: `adb shell cmd locale set-app-locales app.thisdog --locales sr-Latn`.

## Inhalte
`foods.json`, `tips.json`, `public_events.json`: übersetzte Fassung daneben legen, zum Beispiel `foods.en.json` (iOS: `Resources`, Android: `assets`). Fürs Suchen im Food-Check gehören auch die `aliases` übersetzt.

## Prüfen
`tools/i18n/ios_pruefen.py wrap` (in `ios/`) und `tools/i18n/android_pruefen.py wrap` (in `android/app/src/main/`) zeigen Texte, die noch nicht übersetzbar sind. Kurze Texte aus Kleinbuchstaben fallen dabei durch das Raster.

## Noch nur Deutsch, und deshalb vor einer Übersetzung zu klären
- Server: Mails, Mitteilungen wie „Anna hat einen Termin eingetragen“, die Seite des Notfallpasses, Support, Datenschutz, Impressum, Webseite.
- Vom Server geladene Inhalte: In anderen Sprachen nutzt die App nur die mitgelieferten, bis der Server sprachabhängig liefert.
- Orte und Merkmale, die aus den Daten kommen, und Namen wie „Hundezone“ aus OpenStreetMap.
- Store-Bilder und Vorführdaten.
