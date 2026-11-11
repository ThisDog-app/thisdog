#!/bin/bash
# Prüft Ende-zu-Ende-Verschlüsselung und Hundefreunde auf einem lokalen PHP-Server.
# Aufruf: tests/schutz-test.sh – braucht php und curl; alles in einem Wegwerfordner.
set -u
ROOT=$(cd "$(dirname "$0")/.." && pwd)
T=$(mktemp -d); PORT=8098; FAIL=0
trap 'kill $SRV 2>/dev/null; rm -rf "$T"' EXIT
cat > "$T/config.php" <<PHP
<?php return ['DATA_DIR' => '$T/daten', 'APP_URL' => 'https://thisdog.app'];
PHP
mkdir -p "$T/daten"
export STELLA_CONFIG="$T/config.php"

ok()   { echo "  ✔ $1"; }
nein() { echo "  ✘ $1"; FAIL=1; }
check(){ if [ "$2" = "$3" ]; then ok "$1"; else nein "$1 (erwartet „$3“, war „$2“)"; fi; }

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
api() { curl -s -H "$1" -H "Content-Type: application/json" ${3:+-d "$3"} "http://127.0.0.1:$PORT/api/$2"; }
j() { php -r '$d = json_decode(stream_get_contents(STDIN), true); echo '"$1"';'; }
# Zählt Zeilen: db <Tabelle> <Bedingung als SQL, Werte als weitere Argumente>
db() { php -r 'require $argv[1]; $pdo = db(); $s = $pdo->prepare("SELECT COUNT(*) FROM " . $argv[2] . " WHERE " . $argv[3]); $s->execute(array_slice($argv, 4)); echo $s->fetchColumn();' "$ROOT/public/api/lib-pack.php" "$@"; }
E1="QUJDREVGR0hJSktMTU5PUFFSU1RVVldYWVo="   # steht für einen Geheimtext; der Server kann ihn nicht lesen

echo "1. Ein Rudel zieht auf Verschlüsselung um"
PACK_A=$(api "$A" "pack.php?action=list" | j '$d["packs"][0]["id"]')
api "$A" "sync.php?action=push&pack=$PACK_A" '{"records":[{"kind":"event","id":"evt_alt","updatedAt":1000,"payload":{"title":"Klartext"}},{"kind":"weight","id":"w_alt","updatedAt":1000,"payload":{"kg":21}}]}' > /dev/null
check "vorher: nicht verschlüsselt" "$(api "$A" "pack.php?action=list" | j 'json_encode($d["packs"][0]["sealed"])')" "false"
check "Das erste Gerät darf den Schlüssel anlegen" "$(api "$A" "pack.php?action=seal" "{\"pack\":$PACK_A}" | j 'json_encode($d["granted"])')" "true"
check "Solange nichts Verschlüsseltes liegt, darf es neu anlegen (Absturz nach dem Fragen)" "$(api "$A" "pack.php?action=seal" "{\"pack\":$PACK_A}" | j 'json_encode($d["granted"])')" "true"
check "Klartext wird abgelehnt" "$(api "$A" "sync.php?action=push&pack=$PACK_A" '{"records":[{"kind":"event","id":"evt_neu","updatedAt":2000,"payload":{"title":"Geheim"}}]}' | j '$d["stored"]')" "0"
R=$(api "$A" "sync.php?action=push&pack=$PACK_A" "{\"records\":[{\"kind\":\"event\",\"id\":\"evt_alt\",\"updatedAt\":3000,\"payload\":{\"e\":\"$E1\"}}]}")
check "Verschlüsseltes wird angenommen" "$(echo "$R" | j '$d["stored"]')" "1"
check "Übrig gebliebener Klartext ist vom Server verschwunden" "$(db pack_records 'payload NOT LIKE ?' '{"e":%')" "0"
check "Die Revision zählt weiter (ein zweites Gerät verpasst nichts)" "$(db pack_records 'rev <= 2')" "0"
check "In der Datenbank steht der Titel nirgends" "$(db pack_records 'payload LIKE ? OR payload LIKE ?' '%Klartext%' '%Geheim%')" "0"
check "Jetzt: verschlüsselt" "$(api "$A" "pack.php?action=list" | j 'json_encode($d["packs"][0]["sealed"])')" "true"
check "Ein zweites Gerät darf keinen eigenen Schlüssel mehr anlegen" "$(api "$A" "pack.php?action=seal" "{\"pack\":$PACK_A}" | j 'json_encode($d["granted"])')" "false"
check "Der Geheimtext kommt unverändert zurück" "$(api "$A" "sync.php?action=pull&since=0&pack=$PACK_A" | j '$d["records"][0]["payload"]["e"]')" "$E1"
check "Getarnter Klartext neben „e“ wird abgelehnt" "$(api "$A" "sync.php?action=push&pack=$PACK_A" "{\"records\":[{\"kind\":\"event\",\"id\":\"evt_x\",\"updatedAt\":4000,\"payload\":{\"e\":\"$E1\",\"title\":\"Geheim\"}}]}" | j '$d["stored"]')" "0"
check "Löschen (Grabstein) geht weiter" "$(api "$A" "sync.php?action=push&pack=$PACK_A" '{"records":[{"kind":"event","id":"evt_alt","updatedAt":5000,"payload":null}]}' | j '$d["stored"]')" "1"

