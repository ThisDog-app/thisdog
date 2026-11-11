<?php
declare(strict_types=1);

/**
 * Der Weg zu einem Ziel – zu Fuß.
 *
 *   GET ?from=48.2245,16.3780&to=48.2262,16.3802
 *
 * Gerechnet wird von Valhalla beim FOSSGIS, dem Verein hinter der deutschen
 * OpenStreetMap-Gemeinschaft: frei nutzbar, ohne Schlüssel, mit derselben
 * Bitte um Zurückhaltung wie bei den Kacheln. Deshalb liegt auch hier ein
 * Zwischenspeicher davor – ein Weg zwischen denselben zwei Punkten ändert
 * sich nicht von einer Woche zur nächsten.
 *
 * Der Startpunkt wird gerundet, bevor er das Haus verlässt: für einen Fußweg
 * über hunderte Meter macht das keinen Unterschied, für die Frage, vor
 * welcher Tür jemand steht, sehr wohl.
 */

require_once __DIR__ . '/lib.php';
require_once __DIR__ . '/lib-db.php';

const ROUTER = 'https://valhalla1.openstreetmap.de/route';

/** Rundung des Startpunkts: rund 30 Meter. */
const START_GRID = 0.0003;

/** Wie lange ein berechneter Weg gilt. */
const ROUTE_TTL = 604800;

/** Weiter als das ist keine Gassirunde mehr – und keine Anfrage wert. */
const MAX_METERS = 6000;

@set_time_limit(40);

handle_preflight();
guard_origin();

$from = punkt((string) ($_GET['from'] ?? ''));
$to = punkt((string) ($_GET['to'] ?? ''));

if ($from === null || $to === null) respond(['error' => 'bad_position'], 422);
if (!rate_ok('route', 120, 3600)) respond(['error' => 'rate_limited'], 429);

// Luftlinie als Vorprüfung: Was weit jenseits jeder Runde liegt, muss kein
// Router ausrechnen.
if (luftlinie($from, $to) > MAX_METERS) respond(['error' => 'too_far'], 422);

try {
	$fromRund = [
		'lat' => round($from['lat'] / START_GRID) * START_GRID,
		'lon' => round($from['lon'] / START_GRID) * START_GRID,
	];
	$key = sprintf('%.4f,%.4f>%.5f,%.5f', $fromRund['lat'], $fromRund['lon'], $to['lat'], $to['lon']);

	$pdo = db();
	$cached = read_route($pdo, $key);
	if ($cached !== null) {
		respond($cached + ['cached' => true]);
	}

	$route = fetch_route($fromRund, $to);
	write_route($pdo, $key, $route);
	respond($route + ['cached' => false]);
} catch (Throwable $e) {
	error_log('[stella] Weg: ' . $e->getMessage());
	respond(['error' => 'router_unavailable'], 503);
}

/* ============================ Eingaben ============================ */

function punkt(string $roh): ?array
{
	$teile = explode(',', $roh);
	if (count($teile) !== 2) return null;
	$lat = (float) trim($teile[0]);
	$lon = (float) trim($teile[1]);
	if (abs($lat) > 90 || abs($lon) > 180) return null;
	if ($lat === 0.0 && $lon === 0.0) return null;
	return ['lat' => $lat, 'lon' => $lon];
}

function luftlinie(array $a, array $b): float
{
	$r = 6371000;
	$dLat = deg2rad($b['lat'] - $a['lat']);
	$dLon = deg2rad($b['lon'] - $a['lon']);
	$h = sin($dLat / 2) ** 2
		+ cos(deg2rad($a['lat'])) * cos(deg2rad($b['lat'])) * sin($dLon / 2) ** 2;
	return 2 * $r * asin(sqrt($h));
}

/* ============================ Zwischenspeicher ============================ */

