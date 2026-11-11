#!/usr/bin/env python3
"""
Ziele für die Gassirunde aus OpenStreetMap: Hundezonen, Parks, Wälder, Wiesen.

Lädt die Auszüge von Geofabrik, filtert dieselben Arten wie api/places.php und schreibt sie in eine
neue `places.sqlite`, die die alte erst ersetzt, wenn alles durchgelaufen ist. Eigene Orte stehen
nicht hier, sondern in app.sqlite (Tabelle own_places) – ein Import kann sie nicht überschreiben.

    orte-import.py <DATA_DIR> [region …]      Regionen wie bei Geofabrik: europe/germany, europe/austria

Läuft einmal im Monat per Cron. Ohne Region: Deutschland, Österreich, Schweiz. Mit Österreich kommen die
offenen Daten der Stadt Wien dazu (Hundezonen, Hundeverbotszonen, Trinkbrunnen; CC BY 4.0).

Merkmale (place_facts) aus den Tags und aus dem, was in einem Ort steht: Freilaufen, Zaun, Rasen, Licht,
Trinkwasser, Bänke, Schatten (Wald oder mindestens drei Bäume), Sackerlspender, Mistkübel.
"""
import json
import math
import os
import resource
import sqlite3
import sys
import time
import urllib.request

import osmium

REGIONS = ["europe/germany", "europe/austria", "europe/switzerland"]
GEOFABRIK = "https://download.geofabrik.de/{}-latest.osm.pbf"

# Wie KINDS in api/places.php: Schlüssel, Bezeichnung, Rang (kleiner = wichtiger).
KINDS = [
    ("leisure", "dog_park", "dog_park", "Hundezone", 0),
    ("leisure", "park", "park", "Park", 1),
    ("landuse", "forest", "forest", "Wald", 2),
    ("natural", "wood", "wood", "Wald", 2),
    ("leisure", "nature_reserve", "nature_reserve", "Naturschutzgebiet", 2),
    ("landuse", "meadow", "meadow", "Wiese", 3),
]
TAGS = [(k, v) for k, v, *_ in KINDS]


def kind_of(tags):
    for k, v, key, label, rank in KINDS:
        if tags.get(k) == v:
            return key
    return None


def download(region, folder):
    path = os.path.join(folder, region.replace("/", "-") + ".osm.pbf")
    if os.path.exists(path) and time.time() - os.path.getmtime(path) < 86400:
        return path  # heute schon geladen (abgebrochener Lauf)
    req = urllib.request.Request(GEOFABRIK.format(region), headers={"User-Agent": "ThisDog/1.0 (+https://thisdog.app)"})
    with urllib.request.urlopen(req, timeout=120) as r, open(path + ".teil", "wb") as f:
        while chunk := r.read(1 << 20):
            f.write(chunk)
    os.replace(path + ".teil", path)
    return path


# Je Weg nur so viele Stützpunkte: Für die Mitte des umschließenden Rechtecks reicht eine Stichprobe,
# und der Speicher bleibt klein (das Hosting beendet Prozesse, die länger rund 2 GB belegen).
SAMPLE = 12


def sample(refs, n):
    if len(refs) <= n:
        return list(refs)
    step = len(refs) / n
    return [refs[int(i * step)] for i in range(n)]


def wanted(tags):
    """Art, Name, frei laufen, eingezäunt – oder None, wenn das kein Ziel ist."""
    key = kind_of(tags)
    if key is None or tags.get("dog") == "no":
        return None  # Hunde ausdrücklich verboten: als Ziel unbrauchbar
    name = (tags.get("name") or "").strip()
    if not name:
        if key != "dog_park":
            return None  # namenlose Flächen sind in der Stadt meist Verkehrsinseln
        name = "Hundezone"
    off_leash = 1 if tags.get("dog") == "unleashed" or key == "dog_park" else 0
    fenced = 1 if tags.get("barrier") == "fence" or tags.get("fenced") == "yes" else 0
    return key, name, off_leash, fenced


