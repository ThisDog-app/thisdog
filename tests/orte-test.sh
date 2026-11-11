#!/bin/bash
# Prüft die Ziele für die Gassirunde: eigener OpenStreetMap-Auszug, eigene Orte, Ausblenden, Admin-Zugang.
# Aufruf: tests/orte-test.sh – braucht php, sqlite3 und curl; alles in einem Wegwerfordner, ohne Netz.
set -u
ROOT=$(cd "$(dirname "$0")/.." && pwd)
T=$(mktemp -d); PORT=8099; FAIL=0
trap 'kill $SRV 2>/dev/null; rm -rf "$T"' EXIT
cat > "$T/config.php" <<PHP
<?php return ['DATA_DIR' => '$T/daten', 'APP_URL' => 'https://thisdog.app', 'ADMIN_EMAILS' => ['betrieb@example.org']];
PHP
mkdir -p "$T/daten"
export STELLA_CONFIG="$T/config.php"

ok()   { echo "  ✔ $1"; }
nein() { echo "  ✘ $1"; FAIL=1; }
check(){ if [ "$2" = "$3" ]; then ok "$1"; else nein "$1 (erwartet „$3“, war „$2“)"; fi; }

# Ein Mini-Auszug wie von server/orte-import.py: zwei Orte in Wien, einer weit weg.
sqlite3 "$T/daten/places.sqlite" <<'SQL'
CREATE TABLE places (id TEXT PRIMARY KEY, name TEXT NOT NULL, kind TEXT NOT NULL, lat REAL NOT NULL, lon REAL NOT NULL, off_leash INTEGER NOT NULL, fenced INTEGER NOT NULL);
CREATE TABLE regions (name TEXT PRIMARY KEY, min_lat REAL, max_lat REAL, min_lon REAL, max_lon REAL, data_at TEXT, imported_at INTEGER);
INSERT INTO places VALUES ('way/1', 'Augarten', 'park', 48.2253, 16.3762, 0, 0), ('node/2', 'Hundezone', 'dog_park', 48.2194, 16.3942, 1, 1),
                          ('way/3', 'Wienerwald', 'forest', 48.25, 16.20, 0, 0);
INSERT INTO regions VALUES ('europe/austria', 46.37, 49.02, 9.53, 17.16, '2026-10-17', 0);
CREATE TABLE place_facts (place_id TEXT NOT NULL, key TEXT NOT NULL, value INTEGER NOT NULL, source TEXT NOT NULL, PRIMARY KEY (place_id, key));
INSERT INTO place_facts VALUES ('node/2', 'fenced', 2, 'wien'), ('node/2', 'water_bowl', 1, 'wien'), ('node/2', 'bench', 1, 'osm');
SQL
php -r '
  require "'"$ROOT"'/public/api/lib-pack.php";
  $pdo = db();
  foreach (["betrieb@example.org" => "sitzung-betrieb-0123456789", "anna@example.org" => "sitzung-anna-0123456789", "ben@example.org" => "sitzung-ben-0123456789"] as $mail => $s) {
    $pdo->prepare("INSERT INTO accounts (email, created_at) VALUES (?, ?)")->execute([$mail, time()]);
    $pdo->prepare("INSERT INTO sessions (token_hash, account_id, created_at, expires_at, last_seen_at) VALUES (?, ?, ?, ?, ?)")
        ->execute([secret_hash($s), (int) $pdo->lastInsertId(), time(), time() + 3600, time()]);
  }'
TMPDIR="$T" php -S 127.0.0.1:$PORT -t "$ROOT/public" > "$T/server.log" 2>&1 & SRV=$!
sleep 1
U="http://127.0.0.1:$PORT"; ADM="Cookie: stella_session=sitzung-betrieb-0123456789"; ANNA="Cookie: stella_session=sitzung-anna-0123456789"
namen() { curl -s "$U/api/places.php?lat=48.22&lon=16.39" | php -r '$d = json_decode(stream_get_contents(STDIN), true); $n = array_column($d["places"] ?? [], "name"); sort($n); echo ($d["source"] ?? "-") . ": " . implode(", ", $n);'; }
post() { curl -s -o /dev/null -w "%{http_code}" -H "$1" -H "Origin: $U" -H "Content-Type: application/json" -d "$3" "$U/admin-orte.php?action=$2"; }

