<?php
declare(strict_types=1);

/**
 * Das Rudel: die Menschen eines Hundes und ihre gemeinsamen Daten.
 *
 * Ein Konto kann in mehreren Rudeln sein (zwei Hunde, oder der Hund der
 * Eltern). Jedes Konto hat mindestens eines: Wer sich zum ersten Mal anmeldet,
 * bekommt sein eigenes. Wer keines nennt, meint das, dem er zuerst beigetreten
 * ist – so arbeitet die Web-App ohne Änderung weiter.
 */

require_once __DIR__ . '/lib-db.php';

/** Gültigkeit einer Einladung. Kurz genug, dass ein weitergeleiteter alter Link nichts mehr öffnet. */
const INVITE_TTL = 7 * 86400;
const PACK_MAX_MEMBERS = 12;

/** Rollen: Besitzer verwalten das Rudel, Hundesitter sind dabei, ohne gestört zu werden. */
const PACK_ROLES = ['owner', 'sitter'];

/**
 * Wofür es sichtbare Mitteilungen gibt:
 *   termine     – ein Termin wurde eingetragen, geändert, gelöscht
 *   gesundheit  – Impfung, Entwurmung, Medikament, Gewicht
 *   tagebuch    – neuer Eintrag im Gesundheitstagebuch
 *   notfall     – der Notfallpass wurde aufgerufen, der Hund ist entlaufen
 */
const NOTIFY_KINDS = ['termine', 'gesundheit', 'tagebuch', 'notfall'];

/** Ohne eigene Einstellung: Besitzer dürfen und wollen alles, Hundesitter dürfen alles, wollen aber nichts. */
function notify_defaults(string $role): array
{
	return ['allowed' => NOTIFY_KINDS, 'wanted' => $role === 'owner' ? NOTIFY_KINDS : []];
}

/** Eine gespeicherte Liste (JSON) oder der Standard; nur bekannte Arten. */
function notify_list(?string $json, array $fallback): array
{
	if ($json === null) return $fallback;
	$list = json_decode($json, true);
	return is_array($list) ? array_values(array_intersect(NOTIFY_KINDS, $list)) : $fallback;
}

/** Wer bei welcher Art eine sichtbare Mitteilung bekommt: erlaubt und gewollt. [Konto => [Arten]] */
function pack_notify_map(PDO $pdo, int $packId): array
{
	$s = $pdo->prepare('SELECT account_id, role, notify_allowed, notify_wanted FROM pack_members WHERE pack_id = ?');
	$s->execute([$packId]);
	$out = [];
	foreach ($s->fetchAll() as $r) {
		$d = notify_defaults((string) $r['role']);
		$out[(int) $r['account_id']] = array_values(array_intersect(
			notify_list($r['notify_allowed'], $d['allowed']), notify_list($r['notify_wanted'], $d['wanted'])));
	}
	return $out;
}

function member_role(PDO $pdo, int $packId, int $accountId): ?string
{
	$s = $pdo->prepare('SELECT role FROM pack_members WHERE pack_id = ? AND account_id = ?');
	$s->execute([$packId, $accountId]);
	$r = $s->fetchColumn();
	return $r === false ? null : (string) $r;
}

function is_owner(PDO $pdo, int $packId, int $accountId): bool
{
	return member_role($pdo, $packId, $accountId) === 'owner';
}

/**
 * Rolle ändern (nur Besitzer). Den letzten Besitzer gibt es nicht als Hundesitter:
 * Sonst könnte niemand mehr einladen oder Rollen vergeben.
 */
function set_member_role(PDO $pdo, int $packId, int $byAccount, int $member, string $role): array
{
	if (!in_array($role, PACK_ROLES, true)) return ['error' => 'bad_role'];
	if (!is_owner($pdo, $packId, $byAccount)) return ['error' => 'not_owner'];
	if (member_role($pdo, $packId, $member) === null) return ['error' => 'not_a_member'];
	if ($role === 'sitter') {
		$s = $pdo->prepare("SELECT COUNT(*) FROM pack_members WHERE pack_id = ? AND role = 'owner' AND account_id != ?");
		$s->execute([$packId, $member]);
		if ((int) $s->fetchColumn() === 0) return ['error' => 'last_owner'];
	}
	// Mit der Rolle wechselt auch der Standard dessen, was jemand will – eine eigene Wahl bleibt.
	$pdo->prepare('UPDATE pack_members SET role = ? WHERE pack_id = ? AND account_id = ?')->execute([$role, $packId, $member]);
	return ['ok' => true];
}

