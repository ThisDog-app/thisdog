import base64, sys, math
geraet = sys.argv[1]
mi = "data:image/webp;base64," + base64.b64encode(open("maske-iphone.webp","rb").read()).decode()
mp = "data:image/webp;base64," + base64.b64encode(open("maske-ipad.webp","rb").read()).decode()
motive = [
  ("hund", "Alles für deinen Hund.", "Termine, Gesundheit, Gassi und Notfallpass in einer App."),
  ("notfall", "Wenn er wegläuft.", "Ein QR-Code am Halsband zeigt, wen man anrufen soll."),
  ("kalender", "Keine Impfung mehr vergessen.", "ThisDog erinnert dich rechtzeitig."),
  ("gassi", "Wer ist gerade draußen?", "Befreundete Hunde auf der Karte, solange ihr Gassi geht."),
  ("wissen", "Darf mein Hund …?", "273 Lebensmittel, mit Antwort und Begründung."),
  ("rudel", "Einer trägt ein. Alle wissen es.", "Lade Familie und Hundesitter ins Rudel ein."),
]
if geraet == "iphone":
    sw, sh = 660, 1434; dw = 0.80 * sw; ratio = 908/436; frame, mask = "rahmen-iphone.webp", mi
    scr = "left: 3.8991%; top: 1.8722%; width: 92.2018%; height: 96.2555%;"; h1, p = 76, 29
else:
    sw, sh = 1032, 1376; dw = 0.78 * sw; ratio = 1468/1124; frame, mask = "rahmen-ipad.webp", mp
    scr = "left: 4.0925%; top: 3.1335%; width: 91.8149%; height: 93.7330%;"; h1, p = 76, 30
W = sw * len(motive)
# Lage je Gerät: Versatz zur Mitte (Anteil der Breite), Neigung, Oberkante (Anteil der Höhe).
lage = [(-0.04, -5, 0.285), (0.16, 4, 0.31), (-0.08, -3, 0.29), (0.20, 6, 0.32), (-0.06, -4, 0.295), (0.04, 3, 0.30)]
devs, copy = [], []
for i, (bild, titel, unter) in enumerate(motive):
    dx, rot, top = lage[i]
    cx = sw * i + sw / 2 + dx * sw
    devs.append(f'<div class="dev" style="left:{cx - dw/2:.1f}px; top:{top*sh:.1f}px; rotate:{rot}deg"><div class="scr"><img src="{"roh" if geraet=="iphone" else "ipad"}-{bild}.png"></div><img class="frame" src="{frame}"></div>')
    copy.append(f'<div class="copy" style="left:{sw*i + sw*0.07:.1f}px; width:{sw*0.86:.1f}px"><h1>{titel}</h1><p>{unter}</p></div>')
# Die Leine: über jedem Gerät knapp unter der Überschrift, in den Lücken tief hinunter, am Ende die Locke.
pts = [(0, 0.55*sh)]
for i in range(len(motive)):
    pts.append((sw*i + sw*0.5, 0.245*sh + (0.012*sh if i % 2 else -0.004*sh)))
    if i < len(motive) - 1: pts.append((sw*(i+1) + lage[i][0]*sw*0.6, 0.86*sh))
d = f"M{pts[0][0]:.0f},{pts[0][1]:.0f}"
for a, b in zip(pts, pts[1:]):
    mx = (a[0] + b[0]) / 2
    d += f" C{mx:.0f},{a[1]:.0f} {mx:.0f},{b[1]:.0f} {b[0]:.0f},{b[1]:.0f}"
ex, ey = pts[-1]
k = sw / 660
# Nach dem letzten Gerät nach rechts, dann die Locke – in der Lücke zwischen Unterzeile und Gerät.
lx, ly = sw*5 + 0.84*sw, 0.262*sh
d += f" C{ex+60*k:.0f},{ey:.0f} {lx-70*k:.0f},{ly+30*k:.0f} {lx:.0f},{ly:.0f}"
d += f" C{lx+34*k:.0f},{ly-16*k:.0f} {lx+40*k:.0f},{ly-60*k:.0f} {lx+8*k:.0f},{ly-66*k:.0f} C{lx-22*k:.0f},{ly-72*k:.0f} {lx-30*k:.0f},{ly-36*k:.0f} {lx-4*k:.0f},{ly-28*k:.0f}"
dot = (lx-4*k, ly-28*k)
html = f'''<!doctype html><html lang="de"><meta charset="utf-8"><style>
@font-face {{ font-family: Bri; src: url(bricolage-grotesque-latin.woff2) format("woff2"); font-weight: 200 800; font-stretch: 75% 100%; }}
* {{ box-sizing: border-box; margin: 0; }}
html, body {{ width: {W}px; height: {sh}px; overflow: hidden; }}
body {{ background: #EE6A24; color: #fff; font-family: -apple-system, system-ui, sans-serif; position: relative; }}
.copy {{ position: absolute; top: {0.062*sh:.0f}px; text-align: center; z-index: 3; }}
h1 {{ font-family: Bri, system-ui; font-weight: 700; font-stretch: 84%; font-size: {h1}px; line-height: .98; letter-spacing: -0.02em; text-wrap: balance; }}
p {{ margin-top: 16px; font-size: {p}px; line-height: 1.3; opacity: .92; text-wrap: balance; }}
svg {{ position: absolute; inset: 0; z-index: 1; }}
.dev {{ position: absolute; width: {dw:.1f}px; height: {dw*ratio:.1f}px; z-index: 2; filter: drop-shadow(0 30px 40px rgba(60, 20, 0, .38)); }}
.frame {{ position: absolute; inset: 0; width: 100%; height: 100%; z-index: 2; }}
.scr {{ position: absolute; {scr} overflow: hidden; background: #000; -webkit-mask: url({mask}) 0 0 / 100% 100%; }}
.scr img {{ position: absolute; inset: 0; width: 100%; height: 100%; object-fit: cover; }}
</style><body>
<svg width="{W}" height="{sh}" viewBox="0 0 {W} {sh}"><path d="{d}" fill="none" stroke="#fff" stroke-width="{7*k:.1f}" stroke-linecap="round" opacity=".95"/><circle cx="{dot[0]:.0f}" cy="{dot[1]:.0f}" r="{13*k:.0f}" fill="#fff"/></svg>
{"".join(copy)}{"".join(devs)}
</body></html>'''
open(f"pano-{geraet}.html", "w").write(html)
print(W, sh)
