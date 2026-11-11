<?php
declare(strict_types=1);

/**
 * Ziele für die Gassirunde – Parks, Wiesen, Hundezonen.
 *
 *   GET ?lat=48.22&lon=16.38
 *
 * Zwischen App und OpenStreetMap steht dieser Cache, aus drei Gründen:
 *
 * 1. Der öffentliche Overpass-Server ist launisch. Er antwortet mal in einer
 *    Sekunde, mal gar nicht («server too busy»). Wer einmal geholt hat, soll
 *    davon nichts mehr merken.
 * 2. Eine Anfrage je Stadtviertel und Monat ist fair. Eine je Besucher und
 *    Aufruf wäre es nicht.
 * 3. Der Standort geht damit an diesen Server statt an einen fremden – und
 *    zwar auf gut einen Kilometer gerundet.
 */

require_once __DIR__ . '/lib.php';
require_once __DIR__ . '/lib-db.php';
require_once __DIR__ . '/lib-places.php';
require_once __DIR__ . '/auth-session.php';

/** Rasterweite der Zwischenspeicherung: rund 1,1 km. */
const CELL = 0.01;


/** Wie lange ein Eintrag gilt. Ein Park bleibt ein Park. */
const TTL = 2592000;

/**
 * Für ein leeres Ergebnis gilt eine kurze Frist.
 *
 * Sonst friert ein einzelner schlechter Moment – eine unvollständige Antwort,
 * ein abgebrochener Lauf – die ganze Gegend für einen Monat auf »hier gibt es
 * nichts« ein.
 */
const TTL_EMPTY = 3600;

/** Frist für ein Ergebnis, bei dem nicht alle Arten durchkamen. */
const TTL_PARTIAL = 7200;

/** Wie lange alle Abfragen zusammen dauern dürfen. */
const BUDGET = 35;

const ENDPOINTS = [
	'https://overpass-api.de/api/interpreter',
	'https://overpass.kumi.systems/api/interpreter',
];


// Eine kalte Abfrage kann bei überlastetem Overpass eine halbe Minute
// dauern; die übliche Grenze von 30 Sekunden reicht dafür nicht. Der Fall
// tritt einmal je Stadtviertel auf, danach antwortet der Zwischenspeicher.
@set_time_limit(75);

handle_preflight();
guard_origin();

$lat = (float) ($_GET['lat'] ?? 0);
$lon = (float) ($_GET['lon'] ?? 0);

if ($lat === 0.0 && $lon === 0.0 || abs($lat) > 90 || abs($lon) > 180) {
	respond(['error' => 'bad_position'], 422);
}
if (!rate_ok('places', 60, 3600)) {
	respond(['error' => 'rate_limited'], 429);
}

try {
	$cellLat = round($lat / CELL) * CELL;
	$cellLon = round($lon / CELL) * CELL;
	$cell = sprintf('%.2f,%.2f', $cellLat, $cellLon);

	$pdo = db();
	// Eigene, noch nicht angesehene Orte und Fotos sieht man selbst schon.
	$me = (int) (current_session($pdo)['account_id'] ?? 0) ?: null;

	// Zuerst der eigene Auszug (server/orte-import.py, monatlich). Overpass nur, wo er nichts hat.
	$auszug = extract_places($cellLat, $cellLon);
	if ($auszug !== null) {
		respond(['places' => with_checks($pdo, with_votes($pdo, with_own($pdo, $auszug, $cellLat, $cellLon, $me)), $me), 'cell' => $cell, 'source' => 'auszug']);
	}

	$cached = read_cell($pdo, $cell);

	if ($cached !== null) {
		respond(['places' => with_checks($pdo, with_votes($pdo, with_own($pdo, $cached, $cellLat, $cellLon, $me)), $me), 'cell' => $cell, 'cached' => true]);
	}

	$ergebnis = fetch_places($cellLat, $cellLon);
	write_cell($pdo, $cell, $ergebnis['places'], $ergebnis['vollstaendig']);
	respond([
		'places' => with_checks($pdo, with_votes($pdo, with_own($pdo, $ergebnis['places'], $cellLat, $cellLon, $me)), $me),
		'cell' => $cell,
		'cached' => false,
		'vollstaendig' => $ergebnis['vollstaendig'],
	]);
} catch (Throwable $e) {
	error_log('[stella] Ziele: ' . $e->getMessage());
	// Ein abgelaufener Eintrag ist besser als gar keiner: Wenn die Quelle
	// gerade nicht antwortet, zählt, dass die App etwas anzeigen kann.
	$stale = isset($pdo, $cell) ? read_cell($pdo, $cell, PHP_INT_MAX) : null;
	if ($stale !== null) {
		respond(['places' => with_checks($pdo, with_votes($pdo, with_own($pdo, $stale, $cellLat, $cellLon, $me)), $me), 'cell' => $cell, 'cached' => true, 'stale' => true]);
	}
	respond(['error' => 'upstream_unavailable'], 503);
}