/**
 * Mitteilungen einstellen. `allowed` dürfen nur Besitzer setzen (für jeden), `wanted` nur das
 * Mitglied selbst. null lässt den jeweiligen Wert, wie er ist.
 */
function set_member_notify(PDO $pdo, int $packId, int $byAccount, int $member, ?array $allowed, ?array $wanted): array
{
	if (member_role($pdo, $packId, $member) === null) return ['error' => 'not_a_member'];
	if ($allowed !== null) {
		if (!is_owner($pdo, $packId, $byAccount)) return ['error' => 'not_owner'];
		$pdo->prepare('UPDATE pack_members SET notify_allowed = ? WHERE pack_id = ? AND account_id = ?')
			->execute([json_encode(array_values(array_intersect(NOTIFY_KINDS, $allowed))), $packId, $member]);
	}
	if ($wanted !== null) {
		if ($byAccount !== $member) return ['error' => 'not_yours'];
		$pdo->prepare('UPDATE pack_members SET notify_wanted = ? WHERE pack_id = ? AND account_id = ?')
			->execute([json_encode(array_values(array_intersect(NOTIFY_KINDS, $wanted))), $packId, $member]);
	}
	return ['ok' => true];
}

/** Die Rudel eines Kontos, älteste Mitgliedschaft zuerst. */
function account_packs(PDO $pdo, int $accountId): array
{
	$stmt = $pdo->prepare('SELECT pack_id FROM pack_members WHERE account_id = ? ORDER BY joined_at, pack_id');
	$stmt->execute([$accountId]);
	return array_map('intval', $stmt->fetchAll(PDO::FETCH_COLUMN));
}

/**
 * Das Rudel, um das es in dieser Anfrage geht.
 *
 * Genannt (`pack`) und das Konto ist Mitglied → dieses. Nicht genannt → das
 * erste; hat das Konto noch keines, entsteht es jetzt. Genannt, aber kein
 * Mitglied → null; die Schnittstelle antwortet dann 403, statt still ein
 * anderes Rudel zu benutzen.
 */
function resolve_pack(PDO $pdo, int $accountId, ?int $requested): ?int
{
	$packs = account_packs($pdo, $accountId);
	if ($requested !== null && $requested > 0) {
		return in_array($requested, $packs, true) ? $requested : null;
	}
	return $packs[0] ?? create_pack($pdo, $accountId);
}

function create_pack(PDO $pdo, int $accountId): int
{
	$now = time();
	$pdo->prepare('INSERT INTO packs (created_at, created_by) VALUES (?, ?)')->execute([$now, $accountId]);
	$packId = (int) $pdo->lastInsertId();
	$pdo->prepare('INSERT INTO pack_members (pack_id, account_id, joined_at) VALUES (?, ?, ?)')
		->execute([$packId, $accountId, $now]);
	return $packId;
}

/** Mitglieder eines Rudels mit Anzeigename; ohne Namen der Teil der Adresse vor dem @. */
function pack_members(PDO $pdo, int $packId): array
{
	$stmt = $pdo->prepare(<<<'SQL'
		SELECT m.account_id, m.display_name, m.joined_at, m.role, m.notify_allowed, m.notify_wanted, a.email
		FROM pack_members m JOIN accounts a ON a.id = m.account_id
		WHERE m.pack_id = ? ORDER BY m.joined_at, m.account_id
	SQL);
	$stmt->execute([$packId]);
	return array_map(function ($r) {
		$d = notify_defaults((string) $r['role']);
		return [
			'id' => (int) $r['account_id'],
			'name' => member_name($r['display_name'], $r['email'] === null ? null : (string) $r['email']),
			'joinedAt' => (int) $r['joined_at'],
			'role' => (string) $r['role'],
			'notifyAllowed' => notify_list($r['notify_allowed'], $d['allowed']),
			'notifyWanted' => notify_list($r['notify_wanted'], $d['wanted']),
		];
	}, $stmt->fetchAll());
}

