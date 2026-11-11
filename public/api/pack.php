<?php
declare(strict_types=1);

/**
 * Das Rudel: wer zu einem Hund gehört, und wie man dazukommt.
 *
 *   GET  ?action=list                         → meine Rudel mit Mitgliedern
 *   POST ?action=invite   {pack, role?}       → Einladungslink (7 Tage, für mehrere), role: owner|sitter
 *   POST ?action=role     {pack, member, role}  → Rolle ändern (nur Besitzer)
 *   POST ?action=notify   {pack, member, allowed?, wanted?} → Mitteilungen (allowed: Besitzer, wanted: man selbst)
 *   POST ?action=join     {invite}            → mit einer Einladung beitreten
 *   POST ?action=leave    {pack}              → Rudel verlassen
 *   POST ?action=remove   {pack, member}      → ein Mitglied entfernen (nur Besitzer, nicht sich selbst)
 *   POST ?action=revoke_invites {pack}        → alle offenen Einladungslinks ungültig machen (nur Besitzer)
 *   POST ?action=name     {pack, name}        → wie ich im Rudel heiße („Anna“)
 *   POST ?action=create                       → ein weiteres Rudel (zweiter Hund)
 *   POST ?action=seal     {pack}              → {granted}: dieses Gerät legt den Schlüssel an
 *
 * Besitzer laden ein und vergeben Rollen; Hundesitter sind dabei, ohne gestört zu
 * werden. Hinauswerfen gibt es nicht: In einem Rudel aus ein paar Menschen klärt man
 * das miteinander, und die Daten gehören allen, die sie haben.
 */

require_once __DIR__ . '/lib.php';
require_once __DIR__ . '/lib-db.php';
require_once __DIR__ . '/lib-pack.php';
require_once __DIR__ . '/auth-session.php';

handle_preflight();
guard_origin();