# Merkmale eines Ortes (place_facts): Schlüssel wie in der App. Wert 1 = gibt es, 0 = gibt es nicht,
# 2 = teilweise (nur eingezäunt, aus den Wiener Daten). Fehlt ein Schlüssel, weiß niemand etwas.
def tag_facts(key, tags):
    f = {}
    dog = tags.get("dog")
    if key == "dog_park" or dog == "unleashed": f["off_leash"] = 1
    elif dog == "leashed": f["off_leash"] = 0
    if tags.get("barrier") == "fence" or tags.get("fenced") == "yes": f["fenced"] = 1
    elif tags.get("fenced") == "no": f["fenced"] = 0
    surface = tags.get("surface")
    if surface == "grass": f["grass"] = 1
    elif surface in ("sand", "gravel", "fine_gravel", "dirt", "compacted", "ground", "woodchips"): f["grass"] = 0
    if tags.get("lit") in ("yes", "no"): f["lit"] = 1 if tags["lit"] == "yes" else 0
    if tags.get("drinking_water") == "yes": f["water"] = 1
    if key in ("forest", "wood"): f["shade"] = 1
    return f


# Was in einem Ort (oder höchstens 25 m daneben) steht. Bäume zählen erst ab drei als Schatten.
NEARBY = {("amenity", "drinking_water"): "water", ("amenity", "bench"): "bench", ("leisure", "picnic_table"): "bench",
          ("natural", "tree"): "tree", ("vending", "excrement_bags"): "bags", ("amenity", "waste_basket"): "bin"}
MARGIN = 25          # Meter um das umschließende Rechteck
POINT_RADIUS = 40    # Meter um eine Hundezone, die nur als Punkt eingetragen ist
CELL = 0.01          # Raster für die Zuordnung (rund 1 km)
MAX_CELLS = 100      # größere Flächen (weite Wälder) bekommen keine Umgebungsmerkmale


def grow(box, meters):
    lat_m = meters / 111320
    lon_m = meters / (111320 * max(0.2, math.cos(math.radians((box[0] + box[1]) / 2))))
    return (box[0] - lat_m, box[1] + lat_m, box[2] - lon_m, box[3] + lon_m)


