<?php
declare(strict_types=1);

/**
 * Abgleich zwischen Geräten und zwischen den Mitgliedern eines Rudels.
 *
 *   GET  ?action=pull&since=<rev>[&pack=<id>]   → alles, was seit dieser Revision neu ist
 *   POST ?action=push[&pack=<id>] {records:[…]} → eigene Änderungen abliefern
 *   POST ?action=wipe[&pack=<id>]               → alles im Rudel löschen
 *
 * Ohne `pack` gilt das erste Rudel des Kontos – so arbeitet die Web-App,
 * die von Rudeln nichts weiß, unverändert weiter.
 *
 * Abgeglichen wird datensatzweise, nicht als Gesamtstand. Zwei Geräte, die
 * unabhängig voneinander je einen Termin anlegen, behalten damit beide –
 * bei einem Gesamtstand würde der zuletzt hochgeladene den anderen löschen.
 *
 * Trifft dieselbe Kennung von zwei Seiten aufein­ander, gewinnt der jüngere
 * Zeitstempel. Uhren gehen unterschiedlich, aber die Alternative wäre eine
 * Konfliktanzeige für jede Kleinigkeit – das will bei einem Hundekalender
 * niemand bedienen.
 */

require_once __DIR__ . '/lib.php';
require_once __DIR__ . '/lib-db.php';
require_once __DIR__ . '/lib-pack.php';
require_once __DIR__ . '/lib-push.php';
require_once __DIR__ . '/auth-session.php';

/** Was abgeglichen wird. Alles andere lehnt der Server ab. */
const KINDS = [
	'event', 'weight', 'vaccinations', 'deworming', 'meds', 'favorite',
	'profile', 'settings', 'checks', 'walk', 'avatar', 'friendkey', 'checkin', 'notes',
];

/** Obergrenzen, damit ein fehlerhafter Client den Speicher nicht flutet. */
const MAX_RECORDS = 2000;
/** So viele Datensätze je Abholen; die Abfrage nennt dieselbe Zahl. */
const PULL_LIMIT = 5000;
/** Verschlüsselt und als Base64 ist ein Datensatz gut ein Drittel größer als im Klartext. */
const MAX_PAYLOAD = 28000;
/** Eine Runde trägt ihre Strecke mit; auch drei Stunden durch den Wald passen hinein. */
const MAX_PAYLOAD_WALK = 170000;
/** Ein Bild (Hund, Rudelmitglied, Foto im Gesundheitstagebuch): kleines JPEG, als Base64. */
const MAX_PAYLOAD_AVATAR = 110000;

handle_preflight();
guard_origin();

try {
	$pdo = db();
	$session = current_session($pdo);
	if ($session === null) respond(['error' => 'not_signed_in'], 401);

	$accountId = (int) $session['account_id'];
	$requested = isset($_GET['pack']) ? (int) $_GET['pack'] : null;
	$packId = resolve_pack($pdo, $accountId, $requested);
	if ($packId === null) respond(['error' => 'not_a_member'], 403);

	$action = (string) ($_GET['action'] ?? '');

	if ($action === 'pull') {
		respond(pull($pdo, $packId, (int) ($_GET['since'] ?? 0)));
	}
	if ($action === 'push') {
		if (($_SERVER['REQUEST_METHOD'] ?? '') !== 'POST') respond(['error' => 'method_not_allowed'], 405);
		$result = push($pdo, $packId, $accountId, json_input());
		if ($result['stored'] > 0) notify_pack_change($pdo, $packId, $accountId, $result['changes']);
		unset($result['changes']);
		respond($result);
	}
	if ($action === 'wipe') {
		if (($_SERVER['REQUEST_METHOD'] ?? '') !== 'POST') respond(['error' => 'method_not_allowed'], 405);
		// Alles löschen dürfen nur Besitzer – sonst könnte ein Hundesitter die Daten aller tilgen.
		if (!is_owner($pdo, $packId, $accountId)) respond(['error' => 'not_owner'], 403);
		respond(wipe($pdo, $packId, $accountId));
	}
	respond(['error' => 'unknown_action'], 404);
} catch (Throwable $e) {
	error_log('[stella] Abgleich: ' . $e->getMessage());
	respond(['error' => 'server_error'], 500);
}