echo "2. Hundefreunde"
PACK_C=$(api "$C" "pack.php?action=list" | j '$d["packs"][0]["id"]')
INV=$(api "$A" "friends.php?action=invite" "{\"pack\":$PACK_A}")
URL=$(echo "$INV" | j '$d["url"]'); ID=$(echo "$INV" | j '$d["invite"]'); SECRET=${URL##*/freund/}
case "$URL" in https://thisdog.app/freund/*) ok "Einladungslink $URL";; *) nein "Einladungslink: $URL";; esac
check "Die eigene Einladung annehmen geht nicht" "$(api "$A" "friends.php?action=accept" "{\"pack\":$PACK_A,\"invite\":\"$SECRET\"}" | j '$d["error"]')" "own_pack"
check "Cleo nimmt an, beide kennen dieselbe Einladungskennung" "$(api "$C" "friends.php?action=accept" "{\"invite\":\"$SECRET\"}" | j '$d["friend"] . " " . $d["invite"]')" "$PACK_A $ID"
check "Die Einladung gilt nur einmal" "$(api "$B" "friends.php?action=accept" "{\"invite\":\"$SECRET\"}" | j '$d["error"]')" "invite_used"
check "Anna sieht Cleo als Freundin" "$(api "$A" "friends.php?action=list&pack=$PACK_A" | j '$d["friends"][0]["pack"] . " " . $d["friends"][0]["invite"]')" "$PACK_C $ID"
api "$C" "friends.php?action=cards" "{\"blobs\":[{\"friend\":$PACK_A,\"blob\":\"$E1\"}]}" > /dev/null
check "Cleos verschlüsselter Steckbrief kommt bei Anna an" "$(api "$A" "friends.php?action=list&pack=$PACK_A" | j '$d["friends"][0]["card"]')" "$E1"
PACK_B=$(api "$B" "pack.php?action=list" | j '$d["packs"][0]["id"]')
api "$C" "friends.php?action=position" "{\"started\":111,\"blobs\":[{\"friend\":$PACK_A,\"blob\":\"$E1\"},{\"friend\":$PACK_B,\"blob\":\"$E1\"}]}" > /dev/null
check "Unterwegs: Anna sieht Cleos Standort (verschlüsselt)" "$(api "$A" "friends.php?action=live&pack=$PACK_A" | j 'count($d["live"]) . " " . $d["live"][0]["blob"]')" "1 $E1"
check "Ben ist kein Freund und bekommt nichts" "$(api "$B" "friends.php?action=live" | j 'count($d["live"])')" "0"
check "Für Ben wurde auch nichts abgelegt" "$(db friend_blobs 'to_pack = ?' "$PACK_B")" "0"
check "Die Runde wird für Anna einmal angekündigt" "$(db nearby_notices '1')" "1"
api "$C" "friends.php?action=position" "{\"started\":111,\"blobs\":[{\"friend\":$PACK_A,\"blob\":\"$E1\"}]}" > /dev/null
check "…und nicht bei jedem Punkt wieder" "$(db nearby_notices '1')" "1"
api "$C" "friends.php?action=stop" "{}" > /dev/null
check "Nach dem Beenden ist der Standort weg" "$(api "$A" "friends.php?action=live&pack=$PACK_A" | j 'count($d["live"])')" "0"
check "…auch in der Datenbank" "$(db friend_blobs 'kind = ?' pos)" "0"
api "$A" "friends.php?action=remove" "{\"pack\":$PACK_A,\"friend\":$PACK_C}" > /dev/null
check "Freundschaft beendet: keine Freunde mehr" "$(api "$C" "friends.php?action=list" | j 'count($d["friends"])')" "0"
check "…und keine Steckbriefe mehr" "$(db friend_blobs '1')" "0"
check "Ohne Anmeldung kein Zugriff" "$(curl -s "http://127.0.0.1:$PORT/api/friends.php?action=list" | j '$d["error"]')" "not_signed_in"
check "Einladungsseite antwortet" "$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:$PORT/freund.php")" "200"
check "Universal Links kennen /freund/" "$(php -r 'echo json_encode(json_decode(file_get_contents("'"$ROOT"'/public/.well-known/apple-app-site-association"), true)["applinks"]["details"][0]["components"][2]["/"]);')" '"\/freund\/*"'

echo "3. Konto löschen"
INV2=$(api "$A" "friends.php?action=invite" "{\"pack\":$PACK_A}" | j '$d["url"]'); api "$C" "friends.php?action=accept" "{\"invite\":\"${INV2##*/freund/}\"}" > /dev/null
api "$C" "sync.php?action=push&pack=$PACK_C" "{\"records\":[{\"kind\":\"event\",\"id\":\"evt_c\",\"updatedAt\":1000,\"payload\":{\"e\":\"$E1\"}}]}" > /dev/null
api "$C" "auth.php?action=delete" "{}" > /dev/null
check "Cleos Rudel ist mit ihr verschwunden" "$(db packs 'id = ?' "$PACK_C")" "0"
check "…mit seinen Datensätzen" "$(db pack_records 'pack_id = ?' "$PACK_C")" "0"
check "…und der Freundschaft" "$(db friendships 'pack_a = ? OR pack_b = ?' "$PACK_C" "$PACK_C")" "0"
check "Annas Rudel bleibt" "$(db packs 'id = ?' "$PACK_A")" "1"
check "Datenschutz ist erreichbar" "$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:$PORT/rechtliches/datenschutz.html")" "200"

[ $FAIL = 0 ] && echo "ALLES GRÜN" || { echo "FEHLGESCHLAGEN"; cat "$T/server.log" | grep -i "error\|warn" | head; }
exit $FAIL
