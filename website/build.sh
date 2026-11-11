#!/bin/bash
# Baut website/index.html aus src/index.template.html: Schrift und Bildschirmmasken als data:-URI, Logo eingebettet.
# (mask-image wird wie mit CORS geladen; eingebettet geht es auch lokal und von jedem Server.)
# Die Seite liegt dann mit media/ zusammen und kann so auf thisdog.app oder als Vorschau veröffentlicht werden.
cd "$(dirname "$0")" || exit 1
python3 - <<'PY'
import base64, json, pathlib, re
t = pathlib.Path("src/index.template.html").read_text()
font = base64.b64encode(pathlib.Path("media/bricolage.woff2").read_bytes()).decode()
mark = pathlib.Path("media/stella-mark.svg").read_text()
mark = re.sub(r'\s(role|aria-label)="[^"]*"', "", mark)
t = re.sub(r"url\((media/maske-[a-z-]+\.webp)\)",
           lambda m: "url(data:image/webp;base64," + base64.b64encode(pathlib.Path(m.group(1)).read_bytes()).decode() + ")", t)
foods = [{k: f[k] for k in ("name", "status", "reason", "aliases") if k in f} for f in json.loads(pathlib.Path("../ios/ThisDog/Resources/foods.json").read_text())]
foods = json.dumps(foods, ensure_ascii=False, separators=(",", ":")).replace("</", "<\\/")
pathlib.Path("index.html").write_text(t.replace("{{FONT}}", font).replace("{{MARK}}", mark).replace("{{FOODS}}", foods))
print("index.html", len(t), "→", pathlib.Path("index.html").stat().st_size, "Bytes")
PY
