#!/bin/bash
# Prüft die Adressen rund um den Hund und die Partnerplätze: Liste und Suche, Buchung, Stripe-Meldungen, Verwaltung,
# Sperre. Stripe spielt ein kleiner PHP-Server, der nur aufschreibt, was ankommt.
# Aufruf: tests/partner-test.sh – braucht php, sqlite3 und curl; alles in einem Wegwerfordner, ohne Netz.
set -u
ROOT=$(cd "$(dirname "$0")/.." && pwd)
T=$(mktemp -d); PORT=8097; SPORT=8096; FAIL=0
trap 'kill $SRV $STR 2>/dev/null; rm -rf "$T"' EXIT
cat > "$T/config.php" <<PHP
<?php return ['DATA_DIR' => '$T/daten', 'APP_URL' => 'https://thisdog.app', 'ADMIN_EMAILS' => ['betrieb@example.org'],
  'STRIPE_SECRET_KEY' => 'sk_test_probe', 'STRIPE_WEBHOOK_SECRET' => 'whsec_probe', 'STRIPE_API_BASE' => 'http://127.0.0.1:$SPORT',
  'SPONSOR_PRICE_CENTS' => 2900];
PHP
mkdir -p "$T/daten" "$T/stripe"
export STELLA_CONFIG="$T/config.php"

ok()   { echo "  ✔ $1"; }
nein() { echo "  ✘ $1"; FAIL=1; }
check(){ if [ "$2" = "$3" ]; then ok "$1"; else nein "$1 (erwartet „$3“, war „$2“)"; fi; }

# Auszug: Wien mit sechs Betrieben, einer davon 20 km weg; Augarten-Gegend und eine Nachbargegend.
sqlite3 "$T/daten/places.sqlite" <<'SQL'
CREATE TABLE places (id TEXT PRIMARY KEY, name TEXT NOT NULL, kind TEXT NOT NULL, lat REAL NOT NULL, lon REAL NOT NULL, off_leash INTEGER NOT NULL, fenced INTEGER NOT NULL);
CREATE TABLE regions (name TEXT PRIMARY KEY, min_lat REAL, max_lat REAL, min_lon REAL, max_lon REAL, data_at TEXT, imported_at INTEGER);
INSERT INTO regions VALUES ('europe/austria', 46.37, 49.02, 9.53, 17.16, '2026-10-17', 0);
CREATE TABLE services (id TEXT PRIMARY KEY, kind TEXT NOT NULL, name TEXT NOT NULL, lat REAL NOT NULL, lon REAL NOT NULL,
                       street TEXT, city TEXT, phone TEXT, website TEXT, hours TEXT, emergency INTEGER NOT NULL DEFAULT 0);
INSERT INTO services VALUES
  ('node/1', 'vet', 'Tierklinik Prater', 48.2205, 16.3905, 'Praterstraße 12', '1020 Wien', '+43 1 234', NULL, 'Mo-Fr 08:00-18:00', 1),
  ('way/2', 'groomer', 'Salon Struppi', 48.2215, 16.3925, 'Taborstraße 3', '1020 Wien', NULL, 'struppi.at', NULL, 0),
  ('node/3', 'shop', 'Futterhaus Nord', 48.2230, 16.3950, NULL, NULL, NULL, NULL, NULL, 0),
  ('node/4', 'cafe', 'Café Wuff', 48.2190, 16.3890, NULL, '1020 Wien', NULL, NULL, NULL, 0),
  ('node/5', 'shelter', 'Tierheim Fern', 48.10, 16.25, NULL, '2340 Mödling', NULL, NULL, NULL, 0),
  ('node/6', 'school', 'Hundeschule Nachbar', 48.2310, 16.3700, NULL, '1200 Wien', NULL, NULL, NULL, 0),
  ('node/7', 'vet', 'Tierarzt Weit', 48.3000, 16.3900, NULL, NULL, NULL, NULL, NULL, 0);
