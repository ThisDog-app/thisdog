#!/usr/bin/env python3
"""Wandelt die Icons der iOS-Fassung und das Logo in Android-VectorDrawables um und schreibt die Namensliste für Kotlin.
Aufruf im Hauptordner des Repos: python3 android/tools/icons_aus_svg.py
Die SVGs bleiben die einzige Quelle; hier wird nichts gezeichnet."""
import glob, os, re
from xml.sax.saxutils import quoteattr

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
OUT = os.path.join(ROOT, "android/app/src/main/res/drawable")
KT = os.path.join(ROOT, "android/app/src/main/java/app/thisdog/ui/LineIcons.kt")
HEAD = '<?xml version="1.0" encoding="utf-8"?>\n<!-- Erzeugt von android/tools/icons_aus_svg.py aus %s. Nicht von Hand ändern. -->\n'


def num(v):
    return ("%.3f" % v).rstrip("0").rstrip(".")


def circle(cx, cy, r):
    """Ein Kreis als zwei Halbbögen, im selben Umlaufsinn wie die übrigen Pfade."""
    return f"M{num(cx - r)},{num(cy)} a{num(r)},{num(r)} 0 1,1 {num(2 * r)},0 a{num(r)},{num(r)} 0 1,1 {num(-2 * r)},0 Z"


names = []
for svg in sorted(glob.glob(os.path.join(ROOT, "ios/ThisDog/Assets.xcassets/icon-*.imageset/*.svg"))):
    text = open(svg, encoding="utf-8").read()
    name = re.search(r"icon-([^/]+)\.imageset", svg).group(1)
    assert 'viewBox="0 0 24 24"' in text and 'stroke-width="1.7"' in text and 'fill="none"' in text, svg
    unknown = set(re.findall(r"<([a-z]+)", text)) - {"svg", "path", "circle"}
    assert not unknown, (svg, unknown)
    shapes = []
    for m in re.finditer(r"<(path|circle)\b([^>]*)/?>", text):
        attrs = dict(re.findall(r'([a-z-]+)="([^"]*)"', m.group(2)))
        shapes.append(attrs["d"] if m.group(1) == "path" else circle(float(attrs["cx"]), float(attrs["cy"]), float(attrs["r"])))
    paths = "".join(
        f'    <path android:pathData={quoteattr(d)} android:fillColor="#00000000" android:strokeColor="#FF000000" '
        f'android:strokeWidth="1.7" android:strokeLineCap="round" android:strokeLineJoin="round" />\n' for d in shapes)
    res = "icon_" + name.replace("-", "_")
    with open(os.path.join(OUT, res + ".xml"), "w", encoding="utf-8") as f:
        f.write(HEAD % f"icon-{name}.svg")
        f.write('<vector xmlns:android="http://schemas.android.com/apk/res/android" android:width="24dp" android:height="24dp" '
                'android:viewportWidth="24" android:viewportHeight="24">\n' + paths + "</vector>\n")
    names.append((name, res))

# Das Logo: gefüllt, die Farbe kommt beim Zeichnen dazu.
text = open(os.path.join(ROOT, "Design/stella-mark.svg"), encoding="utf-8").read()
vb = re.search(r'viewBox="0 0 (\d+) (\d+)"', text)
a, _, _, d, e, f_ = [float(x) for x in re.search(r'matrix\(([^)]*)\)', text).group(1).split(",")]
paths = "".join(f'        <path android:fillColor="#FF000000" android:fillType="evenOdd" android:pathData={quoteattr(x)} />\n' for x in re.findall(r'\sd="([^"]+)"', text))
with open(os.path.join(OUT, "stella_mark.xml"), "w", encoding="utf-8") as f:
    f.write(HEAD % "Design/stella-mark.svg")
    f.write(f'<vector xmlns:android="http://schemas.android.com/apk/res/android" android:width="172dp" android:height="170dp" '
            f'android:viewportWidth="{vb.group(1)}" android:viewportHeight="{vb.group(2)}">\n'
            f'    <group android:translateX="{e}" android:translateY="{f_}" android:scaleX="{a}" android:scaleY="{d}">\n{paths}    </group>\n</vector>\n')

with open(KT, "w", encoding="utf-8") as f:
    f.write("package app.thisdog.ui\n\nimport app.thisdog.R\n\n")
    f.write("/** Erzeugt von android/tools/icons_aus_svg.py: der Name eines Icons wie auf iOS, das Drawable dazu. */\n")
    f.write("fun lineIconRes(name: String): Int = when (name) {\n")
    for n, r in names:
        f.write(f'    "{n}" -> R.drawable.{r}\n')
    f.write('    else -> error("Unbekanntes Icon: $name")\n}\n')
print(len(names), "Icons, Logo und LineIcons.kt geschrieben")