def import_region(db, region, pbf):
    """Vier Durchläufe ohne Flächenaufbau im Speicher: Relationen, Wege, gebrauchte Punkte, Dinge in der Nähe."""
    header = osmium.io.Reader(pbf, osmium.osm.osm_entity_bits.NOTHING).header()
    box = header.box()
    stamp = header.get("osmosis_replication_timestamp", "")
    filt = osmium.filter.TagFilter(*TAGS)

    owners = []        # [oid, (key, name, off_leash, fenced), [Knoten-IDs], Merkmale]
    member_of = {}     # Weg-ID → Index in owners (Außenring einer Multipolygon-Relation)
    for rel in osmium.FileProcessor(pbf, osmium.osm.RELATION).with_filter(filt):
        if rel.tags.get("type") not in ("multipolygon", "boundary"):
            continue
        w = wanted(rel.tags)
        if w is None:
            continue
        owners.append(["relation/" + str(rel.id), w, [], tag_facts(w[0], rel.tags)])
        for m in rel.members:
            if m.type == "w" and m.role in ("outer", ""):
                member_of.setdefault(m.ref, len(owners) - 1)

    # Eine einfache Menge statt osmium.IdTracker: Der legt eine Bitmap über alle Knoten-IDs an (rund 1,6 GB).
    need = set()
    for way in osmium.FileProcessor(pbf, osmium.osm.WAY):
        idx = member_of.get(way.id)
        if idx is not None:
            refs = sample([n.ref for n in way.nodes], 4)
            owners[idx][2].extend(refs)
        elif way.tags and kind_of(way.tags) is not None:
            w = wanted(way.tags)
            if w is None or len(way.nodes) < 3:
                continue
            refs = sample([n.ref for n in way.nodes], SAMPLE)
            owners.append(["way/" + str(way.id), w, refs, tag_facts(w[0], way.tags)])
        else:
            continue
        for r in refs:
            need.add(r)

    # Ein Durchlauf über alle Knoten: die gebrauchten Stützpunkte und einzelne Punkte (eine Hundezone als Punkt).
    # Ohne osmium.filter.IdFilter – der baut intern ebenfalls eine Bitmap über alle IDs.
    where = {}
    points = []
    for node in osmium.FileProcessor(pbf, osmium.osm.NODE):
        if node.id in need and node.location.valid():
            where[node.id] = (node.location.lat, node.location.lon)
        if node.tags and node.location.valid():
            w = wanted(node.tags)
            if w is not None:
                points.append(["node/" + str(node.id), w, (node.location.lat, node.location.lon), tag_facts(w[0], node.tags)])
    need = None

    # Orte mit Rechteck: (oid, w, (min_lat, max_lat, min_lon, max_lon), Merkmale)
    found = []
    for oid, w, refs, facts in owners:
        pts = [where[r] for r in refs if r in where]
        if pts:
            lats = [p[0] for p in pts]; lons = [p[1] for p in pts]
            found.append((oid, w, (min(lats), max(lats), min(lons), max(lons)), facts))
    for oid, w, (lat, lon), facts in points:
        found.append((oid, w, grow((lat, lat, lon, lon), POINT_RADIUS - MARGIN), facts))
    owners = where = points = None

    # Dinge in der Nähe: Raster über die vergrößerten Rechtecke, dann ein gefilterter Durchlauf über die Knoten.
    grid = {}
    for i, (_, _, b, _) in enumerate(found):
        g = grow(b, MARGIN)
        cells = [(la, lo) for la in range(math.floor(g[0] / CELL), math.floor(g[1] / CELL) + 1)
                 for lo in range(math.floor(g[2] / CELL), math.floor(g[3] / CELL) + 1)]
        if len(cells) > MAX_CELLS:
            continue
        for c in cells:
            grid.setdefault(c, []).append(i)
    trees = {}
    near_filter = osmium.filter.KeyFilter("amenity", "natural", "vending", "leisure")
    for node in osmium.FileProcessor(pbf, osmium.osm.NODE).with_filter(near_filter):
        what = next((v for (k, val), v in NEARBY.items() if node.tags.get(k) == val), None)
        if what is None or not node.location.valid():
            continue
        lat, lon = node.location.lat, node.location.lon
        for i in grid.get((math.floor(lat / CELL), math.floor(lon / CELL)), ()):
            g = grow(found[i][2], MARGIN)
            if g[0] <= lat <= g[1] and g[2] <= lon <= g[3]:
                if what == "tree":
                    trees[i] = trees.get(i, 0) + 1
                else:
                    found[i][3].setdefault(what, 1)
    for i, n in trees.items():
        if n >= 3:
            found[i][3].setdefault("shade", 1)

    seen = set()
    rows, facts_rows = [], []
    for oid, (key, name, off_leash, fenced), b, facts in found:
        lat, lon = round((b[0] + b[1]) / 2, 5), round((b[2] + b[3]) / 2, 5)
        # Dieselbe Anlage steckt oft mehrfach in den Daten – als Fläche und als Punkt.
        dup = (name, round(lat, 3), round(lon, 3))
        if dup in seen:
            continue
        seen.add(dup)
        rows.append((oid, name, key, lat, lon, off_leash, fenced, b[0], b[1], b[2], b[3]))
        facts_rows.extend((oid, k, v, "osm") for k, v in facts.items())

    db.executemany("INSERT OR IGNORE INTO places VALUES (?,?,?,?,?,?,?,?,?,?,?)", rows)
    db.executemany("INSERT OR IGNORE INTO place_facts VALUES (?,?,?,?)", facts_rows)
    db.execute("INSERT OR REPLACE INTO regions VALUES (?,?,?,?,?,?,?)",
               (region, box.bottom_left.lat, box.top_right.lat, box.bottom_left.lon, box.top_right.lon, stamp, int(time.time())))
    db.commit()
    return len(rows)


# ---------------------------------------------------------------- Wien (offene Daten, CC BY 4.0)