/* ============================ Zwischenspeicher ============================ */

function read_cell(PDO $pdo, string $cell, ?int $ttl = null): ?array
{
	$stmt = $pdo->prepare('SELECT payload, fetched_at FROM places_cache WHERE cell = ?');
	$stmt->execute([$cell]);
	$row = $stmt->fetch();
	if (!$row) return null;

	$data = json_decode((string) $row['payload'], true);
	if (!is_array($data)) return null;

	$frist = $ttl ?? (count($data) === 0 ? TTL_EMPTY : TTL);
	if (time() - (int) $row['fetched_at'] > $frist) return null;

	return $data;
}

function write_cell(PDO $pdo, string $cell, array $places, bool $vollstaendig = true): void
{
	// Kam nur ein Teil der Arten durch, soll der Rest bald nachkommen. Statt
	// einer zweiten Spalte wird der Zeitstempel zurückdatiert – dieselbe
	// Frist, nur schon fast abgelaufen.
	$stamp = $vollstaendig ? time() : time() - (TTL - TTL_PARTIAL);

	$stmt = $pdo->prepare(<<<'SQL'
		INSERT INTO places_cache (cell, payload, fetched_at) VALUES (?, ?, ?)
		ON CONFLICT(cell) DO UPDATE SET payload = excluded.payload, fetched_at = excluded.fetched_at
	SQL);
	$stmt->execute([$cell, json_encode($places, JSON_UNESCAPED_UNICODE), $stamp]);

	// Aufräumen: Was ein halbes Jahr niemand mehr abgefragt hat, kann weg.
	if (random_int(1, 50) === 1) {
		$pdo->prepare('DELETE FROM places_cache WHERE fetched_at < ?')->execute([time() - 15552000]);
	}
}

/* ============================ Quelle ============================ */

/**
 * Abfrage für eine einzelne Art.
 *
 * Ohne Filter auf «name»: Der spart zwar Daten, kostet Overpass aber ein
 * Vielfaches an Rechenzeit – gemessen rund elf Sekunden je Art statt gut vier
 * für alle zusammen. Namenlose Flächen fliegen erst beim Aufbereiten heraus.
 */
function build_query(array $kind, float $lat, float $lon): string
{
	$at = sprintf('(around:%d,%.4f,%.4f);', QUERY_RADIUS, $lat, $lon);
	// «out center» liefert auch für Flächen einen Punkt – ohne ihn wären
	// Parks nur Umrisse ohne Ort.
	return '[out:json][timeout:20];(nwr' . $kind['filter'] . $at . ');out center tags 200;';
}

/**
 * Holt die Arten einzeln statt in einem Rutsch.
 *
 * Eine Abfrage über sechs Arten ist für Overpass teuer genug, dass sie in
 * schlechten Minuten in den Zeitausfall läuft – und dann fehlt alles. Einzeln
 * ist jede billig, und was durchkommt, zählt: Wer die Hundezonen bekommt,
 * aber nicht den Wald, hat immer noch eine brauchbare Liste.
 */
function fetch_places(float $lat, float $lon): array
{
	$elements = [];
	$erfolge = 0;
	$lastError = 'keine Antwort';

	// Gesamtbudget statt Zeitlimit je Abfrage: Sechs Arten bei zwei Anbietern
	// könnten sonst Minuten dauern und den Aufruf ins Serverlimit laufen
	// lassen. Wer wartet, bekommt lieber eine kurze Liste als einen Fehler.
	$ende = microtime(true) + BUDGET;

	foreach (KINDS as $kind) {
		if (microtime(true) > $ende - 6) {
			$lastError = 'Zeitbudget aufgebraucht';
			break;
		}
		$teil = fetch_kind($kind, $lat, $lon, $lastError, $ende);
		if ($teil === null) continue;
		$elements = array_merge($elements, $teil);
		$erfolge++;
	}

	if ($erfolge === 0) throw new RuntimeException('Overpass: ' . $lastError);

	return [
		'places' => normalise($elements),
		'vollstaendig' => $erfolge === count(KINDS),
	];
}

