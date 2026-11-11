# Server-Werkzeuge

Was hier liegt, läuft auf dem Server, aber nicht im Web: nichts davon gehört nach `public/`.

## orte-import.py – Ziele für die Gassirunde und Adressen

Liest Parks, Wälder, Wiesen und Hundezonen aus OpenStreetMap-Auszügen von Geofabrik
(Deutschland, Österreich, Schweiz) in `stella-daten/places.sqlite`. `api/places.php` fragt
diese Datei; Overpass nur noch außerhalb dieser Länder. Dazu die Adressen (Tabelle `services`:
Tierärzte, Hundefriseure, Tierbedarf, Hundeschulen, Tierheime, Pensionen, Lokale mit `dog=yes`)
für `api/services.php`; die gibt es nur aus dem Import, ohne Overpass. Eigene Orte stehen in `app.sqlite`
(Tabelle `own_places`, gepflegt unter `/admin-orte.php`) und bleiben bei jedem Import erhalten.

Einrichtung auf dem Server (einmalig; `<server>` ist der ssh-Name, `<home>` das Heimatverzeichnis
des Kontos, `<home>/stella-daten` der Datenordner aus `config.php`):

    python3 -m venv ~/osm-venv && ~/osm-venv/bin/pip install osmium
    mkdir -p ~/osm-import && rsync server/orte-import.py <server>:osm-import/

Cron, am 2. jedes Monats (Deutschland allein braucht rund eine halbe Stunde):

    20 3 2 * * cd <home> && OSMIUM_POOL_THREADS=4 nice -n 19 osm-venv/bin/python osm-import/orte-import.py <home>/stella-daten > osm-import/import.log 2>&1

Das bisherige Hosting beendet Prozesse, die etwa 20 Sekunden lang rund 2 GB belegen. Deshalb setzt das
Skript keine Flächen im Speicher zusammen (`with_areas`), nutzt weder `osmium.IdTracker` noch
`osmium.filter.IdFilter` (beide legen eine Bitmap über alle Knoten-IDs an, rund 1,6 GB) und
begrenzt die Lesethreads mit `OSMIUM_POOL_THREADS=4`. Österreich: rund 190 MB, 5 Minuten.
