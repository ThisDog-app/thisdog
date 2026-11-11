#!/bin/bash
# Baut ThisDog für das iPad und legt es auf dem eigenen Server ab, zum Laden über einen Link (itms-services).
#
# Signiert automatisch mit den von Xcode verwalteten Entwicklungsprofilen (alle Ziele inklusive Watch, mit WeatherKit,
# Push, Universal Links und App-Gruppe). Neue oder abgelaufene Profile holt xcodebuild selbst: mit dem
# App-Store-Connect-API-Schlüssel aus ~/.appstoreconnect/ (AuthKey_<ID>.p8 und eine Datei issuer mit der Issuer-ID),
# sonst über das in Xcode angemeldete Apple-Konto.
#
# Server (ssh-Name), Zielordner, öffentliche Adresse und Schlüsselbund stehen in scripts/lokal.env
# (nicht im Repository; Vorlage: scripts/lokal.env.beispiel).
#
# Aufruf: scripts/ipad-link.sh            → gibt den Link aus
#         scripts/ipad-link.sh --entfernen → löscht die abgelegte Fassung vom Server
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
[ -f scripts/lokal.env ] || { echo "ABBRUCH: scripts/lokal.env fehlt – Vorlage: cp scripts/lokal.env.beispiel scripts/lokal.env"; exit 1; }
. scripts/lokal.env
for v in LADEN_SSH LADEN_ZIEL LADEN_URL; do
  [ -n "${!v:-}" ] || { echo "ABBRUCH: $v ist in scripts/lokal.env nicht gesetzt."; exit 1; }
done
SSH_HOST=$LADEN_SSH
ZIEL=$LADEN_ZIEL
KC=${SIGN_KEYCHAIN:-}
if [ -n "$KC" ]; then
  [ -n "${SIGN_KEYCHAIN_PASSWORD_FILE:-}" ] && [ -r "$SIGN_KEYCHAIN_PASSWORD_FILE" ] || {
    echo "ABBRUCH: SIGN_KEYCHAIN_PASSWORD_FILE in scripts/lokal.env fehlt oder ist nicht lesbar."; exit 1; }
fi

if [ "${1:-}" = "--entfernen" ]; then
  ssh "$SSH_HOST" "rm -rf $ZIEL" && echo "Entfernt."; exit $?
fi

PROFILE=(-allowProvisioningUpdates -allowProvisioningDeviceRegistration)
SCHLUESSEL=$(ls "$HOME"/.appstoreconnect/AuthKey_*.p8 2>/dev/null | head -1)
if [ -n "$SCHLUESSEL" ] && [ -s "$HOME/.appstoreconnect/issuer" ]; then
  KEY_ID=$(basename "$SCHLUESSEL" .p8); KEY_ID=${KEY_ID#AuthKey_}
  PROFILE+=(-authenticationKeyPath "$SCHLUESSEL" -authenticationKeyID "$KEY_ID"
            -authenticationKeyIssuerID "$(tr -d '[:space:]' < "$HOME/.appstoreconnect/issuer")")
fi

[ -z "$KC" ] || security unlock-keychain -p "$(cat "$SIGN_KEYCHAIN_PASSWORD_FILE")" "$KC" || exit 1
xcodegen -q || exit 1
xcodebuild -project ThisDog.xcodeproj -scheme ThisDog -configuration Release -destination 'generic/platform=iOS' \
  -derivedDataPath build/ipad "${PROFILE[@]}" build > build/ipad-bau.log 2>&1
rc=$?
grep -E "error:" build/ipad-bau.log | sort -u | head -5
[ $rc -eq 0 ] || { echo "ABBRUCH: Bau fehlgeschlagen (build/ipad-bau.log)"; exit 1; }
APP=build/ipad/Build/Products/Release-iphoneos/ThisDog.app
codesign --verify --deep --strict "$APP" || { echo "ABBRUCH: Signatur ungültig"; exit 1; }

# Paket und Manifest
OUT=build/laden; rm -rf "$OUT"; mkdir -p "$OUT/Payload"
cp -R "$APP" "$OUT/Payload/"
VERSION=$(plutil -extract CFBundleShortVersionString raw -o - "$APP/Info.plist")
BAU=$(plutil -extract CFBundleVersion raw -o - "$APP/Info.plist")
GEHEIM=${GEHEIM:-$(ssh "$SSH_HOST" "cat $ZIEL/.geheim 2>/dev/null")}
[ -n "$GEHEIM" ] || GEHEIM=$(openssl rand -hex 12)
BASIS="${LADEN_URL%/}/$GEHEIM"
(cd "$OUT" && zip -qry ThisDog.ipa Payload) && rm -rf "$OUT/Payload"
cat > "$OUT/manifest.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict><key>items</key><array><dict>
<key>assets</key><array><dict><key>kind</key><string>software-package</string><key>url</key><string>$BASIS/ThisDog.ipa?v=$(date +%s)</string></dict></array>
<key>metadata</key><dict>
<key>bundle-identifier</key><string>app.thisDog</string>
<key>bundle-version</key><string>$VERSION</string>
<key>kind</key><string>software</string>
<key>title</key><string>ThisDog</string>
</dict></dict></array></dict></plist>
PLIST
STAND=$(git log -1 --format='%h, %cd' --date=format-local:'%d.%m. %H:%M' 2>/dev/null)
# Android dazu, wenn eine fertige APK da ist: eigener Knopf, denn itms-services gibt es nur auf dem iPhone.
APK=../android/app/build/outputs/apk/release/app-release.apk
ANDROID=""
if [ -f "$APK" ]; then
  AV=$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["elements"][0]["versionName"])' "${APK%/*}/output-metadata.json" 2>/dev/null)
  cp "$APK" "$OUT/ThisDog-$AV.apk"
  ANDROID="<h2>Android $AV</h2>
<p><a class=\"laden\" href=\"ThisDog-$AV.apk\" download>APK laden</a></p>
<p>Nach dem Laden öffnen und „Installieren“ tippen (einmalig „Aus dieser Quelle zulassen“).</p>"
fi
cat > "$OUT/index.html" <<HTML
<!doctype html><html lang="de"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<meta name="robots" content="noindex"><title>ThisDog laden</title>
<style>body{font:17px -apple-system,system-ui,sans-serif;max-width:30em;margin:15vh auto;padding:0 16px;color:#222;background:#fff}
a.laden{display:inline-block;background:#222;color:#fff;padding:.8em 1.6em;border-radius:12px;text-decoration:none;font-weight:600}
p{color:#666}@media(prefers-color-scheme:dark){body{background:#111;color:#eee}a.laden{background:#eee;color:#111}p{color:#999}}</style></head>
<body><h1>ThisDog $VERSION ($BAU)</h1>
<p><a class="laden" href="itms-services://?action=download-manifest&amp;url=$BASIS/manifest.plist">Auf dem iPhone installieren</a></p>
$ANDROID
<p>Stand $STAND</p></body></html>
HTML
cat > "$OUT/.htaccess" <<'HT'
Options -Indexes
AddType application/octet-stream .ipa
AddType text/xml .plist
AddType application/vnd.android.package-archive .apk
Header set Cache-Control "no-store"
HT
ssh "$SSH_HOST" "mkdir -p $ZIEL/$GEHEIM && echo $GEHEIM > $ZIEL/.geheim && printf 'Options -Indexes\n' > $ZIEL/.htaccess" || exit 1
rsync -rc -e ssh "$OUT/" "$SSH_HOST:$ZIEL/$GEHEIM/" || exit 1
echo "$BASIS/"
