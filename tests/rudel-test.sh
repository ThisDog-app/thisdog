#!/bin/bash
# Prüft das Rudel auf einem lokalen PHP-Server: Umzug alter Daten, Trennung der Konten,
# Einladen, Beitreten, Abgleich in beide Richtungen, Grenzen. Aufruf: tests/rudel-test.sh
# Braucht php und curl; legt alles in einem Wegwerfordner an.
set -u
ROOT=$(cd "$(dirname "$0")/.." && pwd)
T=$(mktemp -d); PORT=8097; FAIL=0
trap 'kill $SRV 2>/dev/null; rm -rf "$T"' EXIT
cat > "$T/config.php" <<PHP
<?php return ['DATA_DIR' => '$T/daten', 'APP_URL' => 'https://thisdog.app'];
PHP
mkdir -p "$T/daten" "$T/alt"
export STELLA_CONFIG="$T/config.php"

ok()   { echo "  ✔ $1"; }
nein() { echo "  ✘ $1"; FAIL=1; }
check(){ if [ "$2" = "$3" ]; then ok "$1"; else nein "$1 (erwartet „$3“, war „$2“)"; fi; }

echo "1. Umzug einer Datenbank im Stand vor dem Rudel"
# Stand vor dem Rudel (vor Commit 0e1e7f7), als Datei abgelegt: Das öffentliche Repository hat keine ältere Geschichte.
cp "$ROOT/tests/vorlagen/lib-db-vor-rudel.php" "$T/alt/lib-db.php"
cp "$ROOT/public/api/lib.php" "$T/alt/lib.php"
cat > "$T/alt/anlegen.php" <<'PHP'
<?php
require __DIR__ . '/lib-db.php';
$pdo = db();
$pdo->exec("INSERT INTO accounts (email, created_at) VALUES ('alt@example.org', 1700000000)");
$pdo->prepare('INSERT INTO records (account_id, kind, record_id, payload, updated_at, rev) VALUES (1, ?, ?, ?, 1, 1)')
    ->execute(['event', 'evt_alt', json_encode(['title' => 'Alter Termin'])]);
echo (int) $pdo->query('PRAGMA user_version')->fetchColumn();
PHP
php "$T/alt/anlegen.php" > "$T/v"
check "alte Datenbank steht auf Version 8" "$(cat $T/v)" "8"
php -r '
  require "'"$ROOT"'/public/api/lib-pack.php";
  $pdo = db();
  echo (int) $pdo->query("PRAGMA user_version")->fetchColumn(), " ";
  echo $pdo->query("SELECT COUNT(*) FROM pack_members WHERE account_id = 1")->fetchColumn(), " ";
  echo $pdo->query("SELECT p.record_id FROM pack_records p JOIN pack_members m ON m.pack_id = p.pack_id WHERE m.account_id = 1")->fetchColumn(), " ";
  echo $pdo->query("SELECT COUNT(*) FROM sqlite_master WHERE name = \"records_vor_rudel\"")->fetchColumn();
' > "$T/m"
check "Umzug: aktuelle Version, eigenes Rudel, Termin dort, Klartext-Sicherung entfernt" "$(cat $T/m)" "22 1 evt_alt 0"

# Zwei Konten mit Sitzung, direkt angelegt.
php -r '
  require "'"$ROOT"'/public/api/lib-pack.php";
  $pdo = db();
  foreach (["anna@example.org" => "sitzung-anna-0123456789", "ben@example.org" => "sitzung-ben-0123456789", "cleo@example.org" => "sitzung-cleo-0123456789"] as $mail => $s) {
    $pdo->prepare("INSERT INTO accounts (email, created_at) VALUES (?, ?)")->execute([$mail, time()]);
    $id = (int) $pdo->lastInsertId();
    $pdo->prepare("INSERT INTO sessions (token_hash, account_id, created_at, expires_at, last_seen_at) VALUES (?, ?, ?, ?, ?)")
        ->execute([secret_hash($s), $id, time(), time() + 3600, time()]);
  }'

