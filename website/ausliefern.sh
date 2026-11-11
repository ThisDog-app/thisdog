#!/bin/bash
# Bringt die Webseite nach public/ (thisdog.app): index.html mit Dokumentkopf, die verwendeten Medien nach
# public/media. Danach wie immer: rsync -rc --exclude='.DS_Store' -e ssh public/ <server>:<webordner>/
cd "$(dirname "$0")" || exit 1
./build.sh || exit 1
{ printf '<!doctype html>\n<html lang="de">\n'; cat index.html; } > ../public/index.html
mkdir -p ../public/media
for f in $(grep -o 'media/[a-z0-9/-]*\.[a-z0-9]*' index.html | sort -u); do mkdir -p "../public/$(dirname "$f")"; cp "$f" "../public/$f"; done
# Medien heißen bei neuen Aufnahmen gleich – deshalb nur einen Tag zwischenspeichern, nicht ein Jahr.
cat > ../public/media/.htaccess <<'HT'
AddType image/avif .avif
<IfModule mod_headers.c>
	<FilesMatch "\.(jpg|jpeg|png|webp|avif|mp4)$">
		Header set Cache-Control "public, max-age=86400"
	</FilesMatch>
</IfModule>
HT
echo "public/index.html und $(ls ../public/media | wc -l | tr -d ' ') Medien bereit"