/**
 * Eine Art bei den bekannten Anbietern versuchen. Null, wenn keiner mag.
 *
 * Maßgeblich ist der Zeitpunkt, zu dem alles fertig sein muss – nicht eine
 * Frist je Anfrage. Sonst verdoppelt der zweite Anbieter stillschweigend,
 * was der erste schon verbraucht hat, und aus 45 Sekunden Budget werden 55.
 */
function fetch_kind(array $kind, float $lat, float $lon, string &$lastError, float $ende): ?array
{
	$query = build_query($kind, $lat, $lon);

	foreach (ENDPOINTS as $url) {
		$rest = (int) ($ende - microtime(true));
		if ($rest < 5) {
			$lastError = 'Zeitbudget aufgebraucht';
			return null;
		}
		$ch = curl_init($url);
		curl_setopt_array($ch, [
			CURLOPT_POST => true,
			CURLOPT_POSTFIELDS => $query,
			CURLOPT_RETURNTRANSFER => true,
			CURLOPT_TIMEOUT => min(20, $rest),
			CURLOPT_CONNECTTIMEOUT => 8,
			// Overpass bittet um eine erkennbare Kennung, damit sich
			// auffälliger Verkehr zuordnen lässt.
			CURLOPT_USERAGENT => 'ThisDog/1.0 (+https://thisdog.app)',
			CURLOPT_HTTPHEADER => ['Content-Type: text/plain; charset=utf-8'],
		]);
		$body = curl_exec($ch);
		$status = (int) curl_getinfo($ch, CURLINFO_RESPONSE_CODE);
		$error = curl_error($ch);
		// Kein curl_close(): seit PHP 8.0 wirkungslos, seit 8.5 veraltet – die
		// Warnung landete vor dem JSON im Ausgabestrom und machte jede
		// Antwort unlesbar.
		unset($ch);

		if ($body === false || $status !== 200) {
			$lastError = $error !== '' ? $error : "HTTP $status";
			continue;
		}

		$data = json_decode((string) $body, true);
		if (!is_array($data) || !isset($data['elements'])) {
			// Überlastung meldet Overpass als HTML-Seite, nicht als Fehlercode.
			$lastError = 'unlesbare Antwort';
			continue;
		}

		return $data['elements'];
	}

	return null;
}

/** Rohdaten in das schlanke Format bringen, das die App braucht. */
function normalise(array $elements): array
{
	$out = [];
	$seen = [];

	foreach ($elements as $item) {
		$tags = $item['tags'] ?? [];
		if (!is_array($tags)) continue;

		$lat = $item['center']['lat'] ?? $item['lat'] ?? null;
		$lon = $item['center']['lon'] ?? $item['lon'] ?? null;
		if ($lat === null || $lon === null) continue;

		$kind = match_kind($tags);
		if ($kind === null) continue;

		// Hunde ausdrücklich verboten: als Ziel unbrauchbar.
		if (($tags['dog'] ?? '') === 'no') continue;

		$name = trim((string) ($tags['name'] ?? ''));
		if ($name === '') {
			if ($kind['key'] !== 'dog_park') continue;
			$name = 'Hundezone';
		}

		// Dieselbe Anlage steckt oft mehrfach in den Daten – als Fläche und
		// als Punkt, manchmal in mehreren Teilen.
		$key = $name . '|' . round((float) $lat, 3) . '|' . round((float) $lon, 3);
		if (isset($seen[$key])) continue;
		$seen[$key] = true;

		$out[] = [
			'id' => ($item['type'] ?? 'x') . '/' . ($item['id'] ?? 0),
			'name' => $name,
			'kind' => $kind['key'],
			'label' => $kind['label'],
			'rank' => $kind['rank'],
			'lat' => round((float) $lat, 5),
			'lon' => round((float) $lon, 5),
			'offLeash' => ($tags['dog'] ?? '') === 'unleashed' || $kind['key'] === 'dog_park',
			'fenced' => ($tags['barrier'] ?? '') === 'fence' || ($tags['fenced'] ?? '') === 'yes',
		];
	}

	return $out;
}

function match_kind(array $tags): ?array
{
	foreach (KINDS as $kind) {
		[$field, $value] = kind_tag($kind['key']);
		if (($tags[$field] ?? null) === $value) return $kind;
	}
	return null;
}

function kind_tag(string $key): array
{
	return match ($key) {
		'dog_park' => ['leisure', 'dog_park'],
		'park' => ['leisure', 'park'],
		'forest' => ['landuse', 'forest'],
		'wood' => ['natural', 'wood'],
		'nature_reserve' => ['leisure', 'nature_reserve'],
		'meadow' => ['landuse', 'meadow'],
		'common' => ['leisure', 'common'],
		'grass' => ['landuse', 'grass'],
		default => ['none', 'none'],
	};
}