WIEN_WFS = ("https://data.wien.gv.at/daten/geo?service=WFS&request=GetFeature&version=1.1.0"
            "&typeName=ogdwien:{}&srsName=EPSG:4326&outputFormat=json")


def fetch_json(url):
    req = urllib.request.Request(url, headers={"User-Agent": "ThisDog/1.0 (+https://thisdog.app)"})
    with urllib.request.urlopen(req, timeout=120) as r:
        return json.load(r)


def meters(lat1, lon1, lat2, lon2):
    return 6371000 * math.hypot(math.radians(lat2 - lat1), math.radians(lon2 - lon1) * math.cos(math.radians(lat1)))


def park_name(raw):
    """„PA Paltramplatz“ → „Paltramplatz“ (PA = Parkanlage)."""
    raw = (raw or "").strip()
    return raw[3:].strip() if raw.startswith("PA ") else raw


def set_fact(db, pid, key, value):
    # Die Stadt weiß es genauer als OpenStreetMap: ihr Wert ersetzt den aus dem Auszug.
    db.execute("INSERT OR REPLACE INTO place_facts VALUES (?,?,?,'wien')", (pid, key, value))


def import_wien(db, zones=None, fountains=None):
    """Hundezonen (eingezäunt, Tränke, Fläche, Name), Hundeverbotszonen und Trinkbrunnen der Stadt Wien."""
    zones = zones if zones is not None else fetch_json(WIEN_WFS.format("HUNDEZONEOGD"))["features"]
    fountains = fountains if fountains is not None else fetch_json(WIEN_WFS.format("TRINKBRUNNENOGD"))["features"]
    matched = added = banned = 0

    def nearest(lat, lon, radius, kinds):
        d = radius / 111320
        rows = db.execute(f"SELECT id, name, lat, lon FROM places WHERE kind IN ({','.join('?' * len(kinds))}) "
                          "AND lat BETWEEN ? AND ? AND lon BETWEEN ? AND ?", (*kinds, lat - d, lat + d, lon - 2 * d, lon + 2 * d)).fetchall()
        rows = [(meters(lat, lon, r[2], r[3]), r) for r in rows]
        rows = [r for r in rows if r[0] <= radius]
        return [r[1] for r in sorted(rows)]

    for f in zones:
        p = f["properties"]; lon, lat = f["geometry"]["coordinates"][:2]
        typ, park = p.get("TYP"), park_name(p.get("PARK"))
        if typ == "Hundeverbot":
            # Ein Verbot gilt meist für einen Teil des Parks (Spielplatz, Liegewiese) – als Hinweis am Park.
            for pid, name, *_ in nearest(lat, lon, 300, ("park",)):
                if park and (park.lower() in name.lower() or name.lower() in park.lower()):
                    set_fact(db, pid, "no_dogs_area", 1); banned += 1
                    break
            continue
        if typ not in ("Hundezone", "Hundeauslaufplatz"):
            continue
        label = "Hundeauslaufplatz" if typ == "Hundeauslaufplatz" else "Hundezone"
        hit = nearest(lat, lon, 120, ("dog_park",))
        if hit:
            pid, name = hit[0][0], hit[0][1]
            if name == "Hundezone" and park:
                db.execute("UPDATE places SET name = ? WHERE id = ?", (f"{label} {park}", pid))
            matched += 1
        else:
            pid = f"wien/{p['OBJECTID']}"
            db.execute("INSERT OR IGNORE INTO places VALUES (?,?,?,?,?,?,?,?,?,?,?)",
                       (pid, f"{label} {park}".strip(), "dog_park", round(lat, 5), round(lon, 5), 1, 0, *grow((lat, lat, lon, lon), POINT_RADIUS - MARGIN)))
            added += 1
        set_fact(db, pid, "off_leash", 1)
        fence = {"ja": 1, "nein": 0, "teilweise": 2}.get((p.get("EINFRIEDUNG") or "").strip())
        if fence is not None:
            set_fact(db, pid, "fenced", fence)
            db.execute("UPDATE places SET fenced = ? WHERE id = ?", (1 if fence == 1 else 0, pid))
        bowls = str(p.get("HUNDETRAENKE") or "").strip()
        if bowls.isdigit() and int(bowls) > 0:
            set_fact(db, pid, "water", 1); set_fact(db, pid, "water_bowl", 1)
        area = "".join(ch for ch in str(p.get("FLAECHE") or "").split("m")[0] if ch in "0123456789")
        if area:
            set_fact(db, pid, "area", int(area))

    water = 0
    for f in fountains:
        lon, lat = f["geometry"]["coordinates"][:2]
        typ = f["properties"].get("BASIS_TYP_TXT") or ""
        if not (typ.startswith("Trinkbrunnen") or typ.startswith("Trinkhydrant") or typ.startswith("Auslaufbrunnen") or typ == "Hundetrinkbrunnen"):
            continue  # Zier-, Spiel- und Sprühbrunnen sind kein Trinkwasser für Hunde
        d = MARGIN / 111320
        for (pid,) in db.execute("SELECT id FROM places WHERE min_lat - ? <= ? AND max_lat + ? >= ? AND min_lon - ? <= ? AND max_lon + ? >= ?",
                                 (d, lat, d, lat, 2 * d, lon, 2 * d, lon)).fetchall():
            set_fact(db, pid, "water", 1); water += 1
            if "Tränke" in typ or typ == "Hundetrinkbrunnen":
                set_fact(db, pid, "water_bowl", 1)
    db.execute("INSERT OR REPLACE INTO sources VALUES ('wien', 'Stadt Wien – data.wien.gv.at', 'CC BY 4.0', ?)", (int(time.time()),))
    db.commit()
    return matched, added, banned, water


