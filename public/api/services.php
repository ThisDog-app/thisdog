<?php
declare(strict_types=1);

/**
 * Adressen rund um den Hund für die App (Reiter „Adressen“ auf Gassi).
 *
 *   GET  ?lat=48.21&lon=16.37            → {services: [...], sponsor: {...}|null, covered: bool}
 *   GET  ?lat=48.21&lon=16.37&q=struppi  → Namenssuche im weiteren Umkreis
 *   POST {"action":"tap","sponsor":12}   → der Partnerplatz wurde geöffnet (nur als Tagessumme gezählt)
 *
 * Kein Login: Die Daten sind öffentlich (OpenStreetMap), und wer sucht, soll nichts von sich preisgeben müssen.
 * Der Standort kommt wie bei places.php auf rund einen Kilometer gerundet an.
 */

require_once __DIR__ . '/lib-services.php';

handle_preflight();
guard_origin();

if (($_SERVER['REQUEST_METHOD'] ?? '') === 'POST') {
	$body = json_decode((string) file_get_contents('php://input'), true);
	$id = (int) ($body['sponsor'] ?? 0);
	if (($body['action'] ?? '') !== 'tap' || $id <= 0) respond(['error' => 'bad_request'], 400);
	// Je Anschluss höchstens dreimal in der Stunde: Wer sich durchtippt, bläht die Zahl für den Partner nicht auf.
	if (rate_ok('spt_' . $id, 3)) {
		try { sponsor_count(db(), $id, 'taps'); } catch (Throwable $e) { error_log('[stella] Anzeige gezählt: ' . $e->getMessage()); }
	}
	respond(['ok' => true]);
}

$lat = round((float) ($_GET['lat'] ?? 0), 2);
$lon = round((float) ($_GET['lon'] ?? 0), 2);
$q = trim(mb_substr((string) ($_GET['q'] ?? ''), 0, 60));
if ($lat === 0.0 && $lon === 0.0 || abs($lat) > 90 || abs($lon) > 180) respond(['error' => 'bad_position'], 422);
if (!rate_ok('services', $q === '' ? 60 : 240)) respond(['error' => 'rate_limited'], 429);

try {
	$x = services_db();
	if ($x === null || !services_covered($x, $lat, $lon)) respond(['services' => [], 'sponsor' => null, 'covered' => false]);

	$services = services_near($x, $lat, $lon, mb_strlen($q) >= 2 ? $q : '');
	$sponsor = null;
	$row = sponsor_for(db(), $lat, $lon);
	if ($row !== null) {
		$sponsor = sponsor_out($row);
		// Der Platz steht oben; unten nicht noch einmal.
		$services = array_values(array_filter($services, fn($s) => $s['id'] !== $sponsor['place']));
		if ($q === '' && rate_ok('spv_' . $row['id'], 1)) sponsor_count(db(), (int) $row['id'], 'views');
	}
	respond(['services' => $services, 'sponsor' => $sponsor, 'covered' => true]);
} catch (Throwable $e) {
	error_log('[stella] Adressen: ' . $e->getMessage());
	respond(['error' => 'unavailable'], 503);
}