echo "Auszug"
check "Orte im Umkreis aus dem Auszug, der ferne Wald nicht" "$(namen)" "auszug: Augarten, Hundezone"

check "Merkmale mit Quelle" "$(curl -s "$U/api/places.php?lat=48.22&lon=16.39" | php -r '$d = json_decode(stream_get_contents(STDIN), true); foreach ($d["places"] as $p) if ($p["id"] === "node/2") { ksort($p["facts"]); echo json_encode($p["facts"]); }')" '{"bench":{"v":1,"src":"osm"},"fenced":{"v":2,"src":"wien"},"water_bowl":{"v":1,"src":"wien"}}'

echo "Eigene Orte"
check "Ohne Betreiber-Adresse: nicht gefunden" "$(curl -s -o /dev/null -w "%{http_code}" -H "$ANNA" "$U/admin-orte.php")" "404"
check "Ändern nur von der eigenen Seite aus" "$(curl -s -o /dev/null -w "%{http_code}" -H "$ADM" -H "Content-Type: application/json" -d '{"name":"x","kind":"park","lat":48.22,"lon":16.39}' "$U/admin-orte.php?action=add")" "403"
check "Eigenen Ort anlegen" "$(post "$ADM" add '{"name":"Hundewiese am Kanal","kind":"dog_park","lat":48.2215,"lon":16.3912,"offLeash":true}')" "200"
check "Unbekannte Art wird abgelehnt" "$(post "$ADM" add '{"name":"x","kind":"strand","lat":48.22,"lon":16.39}')" "422"
check "Der eigene Ort steht in der App" "$(namen)" "auszug: Augarten, Hundewiese am Kanal, Hundezone"
check "Ort aus dem Auszug ausblenden" "$(post "$ADM" hide '{"id":"way/1","lat":48.2253,"lon":16.3762}')" "200"
check "Ausgeblendet fehlt er in der App" "$(namen)" "auszug: Hundewiese am Kanal, Hundezone"

echo "Monatlicher Import"
php -r '$p = new PDO("sqlite:'"$T"'/daten/places.sqlite"); $p->exec("DELETE FROM places WHERE id = \"node/2\"");'
check "Ein neuer Auszug ändert die eigenen Orte nicht" "$(namen)" "auszug: Hundewiese am Kanal"

echo "Bewerten"
BEN="Cookie: stella_session=sitzung-ben-0123456789"
place() { curl -s -H "${3:-X-Nichts: 1}" -H "Content-Type: application/json" ${2:+-d "$2"} "$U/api/place.php?$1"; }
zahl() { php -r '$d = json_decode(stream_get_contents(STDIN), true); echo '"${1%)}"', JSON_UNESCAPED_UNICODE);'; }
check "Ohne Anmeldung kein Bewerten" "$(curl -s -o /dev/null -w "%{http_code}" -H "Content-Type: application/json" -d '{"id":"node/2","votes":{"water":1}}' "$U/api/place.php?action=vote")" "401"
place "action=vote" '{"id":"node/2","votes":{"water":1,"bench":1,"unsinn":1},"sizes":{"small":true}}' "$ANNA" > /dev/null
place "action=vote" '{"id":"node/2","votes":{"water":0,"bench":1},"sizes":{"small":true,"medium":true}}' "$BEN" > /dev/null
check "Zwei Stimmen gezählt, Unbekanntes ignoriert" "$(place "id=node/2" | zahl 'json_encode([$d["votes"]["water"], $d["votes"]["bench"], $d["voters"], $d["sizes"], isset($d["votes"]["unsinn"])])')" '[[1,1],[2,0],2,[2,1,0],false]'
place "action=vote" '{"id":"node/2","votes":{"water":0,"bench":null}}' "$ANNA" > /dev/null
check "Geänderte Stimme zählt einmal, gelöschte fällt weg" "$(place "id=node/2" "" "$ANNA" | zahl 'json_encode([$d["votes"]["water"], $d["votes"]["bench"], $d["mine"]["votes"]])')" '[[0,2],[1,0],{"water":0}]'
place "action=vote" '{"id":"eigen/1","votes":{"water":0}}' "$ANNA" > /dev/null
check "Die Liste trägt die Zählungen" "$(curl -s "$U/api/places.php?lat=48.22&lon=16.39" | zahl 'json_encode(array_values(array_filter(array_map(fn($p) => $p["id"] === "eigen/1" ? [$p["voters"], $p["votes"]["water"]] : null, $d["places"]))))')" '[[1,[0,1]]]'
ADD=$(place "action=add" '{"name":"Wiese am Schützenhaus","kind":"meadow","lat":48.2230,"lon":16.3870,"votes":{"shade":1,"grass":1}}' "$BEN")
check "Ort eintragen, Angekreuztes ist die erste Stimme" "$(echo "$ADD" | zahl 'json_encode([$d["place"]["name"], $d["place"]["byUser"], $d["place"]["votes"]["shade"]])')" '["Wiese am Schützenhaus",true,[1,0]]'
check "Der neue Ort ist sofort sichtbar" "$(namen | grep -c "Wiese am Schützenhaus")" "1"
check "Ein Name über 60 Zeichen wird abgelehnt" "$(curl -s -o /dev/null -w "%{http_code}" -H "$BEN" -H "Content-Type: application/json" -d "{\"name\":\"$(printf 'x%.0s' {1..61})\",\"kind\":\"park\",\"lat\":48.22,\"lon\":16.39}" "$U/api/place.php?action=add")" "422"
check "Melden" "$(place "action=report" '{"id":"node/2","reason":"hunde_verboten"}' "$BEN" | zahl 'json_encode($d)')" '{"ok":true}'
curl -s -H "$BEN" -H "Content-Type: application/json" -d '{}' "$U/api/auth.php?action=delete" > /dev/null
check "Mit dem Konto verschwinden seine Stimmen" "$(place "id=node/2" | zahl 'json_encode([$d["votes"]["water"], $d["voters"], $d["sizes"]])')" '[[0,1],1,[1,0,0]]'

