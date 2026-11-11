<?php
declare(strict_types=1);

/**
 * Ein Ort für die Gassirunde: bewerten, eintragen, melden.
 *
 *   GET  ?id=<Ort>                                  → {votes, voters, sizes, mine: {votes, sizes}}
 *   POST ?action=vote    {id, votes: {Merkmal: 1|0|null}, sizes: {small, medium, large}}   → dieselbe Antwort wie GET
 *   POST ?action=add     {name, kind, lat, lon, votes: {Merkmal: 1}}                        → {place}
 *   POST ?action=report  {id, reason}                                                       → {ok}
 *   POST ?action=photo   multipart: id, label?, check?, foto (Datei)                        → {photo: {id, status}}
 *   POST ?action=check   {id, answers: {Merkmal: 1|0, area?}, lat, lon, at}  (nur Erkunder)  → {check: {id, distance}}
 *   GET  ?action=mine                                                                       → {scout, checks: […]}
 *
 *   POST ?action=report_photo {photo, reason}                                              → {ok}
 *
 * Fotos und Prüfungen erscheinen sofort. Ein gemeldetes Foto ist verborgen, bis der Betreiber entscheidet.
 *
 * Merkmale: off_leash, fenced, water, clean, grass, shade, bench, bags (Kotbeutelspender),
 * split (getrennte Bereiche für große und kleine Hunde). Nach außen gehen nur Zählungen.
 */

require_once __DIR__ . '/lib.php';
require_once __DIR__ . '/lib-db.php';
require_once __DIR__ . '/lib-places.php';
require_once __DIR__ . '/auth-session.php';

const VOTE_KEYS = ['off_leash', 'fenced', 'water', 'clean', 'grass', 'shade', 'bench', 'bags', 'split'];
/** Diese Merkmale muss eine Prüfung vor Ort beantworten; die übrigen sind freiwillig (ältere Apps kennen sie nicht). */
const CHECK_REQUIRED = ['off_leash', 'fenced', 'water', 'clean', 'grass', 'shade', 'bench'];
/** So viele neue Orte je Konto und Tag. */
const ADDS_PER_DAY = 5;
const REASONS = ['gibt_es_nicht', 'falscher_ort', 'hunde_verboten', 'falscher_name', 'anderes'];

handle_preflight();
guard_origin();

function valid_place_id(string $id): bool
{
	return (bool) preg_match('#^((node|way|relation|wien)/\d+|eigen/\d+)$#', $id);
}

function is_scout(PDO $pdo, ?int $me): bool
{
	if ($me === null) return false;
	$q = $pdo->prepare('SELECT 1 FROM scouts WHERE account_id = ?');
	$q->execute([$me]);
	return (bool) $q->fetchColumn();
}

/** Zählungen eines Ortes, dazu die eigenen Stimmen, Fotos und ob man prüfen darf. */
function place_summary(PDO $pdo, string $id, ?int $me): array
{
	$sum = place_votes($pdo, [$id])[$id] ?? ['votes' => (object) [], 'voters' => 0, 'sizes' => [0, 0, 0]];
	$c = with_checks($pdo, [['id' => $id]])[0];
	$sum['photos'] = $c['photos'] ?? [];
	if (isset($c['checkedAt'])) { $sum['checkedAt'] = $c['checkedAt']; $sum['facts'] = $c['facts']; }
	$sum['scout'] = is_scout($pdo, $me);
	$mine = ['votes' => (object) [], 'sizes' => null];
	if ($me !== null) {
		$q = $pdo->prepare('SELECT key, value FROM place_votes WHERE place_id = ? AND account_id = ?');
		$q->execute([$id, $me]);
		$v = [];
		foreach ($q as $r) $v[$r['key']] = (int) $r['value'];
		$mine['votes'] = (object) $v;
		$q = $pdo->prepare('SELECT small, medium, large FROM place_sizes WHERE place_id = ? AND account_id = ?');
		$q->execute([$id, $me]);
		if ($r = $q->fetch()) $mine['sizes'] = ['small' => (bool) $r['small'], 'medium' => (bool) $r['medium'], 'large' => (bool) $r['large']];
	}
	return $sum + ['mine' => $mine];
}

