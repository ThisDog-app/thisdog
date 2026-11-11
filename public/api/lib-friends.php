<?php
declare(strict_types=1);

/**
 * Hundefreunde: zwei Rudel, die sich während einer Runde auf der Karte sehen.
 *
 * Eine Freundschaft gilt in beide Richtungen und entsteht über einen
 * Einladungslink (einmal gültig, sieben Tage). Beenden kann sie jede Seite.
 *
 * Der Server liest nichts davon. Jede Freundschaft hat einen eigenen Schlüssel,
 * der nur im Einladungslink hinter dem „#“ reist. Steckbrief (Name, Foto) und
 * Standort legt die App verschlüsselt ab, je Freund ein Paket („blob“); der
 * Server reicht sie nur weiter. Ob ein Freund in der Nähe ist, rechnet das
 * Gerät des Freundes aus, nachdem der Server es still geweckt hat.
 *
 * Standorte gibt es nur während einer Runde und immer nur den letzten Punkt.
 * Mit dem Beenden der Runde verschwinden sie, nach fünf Minuten ohne neuen
 * Punkt gelten sie als verwaist und werden nicht mehr ausgeliefert.
 */

require_once __DIR__ . '/lib.php';
require_once __DIR__ . '/lib-push.php';

const FRIEND_INVITE_DAYS = 7;
const LIVE_STALE_SECONDS = 300;
const FRIEND_BLOB_MAX = 120000;

function friend_url(string $secret): string
{
	return rtrim((string) cfg('APP_URL', 'https://thisdog.app'), '/') . '/freund/' . $secret;
}

/** Die Kennung einer Einladung, unter der beide Seiten den Schlüssel der Freundschaft ablegen. */
function invite_id(string $secret): string
{
	return substr(hash('sha256', 'freund:' . $secret), 0, 32);
}

function friend_pair(int $x, int $y): array { return $x < $y ? [$x, $y] : [$y, $x]; }

/** [Rudel des Freundes => Kennung der Einladung] */
function friend_map(PDO $pdo, int $packId): array
{
	$s = $pdo->prepare('SELECT pack_a, pack_b, invite FROM friendships WHERE pack_a = ? OR pack_b = ?');
	$s->execute([$packId, $packId]);
	$out = [];
	foreach ($s->fetchAll() as $r) $out[(int) $r['pack_a'] === $packId ? (int) $r['pack_b'] : (int) $r['pack_a']] = (string) $r['invite'];
	return $out;
}

function create_friend_invite(PDO $pdo, int $packId, int $accountId): array
{
	$secret = rtrim(strtr(base64_encode(random_bytes(18)), '+/', '-_'), '=');
	$now = time();
	$exp = $now + FRIEND_INVITE_DAYS * 86400;
	$pdo->prepare('INSERT INTO friend_invites (secret, pack_id, created_by, created_at, expires_at) VALUES (?, ?, ?, ?, ?)')
		->execute([$secret, $packId, $accountId, $now, $exp]);
	return ['url' => friend_url($secret), 'expiresAt' => $exp, 'invite' => invite_id($secret)];
}

/** Fehler als Code: invite_unknown, invite_used, invite_expired, own_pack. */
function accept_friend_invite(PDO $pdo, int $packId, string $secret): array
{
	$s = $pdo->prepare('SELECT * FROM friend_invites WHERE secret = ?');
	$s->execute([$secret]);
	$inv = $s->fetch();
	if ($inv === false) return ['error' => 'invite_unknown'];
	if ($inv['used_at'] !== null) return ['error' => 'invite_used'];
	if ((int) $inv['expires_at'] < time()) return ['error' => 'invite_expired'];
	$other = (int) $inv['pack_id'];
	if ($other === $packId) return ['error' => 'own_pack'];
	[$a, $b] = friend_pair($packId, $other);
	$id = invite_id($secret);
	$pdo->prepare('INSERT OR REPLACE INTO friendships (pack_a, pack_b, invite, created_at) VALUES (?, ?, ?, ?)')->execute([$a, $b, $id, time()]);
	$pdo->prepare('UPDATE friend_invites SET used_at = ? WHERE secret = ?')->execute([time(), $secret]);
	return ['friend' => $other, 'invite' => $id];
}

function remove_friend(PDO $pdo, int $packId, int $other): void
{
	[$a, $b] = friend_pair($packId, $other);
	$pdo->prepare('DELETE FROM friendships WHERE pack_a = ? AND pack_b = ?')->execute([$a, $b]);
	$pdo->prepare('DELETE FROM friend_blobs WHERE (from_pack = ? AND to_pack = ?) OR (from_pack = ? AND to_pack = ?)')
		->execute([$packId, $other, $other, $packId]);
}