function member_name(?string $displayName, ?string $email): string
{
	$name = trim((string) $displayName);
	if ($name !== '') return $name;
	$local = $email === null ? false : strstr($email, '@', true);
	return $local !== false && $local !== '' ? $local : 'Rudelmitglied';
}

/** Ein neuer Einladungslink; das Geheimnis steht nur im Link, in der Datenbank sein Hash. */
function create_invite(PDO $pdo, int $packId, int $accountId, string $role = 'sitter'): array
{
	$secret = new_secret(24);
	$now = time();
	$pdo->prepare('INSERT INTO pack_invites (token_hash, pack_id, created_by, created_at, expires_at, role) VALUES (?, ?, ?, ?, ?, ?)')
		->execute([secret_hash($secret), $packId, $accountId, $now, $now + INVITE_TTL, in_array($role, PACK_ROLES, true) ? $role : 'sitter']);
	return ['secret' => $secret, 'expiresAt' => ($now + INVITE_TTL) * 1000];
}

/**
 * Tritt mit einer Einladung einem Rudel bei.
 *
 * Gibt das Rudel zurück oder einen Fehlercode. Eine Einladung gilt sieben Tage
 * für beliebig viele Personen (bis das Rudel voll ist), damit ein Link etwa für
 * beide Hundesitter reicht. used_at/used_by halten den letzten Beitritt fest.
 */
function join_with_invite(PDO $pdo, int $accountId, string $secret): array
{
	$stmt = $pdo->prepare('SELECT pack_id, expires_at, used_at, role FROM pack_invites WHERE token_hash = ?');
	$stmt->execute([secret_hash($secret)]);
	$invite = $stmt->fetch();
	if (!$invite) return ['error' => 'invite_unknown'];

	$packId = (int) $invite['pack_id'];
	if (in_array($packId, account_packs($pdo, $accountId), true)) return ['pack' => $packId, 'already' => true];
	if ((int) $invite['expires_at'] < time()) return ['error' => 'invite_expired'];
	if (count(pack_members($pdo, $packId)) >= PACK_MAX_MEMBERS) return ['error' => 'pack_full'];

	$now = time();
	$pdo->beginTransaction();
	try {
		$pdo->prepare('INSERT INTO pack_members (pack_id, account_id, joined_at, role) VALUES (?, ?, ?, ?)')
			->execute([$packId, $accountId, $now, (string) ($invite['role'] ?? 'sitter')]);
		$pdo->prepare('UPDATE pack_invites SET used_at = ?, used_by = ? WHERE token_hash = ?')
			->execute([$now, $accountId, secret_hash($secret)]);
		$pdo->commit();
	} catch (Throwable $e) {
		$pdo->rollBack();
		throw $e;
	}
	return ['pack' => $packId, 'already' => false];
}

/**
 * Verlässt ein Rudel. Geht das letzte Mitglied, verschwindet das Rudel mit
 * allen Daten – niemand könnte sie sonst je wieder lesen oder löschen.
 * Ein Konto ohne Rudel bekommt beim nächsten Zugriff ein neues, leeres.
 */
/**
 * Ein Mitglied entfernen – nur Besitzer, nicht sich selbst (dafür gibt es „verlassen“). Das Konto verliert sofort
 * den Zugang zu allem, was der Server hat; seine Geräte bekommen keine Mitteilungen des Rudels mehr. Was es schon
 * geladen hat, bleibt auf seinen Geräten – das lässt sich nicht zurückholen.
 */
function remove_member(PDO $pdo, int $packId, int $byAccount, int $member): array
{
	if (!is_owner($pdo, $packId, $byAccount)) return ['error' => 'not_owner'];
	if ($member === $byAccount) return ['error' => 'use_leave'];
	if (member_role($pdo, $packId, $member) === null) return ['error' => 'not_a_member'];
	$pdo->prepare('DELETE FROM pack_members WHERE pack_id = ? AND account_id = ?')->execute([$packId, $member]);
	return ['ok' => true];
}

