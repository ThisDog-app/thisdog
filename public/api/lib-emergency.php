<?php
declare(strict_types=1);

/**
 * Der Notfallpass eines Hundes: was auf der Seite hinter dem QR-Code steht.
 *
 * Die App schickt eine Momentaufnahme (Name, Rasse, Chip, Kontakte, Tierarzt,
 * Wichtiges, Foto). Nur diese Felder kommen an, jedes in der Länge begrenzt;
 * alles andere aus dem Rudel bleibt, wo es ist. Der Schlüssel in der Adresse
 * ist zufällig (128 Bit) – wer ihn nicht vom QR-Code hat, findet die Seite nicht.
 */

require_once __DIR__ . '/lib.php';
require_once __DIR__ . '/lib-push.php';

const EMERGENCY_FIELDS = [
	'name' => 60, 'breed' => 80, 'sex' => 20, 'age' => 40, 'chip' => 40,
	'ownerName' => 80, 'ownerPhone' => 40, 'vetName' => 120, 'vetPhone' => 40,
	'important' => 600, 'meds' => 600, 'note' => 600,
	// Entlaufen: seit wann („JJJJ-MM-TTTHH:MM“, Ortszeit), wo zuletzt gesehen, was ein Finder wissen sollte.
	'lostSince' => 20, 'lostWhere' => 200, 'lostNote' => 600,
];
/** Das Foto: dasselbe kleine JPEG wie der Avatar (Base64). */
const EMERGENCY_PHOTO_MAX = 80000;

function emergency_url(string $token): string
{
	return rtrim((string) cfg('APP_URL', 'https://thisdog.app'), '/') . '/notfall/' . $token;
}

/** Nur die bekannten Felder, als Text, gekürzt. */
function emergency_clean(array $card): array
{
	$out = [];
	foreach (EMERGENCY_FIELDS as $key => $max) {
		$v = trim((string) ($card[$key] ?? ''));
		$out[$key] = mb_substr($v, 0, $max);
	}
	return $out;
}

function emergency_get(PDO $pdo, int $packId): ?array
{
	$s = $pdo->prepare('SELECT * FROM emergency_cards WHERE pack_id = ?');
	$s->execute([$packId]);
	$row = $s->fetch();
	return $row === false ? null : $row;
}

function emergency_by_token(PDO $pdo, string $token): ?array
{
	if (!preg_match('/^[A-Za-z0-9_-]{20,64}$/', $token)) return null;
	$s = $pdo->prepare('SELECT * FROM emergency_cards WHERE token = ?');
	$s->execute([$token]);
	$row = $s->fetch();
	return $row === false ? null : $row;
}

/** Legt den Pass an oder ersetzt seinen Inhalt; der Schlüssel bleibt, damit gedruckte QR-Codes gültig bleiben. */
function emergency_publish(PDO $pdo, int $packId, array $card, ?string $photo, ?int $byAccount = null): array
{
	$clean = emergency_clean($card);
	$payload = json_encode($clean, JSON_UNESCAPED_UNICODE);
	$before = emergency_get($pdo, $packId);
	$wasLost = $before !== null && ((json_decode((string) $before['payload'], true) ?: [])['lostSince'] ?? '') !== '';
	if ($photo !== null && (strlen($photo) > EMERGENCY_PHOTO_MAX || base64_decode($photo, true) === false)) $photo = null;
	$existing = emergency_get($pdo, $packId);
	$token = $existing['token'] ?? rtrim(strtr(base64_encode(random_bytes(16)), '+/', '-_'), '=');
	$pdo->prepare(<<<'SQL'
		INSERT INTO emergency_cards (pack_id, token, payload, photo, updated_at) VALUES (?, ?, ?, ?, ?)
		ON CONFLICT(pack_id) DO UPDATE SET payload = excluded.payload, photo = excluded.photo, updated_at = excluded.updated_at
	SQL)->execute([$packId, $token, $payload, $photo, time()]);
	// Gerade als entlaufen gemeldet: Alle, die Notfälle bekommen, erfahren es sofort.
	if (!$wasLost && $clean['lostSince'] !== '') {
		$name = $clean['name'] !== '' ? $clean['name'] : 'Euer Hund';
		$where = $clean['lostWhere'] !== '' ? ' Zuletzt gesehen: ' . $clean['lostWhere'] . '.' : '';
		notify_pack_alert($pdo, $packId, 'notfall', ['title' => "$name wird vermisst", 'body' => "$name ist entlaufen.$where"], $byAccount, true);
	}
	return emergency_get($pdo, $packId);
}

/** Sperren: Die Seite verschwindet, der QR-Code führt ins Leere. Ein neuer Pass bekommt einen neuen Schlüssel. */
function emergency_revoke(PDO $pdo, int $packId): void
{
	$pdo->prepare('DELETE FROM emergency_cards WHERE pack_id = ?')->execute([$packId]);
}

function emergency_status(?array $row): array
{
	if ($row === null) return ['active' => false];
	return [
		'active' => true,
		'url' => emergency_url((string) $row['token']),
		'updatedAt' => (int) $row['updated_at'],
		'views' => (int) $row['views'],
		'lastViewAt' => $row['last_view_at'] === null ? null : (int) $row['last_view_at'],
	];
}

/**
 * Jemand hat den Pass geöffnet – vielleicht hat er den Hund gefunden. Das Rudel
 * erfährt es, höchstens alle zehn Minuten, damit Neuladen keine Flut auslöst.
 */
function emergency_viewed(PDO $pdo, array $row): void
{
	$now = time();
	$pdo->prepare('UPDATE emergency_cards SET views = views + 1, last_view_at = ? WHERE pack_id = ?')
		->execute([$now, (int) $row['pack_id']]);
	if ($row['notified_at'] !== null && $now - (int) $row['notified_at'] < 600) return;
	$pdo->prepare('UPDATE emergency_cards SET notified_at = ? WHERE pack_id = ?')->execute([$now, (int) $row['pack_id']]);
	if (!push_configured()) return;

	$card = json_decode((string) $row['payload'], true) ?: [];
	$name = (string) ($card['name'] ?? '') ?: 'Dein Hund';
	notify_pack_alert($pdo, (int) $row['pack_id'], 'notfall',
		['title' => 'Notfallpass geöffnet', 'body' => "Gerade hat jemand den Notfallpass von $name aufgerufen."], null, true);
}