function read_route(PDO $pdo, string $key): ?array
{
	$stmt = $pdo->prepare('SELECT payload, fetched_at FROM routes_cache WHERE route_key = ?');
	$stmt->execute([$key]);
	$row = $stmt->fetch();
	if (!$row) return null;
	if (time() - (int) $row['fetched_at'] > ROUTE_TTL) return null;

	$data = json_decode((string) $row['payload'], true);
	return is_array($data) ? $data : null;
}

function write_route(PDO $pdo, string $key, array $route): void
{
	$stmt = $pdo->prepare(<<<'SQL'
		INSERT INTO routes_cache (route_key, payload, fetched_at) VALUES (?, ?, ?)
		ON CONFLICT(route_key) DO UPDATE SET payload = excluded.payload, fetched_at = excluded.fetched_at
	SQL);
	$stmt->execute([$key, json_encode($route, JSON_UNESCAPED_UNICODE), time()]);

	if (random_int(1, 40) === 1) {
		$pdo->prepare('DELETE FROM routes_cache WHERE fetched_at < ?')->execute([time() - 2592000]);
	}
}

/* ============================ Quelle ============================ */

function fetch_route(array $from, array $to): array
{
	$anfrage = [
		'locations' => [
			['lat' => round($from['lat'], 5), 'lon' => round($from['lon'], 5)],
			['lat' => round($to['lat'], 5), 'lon' => round($to['lon'], 5)],
		],
		'costing' => 'pedestrian',
		'directions_options' => ['units' => 'kilometers'],
	];

	$url = ROUTER . '?json=' . rawurlencode(json_encode($anfrage));
	$ch = curl_init($url);
	curl_setopt_array($ch, [
		CURLOPT_RETURNTRANSFER => true,
		CURLOPT_TIMEOUT => 20,
		CURLOPT_CONNECTTIMEOUT => 8,
		CURLOPT_USERAGENT => 'ThisDog/1.0 (+https://thisdog.app)',
	]);
	$body = curl_exec($ch);
	$status = (int) curl_getinfo($ch, CURLINFO_RESPONSE_CODE);
	$error = curl_error($ch);
	unset($ch);

	if ($body === false || $status !== 200) {
		throw new RuntimeException('Valhalla: ' . ($error !== '' ? $error : "HTTP $status"));
	}

	$data = json_decode((string) $body, true);
	$leg = $data['trip']['legs'][0] ?? null;
	if (!is_array($leg) || !isset($leg['shape'])) {
		throw new RuntimeException('Valhalla: keine Route in der Antwort');
	}

	$summary = $data['trip']['summary'] ?? [];
	return [
		'meters' => (int) round(((float) ($summary['length'] ?? 0)) * 1000),
		'seconds' => (int) round((float) ($summary['time'] ?? 0)),
		'points' => decode_shape((string) $leg['shape']),
	];
}

/**
 * Valhallas Streckenzug in Koordinaten.
 *
 * Dasselbe Verfahren wie bei Google, aber mit sechs Nachkommastellen statt
 * fünf – wer den Faktor verwechselt, landet zehnfach daneben, mitten im
 * Nirgendwo.
 */
function decode_shape(string $shape): array
{
	$punkte = [];
	$i = 0;
	$lat = 0;
	$lon = 0;
	$len = strlen($shape);

	while ($i < $len) {
		foreach ([0, 1] as $achse) {
			$ergebnis = 0;
			$verschiebung = 0;
			do {
				if ($i >= $len) return $punkte;
				$byte = ord($shape[$i++]) - 63;
				$ergebnis |= ($byte & 0x1f) << $verschiebung;
				$verschiebung += 5;
			} while ($byte >= 0x20);

			$delta = ($ergebnis & 1) ? ~($ergebnis >> 1) : ($ergebnis >> 1);
			if ($achse === 0) $lat += $delta;
			else $lon += $delta;
		}
		$punkte[] = ['lat' => round($lat / 1e6, 6), 'lon' => round($lon / 1e6, 6)];
	}
	return $punkte;
}