function json_input(): array
{
	$raw = file_get_contents('php://input');
	if (!is_string($raw) || $raw === '') return [];
	$data = json_decode($raw, true);
	return is_array($data) ? $data : [];
}

/* ============================ Abholen ============================ */

function pull(PDO $pdo, int $packId, int $since): array
{
	$stmt = $pdo->prepare(<<<'SQL'
		SELECT kind, record_id, payload, updated_at, rev, changed_by
		FROM pack_records WHERE pack_id = ? AND rev > ?
		ORDER BY rev LIMIT 5000
	SQL);
	$stmt->execute([$packId, $since]);

	$records = [];
	$rev = $since;
	foreach ($stmt as $row) {
		$rev = max($rev, (int) $row['rev']);
		$records[] = [
			'kind' => $row['kind'],
			'id' => $row['record_id'],
			'updatedAt' => (int) $row['updated_at'],
			'by' => $row['changed_by'] === null ? null : (int) $row['changed_by'],
			// Ein leerer Rumpf ist ein Grabstein: der Datensatz ist gelöscht.
			'payload' => $row['payload'] === null ? null : json_decode((string) $row['payload'], true),
		];
	}

	// Volle Seite: Es kommt noch mehr. Die App holt weiter, bevor sie etwas daraus schließt (etwa „das Rudel hat kein Profil“).
	return ['pack' => $packId, 'rev' => $rev, 'records' => $records, 'more' => count($records) >= PULL_LIMIT, 'serverTime' => time() * 1000];
}

/* ============================ Abliefern ============================ */

function push(PDO $pdo, int $packId, int $accountId, array $body): array
{
	$incoming = $body['records'] ?? [];
	if (!is_array($incoming)) respond(['error' => 'bad_request'], 422);
	if (count($incoming) > MAX_RECORDS) respond(['error' => 'too_many_records'], 413);

	$since = (int) ($body['since'] ?? 0);
	$stored = 0;
	$sealed = pack_sealed($pdo, $packId);
	$changes = [];

	$pdo->beginTransaction();
	try {
		$read = $pdo->prepare('SELECT updated_at, payload FROM pack_records WHERE pack_id = ? AND kind = ? AND record_id = ?');
		$write = $pdo->prepare(<<<'SQL'
			INSERT INTO pack_records (pack_id, kind, record_id, payload, updated_at, rev, changed_by)
			VALUES (:pack, :kind, :id, :payload, :updated, :rev, :by)
			ON CONFLICT(pack_id, kind, record_id) DO UPDATE SET
				payload = excluded.payload,
				updated_at = excluded.updated_at,
				rev = excluded.rev,
				changed_by = excluded.changed_by
		SQL);

		foreach ($incoming as $record) {
			if (!is_array($record)) continue;
			$kind = (string) ($record['kind'] ?? '');
			$id = (string) ($record['id'] ?? '');
			$updated = (int) ($record['updatedAt'] ?? 0);
			// Eine Uhr, die vorgeht, gewönne sonst jeden Konflikt – und machte den Datensatz unlöschbar.
			$updated = min($updated, (int) (microtime(true) * 1000) + 5 * 60 * 1000);

			if ($id === '' || strlen($id) > 200 || !in_array($kind, KINDS, true)) continue;

			$payload = null;
			// Verschlüsselte Rudel nehmen keinen Klartext an – auch nicht von einer alten App.
			if ($sealed && ($record['payload'] ?? null) !== null && !is_sealed_payload($record['payload'])) continue;
			if (array_key_exists('payload', $record) && $record['payload'] !== null) {
				$payload = json_encode($record['payload'], JSON_UNESCAPED_UNICODE);
				$limit = match ($kind) { 'walk' => MAX_PAYLOAD_WALK, 'avatar', 'notes' => MAX_PAYLOAD_AVATAR, default => MAX_PAYLOAD };
				if (!is_string($payload) || strlen($payload) > $limit) continue;
			}

			// Wer älter ist, überschreibt nicht. Sonst würde ein Gerät, das
			// lange offline war, beim Wiederauftauchen neuere Änderungen
			// zurückdrehen. Gleich alt und gleicher Inhalt ist keine Änderung –
			// sonst lösten zwei Geräte desselben Menschen gegenseitig Mitteilungen aus.
			$read->execute([$packId, $kind, $id]);
			$existing = $read->fetch();
			if ($existing !== false && (int) $existing['updated_at'] > $updated) continue;
			if ($existing !== false && (int) $existing['updated_at'] === $updated && $existing['payload'] === $payload) continue;

			$write->execute([
				':pack' => $packId,
				':kind' => $kind,
				':id' => $id,
				':payload' => $payload,
				':updated' => $updated,
				':rev' => next_rev($pdo, $packId),
				':by' => $accountId,
			]);
			$stored++;
			// Nur, was der Server ohne Schlüssel weiß: Art, neu oder gelöscht.
			$changes[] = [
				'kind' => $kind,
				'new' => $existing === false || $existing['payload'] === null,
				'deleted' => $payload === null,
			];
		}
		// Nach dem Umzug: Was noch im Klartext liegt, verschwindet vom Server. Kein Grabstein – der
		// wäre jünger als jede Fassung auf den Geräten und löschte dort Daten, die nur noch nicht
		// verschlüsselt hochgeladen sind. Die Geräte behalten ihre Fassung und laden sie verschlüsselt nach.
		if ($sealed) {
			$pdo->prepare(<<<'SQL'
				DELETE FROM pack_records WHERE pack_id = ? AND payload IS NOT NULL AND payload NOT LIKE '{"e":%'
			SQL)->execute([$packId]);
		}
		$pdo->commit();
	} catch (Throwable $e) {
		$pdo->rollBack();
		throw $e;
	}

	// Im selben Zug zurückgeben, was das Gerät noch nicht kennt – ein
	// Abgleich ist dann eine einzige Runde statt zweier.
	$result = pull($pdo, $packId, $since);
	$result['stored'] = $stored;
	$result['changes'] = $changes;
	return $result;
}

