<?php
declare(strict_types=1);

/**
 * Ziele für die Gassirunde: Arten, eigener OpenStreetMap-Auszug (places.sqlite) und eigene Orte.
 * Gebraucht von places.php (App) und admin-orte.php (Betreiber).
 */

require_once __DIR__ . '/lib.php';

/** Abgefragter Umkreis um den Zellmittelpunkt – größer als die Zelle. */
const QUERY_RADIUS = 3500;

/**
 * Was gesucht wird. Namenlose Flächen fallen schon in der Abfrage weg – in
 * der Stadt sind das überwiegend Verkehrsinseln. Hundezonen dürfen namenlos
 * bleiben, die sind auch so ein Ziel.
 */
const KINDS = [
	['key' => 'dog_park', 'label' => 'Hundezone', 'rank' => 0, 'filter' => '["leisure"="dog_park"]', 'anon' => true],
	['key' => 'park', 'label' => 'Park', 'rank' => 1, 'filter' => '["leisure"="park"]'],
	['key' => 'forest', 'label' => 'Wald', 'rank' => 2, 'filter' => '["landuse"="forest"]'],
	['key' => 'wood', 'label' => 'Wald', 'rank' => 2, 'filter' => '["natural"="wood"]'],
	['key' => 'nature_reserve', 'label' => 'Naturschutzgebiet', 'rank' => 2, 'filter' => '["leisure"="nature_reserve"]'],
	['key' => 'meadow', 'label' => 'Wiese', 'rank' => 3, 'filter' => '["landuse"="meadow"]'],
];

/* ============================ Eigener Auszug ============================ */

/** Rechteck um einen Punkt, das den Abfrageradius sicher enthält. */
function around_box(float $lat, float $lon): array
{
	$dLat = QUERY_RADIUS / 111320;
	$dLon = QUERY_RADIUS / (111320 * max(0.1, cos(deg2rad($lat))));
	return [$lat - $dLat, $lat + $dLat, $lon - $dLon, $lon + $dLon];
}

function distance_m(float $lat1, float $lon1, float $lat2, float $lon2): float
{
	$p1 = deg2rad($lat1); $p2 = deg2rad($lat2);
	$h = sin(($p2 - $p1) / 2) ** 2 + cos($p1) * cos($p2) * sin(deg2rad($lon2 - $lon1) / 2) ** 2;
	return 2 * 6371000 * asin(min(1.0, sqrt($h)));
}

/** Ein Ort im Format der App aus einer Zeile von places.sqlite oder own_places. */
function place_row(array $r, string $id): ?array
{
	$kind = null;
	foreach (KINDS as $k) if ($k['key'] === $r['kind']) $kind = $k;
	if ($kind === null) return null;
	return [
		'id' => $id,
		'name' => (string) $r['name'],
		'kind' => $kind['key'],
		'label' => $kind['label'],
		'rank' => $kind['rank'],
		'lat' => round((float) $r['lat'], 5),
		'lon' => round((float) $r['lon'], 5),
		'offLeash' => (bool) $r['off_leash'],
		'fenced' => (bool) $r['fenced'],
	];
}

/**
 * Orte aus places.sqlite im Abfrageradius. Null, wenn es die Datei nicht gibt, die Gegend nicht
 * importiert ist oder dort nichts verzeichnet ist – dann fragt places.php Overpass.
 */
function extract_places(float $lat, float $lon): ?array
{
	$path = data_file('places.sqlite');
	if (!is_file($path)) return null;
	$x = new PDO('sqlite:' . $path, null, null, [PDO::ATTR_ERRMODE => PDO::ERRMODE_EXCEPTION, PDO::ATTR_DEFAULT_FETCH_MODE => PDO::FETCH_ASSOC]);
	$covered = $x->prepare('SELECT 1 FROM regions WHERE ? BETWEEN min_lat AND max_lat AND ? BETWEEN min_lon AND max_lon');
	$covered->execute([$lat, $lon]);
	if (!$covered->fetchColumn()) return null;

	[$a, $b, $c, $d] = around_box($lat, $lon);
	$q = $x->prepare('SELECT * FROM places WHERE lat BETWEEN ? AND ? AND lon BETWEEN ? AND ?');
	$q->execute([$a, $b, $c, $d]);
	$out = [];
	foreach ($q as $r) {
		$dist = distance_m($lat, $lon, (float) $r['lat'], (float) $r['lon']);
		if ($dist > QUERY_RADIUS) continue;
		$p = place_row($r, (string) $r['id']);
		if ($p !== null) $out[] = [$dist, $p];
	}
	if (!$out) return null;
	// Wie bei Overpass höchstens 200 je Abfrage – die nächsten.
	usort($out, fn($m, $n) => $m[0] <=> $n[0]);
	$places = array_map(fn($e) => $e[1], array_slice($out, 0, 200));
	return with_facts($x, $places);
}

