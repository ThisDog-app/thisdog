#!/usr/bin/env python3
"""Schreibt alle Texte der Android-Fassung als Vorlage für Übersetzer: android/app/src/main/assets/i18n/vorlage.json.
Aufruf im Hauptordner des Repos. Die fertige Sprache heißt dann en.json oder sr-Latn.json."""
import json, pathlib, re
R = pathlib.Path("android/app/src/main/java/app/thisdog")
keys = set()
for f in R.rglob("*.kt"):
    if f.name == "L.kt":
        continue
    for m in re.finditer(r'L\.t\("((?:[^"\\]|\\.)*)"', f.read_text()):
        keys.add(m.group(1).replace('\\$', '$').replace('\\"', '"').replace('\\n', '\n'))
out = pathlib.Path("android/app/src/main/assets/i18n/vorlage.json")
out.write_text(json.dumps({k: "" for k in sorted(keys)}, ensure_ascii=False, indent=1) + "\n")
print(len(keys), "Texte in", out)
