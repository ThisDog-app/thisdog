<?php
declare(strict_types=1);

/**
 * Mitteilungen an die Geräte eines Rudels über Apple Push (APNs).
 *
 * Braucht in `stella-daten/config.php` vier Werte: APNS_KEY_ID, APNS_TEAM_ID,
 * APNS_KEY_FILE (Pfad zur .p8-Datei, am besten in stella-daten) und
 * APNS_TOPIC (die Kennung der App, „app.thisDog“). Fehlt einer davon, wird
 * nichts verschickt – der Abgleich funktioniert trotzdem, nur ohne Mitteilung.
 *
 * Eine Mitteilung ist nie die Daten selbst: Sie sagt, dass sich etwas geändert
 * hat, und weckt die App, die dann den neuen Stand abholt. So steht nichts
 * über den Hund in Apples Systemen.
 */

require_once __DIR__ . '/lib.php';
require_once __DIR__ . '/lib-pack.php';

function push_configured(): bool
{
	foreach (['APNS_KEY_ID', 'APNS_TEAM_ID', 'APNS_KEY_FILE', 'APNS_TOPIC'] as $k) {
		if ((string) cfg($k, '') === '') return false;
	}
	return is_readable((string) cfg('APNS_KEY_FILE'));
}

/** Merkt sich ein Gerät für Mitteilungen. Dieselbe Kennung wandert mit, wenn sich jemand anderes anmeldet. */
function register_device(PDO $pdo, int $accountId, string $token, string $environment): void
{
	$now = time();
	$pdo->prepare(<<<'SQL'
		INSERT INTO push_devices (token, account_id, platform, environment, created_at, last_seen_at)
		VALUES (?, ?, 'apns', ?, ?, ?)
		ON CONFLICT(token) DO UPDATE SET account_id = excluded.account_id,
			environment = excluded.environment, last_seen_at = excluded.last_seen_at
	SQL)->execute([$token, $accountId, $environment, $now, $now]);
}

function unregister_device(PDO $pdo, string $token): void
{
	$pdo->prepare('DELETE FROM push_devices WHERE token = ?')->execute([$token]);
}

/**
 * Sagt den anderen Rudelmitgliedern, was sich geändert hat.
 *
 * Eigene Geräte bekommen nur das stille Wecken (sie sollen den Stand holen,
 * aber niemand will über die eigene Änderung benachrichtigt werden). Die
 * anderen bekommen eine sichtbare Mitteilung, wenn es um Termine geht.
 */
function notify_pack_change(PDO $pdo, int $packId, int $byAccount, array $changes): void
{
	if (!push_configured()) return;

	$members = pack_members($pdo, $packId);
	$byName = 'Jemand aus dem Rudel';
	foreach ($members as $m) if ($m['id'] === $byAccount) $byName = $m['name'];
	$said = change_text($byName, $changes);
	$alert = $said === null ? null : ['title' => $said['title'], 'body' => $said['body']];
	// Wer welche Art sichtbar bekommt, legen Rolle und Einstellungen im Rudel fest; alle anderen
	// Geräte werden nur still geweckt, damit sie den neuen Stand holen.
	$wants = pack_notify_map($pdo, $packId);

	$ids = array_column($members, 'id');
	if (!$ids) return;
	$in = implode(',', array_fill(0, count($ids), '?'));
	$stmt = $pdo->prepare("SELECT token, account_id, environment FROM push_devices WHERE account_id IN ($in)");
	$stmt->execute($ids);

	foreach ($stmt->fetchAll() as $d) {
		$own = (int) $d['account_id'] === $byAccount;
		$shows = !$own && $alert !== null && in_array($said['kind'], $wants[(int) $d['account_id']] ?? [], true);
		$payload = ['aps' => ['content-available' => 1], 'pack' => $packId, 'by' => $byAccount];
		if ($shows) {
			$payload['aps']['alert'] = $alert;
			$payload['aps']['sound'] = 'default';
			// Das Gerät ergänzt Bild und Namen der Person (Mitteilungs-Erweiterung) – der Server kennt sie nicht.
			$payload['aps']['mutable-content'] = 1;
		}
		$status = apns_send((string) $d['token'], (string) $d['environment'], $payload, !$shows);
		// 410: Das Gerät gibt es unter dieser Kennung nicht mehr (App gelöscht).
		if ($status === 410 || $status === 400) unregister_device($pdo, (string) $d['token']);
	}
}

