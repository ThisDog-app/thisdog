# Bilder für den App Store

`bilder/` enthält die fertigen Bildschirmfotos: sechs für das 6,9-Zoll-iPhone (1320 × 2868) und sechs für das 13-Zoll-iPad (2064 × 2752). Sie entstehen als ein Panorama, das eine Leine verbindet, und werden danach in sechs Bilder geschnitten.

So entstehen sie neu:

1. Aufnahmen aus dem Simulator mit Vorführdaten, z. B. `-beispiel -hundefoto <Foto> -rudeldemo -tab hund` (iPhone 18 Pro Max; iPad Pro 13 im Hochformat, notfalls mit dem UI-Test „Aufnahmen“ und `AUFNAHME_LAGE=hoch`). Dateinamen: `roh-<motiv>.png` (iPhone) bzw. `ipad-<motiv>.png`.
2. Daneben legen: `rahmen-iphone.webp`, `maske-iphone.webp`, `rahmen-ipad.webp`, `maske-ipad.webp` (aus `website/media`) und `bricolage-grotesque-latin.woff2` (aus `public/fonts`).
3. `python3 quelle/pano.py iphone` bzw. `ipad` schreibt `pano-<gerät>.html`. In WebKit in voller Breite rendern (3960 × 1434 bzw. 6192 × 1376 Punkte, doppelte Auflösung) und in sechs gleich breite Bilder schneiden.