SQL
php -r '
  require "'"$ROOT"'/public/api/lib-pack.php";
  $pdo = db();
  $pdo->prepare("INSERT INTO accounts (email, created_at) VALUES (?, ?)")->execute(["betrieb@example.org", time()]);
  $pdo->prepare("INSERT INTO sessions (token_hash, account_id, created_at, expires_at, last_seen_at) VALUES (?, ?, ?, ?, ?)")
      ->execute([secret_hash("sitzung-betrieb-0123456789"), (int) $pdo->lastInsertId(), time(), time() + 3600, time()]);'

# Stripe zum Mitschreiben.
cat > "$T/stripe/index.php" <<'PHP'
<?php
file_put_contents(__DIR__ . '/log', $_SERVER['REQUEST_METHOD'] . ' ' . $_SERVER['REQUEST_URI'] . ' ' . file_get_contents('php://input') . "\n", FILE_APPEND);
header('Content-Type: application/json');
$p = parse_url($_SERVER['REQUEST_URI'], PHP_URL_PATH);
if ($p === '/v1/checkout/sessions') { $n = count(file(__DIR__ . '/log')); echo json_encode(['id' => "cs_test_$n", 'url' => "https://checkout.stripe.test/cs_test_$n"]); }
elseif ($p === '/v1/billing_portal/sessions') echo json_encode(['url' => 'https://billing.stripe.test/p']);
elseif (str_starts_with($p, '/v1/subscriptions/')) echo json_encode(['id' => basename($p), 'status' => 'canceled']);
else { http_response_code(404); echo '{"error":{"message":"unbekannt"}}'; }
PHP
php -S 127.0.0.1:$SPORT "$T/stripe/index.php" > /dev/null 2>&1 & STR=$!
TMPDIR="$T" php -S 127.0.0.1:$PORT -t "$ROOT/public" > "$T/server.log" 2>&1 & SRV=$!
sleep 1
U="http://127.0.0.1:$PORT"; ADM="Cookie: stella_session=sitzung-betrieb-0123456789"
json() { php -r '$d = json_decode(stream_get_contents(STDIN), true); '"$1"; }
db()   { sqlite3 "$T/daten/app.sqlite" "$1"; }
# Eine Meldung, wie Stripe sie unterschreibt.
hook() {
  local ts sig; ts=$(date +%s)
  sig=$(printf '%s' "$ts.$1" | openssl dgst -sha256 -hmac whsec_probe | sed 's/^.* //')
  curl -s -o /dev/null -w "%{http_code}" -H "Stripe-Signature: t=$ts,v1=${2:-$sig}" -H "Content-Type: application/json" -d "$1" "$U/api/stripe.php"
}
buchen() { curl -s -o /dev/null -w "%{http_code} %{redirect_url}" -H "Origin: $U" --data-urlencode "action=buchen" --data-urlencode "ort=$1" \
  --data-urlencode "text=$2" --data-urlencode "auftraggeber=Struppi GmbH" --data-urlencode "email=chef@struppi.at" --data-urlencode "bedingungen=1" "$U/partner.php"; }

echo "Adressen"
check "Nach Entfernung, im Umkreis, mit Art" "$(curl -s "$U/api/services.php?lat=48.22&lon=16.39" | json 'foreach ($d["services"] as $s) echo $s["id"], ":", $s["kind"], " "; echo json_encode($d["sponsor"]), " ", json_encode($d["covered"]);')" \
  "node/1:vet node/4:cafe way/2:groomer node/3:shop node/6:school null true"
check "Leere Felder fehlen, Notdienst" "$(curl -s "$U/api/services.php?lat=48.22&lon=16.39" | json 'echo json_encode($d["services"][0], JSON_UNESCAPED_UNICODE | JSON_UNESCAPED_SLASHES), "|", json_encode(array_keys($d["services"][3]));')" \
  '{"id":"node/1","kind":"vet","label":"Tierarzt","name":"Tierklinik Prater","lat":48.2205,"lon":16.3905,"street":"Praterstraße 12","city":"1020 Wien","phone":"+43 1 234","hours":"Mo-Fr 08:00-18:00","emergency":true}|["id","kind","label","name","lat","lon"]'