/**
 * „Anna hat einen Termin eingetragen“ – oder null, wenn es nichts zu sagen gibt.
 * Den Titel kennt der Server nicht: Die Datensätze sind Ende-zu-Ende verschlüsselt.
 */
function change_text(string $who, array $changes): ?array
{
	$events = array_values(array_filter($changes, fn($c) => $c['kind'] === 'event'));
	if (count($events) === 1) {
		$c = $events[0];
		$what = 'einen Termin';
		$verb = $c['deleted'] ? 'gelöscht' : ($c['new'] ? 'eingetragen' : 'geändert');
		return ['title' => $who, 'body' => "hat $what $verb.", 'kind' => 'termine'];
	}
	if (count($events) > 1) return ['title' => $who, 'body' => 'hat ' . count($events) . ' Termine geändert.', 'kind' => 'termine'];
	// Ein neuer Eintrag im Gesundheitstagebuch ist meist etwas, das die anderen sofort wissen sollten.
	$notes = array_filter($changes, fn($c) => $c['kind'] === 'notes' && $c['new'] && !$c['deleted']);
	if ($notes) return ['title' => $who, 'body' => 'hat etwas ins Gesundheitstagebuch geschrieben.', 'kind' => 'tagebuch'];
	$health = array_filter($changes, fn($c) => in_array($c['kind'], ['vaccinations', 'deworming', 'meds', 'weight', 'notes'], true));
	if ($health) return ['title' => $who, 'body' => 'hat Gesundheitsdaten eingetragen.', 'kind' => 'gesundheit'];
	return null;
}

/**
 * Eine sichtbare Mitteilung an alle im Rudel, die diese Art bekommen wollen und dürfen.
 * `$except`: wer sie ausgelöst hat (bekommt nichts).
 */
function notify_pack_alert(PDO $pdo, int $packId, string $kind, array $alert, ?int $except = null, bool $urgent = false): void
{
	if (!push_configured()) return;
	$wants = pack_notify_map($pdo, $packId);
	$ids = array_keys(array_filter($wants, fn($kinds, $id) => $id !== $except && in_array($kind, $kinds, true), ARRAY_FILTER_USE_BOTH));
	if (!$ids) return;
	$in = implode(',', array_fill(0, count($ids), '?'));
	$stmt = $pdo->prepare("SELECT token, environment FROM push_devices WHERE account_id IN ($in)");
	$stmt->execute($ids);
	foreach ($stmt->fetchAll() as $d) {
		$aps = ['alert' => $alert, 'sound' => 'default'];
		if ($urgent) $aps['interruption-level'] = 'time-sensitive';
		$status = apns_send((string) $d['token'], (string) $d['environment'], ['aps' => $aps], false);
		if ($status === 410 || $status === 400) unregister_device($pdo, (string) $d['token']);
	}
}

/** Schickt eine Mitteilung; gibt den HTTP-Status zurück (0 bei Netzfehler). */
function apns_send(string $token, string $environment, array $payload, bool $silent): int
{
	if (!function_exists('curl_init') || !defined('CURL_HTTP_VERSION_2_0')) return 0;
	$host = $environment === 'production' ? 'https://api.push.apple.com' : 'https://api.sandbox.push.apple.com';
	$ch = curl_init("$host/3/device/" . rawurlencode($token));
	curl_setopt_array($ch, [
		CURLOPT_HTTP_VERSION => CURL_HTTP_VERSION_2_0,
		CURLOPT_POST => true,
		CURLOPT_POSTFIELDS => json_encode($payload, JSON_UNESCAPED_UNICODE),
		CURLOPT_RETURNTRANSFER => true,
		CURLOPT_TIMEOUT => 8,
		CURLOPT_HTTPHEADER => [
			'authorization: bearer ' . apns_jwt(),
			'apns-topic: ' . cfg('APNS_TOPIC'),
			'apns-push-type: ' . ($silent ? 'background' : 'alert'),
			'apns-priority: ' . ($silent ? '5' : '10'),
		],
	]);
	$body = curl_exec($ch);
	$status = (int) curl_getinfo($ch, CURLINFO_HTTP_CODE);
	curl_close($ch);
	if ($status !== 200) error_log('[stella] APNs ' . $status . ': ' . (is_string($body) ? $body : ''));
	return $status;
}