def main():
    data_dir = sys.argv[1]
    regions = sys.argv[2:] or REGIONS
    work = os.path.join(data_dir, "osm")
    os.makedirs(work, exist_ok=True)
    new = os.path.join(data_dir, "places-neu.sqlite")
    if os.path.exists(new):
        os.remove(new)
    db = sqlite3.connect(new)
    db.executescript("""
        CREATE TABLE places (id TEXT PRIMARY KEY, name TEXT NOT NULL, kind TEXT NOT NULL, lat REAL NOT NULL, lon REAL NOT NULL,
                             off_leash INTEGER NOT NULL, fenced INTEGER NOT NULL,
                             min_lat REAL, max_lat REAL, min_lon REAL, max_lon REAL);
        CREATE TABLE place_facts (place_id TEXT NOT NULL, key TEXT NOT NULL, value INTEGER NOT NULL, source TEXT NOT NULL,
                                  PRIMARY KEY (place_id, key));
        CREATE TABLE sources (name TEXT PRIMARY KEY, label TEXT, license TEXT, fetched_at INTEGER);
        CREATE TABLE regions (name TEXT PRIMARY KEY, min_lat REAL, max_lat REAL, min_lon REAL, max_lon REAL, data_at TEXT, imported_at INTEGER);
    """)
    for region in regions:
        t = time.time()
        pbf = download(region, work)
        n = import_region(db, region, pbf)
        os.remove(pbf)
        print(f"{region}: Speicher zuletzt {resource.getrusage(resource.RUSAGE_SELF).ru_maxrss // 1024} MB", flush=True)
        print(f"{region}: {n} Orte in {time.time() - t:.0f} s", flush=True)
    db.execute("CREATE INDEX places_pos ON places(lat, lon)")
    db.execute("CREATE INDEX places_box ON places(min_lat, max_lat)")
    if "europe/austria" in regions:
        try:
            m, a, b, w = import_wien(db)
            print(f"Wien: {m} Hundezonen zugeordnet, {a} neu, {b} Parks mit Hundeverbotszone, {w} Trinkbrunnen", flush=True)
        except Exception as e:  # Ohne die Wiener Daten bleibt der Auszug brauchbar.
            print(f"Wien: nicht geladen ({e})", flush=True)
    db.commit()
    db.close()
    # Erst jetzt die alte Datei ersetzen: Bricht der Import ab, bleibt die vorige gültig.
    os.replace(new, os.path.join(data_dir, "places.sqlite"))


if __name__ == "__main__":
    main()
