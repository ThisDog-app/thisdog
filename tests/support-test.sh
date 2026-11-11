#!/bin/bash
# Prüft den Support: Gerätecode, Anfrage aus App und Web, Benachrichtigung, Admin-Seite.
# Aufruf: tests/support-test.sh – braucht php und curl; alles in einem Wegwerfordner.
set -u
ROOT=$(cd "$(dirname "$0")/.." && pwd)
T=$(mktemp -d); PORT=8097; FAIL=0
trap 'kill $SRV 2>/dev/null; rm -rf "$T"' EXIT
cat > "$T/config.php" <<PHP
<?php return ['DATA_DIR' => '$T/daten', 'APP_URL' => 'https://thisdog.app', 'ADMIN_EMAILS' => ['betrieb@example.org'], 'NOTIFY_TO' => 'betrieb@example.org'];
PHP
mkdir -p "$T/daten"
export STELLA_CONFIG="$T/config.php"
ok()   { echo "  ✔ $1"; }
nein() { echo "  ✘ $1"; FAIL=1; }
check(){ if [ "$2" = "$3" ]; then ok "$1"; else nein "$1 (erwartet „$3“, war „$2“)"; fi; }

php -r '
  require "'"$ROOT"'/public/api/lib-pack.php";
  $pdo = db();
  $pdo->prepare("INSERT INTO accounts (email, created_at) VALUES (?, ?)")->execute(["betrieb@example.org", time()]);
  $pdo->prepare("INSERT INTO sessions (token_hash, account_id, created_at, expires_at, last_seen_at) VALUES (?, ?, ?, ?, ?)")->execute([secret_hash("sitzung-betrieb-0123456789"), 1, time(), time() + 3600, time()]);'
TMPDIR="$T" php -S 127.0.0.1:$PORT -t "$ROOT/public" > "$T/server.log" 2>&1 & SRV=$!
sleep 1
U="http://127.0.0.1:$PORT"; ADM="Cookie: stella_session=sitzung-betrieb-0123456789"
send() { curl -s -H "Content-Type: application/json" -d "$1" "$U/api/support.php"; }

echo "Gerätecode"
check "Prüfwerte wie in den Apps" "$(php -r 'require "'"$ROOT"'/public/api/lib-support.php"; echo device_code_encode(0, 27, 1, 3, 1, 0, 12), " ", device_code_encode(2, 16, 5, 4, 1, 2, 345);')" "0V5-H00-0CG 4GP-110-AS9"
check "Lesen, auch klein und ohne Striche" "$(php -r 'require "'"$ROOT"'/public/api/lib-support.php"; echo device_code_text(device_code_decode("0v5h000cg"));')" "ThisDog 1.0 (12), iOS 27, iPhone Duo, 8 GB"
check "Ein Tippfehler fällt auf" "$(php -r 'require "'"$ROOT"'/public/api/lib-support.php"; var_export(device_code_decode("0V5-H00-0CH"));')" "NULL"

echo "Anfrage"
check "Aus der App" "$(send '{"kind":"problem","email":"anna@example.org","text":"Der Kalender zeigt nichts.","code":"0V5-H00-0CG","via":"app"}')" '{"number":"T-0001"}'
check "Über das Formular, ohne Code" "$(send '{"kind":"idee","email":"ben@example.org","text":"Eine Wasserkarte wäre toll."}')" '{"number":"T-0002"}'
check "Falscher Code wird abgelehnt" "$(send '{"kind":"frage","email":"a@example.org","text":"Hallo zusammen","code":"0V5-H00-0CH"}')" '{"error":"invalid_code"}'
check "Ohne E-Mail-Adresse nicht" "$(send '{"kind":"frage","email":"nein","text":"Hallo zusammen"}')" '{"error":"invalid_email"}'
check "Programme, die das versteckte Feld füllen, landen nirgends" "$(send '{"kind":"frage","email":"bot@example.org","text":"Kauf jetzt","website":"spam"}') $(sqlite3 "$T/daten/app.sqlite" 'SELECT COUNT(*) FROM support_requests')" '{"number":"T-0000"} 2'
check "Benachrichtigung an den Betreiber mit Antwortadresse, Bestätigung an den Absender" "$(grep -c 'Reply-To: anna@example.org\|Betreff: Deine Anfrage bei ThisDog (T-0001)' "$T/daten/mail-dev.log")" "2"
check "Admin sieht beide" "$(curl -s -H "$ADM" "$U/admin-support.php" | grep -c 'class="anfrage"')" "2"
check "Erledigen" "$(curl -s -o /dev/null -w "%{http_code}" -H "$ADM" -H "Origin: $U" -H "Content-Type: application/json" -d '{"id":1,"status":"erledigt"}' "$U/admin-support.php?action=status")" "200"
check "Danach nur noch eine offen" "$(curl -s -H "$ADM" "$U/admin-support.php" | grep -c 'class="anfrage"')" "1"

[ $FAIL = 0 ] && echo "Alles bestanden." || { echo "FEHLGESCHLAGEN"; exit 1; }
