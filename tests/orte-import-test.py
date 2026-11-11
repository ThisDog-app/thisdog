#!/usr/bin/env python3
"""Prüft server/orte-import.py mit einer winzigen OSM-Datei und erfundenen Wiener Daten.
Aufruf: <python mit osmium> tests/orte-import-test.py"""
import importlib.util, os, sqlite3, sys, tempfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
spec = importlib.util.spec_from_file_location("imp", os.path.join(ROOT, "server", "orte-import.py"))
imp = importlib.util.module_from_spec(spec); spec.loader.exec_module(imp)

# Eine Hundezone als Fläche (eingezäunt) mit Trinkbrunnen, Bank und drei Bäumen; ein Park; eine Hundezone als Punkt.
OSM = """<?xml version='1.0' encoding='UTF-8'?>
<osm version="0.6"><bounds minlat="48.20" minlon="16.36" maxlat="48.24" maxlon="16.42"/>
<node id="1" lat="48.2200" lon="16.3900"/><node id="2" lat="48.2200" lon="16.3910"/>
<node id="3" lat="48.2207" lon="16.3910"/><node id="4" lat="48.2207" lon="16.3900"/>
<node id="10" lat="48.2203" lon="16.3905"><tag k="amenity" v="drinking_water"/></node>
<node id="11" lat="48.2204" lon="16.3906"><tag k="amenity" v="bench"/></node>
<node id="12" lat="48.2201" lon="16.3901"><tag k="natural" v="tree"/></node>
<node id="13" lat="48.2202" lon="16.3902"><tag k="natural" v="tree"/></node>
<node id="14" lat="48.2205" lon="16.3908"><tag k="natural" v="tree"/></node>
<node id="15" lat="48.2300" lon="16.4100"><tag k="amenity" v="bench"/></node>
<way id="100"><nd ref="1"/><nd ref="2"/><nd ref="3"/><nd ref="4"/><nd ref="1"/>
  <tag k="leisure" v="dog_park"/><tag k="barrier" v="fence"/></way>
<node id="21" lat="48.2250" lon="16.3750"/><node id="22" lat="48.2250" lon="16.3780"/>
<node id="23" lat="48.2270" lon="16.3780"/><node id="24" lat="48.2270" lon="16.3750"/>
<way id="200"><nd ref="21"/><nd ref="22"/><nd ref="23"/><nd ref="24"/><nd ref="21"/>
  <tag k="leisure" v="park"/><tag k="name" v="Augarten"/></way>
<node id="30" lat="48.2100" lon="16.4000"><tag k="leisure" v="dog_park"/><tag k="name" v="Hundezone Kanal"/></node>
</osm>"""

ZONES = [  # wie HUNDEZONEOGD
    {"properties": {"OBJECTID": 1, "PARK": "PA Augarten-Nord", "TYP": "Hundezone", "EINFRIEDUNG": "teilweise", "HUNDETRAENKE": "1", "FLAECHE": "ca. 1.750 m²"},
     "geometry": {"type": "Point", "coordinates": [16.3905, 48.22035]}},
    {"properties": {"OBJECTID": 2, "PARK": "Neue Zone", "TYP": "Hundeauslaufplatz", "EINFRIEDUNG": "ja", "HUNDETRAENKE": "keine", "FLAECHE": ""},
     "geometry": {"type": "Point", "coordinates": [16.4150, 48.2350]}},
    {"properties": {"OBJECTID": 3, "PARK": "Augarten", "TYP": "Hundeverbot", "EINFRIEDUNG": "ja", "HUNDETRAENKE": "keine", "FLAECHE": ""},
     "geometry": {"type": "Point", "coordinates": [16.3765, 48.2262]}},
]
FOUNTAINS = [{"properties": {"BASIS_TYP_TXT": "Trinkbrunnen mit Tränke"}, "geometry": {"type": "Point", "coordinates": [16.40002, 48.21002]}},
             {"properties": {"BASIS_TYP_TXT": "Zierbrunnen"}, "geometry": {"type": "Point", "coordinates": [16.3765, 48.2260]}}]

fails = 0
def check(name, got, want):
    global fails
    ok = got == want
    fails += not ok
    print(f"  {'✔' if ok else '✘'} {name}" + ("" if ok else f" (erwartet {want!r}, war {got!r})"))

with tempfile.TemporaryDirectory() as t:
    osm = os.path.join(t, "probe.osm"); open(osm, "w").write(OSM)
    db = sqlite3.connect(os.path.join(t, "p.sqlite"))
    db.executescript("""CREATE TABLE places (id TEXT PRIMARY KEY, name TEXT NOT NULL, kind TEXT NOT NULL, lat REAL NOT NULL, lon REAL NOT NULL,
                             off_leash INTEGER NOT NULL, fenced INTEGER NOT NULL, min_lat REAL, max_lat REAL, min_lon REAL, max_lon REAL);
        CREATE TABLE place_facts (place_id TEXT NOT NULL, key TEXT NOT NULL, value INTEGER NOT NULL, source TEXT NOT NULL, PRIMARY KEY (place_id, key));
        CREATE TABLE sources (name TEXT PRIMARY KEY, label TEXT, license TEXT, fetched_at INTEGER);
        CREATE TABLE regions (name TEXT PRIMARY KEY, min_lat REAL, max_lat REAL, min_lon REAL, max_lon REAL, data_at TEXT, imported_at INTEGER);""")
    n = imp.import_region(db, "probe", osm)
    facts = lambda pid: {k: (v, s) for k, v, s in db.execute("SELECT key, value, source FROM place_facts WHERE place_id = ?", (pid,))}
    print("Auszug")
    check("Drei Orte", n, 3)
    check("Hundezone: Zaun, Freilauf, Wasser, Bank, Schatten aus der Umgebung",
          {k: v for k, (v, _) in facts("way/100").items()}, {"off_leash": 1, "fenced": 1, "water": 1, "bench": 1, "shade": 1})
    check("Bank 1 km entfernt zählt nicht beim Park", "bench" in facts("way/200"), False)
    print("Wien")
    m, a, b, w = imp.import_wien(db, ZONES, FOUNTAINS)
    check("Zugeordnet, neu, Verbotszone, Trinkbrunnen", (m, a, b, w), (1, 1, 1, 1))
    check("Namenlose Hundezone heißt nach dem Park", db.execute("SELECT name FROM places WHERE id='way/100'").fetchone()[0], "Hundezone Augarten-Nord")
    check("Stadt ersetzt OSM: teilweise eingezäunt, Tränke, Fläche",
          {k: facts("way/100")[k] for k in ("fenced", "water_bowl", "area")}, {"fenced": (2, "wien"), "water_bowl": (1, "wien"), "area": (1750, "wien")})
    check("Fehlende Zone kommt dazu", db.execute("SELECT name, fenced FROM places WHERE id='wien/2'").fetchone(), ("Hundeauslaufplatz Neue Zone", 1))
    check("Verbotszone als Hinweis am Park", facts("way/200").get("no_dogs_area"), (1, "wien"))
    check("Tränke am Punkt Hundezone Kanal", facts("node/30").get("water_bowl"), (1, "wien"))
    check("Zierbrunnen ist kein Trinkwasser", "water" in facts("way/200"), False)

print("Alles bestanden." if not fails else "FEHLGESCHLAGEN")
sys.exit(1 if fails else 0)