/** Macht alle noch gültigen Einladungslinks des Rudels ungültig; gibt zurück, wie viele es waren. */
function revoke_invites(PDO $pdo, int $packId): int
{
	$now = time();
	$s = $pdo->prepare('UPDATE pack_invites SET expires_at = ? WHERE pack_id = ? AND expires_at > ?');
	$s->execute([$now - 1, $packId, $now]);
	return $s->rowCount();
}

/** Wie viele Einladungslinks noch gelten. */
function open_invites(PDO $pdo, int $packId): int
{
	$s = $pdo->prepare('SELECT COUNT(*) FROM pack_invites WHERE pack_id = ? AND expires_at > ?');
	$s->execute([$packId, time()]);
	return (int) $s->fetchColumn();
}

function leave_pack(PDO $pdo, int $accountId, int $packId): array
{
	$pdo->prepare('DELETE FROM pack_members WHERE pack_id = ? AND account_id = ?')->execute([$packId, $accountId]);
	$left = count(pack_members($pdo, $packId));
	if ($left === 0) $pdo->prepare('DELETE FROM packs WHERE id = ?')->execute([$packId]);
	// Geht der letzte Besitzer, wird das am längsten dabei gewesene Mitglied Besitzer – sonst
	// könnte niemand mehr einladen.
	if ($left > 0 && !in_array('owner', array_column(pack_members($pdo, $packId), 'role'), true)) {
		$pdo->prepare("UPDATE pack_members SET role = 'owner' WHERE pack_id = ? AND account_id = (SELECT account_id FROM pack_members WHERE pack_id = ? ORDER BY joined_at, account_id LIMIT 1)")
			->execute([$packId, $packId]);
	}
	return ['ok' => true, 'packRemoved' => $left === 0];
}

/** Der Name, unter dem jemand im Rudel erscheint („Anna“). */
function set_display_name(PDO $pdo, int $accountId, int $packId, string $name): void
{
	$name = mb_substr(trim(preg_replace('/\s+/u', ' ', $name) ?? ''), 0, 40);
	$pdo->prepare('UPDATE pack_members SET display_name = ? WHERE pack_id = ? AND account_id = ?')
		->execute([$name === '' ? null : $name, $packId, $accountId]);
}

/**
 * Nächste Revision des Rudels. Fortlaufend je Rudel: Die Zahl sagt jedem
 * Gerät genau, wie viel es verpasst hat.
 */
/**
 * Die nächste Revision des Rudels. Sie steigt nur: Der Zähler steht im Rudel selbst, damit
 * gelöschte Zeilen (Klartext nach dem Umzug) ihn nicht zurückdrehen – sonst verpasste ein
 * Gerät, das schon weiter war, alles Neue.
 */
function next_rev(PDO $pdo, int $packId): int
{
	$stmt = $pdo->prepare('SELECT MAX(COALESCE((SELECT MAX(rev) FROM pack_records WHERE pack_id = ?), 0), COALESCE(rev, 0)) FROM packs WHERE id = ?');
	$stmt->execute([$packId, $packId]);
	$next = (int) $stmt->fetchColumn() + 1;
	$pdo->prepare('UPDATE packs SET rev = ? WHERE id = ?')->execute([$next, $packId]);
	return $next;
}

/** Das Rudel nimmt nur noch verschlüsselte Datensätze an. */
function pack_sealed(PDO $pdo, int $packId): bool
{
	$s = $pdo->prepare('SELECT sealed_at IS NOT NULL FROM packs WHERE id = ?');
	$s->execute([$packId]);
	return (bool) $s->fetchColumn();
}

function pack_has_sealed_records(PDO $pdo, int $packId): bool
{
	$s = $pdo->prepare("SELECT 1 FROM pack_records WHERE pack_id = ? AND payload LIKE '{\"e\":%' LIMIT 1");
	$s->execute([$packId]);
	return $s->fetchColumn() !== false;
}

/** `{"e": "<Base64>"}` und sonst nichts – so sieht ein verschlüsselter Datensatz aus. */
function is_sealed_payload($payload): bool
{
	return is_array($payload) && count($payload) === 1 && isset($payload['e']) && is_string($payload['e'])
		&& preg_match('/^[A-Za-z0-9+\/]+={0,2}$/', $payload['e']) === 1;
}