try {
	$pdo = db();
	$session = current_session($pdo);
	if ($session === null) respond(['error' => 'not_signed_in'], 401);
	$accountId = (int) $session['account_id'];

	$action = (string) ($_GET['action'] ?? '');
	if ($action !== 'list' && ($_SERVER['REQUEST_METHOD'] ?? '') !== 'POST') respond(['error' => 'method_not_allowed'], 405);
	$body = pack_json_input();
	$member = function () use ($pdo, $accountId, $body): int {
		$packId = resolve_pack($pdo, $accountId, isset($body['pack']) ? (int) $body['pack'] : null);
		if ($packId === null) respond(['error' => 'not_a_member'], 403);
		return $packId;
	};

	switch ($action) {
		case 'list':
			resolve_pack($pdo, $accountId, null); // legt das erste Rudel an, falls es fehlt
			respond(['me' => $accountId, 'packs' => array_map(
				fn($id) => ['id' => $id, 'members' => pack_members($pdo, $id), 'sealed' => pack_sealed($pdo, $id),
					'openInvites' => open_invites($pdo, $id)],
				account_packs($pdo, $accountId),
			)]);

		case 'invite':
			$packId = $member();
			if (!is_owner($pdo, $packId, $accountId)) respond(['error' => 'not_owner'], 403);
			if (!rate_ok('invite:' . $accountId, 20)) respond(['error' => 'rate_limited'], 429);
			// Ohne Angabe als Hundesitter: Ein weitergeleiteter Link soll nicht zum Besitzer machen.
			$role = (string) ($body['role'] ?? 'sitter');
			if (!in_array($role, PACK_ROLES, true)) respond(['error' => 'bad_role'], 400);
			$invite = create_invite($pdo, $packId, $accountId, $role);
			respond([
				'url' => rtrim((string) cfg('APP_URL', 'https://thisdog.app'), '/') . '/rudel/' . $invite['secret'],
				'expiresAt' => $invite['expiresAt'],
			]);

		case 'join':
			$secret = (string) ($body['invite'] ?? '');
			if (!preg_match('/^[A-Za-z0-9_-]{20,64}$/', $secret)) respond(['error' => 'invite_unknown'], 404);
			if (!rate_ok('join:' . $accountId, 30)) respond(['error' => 'rate_limited'], 429);
			$result = join_with_invite($pdo, $accountId, $secret);
			if (isset($result['error'])) respond($result, $result['error'] === 'invite_unknown' ? 404 : 410);
			respond($result + ['members' => pack_members($pdo, $result['pack'])]);

		case 'leave':
			respond(leave_pack($pdo, $accountId, $member()));

		case 'remove':
			$packId = $member();
			$r = remove_member($pdo, $packId, $accountId, (int) ($body['member'] ?? 0));
			if (isset($r['error'])) respond($r, 403);
			respond(['ok' => true, 'members' => pack_members($pdo, $packId)]);

		case 'revoke_invites':
			$packId = $member();
			if (!is_owner($pdo, $packId, $accountId)) respond(['error' => 'not_owner'], 403);
			respond(['ok' => true, 'revoked' => revoke_invites($pdo, $packId)]);

		case 'name':
			$packId = $member();
			set_display_name($pdo, $accountId, $packId, (string) ($body['name'] ?? ''));
			respond(['ok' => true, 'members' => pack_members($pdo, $packId)]);

		case 'role':
			$packId = $member();
			$r = set_member_role($pdo, $packId, $accountId, (int) ($body['member'] ?? 0), (string) ($body['role'] ?? ''));
			if (isset($r['error'])) respond($r, 403);
			respond(['ok' => true, 'members' => pack_members($pdo, $packId)]);

		case 'notify':
			$packId = $member();
			$list = fn($k) => isset($body[$k]) && is_array($body[$k]) ? array_map('strval', $body[$k]) : null;
			$r = set_member_notify($pdo, $packId, $accountId, (int) ($body['member'] ?? $accountId), $list('allowed'), $list('wanted'));
			if (isset($r['error'])) respond($r, 403);
			respond(['ok' => true, 'members' => pack_members($pdo, $packId)]);

		case 'seal':
			// Ein Rudel wird einmal verschlüsselt. Den Schlüssel legt das erste Gerät an,
			// das fragt; andere warten, bis er sie über den iCloud-Schlüsselbund oder einen
			// Einladungslink erreicht. Liegt noch nichts Verschlüsseltes vor (das Gerät
			// stürzte nach dem Fragen ab), darf erneut angelegt werden.
			// In einem Schritt: Zwei Geräte, die zugleich fragen, bekämen sonst beide ja und legten zwei Schlüssel an.
			// Liegt noch nichts Verschlüsseltes vor, darf dasselbe Konto sofort erneut anlegen (Absturz nach dem Fragen),
			// ein anderes erst nach zehn Minuten.
			$packId = $member();
			$now = time();
			$granted = false;
			if (!pack_has_sealed_records($pdo, $packId)) {
				$grant = $pdo->prepare('UPDATE packs SET sealed_at = ?, sealed_by = ? WHERE id = ? AND (sealed_at IS NULL OR sealed_by = ? OR sealed_at < ?)');
				$grant->execute([$now, $accountId, $packId, $accountId, $now - 600]);
				$granted = $grant->rowCount() === 1;
			}
			respond(['granted' => $granted]);

		case 'create':
			$packId = create_pack($pdo, $accountId);
			respond(['pack' => $packId, 'members' => pack_members($pdo, $packId)]);
	}
	respond(['error' => 'unknown_action'], 404);
} catch (Throwable $e) {
	error_log('[stella] Rudel: ' . $e->getMessage());
	respond(['error' => 'server_error'], 500);
}

function pack_json_input(): array
{
	$raw = file_get_contents('php://input');
	$data = is_string($raw) && $raw !== '' ? json_decode($raw, true) : null;
	return is_array($data) ? $data : [];
}
