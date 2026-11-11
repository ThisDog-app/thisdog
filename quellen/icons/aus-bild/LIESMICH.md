# Nachgezeichnet aus dem Icon-Blatt

45 Zeichen aus `Gemini_Generated_Image_5clzoe5clzoe5clz.jpeg` (2816 × 1536),
maschinell nachgezeichnet – nicht neu entworfen.

## Wie

Die Zeilen- und Spaltengrenzen wurden aus dem Bild gemessen, nicht geschätzt:
Über die mittlere Helligkeit je Zeile und Spalte lassen sich die leeren
Streifen zwischen den Zeichen eindeutig finden. Jede Zelle wurde einzeln
freigestellt, auf Schwarzweiß gebracht, auf 200 % vergrößert und mit
`potrace` in Kurven übersetzt.

Die Vergrößerung vor dem Nachzeichnen ist der Grund, warum aus Treppenstufen
runde Kurven werden. 400 % brachte darüber hinaus keinen sichtbaren Gewinn
mehr, kostete aber das Vierfache an Dateigröße.

Nachgemessen: Die Kurven decken die Vorlage zu 101 % ab – die Striche sind
also weder dicker noch dünner geworden.

## Form

Es sind Flächen, keine Striche: `potrace` zeichnet den Umriss einer Linie
nach, nicht die Linie selbst. Deshalb lässt sich die Strichstärke nachträglich
nicht ändern – anders als bei Konturicons, die eine `stroke-width` tragen.

Der Rahmen sitzt quadratisch um das Motiv, mittig, mit 12 % Luft. So wirken
hoch- und querformatige Zeichen gleich groß.

Gefüllt ist `currentColor`, die Zeichen nehmen also die Textfarbe an.

## Nicht dabei: der Pudel

Auf dem Blatt steht er in Zelle 1-4. Er ist die Marke der App und liegt in der
Fassung, aus der auch das App-Icon stammt, als `website/media/stella-mark.svg`
und `ios/ThisDog/Assets.xcassets/StellaMark.imageset/`. Eine nachgezeichnete Kopie wäre schlechter als das Original
und würde es früher oder später ersetzen. Deshalb liegt sie hier nicht.

## Doppelt

Vier Zeichen kommen zweimal vor, mit kleinen Abweichungen:
`plus` / `plus-2`, `download` / `download-2`, `worm` / `worm-2`,
`clock` / `clock-dial`. Beide Fassungen sind erhalten.
