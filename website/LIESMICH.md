# Webseite für ThisDog

`index.html` entsteht mit `./build.sh` aus `src/index.template.html` (Schrift und Logo werden eingebettet).
Die Videos in `media/` sind echte Aufnahmen der App im Simulator (iPhone Duo, zugeklappt), aufgenommen mit
den Vorführmodi der Entwicklerfassung (`-vorfuehrung`, `-tippe`, `-runde`). Die Schrift `media/bricolage.woff2`
ist aus der TTF der App erzeugt (lateinische Zeichen, Achsen für Stärke und Breite).

Auf thisdog.app bringt sie `./ausliefern.sh` nach `public/`, danach rsync wie dort beschrieben. Das Bild für geteilte
Links entsteht aus `src/og.html` (`media/og-runde.jpg`, 1200 × 630); bei einem neuen Bild den Dateinamen ändern,
weil Dienste die alte Adresse lange zwischenspeichern.