/**
 * Startet die Live-Aktivität einer Runde (Push-to-Start). `$state` ist der ContentState der App, so wie
 * ActivityKit ihn liest: Zeitpunkte als Sekunden seit 2001 (Swifts Standard für Date).
 */
function apns_live_start(string $token, string $environment, array $state): int
{
	if (!function_exists('curl_init') || !defined('CURL_HTTP_VERSION_2_0')) return 0;
	$host = $environment === 'production' ? 'https://api.push.apple.com' : 'https://api.sandbox.push.apple.com';
	$payload = ['aps' => [
		'timestamp' => time(),
		'event' => 'start',
		'content-state' => $state,
		'attributes-type' => 'WalkActivityAttributes',
		'attributes' => ['dogName' => ''],
		'alert' => ['title' => 'Runde läuft', 'body' => 'Auf der Watch gestartet.'],
		// Bleibt die Watch stumm, gilt die Anzeige nach einer Stunde als veraltet.
		'stale-date' => time() + 3600,
	]];
	$ch = curl_init("$host/3/device/" . rawurlencode($token));
	curl_setopt_array($ch, [
		CURLOPT_HTTP_VERSION => CURL_HTTP_VERSION_2_0,
		CURLOPT_POST => true,
		CURLOPT_POSTFIELDS => json_encode($payload, JSON_UNESCAPED_UNICODE),
		CURLOPT_RETURNTRANSFER => true,
		CURLOPT_TIMEOUT => 8,
		CURLOPT_HTTPHEADER => [
			'authorization: bearer ' . apns_jwt(),
			'apns-topic: ' . cfg('APNS_TOPIC') . '.push-type.liveactivity',
			'apns-push-type: liveactivity',
			'apns-priority: 10',
		],
	]);
	$body = curl_exec($ch);
	$status = (int) curl_getinfo($ch, CURLINFO_HTTP_CODE);
	curl_close($ch);
	if ($status !== 200) error_log('[stella] APNs live ' . $status . ': ' . (is_string($body) ? $body : ''));
	return $status;
}

/**
 * Der Anmeldenachweis bei Apple: ein mit dem .p8-Schlüssel signiertes JWT.
 * Apple will es höchstens stündlich neu; es wird 50 Minuten zwischengespeichert.
 */
function apns_jwt(): string
{
	$cache = data_file('apns-jwt.json');
	$cached = @json_decode((string) @file_get_contents($cache), true);
	if (is_array($cached) && ($cached['at'] ?? 0) > time() - 3000) return (string) $cached['jwt'];

	$b64 = fn(string $s) => rtrim(strtr(base64_encode($s), '+/', '-_'), '=');
	$head = $b64(json_encode(['alg' => 'ES256', 'kid' => cfg('APNS_KEY_ID')]));
	$claims = $b64(json_encode(['iss' => cfg('APNS_TEAM_ID'), 'iat' => time()]));
	$key = openssl_pkey_get_private((string) file_get_contents((string) cfg('APNS_KEY_FILE')));
	openssl_sign("$head.$claims", $der, $key, OPENSSL_ALGO_SHA256);
	$jwt = "$head.$claims." . $b64(der_to_raw_signature($der));
	@file_put_contents($cache, json_encode(['jwt' => $jwt, 'at' => time()]));
	return $jwt;
}

/** OpenSSL liefert ES256 als DER; JWT verlangt die 64 Byte r‖s. */
function der_to_raw_signature(string $der): string
{
	$pos = 2;
	$read = function () use ($der, &$pos): string {
		$pos++; // 0x02 INTEGER
		$len = ord($der[$pos++]);
		$v = substr($der, $pos, $len);
		$pos += $len;
		return str_pad(ltrim($v, "\x00"), 32, "\x00", STR_PAD_LEFT);
	};
	return $read() . $read();
}