/** Die Freunde mit ihrem (verschlüsselten) Steckbrief für dieses Rudel. */
function friends_list(PDO $pdo, int $packId): array
{
	$out = [];
	$card = $pdo->prepare("SELECT blob, updated_at FROM friend_blobs WHERE from_pack = ? AND to_pack = ? AND kind = 'card'");
	foreach (friend_map($pdo, $packId) as $friend => $invite) {
		$card->execute([$friend, $packId]);
		$c = $card->fetch();
		$out[] = ['pack' => $friend, 'invite' => $invite, 'card' => $c === false ? null : (string) $c['blob']];
	}
	return $out;
}

/** Legt verschlüsselte Pakete ab – nur für Rudel, die wirklich befreundet sind. */
function store_blobs(PDO $pdo, int $packId, string $kind, array $blobs, ?int $startedAt): array
{
	$friends = friend_map($pdo, $packId);
	$write = $pdo->prepare(<<<'SQL'
		INSERT INTO friend_blobs (from_pack, to_pack, kind, blob, started_at, updated_at) VALUES (?, ?, ?, ?, ?, ?)
		ON CONFLICT(from_pack, to_pack, kind) DO UPDATE SET blob = excluded.blob, started_at = excluded.started_at, updated_at = excluded.updated_at
	SQL);
	$stored = [];
	foreach ($blobs as $b) {
		$to = (int) ($b['friend'] ?? 0);
		$blob = (string) ($b['blob'] ?? '');
		if (!isset($friends[$to]) || $blob === '' || strlen($blob) > FRIEND_BLOB_MAX || !preg_match('/^[A-Za-z0-9+\/]+={0,2}$/', $blob)) continue;
		$write->execute([$packId, $to, $kind, $blob, $startedAt, time()]);
		$stored[$to] = $blob;
	}
	return $stored;
}

/**
 * Ein Punkt der laufenden Runde, je Freund verschlüsselt. Beim ersten Punkt einer
 * Runde weckt der Server die Geräte der Freunde still, mit ihrem Paket – je Freund
 * und Runde einmal. Ob es „in der Nähe“ ist, entscheidet dort das Gerät.
 */
function post_positions(PDO $pdo, int $packId, array $blobs, int $startedAt): void
{
	foreach (store_blobs($pdo, $packId, 'pos', $blobs, $startedAt) as $friend => $blob) {
		$once = $pdo->prepare('INSERT OR IGNORE INTO nearby_notices (from_pack, to_pack, started_at) VALUES (?, ?, ?)');
		$once->execute([$packId, $friend, $startedAt]);
		if ($once->rowCount() === 0 || !push_configured()) continue;
		$devices = $pdo->prepare('SELECT d.token, d.environment FROM push_devices d JOIN pack_members m ON m.account_id = d.account_id WHERE m.pack_id = ?');
		$devices->execute([$friend]);
		foreach ($devices->fetchAll() as $d) {
			apns_send((string) $d['token'], (string) $d['environment'],
				['aps' => ['content-available' => 1], 'friend' => $packId, 'e' => $blob, 'started' => $startedAt], true);
		}
	}
}

function stop_positions(PDO $pdo, int $packId): void
{
	$pdo->prepare("DELETE FROM friend_blobs WHERE from_pack = ? AND kind = 'pos'")->execute([$packId]);
}

/** Was Freunde gerade für dieses Rudel unterwegs abgelegt haben. */
/** So lange sehen Freunde einen Check-in („Bello ist seit 10 Minuten im Augarten“). */
const CHECKIN_SECONDS = 3 * 3600;

/** Check-ins der Freunde aus den letzten drei Stunden, je Freund der letzte, verschlüsselt. */
function friends_checkins(PDO $pdo, int $packId): array
{
	$s = $pdo->prepare("SELECT from_pack, blob, updated_at FROM friend_blobs WHERE to_pack = ? AND kind = 'checkin' AND updated_at >= ?");
	$s->execute([$packId, time() - CHECKIN_SECONDS]);
	$friends = friend_map($pdo, $packId);
	$out = [];
	foreach ($s->fetchAll() as $r) {
		if (!isset($friends[(int) $r['from_pack']])) continue;
		$out[] = ['pack' => (int) $r['from_pack'], 'blob' => (string) $r['blob'], 'updatedAt' => (int) $r['updated_at']];
	}
	return $out;
}

function friends_live(PDO $pdo, int $packId): array
{
	$s = $pdo->prepare("SELECT from_pack, blob, started_at, updated_at FROM friend_blobs WHERE to_pack = ? AND kind = 'pos' AND updated_at >= ?");
	$s->execute([$packId, time() - LIVE_STALE_SECONDS]);
	$friends = friend_map($pdo, $packId);
	$out = [];
	foreach ($s->fetchAll() as $r) {
		if (!isset($friends[(int) $r['from_pack']])) continue;
		$out[] = ['pack' => (int) $r['from_pack'], 'blob' => (string) $r['blob'], 'startedAt' => (int) $r['started_at'], 'updatedAt' => (int) $r['updated_at']];
	}
	return $out;
}