echo "Fotos"
php -r '$i = imagecreatetruecolor(800, 600); imagefill($i, 0, 0, imagecolorallocate($i, 120, 160, 90)); imagejpeg($i, "'"$T"'/foto.jpg");'
up() { curl -s -H "$1" -F "id=$2" -F "foto=@$T/foto.jpg" ${3:+-F "check=$3"} "$U/api/place.php?action=photo"; }
PID=$(up "$ANNA" node/2 | php -r '$d = json_decode(stream_get_contents(STDIN), true); echo $d["photo"]["id"] ?? "fehlt";')
check "Jeder darf ein Foto hochladen" "$([ "$PID" != fehlt ] && echo ja)" "ja"
check "Sofort für alle sichtbar und am Ort" "$(curl -s -o /dev/null -w "%{http_code}" "$U/api/photo.php?id=$PID") $(curl -s "$U/api/place.php?id=node/2" | php -r '$d = json_decode(stream_get_contents(STDIN), true); echo count($d["photos"]);')" "200 1"
check "Kein Bild, kein Foto" "$(curl -s -o /dev/null -w "%{http_code}" -H "$ANNA" -F "id=node/2" -F "foto=@$ROOT/tests/orte-test.sh" "$U/api/place.php?action=photo")" "422"
check "Gespeichert ohne Metadaten als WebP" "$(file -b "$T/daten/fotos/"*.webp | grep -c 'Web/P')" "1"
REP="{\"photo\":$PID,\"reason\":\"person\"}"
check "Melden" "$(curl -s -H "$ADM" -H "Content-Type: application/json" -d "$REP" "$U/api/place.php?action=report_photo")" '{"ok":true}'
check "Gemeldet ist es verborgen, außer für den, der es hochgeladen hat" "$(curl -s -o /dev/null -w "%{http_code}" "$U/api/photo.php?id=$PID") $(curl -s -o /dev/null -w "%{http_code}" -H "$ANNA" "$U/api/photo.php?id=$PID")" "404 200"
check "Admin sieht es unter Gemeldete Fotos" "$(curl -s -H "$ADM" "$U/admin-orte.php" | grep -c 'Person erkennbar')" "1"
check "Behalten" "$(post "$ADM" photo_ok "{\"id\":$PID}")" "200"
check "Danach wieder sichtbar" "$(curl -s -o /dev/null -w "%{http_code}" "$U/api/photo.php?id=$PID")" "200"