TMPDIR="$T" php -S 127.0.0.1:$PORT -t "$ROOT/public" > "$T/server.log" 2>&1 & SRV=$!
sleep 1
A="Cookie: stella_session=sitzung-anna-0123456789"; B="Cookie: stella_session=sitzung-ben-0123456789"; C="Cookie: stella_session=sitzung-cleo-0123456789"
api() { if [ -n "${3:-}" ]; then curl -sg -H "$1" -H "Content-Type: application/json" -d "$3" "http://127.0.0.1:$PORT/api/$2"; else curl -sg -H "$1" "http://127.0.0.1:$PORT/api/$2"; fi; }
j() { php -r '$d = json_decode(stream_get_contents(STDIN), true); echo '"$1"';'; }

echo "2. Jedes Konto hat sein eigenes Rudel"
api "$A" "sync.php?action=push" '{"records":[{"kind":"event","id":"evt_1","updatedAt":1000,"payload":{"title":"Tierarzt"}}]}' > /dev/null
check "Ben sieht Annas Termin nicht" "$(api "$B" 'sync.php?action=pull&since=0' | j 'count($d["records"])')" "0"
PACK_A=$(api "$A" "pack.php?action=list" | j '$d["packs"][0]["id"]')
check "Ben darf Annas Rudel nicht lesen" "$(api "$B" "sync.php?action=pull&since=0&pack=$PACK_A" | j '$d["error"] ?? "kein Fehler"')" "not_a_member"

echo "3. Einladen und Beitreten"
URL=$(api "$A" "pack.php?action=invite" "{\"pack\":$PACK_A}" | j '$d["url"]')
SECRET=${URL##*/rudel/}
case "$URL" in https://thisdog.app/rudel/*) ok "Einladungslink $URL";; *) nein "Einladungslink: $URL";; esac
check "Einladungsseite antwortet" "$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:$PORT/rudel.php?t=$SECRET")" "200"
check "Ben tritt bei" "$(api "$B" "pack.php?action=join" "{\"invite\":\"$SECRET\"}" | j '$d["pack"]')" "$PACK_A"
check "Ben ein zweites Mal: schon Mitglied" "$(api "$B" "pack.php?action=join" "{\"invite\":\"$SECRET\"}" | j 'json_encode($d["already"] ?? null)')" "true"
check "Derselbe Link reicht für mehrere: Cleo kommt auch hinein" "$(api "$C" "pack.php?action=join" "{\"invite\":\"$SECRET\"}" | j '$d["pack"] ?? $d["error"]')" "$PACK_A"
api "$A" "pack.php?action=name" "{\"pack\":$PACK_A,\"name\":\"Anna\"}" > /dev/null
check "Im Rudel: drei Mitglieder, Anna mit Namen" "$(api "$B" "pack.php?action=list" | j 'implode(",", array_column(array_values(array_filter($d["packs"], fn($p) => $p["id"] == '"$PACK_A"'))[0]["members"], "name"))')" "Anna,ben,cleo"
check "Ben sieht jetzt Annas Termin" "$(api "$B" "sync.php?action=pull&since=0&pack=$PACK_A" | j '$d["records"][0]["payload"]["title"]')" "Tierarzt"
ANNA_ID=$(api "$A" "pack.php?action=list" | j '$d["me"]')
check "…und weiß, dass Anna ihn eingetragen hat" "$(api "$B" "sync.php?action=pull&since=0&pack=$PACK_A" | j '$d["records"][0]["by"]')" "$ANNA_ID"
api "$B" "sync.php?action=push&pack=$PACK_A" '{"records":[{"kind":"event","id":"evt_1","updatedAt":2000,"payload":{"title":"Tierarzt, 10:30"}}]}' > /dev/null
check "Bens Änderung kommt bei Anna an" "$(api "$A" 'sync.php?action=pull&since=0' | j '$d["records"][0]["payload"]["title"]')" "Tierarzt, 10:30"
api "$A" "sync.php?action=push" '{"records":[{"kind":"event","id":"evt_1","updatedAt":1500,"payload":{"title":"veraltet"}}]}' > /dev/null
check "Eine ältere Fassung überschreibt nicht" "$(api "$B" "sync.php?action=pull&since=0&pack=$PACK_A" | j '$d["records"][0]["payload"]["title"]')" "Tierarzt, 10:30"