/**
 * Merkmale aus place_facts: `facts` = {Schlüssel: {v, src}}. v: 1 gibt es, 0 gibt es nicht, 2 teilweise;
 * `area` in m². src: osm (OpenStreetMap), wien (Stadt Wien), eigen. Ältere Auszüge ohne Tabelle: keine Merkmale.
 */
function with_facts(PDO $x, array $places): array
{
	if (!$places) return $places;
	try {
		$ids = array_column($places, 'id');
		$q = $x->prepare('SELECT place_id, key, value, source FROM place_facts WHERE place_id IN (' . implode(',', array_fill(0, count($ids), '?')) . ')');
		$q->execute($ids);
	} catch (PDOException $e) {
		return $places;
	}
	$facts = [];
	foreach ($q as $r) $facts[$r['place_id']][$r['key']] = ['v' => (int) $r['value'], 'src' => $r['source']];
	foreach ($places as &$p) {
		if (isset($facts[$p['id']])) $p['facts'] = $facts[$p['id']];
	}
	return $places;
}

/**
 * Zählungen der Bewertungen je Ort: `votes` = {Merkmal: [ja, nein]}, `voters` = wie viele Konten bewertet
 * haben, `sizes` = [kleine, mittlere, große] (wie viele das jeweils angaben).
 */
function place_votes(PDO $pdo, array $ids): array
{
	if (!$ids) return [];
	$in = implode(',', array_fill(0, count($ids), '?'));
	$out = [];
	$q = $pdo->prepare("SELECT place_id, key, SUM(value = 1) AS ja, SUM(value = 0) AS nein FROM place_votes WHERE place_id IN ($in) GROUP BY place_id, key");
	$q->execute($ids);
	foreach ($q as $r) $out[$r['place_id']]['votes'][$r['key']] = [(int) $r['ja'], (int) $r['nein']];
	$q = $pdo->prepare("SELECT place_id, COUNT(DISTINCT account_id) AS n FROM (SELECT place_id, account_id FROM place_votes WHERE place_id IN ($in)
		UNION SELECT place_id, account_id FROM place_sizes WHERE place_id IN ($in)) GROUP BY place_id");
	$q->execute([...$ids, ...$ids]);
	foreach ($q as $r) $out[$r['place_id']]['voters'] = (int) $r['n'];
	$q = $pdo->prepare("SELECT place_id, SUM(small) AS s, SUM(medium) AS m, SUM(large) AS l FROM place_sizes WHERE place_id IN ($in) GROUP BY place_id");
	$q->execute($ids);
	foreach ($q as $r) $out[$r['place_id']]['sizes'] = [(int) $r['s'], (int) $r['m'], (int) $r['l']];
	foreach ($out as &$o) $o += ['votes' => (object) [], 'voters' => 0, 'sizes' => [0, 0, 0]];
	return $out;
}

/** Bewertungen an die Orte hängen (nur, wo es welche gibt). */
function with_votes(PDO $pdo, array $places): array
{
	$all = place_votes($pdo, array_column($places, 'id'));
	foreach ($places as &$p) {
		if (isset($all[$p['id']])) $p += $all[$p['id']];
	}
	return $places;
}

/** Eigene Orte dazu; was sie ersetzen oder ausblenden, fällt weg. */
function with_own(PDO $pdo, array $places, float $lat, float $lon): array
{
	[$a, $b, $c, $d] = around_box($lat, $lon);
	$q = $pdo->prepare('SELECT * FROM own_places WHERE lat BETWEEN ? AND ? AND lon BETWEEN ? AND ?');
	$q->execute([$a, $b, $c, $d]);
	$own = $q->fetchAll();
	if (!$own) return $places;
	$hidden = array_filter(array_map(fn($r) => $r['replaces'], $own));
	$places = array_values(array_filter($places, fn($p) => !in_array($p['id'], $hidden, true)));
	foreach ($own as $r) {
		if (trim((string) $r['name']) === '') continue;  // nur ausblenden
		if (distance_m($lat, $lon, (float) $r['lat'], (float) $r['lon']) > QUERY_RADIUS) continue;
		$p = place_row($r, 'eigen/' . $r['id']);
		if ($p === null) continue;
		// Bei eigenen Orten steht nur, was angekreuzt wurde: ein fehlendes Häkchen heißt „weiß nicht“.
		$f = [];
		if ($p['offLeash']) $f['off_leash'] = ['v' => 1, 'src' => 'eigen'];
		if ($p['fenced']) $f['fenced'] = ['v' => 1, 'src' => 'eigen'];
		if ($f) $p['facts'] = $f;
		if (!empty($r['by_user'])) $p['byUser'] = true;
		$places[] = $p;
	}
	return $places;
}