echo "Gerätekonten (ohne E-Mail)"
GA="$T/geraet-a.txt"; GB="$T/geraet-b.txt"
curl -s -c "$GA" -H "Content-Type: application/json" -d '{}' "$U/api/auth.php?action=start" > /dev/null
curl -s -c "$GB" -H "Content-Type: application/json" -d '{}' "$U/api/auth.php?action=start" > /dev/null
gup() { curl -s -b "$1" -F "id=$2" -F "foto=@$T/foto.jpg" "$U/api/place.php?action=photo"; }
GPID=$(gup "$GA" eigen/1 | php -r '$d = json_decode(stream_get_contents(STDIN), true); echo ($d["photo"]["id"] ?? "fehlt") . " " . ($d["photo"]["status"] ?? "");')
check "Foto eines Gerätekontos wartet auf Freigabe" "${GPID#* }" "pending"
GPID=${GPID%% *}
check "…für andere unsichtbar, für sich selbst schon da" "$(curl -s -o /dev/null -w "%{http_code}" "$U/api/photo.php?id=$GPID") $(curl -s "$U/api/place.php?id=eigen/1" | php -r '$d = json_decode(stream_get_contents(STDIN), true); echo count($d["photos"]);') $(curl -s -b "$GA" "$U/api/place.php?id=eigen/1" | php -r '$d = json_decode(stream_get_contents(STDIN), true); echo count($d["photos"]);')" "404 0 1"
check "Admin sieht es zur Freigabe" "$(curl -s -H "$ADM" "$U/admin-orte.php" | grep -c 'wartet auf Freigabe')" "1"
check "Freigeben" "$(post "$ADM" photo_ok "{\"id\":$GPID}")" "200"
check "…dann für alle da" "$(curl -s -o /dev/null -w "%{http_code}" "$U/api/photo.php?id=$GPID")" "200"
GREP="{\"photo\":$PID,\"reason\":\"unpassend\"}"
check "Eine Meldung von einem Gerätekonto verbirgt noch nicht" "$(curl -s -b "$GA" -H "Content-Type: application/json" -d "$GREP" "$U/api/place.php?action=report_photo" > /dev/null; curl -s -b "$GA" -H "Content-Type: application/json" -d "$GREP" "$U/api/place.php?action=report_photo" > /dev/null; curl -s -o /dev/null -w "%{http_code}" "$U/api/photo.php?id=$PID")" "200"
check "…eine zweite von einem anderen schon" "$(curl -s -b "$GB" -H "Content-Type: application/json" -d "$GREP" "$U/api/place.php?action=report_photo" > /dev/null; curl -s -o /dev/null -w "%{http_code}" "$U/api/photo.php?id=$PID")" "404"
post "$ADM" photo_ok "{\"id\":$PID}" > /dev/null
curl -s -b "$GA" -H "Content-Type: application/json" -d '{"name":"Geheimwiese","kind":"meadow","lat":48.2232,"lon":16.3872}' "$U/api/place.php?action=add" > /dev/null
check "Ort eines Gerätekontos sieht zuerst nur es selbst" "$(namen | grep -c Geheimwiese) $(curl -s -b "$GA" "$U/api/places.php?lat=48.22&lon=16.39" | grep -c Geheimwiese)" "0 1"
check "Admin: noch unsichtbar" "$(curl -s -H "$ADM" "$U/admin-orte.php" | grep -c 'Geheimwiese <span class="ort">· noch unsichtbar')" "1"
GID=$(php -r '$p = new PDO("sqlite:'"$T"'/daten/app.sqlite"); echo $p->query("SELECT id FROM own_places WHERE name = \"Geheimwiese\"")->fetchColumn();')
post "$ADM" reviewed "{\"id\":$GID}" > /dev/null
check "Nach dem Ansehen für alle" "$(namen | grep -c Geheimwiese)" "1"