LANG=$(php -r 'echo str_repeat("_ibE~", 6000);')
api "$B" "sync.php?action=push&pack=$PACK_A" "{\"records\":[{\"kind\":\"walk\",\"id\":\"walk_1\",\"updatedAt\":3000,\"payload\":{\"meters\":1840,\"path\":\"$LANG\"}}]}" > /dev/null
check "Eine lange Runde kommt im Rudel an" "$(api "$A" 'sync.php?action=pull&since=0' | j 'implode(",", array_map(fn($r) => $r["kind"], $d["records"]))')" "event,walk"

echo "4. Grenzen"
check "Unbekannte Einladung" "$(api "$B" "pack.php?action=join" '{"invite":"gibt-es-nicht-0123456789"}' | j '$d["error"]')" "invite_unknown"
check "Ohne Anmeldung kein Zugriff" "$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:$PORT/api/sync.php?action=pull")" "401"
check "Ben verlässt das Rudel" "$(api "$B" "pack.php?action=leave" "{\"pack\":$PACK_A}" | j 'json_encode($d["packRemoved"])')" "false"
check "Annas Daten bleiben" "$(api "$A" 'sync.php?action=pull&since=0' | j 'count($d["records"])')" "2"
check "Ben kann Annas Rudel nicht mehr lesen" "$(api "$B" "sync.php?action=pull&since=0&pack=$PACK_A" | j '$d["error"] ?? "kein Fehler"')" "not_a_member"
check "Universal-Links-Datei ist gültiges JSON" "$(php -r 'echo json_decode(file_get_contents("'"$ROOT"'/public/.well-known/apple-app-site-association"), true)["applinks"]["details"][0]["appIDs"][0];')" "Z42VKTJ79H.app.thisDog"

echo "5. Ohne E-Mail: Konto für das Gerät, mit einem Tipp ins Rudel"
JAR="$T/geraet.txt"
dev() { curl -s -b "$JAR" -c "$JAR" -H "Content-Type: application/json" ${2:+-d "$2"} "http://127.0.0.1:$PORT/api/$1"; }
check "Konto ohne E-Mail entsteht" "$(dev 'auth.php?action=start' '{}' | j 'json_encode([$d["signedIn"], $d["email"]])')" '[true,null]'
check "angemeldet, ohne Adresse" "$(dev 'auth.php?action=me' | j 'json_encode([$d["signedIn"], $d["email"]])')" '[true,null]'
check "Ein zweiter Start bleibt beim selben Konto" "$(dev 'auth.php?action=start' '{}' | j 'json_encode($d["signedIn"])')" "true"
check "Konten insgesamt (vier mit Adresse, eins ohne)" "$(php -r 'require "'"$ROOT"'/public/api/lib-db.php"; echo db()->query("SELECT COUNT(*) FROM accounts")->fetchColumn(), " ", db()->query("SELECT COUNT(*) FROM accounts WHERE email IS NULL")->fetchColumn();')" "5 1"
check "Mit derselben Einladung ins Rudel" "$(dev 'pack.php?action=join' "{\"invite\":\"$SECRET\"}" | j '$d["pack"] ?? $d["error"]')" "$PACK_A"
check "Name ohne Adresse: Rudelmitglied" "$(dev 'pack.php?action=list' | j 'end(array_values(array_filter($d["packs"], fn($p) => $p["id"] == '"$PACK_A"'))[0]["members"])["name"]')" "Rudelmitglied"
check "Sieht Annas Termin" "$(dev "sync.php?action=pull&since=0&pack=$PACK_A" | j '$d["records"][0]["payload"]["title"] ?? "nichts"')" "Tierarzt, 10:30"
# E-Mail später hinzufügen: ein Code für dieses Konto (wie aus der Mail) hängt die Adresse an.
php -r 'require "'"$ROOT"'/public/api/lib-db.php"; $pdo = db(); $id = (int) $pdo->query("SELECT id FROM accounts WHERE email IS NULL")->fetchColumn();
  $pdo->prepare("INSERT INTO login_tokens (token_hash, account_id, created_at, expires_at, code_hash, email, from_app) VALUES (?, ?, ?, ?, ?, ?, 1)")
      ->execute([secret_hash("t-geraet"), $id, time(), time() + 600, secret_hash("123456"), "dora@example.org"]);'