function save_votes(PDO $pdo, string $id, int $me, array $votes): void
{
	$set = $pdo->prepare('INSERT INTO place_votes (place_id, account_id, key, value, updated_at) VALUES (?, ?, ?, ?, ?)
		ON CONFLICT(place_id, account_id, key) DO UPDATE SET value = excluded.value, updated_at = excluded.updated_at');
	$del = $pdo->prepare('DELETE FROM place_votes WHERE place_id = ? AND account_id = ? AND key = ?');
	foreach ($votes as $key => $value) {
		if (!in_array($key, VOTE_KEYS, true)) continue;
		if ($value === null) $del->execute([$id, $me, $key]);
		elseif ($value === 0 || $value === 1 || $value === true || $value === false) $set->execute([$id, $me, $key, (int) $value, time()]);
	}
}

try {
	$pdo = db();
	$session = current_session($pdo);
	$me = $session === null ? null : (int) $session['account_id'];
	$action = (string) ($_GET['action'] ?? '');

	if ($action === 'mine') {
		if ($me === null) respond(['error' => 'not_signed_in'], 401);
		$q = $pdo->prepare('SELECT c.id, c.place_id, c.checked_at, c.status, (SELECT COUNT(*) FROM place_photos f WHERE f.check_id = c.id) AS photos
			FROM place_checks c WHERE c.account_id = ? ORDER BY c.checked_at DESC LIMIT 100');
		$q->execute([$me]);
		$list = array_map(fn($r) => ['id' => (int) $r['id'], 'place' => $r['place_id'], 'name' => place_lookup($pdo, $r['place_id'])['name'] ?? '',
			'at' => (int) $r['checked_at'], 'status' => $r['status'], 'photos' => (int) $r['photos']], $q->fetchAll());
		respond(['scout' => is_scout($pdo, $me), 'checks' => $list]);
	}

	if ($action === '') {
		$id = (string) ($_GET['id'] ?? '');
		if (!valid_place_id($id)) respond(['error' => 'unknown_place'], 404);
		respond(place_summary($pdo, $id, $me));
	}

	if (($_SERVER['REQUEST_METHOD'] ?? '') !== 'POST') respond(['error' => 'method_not_allowed'], 405);
	if ($me === null) respond(['error' => 'not_signed_in'], 401);
	$body = json_decode((string) file_get_contents('php://input'), true) ?: [];

	switch ($action) {
		case 'vote':
			$id = (string) ($body['id'] ?? '');
			if (!valid_place_id($id)) respond(['error' => 'unknown_place'], 404);
			if (!rate_ok('place-vote:' . $me, 200)) respond(['error' => 'rate_limited'], 429);
			$pdo->beginTransaction();
			save_votes($pdo, $id, $me, is_array($body['votes'] ?? null) ? $body['votes'] : []);
			if (is_array($body['sizes'] ?? null)) {
				$s = $body['sizes'];
				$pdo->prepare('INSERT INTO place_sizes (place_id, account_id, small, medium, large, updated_at) VALUES (?, ?, ?, ?, ?, ?)
					ON CONFLICT(place_id, account_id) DO UPDATE SET small = excluded.small, medium = excluded.medium, large = excluded.large, updated_at = excluded.updated_at')
					->execute([$id, $me, empty($s['small']) ? 0 : 1, empty($s['medium']) ? 0 : 1, empty($s['large']) ? 0 : 1, time()]);
			}
			$pdo->commit();
			respond(place_summary($pdo, $id, $me));

		case 'add':
			$name = trim((string) ($body['name'] ?? ''));
			$kind = (string) ($body['kind'] ?? '');
			$lat = (float) ($body['lat'] ?? 0); $lon = (float) ($body['lon'] ?? 0);
			if ($name === '' || mb_strlen($name) > 60 || !in_array($kind, array_column(KINDS, 'key'), true)
				|| abs($lat) > 90 || abs($lon) > 180 || ($lat == 0 && $lon == 0)) {
				respond(['error' => 'invalid'], 422);
			}
			$q = $pdo->prepare('SELECT COUNT(*) FROM own_places WHERE created_by = ? AND by_user = 1 AND created_at > ?');
			$q->execute([$me, time() - 86400]);
			if ((int) $q->fetchColumn() >= ADDS_PER_DAY) respond(['error' => 'rate_limited'], 429);
			$pdo->beginTransaction();
			$pdo->prepare('INSERT INTO own_places (name, kind, lat, lon, created_by, created_at, by_user) VALUES (?, ?, ?, ?, ?, ?, 1)')
				->execute([$name, $kind, round($lat, 6), round($lon, 6), $me, time()]);
			$id = 'eigen/' . $pdo->lastInsertId();
			// Was beim Eintragen angekreuzt war, ist die erste Stimme.
			save_votes($pdo, $id, $me, is_array($body['votes'] ?? null) ? $body['votes'] : []);
			$pdo->commit();
			$row = $pdo->query('SELECT * FROM own_places WHERE id = ' . (int) substr($id, 6))->fetch();
			respond(['place' => with_votes($pdo, [place_row($row, $id) + ['byUser' => true]])[0]]);

		case 'photo':
			$id = (string) ($_POST['id'] ?? '');
			if (!valid_place_id($id)) respond(['error' => 'unknown_place'], 404);
			if (!rate_ok('place-photo:' . $me, 30, 86400)) respond(['error' => 'rate_limited'], 429);
			$f = $_FILES['foto'] ?? null;
			if (!$f || ($f['error'] ?? 1) !== UPLOAD_ERR_OK || $f['size'] > 15 * 1024 * 1024) respond(['error' => 'invalid'], 422);
			$stored = store_photo($f['tmp_name']);
			if ($stored === null) respond(['error' => 'invalid'], 422);
			$check = (int) ($_POST['check'] ?? 0) ?: null;
			if ($check !== null) {
				$q = $pdo->prepare('SELECT 1 FROM place_checks WHERE id = ? AND account_id = ?');
				$q->execute([$check, $me]);
				if (!$q->fetchColumn()) $check = null;
			}
			$pdo->prepare("INSERT INTO place_photos (place_id, account_id, check_id, file, width, height, label, created_at, status) VALUES (?, ?, ?, ?, ?, ?, ?, ?, 'ok')")
				->execute([$id, $me, $check, $stored[0], $stored[1], $stored[2], mb_substr(trim((string) ($_POST['label'] ?? '')), 0, 40), time()]);
			respond(['photo' => ['id' => (int) $pdo->lastInsertId(), 'status' => 'ok']]);

		case 'check':
			if (!is_scout($pdo, $me)) respond(['error' => 'forbidden'], 403);
			$id = (string) ($body['id'] ?? '');
			if (!valid_place_id($id)) respond(['error' => 'unknown_place'], 404);
			$answers = [];
			foreach (VOTE_KEYS as $k) {
				$v = $body['answers'][$k] ?? null;
				if ($v !== 0 && $v !== 1) {
					if (in_array($k, CHECK_REQUIRED, true)) respond(['error' => 'incomplete', 'missing' => $k], 422);
					continue;
				}
				$answers[$k] = $v;
			}
			$area = (int) ($body['answers']['area'] ?? 0);
			if ($area > 0 && $area < 2000000) $answers['area'] = $area;
			$lat = (float) ($body['lat'] ?? 0); $lon = (float) ($body['lon'] ?? 0);
			$o = place_lookup($pdo, $id);
			$dist = $o ? (int) round(distance_m($lat, $lon, (float) $o['lat'], (float) $o['lon'])) : null;
			if ($dist === null || $dist > CHECK_REACH) respond(['error' => 'too_far', 'distance' => $dist], 422);
			// Ohne Netz geprüft: die Zeit von damals, aber nicht aus der Zukunft und höchstens zwei Wochen alt.
			$at = (int) ($body['at'] ?? time());
			$at = min(time(), max(time() - 14 * 86400, $at));
			$pdo->prepare("INSERT INTO place_checks (place_id, account_id, answers, lat, lon, distance_m, checked_at, created_at, status) VALUES (?, ?, ?, ?, ?, ?, ?, ?, 'ok')")
				->execute([$id, $me, json_encode($answers), round($lat, 5), round($lon, 5), $dist, $at, time()]);
			respond(['check' => ['id' => (int) $pdo->lastInsertId(), 'distance' => $dist]]);

		case 'report_photo':
			$pid = (int) ($body['photo'] ?? 0);
			$reason = (string) ($body['reason'] ?? '');
			if (!in_array($reason, ['person', 'unpassend', 'falscher_ort', 'anderes'], true)) respond(['error' => 'invalid'], 422);
			if (!rate_ok('photo-report:' . $me, 20)) respond(['error' => 'rate_limited'], 429);
			$pdo->prepare("UPDATE place_photos SET status = 'reported', report_reason = ?, reported_at = ? WHERE id = ? AND status = 'ok'")->execute([$reason, time(), $pid]);
			respond(['ok' => true]);

		case 'report':
			$id = (string) ($body['id'] ?? '');
			$reason = (string) ($body['reason'] ?? '');
			if (!valid_place_id($id) || !in_array($reason, REASONS, true)) respond(['error' => 'invalid'], 422);
			if (!rate_ok('place-report:' . $me, 20)) respond(['error' => 'rate_limited'], 429);
			$pdo->prepare('INSERT INTO place_reports (place_id, account_id, reason, created_at) VALUES (?, ?, ?, ?)')
				->execute([$id, $me, $reason, time()]);
			respond(['ok' => true]);
	}
	respond(['error' => 'unknown_action'], 400);
} catch (Throwable $e) {
	error_log('[stella] place: ' . $e->getMessage());
	respond(['error' => 'server'], 500);
}