/* ============================ Leeren ============================ */

/**
 * Löscht alles, was in diesem Rudel liegt.
 *
 * Die Zeilen werden nicht entfernt, sondern zu Grabsteinen: leerer Rumpf,
 * frischer Zeitstempel, neue Revision. Der Unterschied ist der ganze Zweck.
 *
 * Ein einfaches DELETE löschte nur hier. Auf dem Telefon in der Tasche liegen
 * dieselben Termine weiter, und beim nächsten vollständigen Abgleich lädt es
 * sie wieder hoch – der Bestand wäre zurück, ohne dass jemand etwas falsch
 * gemacht hätte. Der Grabstein dagegen reist: Jedes Gerät, das sich noch
 * einmal meldet, räumt mit.
 *
 * Der Zeitstempel liegt in Millisekunden, wie überall im Abgleich – der Client
 * vergleicht ihn mit `Date.now()`. In Sekunden wäre er älter als jeder lokale
 * Eintrag und verlöre gegen ihn.
 */
function wipe(PDO $pdo, int $packId, int $accountId): array
{
	$rev = next_rev($pdo, $packId);
	$now = (int) round(microtime(true) * 1000);

	// Was schon ein Grabstein ist, bleibt liegen: Es gibt nichts mehr zu
	// löschen, und ein neuer Stempel schickte alte Löschungen nur erneut
	// durch die Leitung.
	$stmt = $pdo->prepare(<<<'SQL'
		UPDATE pack_records SET payload = NULL, updated_at = ?, rev = ?, changed_by = ?
		WHERE pack_id = ? AND payload IS NOT NULL
	SQL);
	$stmt->execute([$now, $rev, $accountId, $packId]);

	return ['ok' => true, 'rev' => $rev, 'cleared' => $stmt->rowCount()];
}