check "Suche nach Name auch weiter weg" "$(curl -s "$U/api/services.php?lat=48.22&lon=16.39&q=fern" | json 'echo implode(",", array_column($d["services"], "id"));')" "node/5"
check "Suche nach Art" "$(curl -s "$U/api/services.php?lat=48.22&lon=16.39&q=tierarzt" | json 'echo implode(",", array_column($d["services"], "id"));')" "node/1,node/7"
check "Außerhalb des Auszugs: nicht abgedeckt" "$(curl -s "$U/api/services.php?lat=52.52&lon=13.40" | json 'echo json_encode($d);')" '{"services":[],"sponsor":null,"covered":false}'

echo "Buchung"
check "Suche auf der Partnerseite: Gegend frei" "$(curl -s "$U/partner.php?name=struppi" | grep -c 'Gegend frei')" "1"
check "Formular zum gewählten Betrieb, Preis" "$(curl -s "$U/partner.php?platz=way/2" | grep -c '29 € im Monat')" "1"
check "Fremdes Formular wird abgewiesen" "$(curl -s -o /dev/null -w "%{http_code}" -d "action=buchen&ort=way/2" "$U/partner.php")" "403"
check "Ohne Zustimmung zu den Bedingungen keine Kasse" "$(curl -s -H "Origin: $U" -d "action=buchen&ort=way/2&auftraggeber=X&email=a@b.at" "$U/partner.php" | grep -c 'Werbebedingungen zustimmen')" "1"
check "Weiter zur Kasse" "$(buchen way/2 'Erste Pflege für Welpen gratis')" "303 https://checkout.stripe.test/cs_test_1"
check "Kasse: Monatsabo zum Preis, Rückweg, Nummer des Platzes" "$(grep -c 'mode=subscription.*unit_amount%5D=2900.*interval%5D=month.*danke%3D%7BCHECKOUT_SESSION_ID%7D' "$T/stripe/log") $(db "SELECT id, status, checkout_id, tile FROM sponsors")" \
  "1 1|pending|cs_test_1|1607:364"
check "Während jemand an der Kasse steht, ist die Gegend belegt" "$(curl -s -H "Origin: $U" -d "action=buchen&ort=node/1&auftraggeber=X&email=a@b.at&bedingungen=1" "$U/partner.php" | grep -c 'gerade vergeben')" "1"
check "…und die Suche sagt es" "$(curl -s "$U/partner.php?name=prater" | grep -c 'wird gerade gebucht')" "1"
check "Noch nicht bezahlt: kein Platz in der App" "$(curl -s "$U/api/services.php?lat=48.22&lon=16.39" | json 'echo json_encode($d["sponsor"]);')" "null"

echo "Zahlung"
PAID='{"type":"checkout.session.completed","data":{"object":{"id":"cs_test_1","payment_status":"paid","subscription":"sub_1","customer":"cus_1","client_reference_id":"1","metadata":{"sponsor":"1"}}}}'
check "Ohne gültige Unterschrift ändert sich nichts" "$(hook "$PAID" deadbeef) $(db "SELECT status FROM sponsors WHERE id = 1")" "400 pending"
check "Bezahlt: Platz läuft" "$(hook "$PAID") $(db "SELECT status, subscription_id, customer_id, paid_until > strftime('%s','now') + 30*86400 FROM sponsors WHERE id = 1")" "200 active|sub_1|cus_1|1"
LINK=$(grep -o 'https://thisdog.app/partner/verwalten/[A-Za-z0-9_-]*' "$T/daten/mail-dev.log" | head -1)
check "Mail mit Verwaltungslink, Betreiber erfährt es" "$(test -n "$LINK" && echo ja) $(grep -c 'Neuer Partnerplatz: Salon Struppi' "$T/daten/mail-dev.log")" "ja 1"
check "Doppelte Meldung schickt keine zweite Mail" "$(hook "$PAID") $(grep -c 'verwalten/' "$T/daten/mail-dev.log")" "200 1"
check "Der Platz steht oben, unten nicht noch einmal" "$(curl -s "$U/api/services.php?lat=48.22&lon=16.39" | json 'echo $d["sponsor"]["name"], "|", $d["sponsor"]["text"], "|", $d["sponsor"]["advertiser"], "|", $d["sponsor"]["id"], "|", in_array("way/2", array_column($d["services"], "id")) ? "doppelt" : "einmal";')" \
  "Salon Struppi|Erste Pflege für Welpen gratis|Struppi GmbH|1|einmal"