check "Code bestätigt" "$(dev 'auth.php?action=code' '{"email":"dora@example.org","code":"123456"}' | j 'json_encode($d["signedIn"] ?? $d)')" "true"
check "Adresse hängt jetzt am Gerätekonto, Rudel bleibt" "$(dev 'auth.php?action=me' | j '$d["email"]') $(dev 'pack.php?action=list' | j 'count($d["packs"])')" "dora@example.org 1"
check "Admin-Liste verträgt Konten ohne Adresse" "$(php -l "$ROOT/public/admin.php" > /dev/null && echo ok)" "ok"

echo "5b. Anmeldecode gehört zum Gerät, das ihn angefordert hat"
JV="$T/eva.txt"; JX="$T/fremd.txt"
rq() { curl -s -b "$1" -c "$1" -H "Content-Type: application/json" -d '{"email":"eva@example.org","app":true}' "http://127.0.0.1:$PORT/api/auth.php?action=request"; }
CV=$(rq "$JV" | j '$d["devCode"] ?? "kein Code"')
rq "$JX" > /dev/null
for i in 1 2 3; do curl -s -H "Content-Type: application/json" -d '{"email":"eva@example.org","code":"000000"}' "http://127.0.0.1:$PORT/api/auth.php?action=code" > /dev/null; done
check "Fremde Anforderung und falsche Versuche ohne Cookie stören Evas Code nicht" "$(curl -s -b "$JV" -c "$JV" -H "Content-Type: application/json" -d "{\"email\":\"eva@example.org\",\"code\":\"$CV\"}" "http://127.0.0.1:$PORT/api/auth.php?action=code" | j 'json_encode($d["signedIn"] ?? $d)')" "true"