echo "Prüfen"
php -r '$p = new PDO("sqlite:'"$T"'/daten/places.sqlite"); $p->exec("INSERT OR REPLACE INTO places VALUES (\"node/2\", \"Hundezone\", \"dog_park\", 48.2194, 16.3942, 1, 1)"); $p->exec("INSERT OR REPLACE INTO place_facts VALUES (\"node/2\", \"water\", 1, \"wien\")");'
CHK='{"id":"node/2","answers":{"off_leash":1,"fenced":1,"water":0,"clean":1,"grass":1,"shade":0,"bench":1},"lat":48.2195,"lon":16.3943}'
check "Nur Erkunder dürfen prüfen" "$(curl -s -o /dev/null -w "%{http_code}" -H "$ANNA" -H "Content-Type: application/json" -d "$CHK" "$U/api/place.php?action=check")" "403"
check "Erkunder eintragen" "$(post "$ADM" scout_add '{"email":"anna@example.org"}')" "200"
check "Unvollständig wird abgelehnt" "$(curl -s -H "$ANNA" -H "Content-Type: application/json" -d '{"id":"node/2","answers":{"water":1},"lat":48.2195,"lon":16.3943}' "$U/api/place.php?action=check" | php -r '$d = json_decode(stream_get_contents(STDIN), true); echo $d["error"];')" "incomplete"
check "Zu weit weg wird abgelehnt" "$(curl -s -H "$ANNA" -H "Content-Type: application/json" -d "${CHK/48.2195/48.23}" "$U/api/place.php?action=check" | php -r '$d = json_decode(stream_get_contents(STDIN), true); echo $d["error"];')" "too_far"
CID=$(curl -s -H "$ANNA" -H "Content-Type: application/json" -d "$CHK" "$U/api/place.php?action=check" | php -r '$d = json_decode(stream_get_contents(STDIN), true); echo $d["check"]["id"];')
up "$ANNA" node/2 "$CID" > /dev/null
check "Admin sieht die Abweichung zur Stadt Wien" "$(curl -s -H "$ADM" "$U/admin-orte.php" | grep -c 'Trinkwasser: nein (bisher ja, Stadt Wien)')" "0"
check "Geprüft gilt sofort vor der Stadt Wien" "$(curl -s "$U/api/places.php?lat=48.22&lon=16.39" | php -r '$d = json_decode(stream_get_contents(STDIN), true); foreach ($d["places"] as $p) if ($p["id"] === "node/2") echo json_encode([$p["facts"]["water"], isset($p["checkedAt"]), count($p["photos"])]);')" '[{"v":0,"src":"thisdog"},true,2]'
check "Zurückziehen" "$(post "$ADM" check_no "{\"id\":$CID}")" "200"
check "Danach gilt wieder die Stadt Wien, die Fotos der Prüfung sind weg" "$(curl -s "$U/api/places.php?lat=48.22&lon=16.39" | php -r '$d = json_decode(stream_get_contents(STDIN), true); foreach ($d["places"] as $p) if ($p["id"] === "node/2") echo json_encode([$p["facts"]["water"], count($p["photos"] ?? [])]);')" '[{"v":1,"src":"wien"},1]'
CHK2=$(curl -s -H "$ANNA" -H "Content-Type: application/json" -d "$CHK" "$U/api/place.php?action=check" | php -r '$d = json_decode(stream_get_contents(STDIN), true); echo $d["check"]["id"];')
check "Meine Prüfungen" "$(curl -s -H "$ANNA" "$U/api/place.php?action=mine" | php -r '$d = json_decode(stream_get_contents(STDIN), true); echo json_encode([$d["scout"], count(array_filter($d["checks"], fn($c) => $c["status"] === "ok")), count($d["checks"])]);')" '[true,1,2]'

echo "Admin"
check "Gemeldeter Ort steht auf der Admin-Seite" "$(curl -s -H "$ADM" "$U/admin-orte.php" | grep -c 'data-id="node/2"')" "1"
check "Neuer Ort von Nutzern steht dort" "$(curl -s -H "$ADM" "$U/admin-orte.php" | grep -c 'Wiese am Schützenhaus')" "1"
check "Meldung erledigen" "$(post "$ADM" resolve '{"id":"node/2"}')" "200"
check "Danach nicht mehr gemeldet" "$(curl -s -H "$ADM" "$U/admin-orte.php" | grep -c 'data-id="node/2"')" "0"
NID=$(php -r '$p = new PDO("sqlite:'"$T"'/daten/app.sqlite"); echo $p->query("SELECT id FROM own_places WHERE by_user = 1")->fetchColumn();')
check "Durchgesehen" "$(post "$ADM" reviewed "{\"id\":$NID}")" "200"
check "Danach nicht mehr unter Neu" "$(curl -s -H "$ADM" "$U/admin-orte.php" | sed -n '/neu-von-nutzern/,/Eigene Einträge/p' | grep -c 'Wiese am Schützenhaus')" "0"

[ $FAIL = 0 ] && echo "Alles bestanden." || { echo "FEHLGESCHLAGEN"; exit 1; }