check "Auch aus der Nachbargegend in Reichweite" "$(curl -s "$U/api/services.php?lat=48.23&lon=16.37" | json 'echo $d["sponsor"]["name"] ?? "-";')" "Salon Struppi"
check "Weiter weg nicht" "$(curl -s "$U/api/services.php?lat=48.30&lon=16.39" | json 'echo $d["sponsor"]["name"] ?? "-";')" "-"
curl -s -o /dev/null -H "Content-Type: application/json" -d '{"action":"tap","sponsor":1}' "$U/api/services.php"
curl -s -o /dev/null -H "Content-Type: application/json" -d '{"action":"tap","sponsor":1}' "$U/api/services.php"
check "Gezeigt einmal je Stunde und Anschluss, geöffnet gezählt" "$(db "SELECT views, taps FROM sponsor_stats WHERE sponsor_id = 1")" "1|2"
check "Die Partnerseite listet aktuelle Partner" "$(curl -s "$U/partner.php" | grep -c 'Aktuelle Partner')" "1"
check "Gegend jetzt vergeben" "$(curl -s "$U/partner.php?platz=node/1" | grep -c 'Gegend vergeben')" "1"

INV='{"type":"invoice.paid","data":{"object":{"subscription":"sub_1","customer":"cus_1","lines":{"data":[{"period":{"start":1,"end":4102444800}}]}}}}'
check "Rechnung bezahlt: läuft bis zum Ende des Zeitraums" "$(hook "$INV") $(db "SELECT paid_until FROM sponsors WHERE id = 1")" "200 4102444800"
INV2='{"type":"invoice.paid","data":{"object":{"parent":{"subscription_details":{"subscription":"sub_1","metadata":{"sponsor":"1"}}},"lines":{"data":[{"period":{"end":4102444900}}]}}}}'
check "…auch in der neuen Schreibweise von Stripe" "$(hook "$INV2") $(db "SELECT paid_until FROM sponsors WHERE id = 1")" "200 4102444900"
UPD='{"type":"customer.subscription.updated","data":{"object":{"id":"sub_1","cancel_at_period_end":true,"current_period_end":4102444900}}}'
check "Gekündigt zum Monatsende: läuft weiter, Datum steht da" "$(hook "$UPD") $(db "SELECT status, cancels_at FROM sponsors WHERE id = 1")" "200 active|4102444900"