/** Name und Lage eines Ortes, egal ob aus dem Auszug oder eigen (für die Admin-Seite). */
function place_lookup(PDO $pdo, string $id): ?array
{
	if (str_starts_with($id, 'eigen/')) {
		$q = $pdo->prepare('SELECT name, kind, lat, lon FROM own_places WHERE id = ?');
		$q->execute([(int) substr($id, 6)]);
		$r = $q->fetch();
		return $r ?: null;
	}
	$path = data_file('places.sqlite');
	if (!is_file($path)) return null;
	$x = new PDO('sqlite:' . $path, null, null, [PDO::ATTR_DEFAULT_FETCH_MODE => PDO::FETCH_ASSOC]);
	$q = $x->prepare('SELECT name, kind, lat, lon FROM places WHERE id = ?');
	$q->execute([$id]);
	$r = $q->fetch();
	return $r ?: null;
}

/* ============================ Fotos und Prüfungen ============================ */

/** So weit darf eine Prüfung vom Ort entfernt sein (Parks werden mit ihrer Mitte geführt). */
const CHECK_REACH = 300;

function photo_dir(): string
{
	$dir = data_dir() . '/fotos';
	if (!is_dir($dir)) mkdir($dir, 0700, true);
	return $dir;
}

/**
 * Ein hochgeladenes Bild neu kodieren: höchstens 1600 px, WebP, ohne Metadaten (auch ohne den Aufnahmeort).
 * Gibt [Datei, Breite, Höhe] zurück oder null, wenn es kein Bild ist.
 */
function store_photo(string $tmp): ?array
{
	$info = @getimagesize($tmp);
	if (!$info || !in_array($info[2], [IMAGETYPE_JPEG, IMAGETYPE_PNG, IMAGETYPE_WEBP, -1], true)) {
		if (!$info || !in_array($info[2], [IMAGETYPE_JPEG, IMAGETYPE_PNG, IMAGETYPE_WEBP], true)) return null;
	}
	// Erst die Maße, dann entpacken: Ein winziges PNG mit riesigen Maßen belegte sonst Gigabytes Speicher.
	if ((int) $info[0] * (int) $info[1] > 50_000_000) return null;
	$src = @imagecreatefromstring((string) file_get_contents($tmp));
	if (!$src) return null;
	// Hochformat-Fotos vom Telefon tragen die Drehung oft nur in den Metadaten.
	if ($info[2] === IMAGETYPE_JPEG && function_exists('exif_read_data')) {
		$o = (int) (@exif_read_data($tmp)['Orientation'] ?? 1);
		$src = match ($o) { 3 => imagerotate($src, 180, 0), 6 => imagerotate($src, -90, 0), 8 => imagerotate($src, 90, 0), default => $src };
	}
	$w = imagesx($src); $h = imagesy($src);
	if ($w < 200 || $h < 200) return null;
	$k = min(1, 1600 / max($w, $h));
	$nw = (int) round($w * $k); $nh = (int) round($h * $k);
	$dst = imagecreatetruecolor($nw, $nh);
	imagecopyresampled($dst, $src, 0, 0, 0, 0, $nw, $nh, $w, $h);
	$name = bin2hex(random_bytes(16)) . '.webp';
	if (!imagewebp($dst, photo_dir() . '/' . $name, 80)) return null;
	return [$name, $nw, $nh];
}

/** Freigegebene Fotos und die letzte freigegebene Prüfung je Ort; Prüf-Angaben gelten vor allen anderen. */
function with_checks(PDO $pdo, array $places): array
{
	$ids = array_column($places, 'id');
	if (!$ids) return $places;
	$in = implode(',', array_fill(0, count($ids), '?'));
	$checks = [];
	$q = $pdo->prepare("SELECT place_id, answers, checked_at FROM place_checks WHERE status = 'ok' AND place_id IN ($in) ORDER BY checked_at");
	$q->execute($ids);
	foreach ($q as $r) $checks[$r['place_id']] = $r;  // die jüngste gewinnt
	$photos = [];
	$q = $pdo->prepare("SELECT place_id, id, width, height FROM place_photos WHERE status = 'ok' AND place_id IN ($in) ORDER BY check_id IS NULL, id DESC");
	$q->execute($ids);
	foreach ($q as $r) $photos[$r['place_id']][] = ['id' => (int) $r['id'], 'w' => (int) $r['width'], 'h' => (int) $r['height']];
	foreach ($places as &$p) {
		if (isset($checks[$p['id']])) {
			$a = json_decode($checks[$p['id']]['answers'], true) ?: [];
			foreach ($a as $k => $v) if (is_int($v)) $p['facts'][$k] = ['v' => $v, 'src' => 'thisdog'];
			$p['checkedAt'] = (int) $checks[$p['id']]['checked_at'];
		}
		if (isset($photos[$p['id']])) $p['photos'] = array_slice($photos[$p['id']], 0, 12);
	}
	return $places;
}
