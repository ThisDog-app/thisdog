#!/bin/bash
# Baut ThisDog für ein eigenes iPad und installiert es übers Netz oder Kabel.
#
# Solange Xcode auf diesem Mac kein Apple-Konto kennt, gibt es kein Profil für app.thisDog mit
# Universal Links und Push. Diese Fassung kommt deshalb ohne beides aus und wird mit dem Profil
# signiert, das für alle Apps des Teams gilt („iOS Team Provisioning Profile: *“).
# Folgen: Anmelden nur mit dem Code aus der Mail (der Link öffnet die App nicht), keine Mitteilungen
# vom Server. Alles andere – Abgleich, Rudel, Gassi, Live-Aktivität, Erinnerungen – geht.
#
# Gerät, Signaturidentität und Schlüsselbund stehen in scripts/lokal.env (nicht im Repository;
# Vorlage: scripts/lokal.env.beispiel). Die Team-ID kommt aus project.yml (DEVELOPMENT_TEAM).
#
# Aufruf: scripts/ipad-bauen.sh [--nur-bauen]
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
[ -f scripts/lokal.env ] || { echo "ABBRUCH: scripts/lokal.env fehlt – Vorlage: cp scripts/lokal.env.beispiel scripts/lokal.env"; exit 1; }
. scripts/lokal.env
for v in IPAD_UDID SIGN_IDENTITY; do
  [ -n "${!v:-}" ] || { echo "ABBRUCH: $v ist in scripts/lokal.env nicht gesetzt."; exit 1; }
done
IPAD=$IPAD_UDID
IDENT=$SIGN_IDENTITY
KC=${SIGN_KEYCHAIN:-}
TEAM=$(awk '/DEVELOPMENT_TEAM:/ {print $2; exit}' project.yml)
[ -n "$TEAM" ] || { echo "ABBRUCH: DEVELOPMENT_TEAM fehlt in project.yml."; exit 1; }
# Mit eigenem Schlüsselbund: entsperren und beim Signieren angeben. Ohne: der Standard-Schlüsselbund.
KCARG=()
if [ -n "$KC" ]; then
  KCARG=(--keychain "$KC")
  [ -n "${SIGN_KEYCHAIN_PASSWORD_FILE:-}" ] && [ -r "$SIGN_KEYCHAIN_PASSWORD_FILE" ] || {
    echo "ABBRUCH: SIGN_KEYCHAIN_PASSWORD_FILE in scripts/lokal.env fehlt oder ist nicht lesbar."; exit 1; }
fi

PROFIL=""
for f in "$HOME/Library/Developer/Xcode/UserData/Provisioning Profiles"/*.mobileprovision; do
  security cms -D -i "$f" 2>/dev/null > /tmp/thisdog-profil.plist || continue
  plutil -extract Entitlements.application-identifier raw -o - /tmp/thisdog-profil.plist 2>/dev/null | grep -q '\.\*$' || continue
  plutil -extract ProvisionedDevices json -o - /tmp/thisdog-profil.plist 2>/dev/null | grep -q "$IPAD" || continue
  PROFIL=$(plutil -extract UUID raw -o - /tmp/thisdog-profil.plist); break
done
[ -n "$PROFIL" ] || { echo "ABBRUCH: Kein Team-Profil mit dem iPad gefunden."; exit 1; }

[ -z "$KC" ] || security unlock-keychain -p "$(cat "$SIGN_KEYCHAIN_PASSWORD_FILE")" "$KC" || exit 1
xcodegen -q || exit 1
# Unsigniert bauen und danach selbst signieren: Xcode nimmt das von Xcode verwaltete Team-Profil
# bei manueller Signatur nicht an.
xcodebuild -project ThisDog.xcodeproj -scheme ThisDog -configuration Debug -destination 'generic/platform=iOS' \
  -derivedDataPath build/ipad CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO build > build/ipad-bau.log 2>&1
rc=$?
grep -E "error:" build/ipad-bau.log | sort -u | head -5
[ $rc -eq 0 ] || { echo "ABBRUCH: Bau fehlgeschlagen (build/ipad-bau.log)"; exit 1; }
APP=build/ipad/Build/Products/Debug-iphoneos/ThisDog.app
PROFILDATEI="$HOME/Library/Developer/Xcode/UserData/Provisioning Profiles/$PROFIL.mobileprovision"

# Berechtigungen für eine Kennung: nur, was das Team-Profil hergibt – ohne Universal Links und Push.
berechtigungen() {
  cat > "build/$1.entitlements" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>application-identifier</key><string>$TEAM.$1</string>
<key>com.apple.developer.team-identifier</key><string>$TEAM</string>
<key>get-task-allow</key><true/>
</dict></plist>
PLIST
}
signiere() {  # Pfad, Kennung
  cp "$PROFILDATEI" "$1/embedded.mobileprovision"
  berechtigungen "$2"
  codesign --force --sign "$IDENT" ${KCARG[@]+"${KCARG[@]}"} --entitlements "build/$2.entitlements" --timestamp=none "$1" || exit 1
}
for fw in "$APP"/Frameworks/*; do [ -e "$fw" ] && codesign --force --sign "$IDENT" ${KCARG[@]+"${KCARG[@]}"} --timestamp=none "$fw"; done
[ -f "$APP/ThisDog.debug.dylib" ] && codesign --force --sign "$IDENT" ${KCARG[@]+"${KCARG[@]}"} --timestamp=none "$APP/ThisDog.debug.dylib"
[ -f "$APP/__preview.dylib" ] && codesign --force --sign "$IDENT" ${KCARG[@]+"${KCARG[@]}"} --timestamp=none "$APP/__preview.dylib"
signiere "$APP/PlugIns/ThisDogWidgets.appex" app.thisDog.widgets
signiere "$APP" app.thisDog
codesign --verify --deep --strict "$APP" || { echo "ABBRUCH: Signatur ungültig"; exit 1; }
echo "Gebaut und signiert: $APP ($(git log --oneline -1))"
for a in "$@"; do [ "$a" = "--nur-bauen" ] && exit 0; done

xcrun devicectl device install app --device "$IPAD" "$APP" > build/ipad-install.log 2>&1 || {
  tail -3 build/ipad-install.log
  grep -qi "locked" build/ipad-install.log && echo "Das iPad ist gesperrt – entsperren und noch einmal starten."
  echo "ABBRUCH: Installation"; exit 1; }
echo "Installiert auf dem iPad."