echo "Verwaltung"
TOKEN=${LINK##*/}
check "Verwaltung mit dem Link aus der Mail" "$(curl -s "$U/partner.php?verwalten=$TOKEN" | grep -c 'gekündigt zum')" "1"
check "Falscher Link" "$(curl -s "$U/partner.php?verwalten=falsch0123456789" | grep -c 'gilt nicht')" "1"
check "Text ändern" "$(curl -s -o /dev/null -w "%{http_code}" -H "Origin: $U" -d "action=text&text=Neu: Krallen schneiden" "$U/partner.php?verwalten=$TOKEN") $(curl -s "$U/api/services.php?lat=48.22&lon=16.39" | json 'echo $d["sponsor"]["text"];')" \
  "303 Neu: Krallen schneiden"
check "Zum Kundenbereich bei Stripe" "$(curl -s -o /dev/null -w "%{redirect_url}" -H "Origin: $U" -d "action=portal" "$U/partner.php?verwalten=$TOKEN") $(grep -c 'billing_portal.*customer=cus_1' "$T/stripe/log")" \
  "https://billing.stripe.test/p 1"

echo "Abbrechen und Ende"
check "Andere Gegend buchen" "$(buchen node/7 '')" "303 https://checkout.stripe.test/cs_test_3"
curl -s -o /dev/null "$U/partner.php?abgebrochen=2"
check "Kasse abgebrochen: Gegend sofort wieder frei" "$(db "SELECT COUNT(*) FROM sponsors WHERE id = 2") $(curl -s "$U/partner.php?platz=node/7" | grep -c 'Weiter zur Kasse')" "0 1"
check "Ein laufender Platz lässt sich so nicht löschen" "$(curl -s -o /dev/null "$U/partner.php?abgebrochen=1"; db "SELECT status FROM sponsors WHERE id = 1")" "active"
check "Admin: Bereich Partnerplätze" "$(curl -s -H "$ADM" "$U/admin-orte.php" | grep -c 'Struppi GmbH')" "1"
check "Admin sperrt: Abo endet bei Stripe, Platz verschwindet" "$(curl -s -o /dev/null -w "%{http_code}" -H "$ADM" -H "Origin: $U" -H "Content-Type: application/json" -d '{"id":1}' "$U/admin-orte.php?action=partner_block") $(grep -c 'DELETE /v1/subscriptions/sub_1' "$T/stripe/log") $(curl -s "$U/api/services.php?lat=48.22&lon=16.39" | json 'echo json_encode($d["sponsor"]);')" \
  "200 1 null"
DEL='{"type":"customer.subscription.deleted","data":{"object":{"id":"sub_1"}}}'
check "Die Meldung danach hebt die Sperre nicht auf" "$(hook "$DEL") $(db "SELECT status FROM sponsors WHERE id = 1")" "200 blocked"
check "Gegend wieder frei" "$(curl -s "$U/partner.php?platz=node/1" | grep -c 'Weiter zur Kasse')" "1"
echo "Selbst eingetragen"
ap() { curl -s -H "$ADM" -H "Origin: $U" -H "Content-Type: application/json" -d "$2" "$U/admin-orte.php?action=$1"; }
apc() { curl -s -o /dev/null -w "%{http_code}" -H "$ADM" -H "Origin: $U" -H "Content-Type: application/json" -d "$2" "$U/admin-orte.php?action=$1"; }
check "Suche im Auszug" "$(ap partner_search '{"name":"klinik","where":"Prater"}' | json 'echo $d["found"][0]["id"], " ", count($d["found"]);')" "node/1 1"
check "Nur von der eigenen Seite aus" "$(curl -s -o /dev/null -w "%{http_code}" -H "$ADM" -H "Content-Type: application/json" -d '{}' "$U/admin-orte.php?action=partner_add")" "403"
NEU=$(ap partner_add '{"lat":48.2205,"lon":16.3905,"place":"node/1","name":"Tierklinik Prater","kind":"vet","street":"Praterstraße 12","city":"1020 Wien","text":"Notdienst rund um die Uhr","advertiser":"","email":"klinik@example.org","until":"","sendLink":true}')
MID=$(echo "$NEU" | json 'echo $d["id"];')
check "Eintragen ohne Stripe, unbefristet" "$(echo "$NEU" | json 'echo str_contains($d["link"], "/partner/verwalten/") ? "link" : "-";') $(db "SELECT status, paid_until, advertiser, checkout_id IS NULL FROM sponsors WHERE id = $MID") $(grep -c 'POST' "$T/stripe/log")" \
  "link active|4102444800|Tierklinik Prater|1 3"
check "App zeigt ihn oben, unten nicht noch einmal" "$(curl -s "$U/api/services.php?lat=48.22&lon=16.39" | json 'echo $d["sponsor"]["name"], "|", $d["sponsor"]["text"], "|", in_array("node/1", array_column($d["services"], "id")) ? "doppelt" : "einmal";')" \
  "Tierklinik Prater|Notdienst rund um die Uhr|einmal"
check "Mail mit Verwaltungslink an den Betrieb" "$(grep -c 'an klinik@example.org' "$T/daten/mail-dev.log")" "1"
MLINK=$(echo "$NEU" | json 'echo basename($d["link"]);')
check "Verwaltung: läuft, ohne Abo und Kundenbereich" "$(curl -s "$U/partner.php?verwalten=$MLINK" | grep -c 'Läuft\|verlängert sich\|Kundenbereich')" "1"
check "Gegend belegt: zweiter Eintrag geht nicht" "$(apc partner_add '{"lat":48.2190,"lon":16.3890,"place":"node/4","name":"Café Wuff","kind":"cafe","until":""}') $(curl -s "$U/partner.php?platz=node/4" | grep -c 'Gegend vergeben')" "409 1"
check "Admin: selbst eingetragen, unbefristet" "$(curl -s -H "$ADM" "$U/admin-orte.php" | grep -c 'läuft unbefristet\|selbst eingetragen')" "2"
BIS=$(date -v+10d +%Y-%m-%d 2>/dev/null || date -d '+10 days' +%Y-%m-%d)
check "Laufzeit: Vergangenes nicht, Zukunft schon (bis Tagesende)" "$(apc partner_until "{\"id\":$MID,\"until\":\"2020-01-01\"}") $(apc partner_until "{\"id\":$MID,\"until\":\"$BIS\"}") $(db "SELECT strftime('%Y-%m-%d %H:%M', paid_until, 'unixepoch', 'localtime') FROM sponsors WHERE id = $MID")" \
  "422 200 $BIS 23:59"
check "Gebuchte Plätze nicht über die Laufzeit ändern" "$(apc partner_until '{"id":1,"until":""}')" "422"
check "Neuer Link: alter gilt nicht mehr" "$(ap partner_link "{\"id\":$MID}" | json 'echo str_contains($d["link"], "/partner/verwalten/") ? "link" : "-";') $(curl -s "$U/partner.php?verwalten=$MLINK" | grep -c 'gilt nicht')" "link 1"
check "Beenden: sofort weg" "$(apc partner_end "{\"id\":$MID}") $(curl -s "$U/api/services.php?lat=48.22&lon=16.39" | json 'echo json_encode($d["sponsor"]);')" "200 null"
check "Wieder an" "$(apc partner_until "{\"id\":$MID,\"until\":\"\"}") $(curl -s "$U/api/services.php?lat=48.22&lon=16.39" | json 'echo $d["sponsor"]["name"];')" "200 Tierklinik Prater"
check "Ohne Treffer in OSM: Stelle von der Karte, ohne E-Mail" "$(ap partner_add '{"lat":48.3001,"lon":16.3901,"name":"Gassi-Shop Weit","kind":"shop","until":"","sendLink":true}' | json 'echo $d["link"] === null ? "kein-link" : "link";') $(db "SELECT substr(place_id, 1, 5) FROM sponsors WHERE name = 'Gassi-Shop Weit'")" \
  "kein-link eigen"
check "Falsche E-Mail oder Art" "$(apc partner_add '{"lat":48.5,"lon":16.5,"name":"X","kind":"shop","email":"nein"}') $(apc partner_add '{"lat":48.5,"lon":16.5,"name":"X","kind":"park"}')" "422 422"
check "Fehler im Protokoll" "$(grep -c 'PHP \(Warning\|Fatal\|Deprecated\)' "$T/server.log")" "0"

if [ $FAIL = 0 ]; then echo "Alles bestanden."; else echo "FEHLGESCHLAGEN"; grep -i 'php\|stella' "$T/server.log" | head -20; exit 1; fi