echo "6. Rollen und Mitteilungen"
SURL=$(api "$A" "pack.php?action=invite" "{\"pack\":$PACK_A,\"role\":\"sitter\"}" | j '$d["url"]')
SSEC=${SURL##*/rudel/}
J2="$T/sitter.txt"
# Mit -g (ohne URL-Globbing) und immer zitiert: Arrays wie ["notfall"] kommen sonst nicht heil an.
sit() { if [ -n "${2:-}" ]; then curl -sg -b "$J2" -c "$J2" -H "Content-Type: application/json" -d "$2" "http://127.0.0.1:$PORT/api/$1"; else curl -sg -b "$J2" -c "$J2" "http://127.0.0.1:$PORT/api/$1"; fi; }
sit 'auth.php?action=start' '{}' > /dev/null
check "Hundesitterin tritt bei" "$(sit 'pack.php?action=join' "{\"invite\":\"$SSEC\"}" | j '$d["pack"] ?? $d["error"]')" "$PACK_A"
SID=$(sit 'pack.php?action=list' | j '$d["me"]')
mem() { api "$A" "pack.php?action=list" | php -r '$d = json_decode(stream_get_contents(STDIN), true); $m = array_values(array_filter(array_values(array_filter($d["packs"], fn($p) => $p["id"] == '"$PACK_A"'))[0]["members"], fn($m) => $m["id"] == '"$1"'))[0]; echo '"$2"';'; }
check "…als Hundesitterin, will von sich aus nichts" "$(mem $SID '$m["role"] . " " . implode(",", $m["notifyWanted"]) . "|" . implode(",", $m["notifyAllowed"])')" "sitter |termine,gesundheit,tagebuch,notfall"
check "Anna (Besitzerin) bekommt alles" "$(mem $ANNA_ID '$m["role"] . " " . implode(",", $m["notifyWanted"])')" "owner termine,gesundheit,tagebuch,notfall"
check "Hundesitter laden nicht ein" "$(sit 'pack.php?action=invite' "{\"pack\":$PACK_A}" | j '$d["error"] ?? "eingeladen"')" "not_owner"
check "…und vergeben keine Rollen" "$(sit 'pack.php?action=role' "{\"pack\":$PACK_A,\"member\":$SID,\"role\":\"owner\"}" | j '$d["error"] ?? "geändert"')" "not_owner"
check "Sitterin wünscht sich Notfälle" "$(sit 'pack.php?action=notify' '{"pack":'"$PACK_A"',"member":'"$SID"',"wanted":["notfall","termine"]}' | j 'json_encode($d["ok"] ?? $d["error"])')" "true"
check "…aber nicht für Anna" "$(sit 'pack.php?action=notify' '{"pack":'"$PACK_A"',"member":'"$ANNA_ID"',"wanted":[]}' | j '$d["error"] ?? "geändert"')" "not_yours"
check "Anna erlaubt ihr nur Notfälle" "$(api "$A" "pack.php?action=notify" '{"pack":'"$PACK_A"',"member":'"$SID"',"allowed":["notfall"]}' | j 'json_encode($d["ok"] ?? $d["error"])')" "true"
check "Wer was sichtbar bekommt: Sitterin nur Notfall" "$(php -r 'require "'"$ROOT"'/public/api/lib-pack.php"; $m = pack_notify_map(db(), '"$PACK_A"'); echo implode(",", $m['"$SID"'] ?? ["fehlt:" . implode("/", array_keys($m))]);')" "notfall"
# Ein weitergereichter Sitter-Link soll nicht reichen, um alles zu löschen: Fremde Einträge höchstens 30 pro Stunde.
MASSE=$(php -r '$r = []; for ($i = 0; $i < 32; $i++) $r[] = ["kind" => "event", "id" => "masse_$i", "updatedAt" => 5000, "payload" => ["title" => "Termin $i"]]; echo json_encode(["records" => $r]);')
api "$A" "sync.php?action=push&pack=$PACK_A" "$MASSE" > /dev/null
GRAB=$(php -r '$r = []; for ($i = 0; $i < 32; $i++) $r[] = ["kind" => "event", "id" => "masse_$i", "updatedAt" => 6000, "payload" => null]; echo json_encode(["records" => $r, "since" => 0]);')
check "Hundesitterin löscht 30 fremde Einträge, nicht mehr" "$(sit "sync.php?action=push&pack=$PACK_A" "$GRAB" | j '$d["stored"] . " " . ($d["refused"] ?? 0) . " " . count(array_filter($d["records"], fn($r) => str_starts_with($r["id"], "masse_") && $r["payload"] !== null && $r["updatedAt"] > 6000))')" "30 2 2"
check "…die übrigen bleiben für alle da" "$(api "$A" "sync.php?action=pull&since=0&pack=$PACK_A" | j 'count(array_filter($d["records"], fn($r) => str_starts_with($r["id"], "masse_") && $r["payload"] !== null))')" "2"
check "Eigene Einträge darf sie weiter ändern" "$(sit "sync.php?action=push&pack=$PACK_A" '{"records":[{"kind":"event","id":"masse_0","updatedAt":7000,"payload":{"title":"neu"}}]}' | j '$d["stored"]')" "1"
check "Die letzte Besitzerin bleibt Besitzerin" "$(api "$A" "pack.php?action=role" "{\"pack\":$PACK_A,\"member\":$ANNA_ID,\"role\":\"sitter\"}" | j '$d["error"] ?? "geändert"')" "last_owner"
check "Anna macht die Sitterin zur Besitzerin" "$(api "$A" "pack.php?action=role" "{\"pack\":$PACK_A,\"member\":$SID,\"role\":\"owner\"}" | j 'json_encode($d["ok"] ?? $d["error"])')" "true"
check "…jetzt darf sie einladen" "$(sit 'pack.php?action=invite' "{\"pack\":$PACK_A,\"role\":\"sitter\"}" | j 'isset($d["url"]) ? "ja" : $d["error"]')" "ja"
check "Mitteilungstexte haben ihre Art" "$(php -r 'require "'"$ROOT"'/public/api/lib-push.php"; echo change_text("A", [["kind"=>"event","deleted"=>false,"new"=>true]])["kind"], " ", change_text("A", [["kind"=>"notes","deleted"=>false,"new"=>true]])["kind"], " ", change_text("A", [["kind"=>"weight","deleted"=>false,"new"=>true]])["kind"];')" "termine tagebuch gesundheit"

grep -i "fatal\|warning" "$T/server.log" | head -3
[ $FAIL -eq 0 ] && echo "Alles bestanden." || { echo "FEHLGESCHLAGEN"; exit 1; }
