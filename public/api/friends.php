<?php
declare(strict_types=1);

/**
 * Hundefreunde (nur Mitglieder des Rudels). Alle Pakete sind Ende-zu-Ende verschlüsselt.
 *
 *   GET  ?action=list&pack=<id>                       → {friends: [{pack, invite, card}]}
 *   GET  ?action=live&pack=<id>                       → {live: [{pack, blob, startedAt, updatedAt}]}
 *   POST ?action=invite    {pack}                     → {url, expiresAt, invite}
 *   POST ?action=accept    {pack, invite}             → {friend, invite}
 *   POST ?action=remove    {pack, friend}             → {ok}
 *   POST ?action=cards     {pack, blobs:[{friend,blob}]}            → {ok}
 *   POST ?action=position  {pack, started, blobs:[{friend,blob}]}   → {ok}
 *   POST ?action=stop      {pack}                     → {ok}
 *   POST ?action=checkin   {pack, blobs:[{friend,blob}]}            → {ok}
 *   GET  ?action=checkins&pack=<id>                   → {checkins: [{pack, blob, updatedAt}]}
 */

require_once __DIR__ . '/lib.php';
require_once __DIR__ . '/lib-db.php';
require_once __DIR__ . '/lib-pack.php';
require_once __DIR__ . '/lib-friends.php';
require_once __DIR__ . '/auth-session.php';

handle_preflight();
guard_origin();

try {
	$pdo = db();
	$session = current_session($pdo);
	if ($session === null) respond(['error' => 'not_signed_in'], 401);
	$accountId = (int) $session['account_id'];

	$action = (string) ($_GET['action'] ?? '');
	$raw = file_get_contents('php://input');
	$body = is_string($raw) && $raw !== '' ? (json_decode($raw, true) ?: []) : [];
	$requested = isset($body['pack']) ? (int) $body['pack'] : (isset($_GET['pack']) ? (int) $_GET['pack'] : null);
	$packId = resolve_pack($pdo, $accountId, $requested);
	if ($packId === null) respond(['error' => 'not_a_member'], 403);
	if (!in_array($action, ['list', 'live', 'checkins'], true) && ($_SERVER['REQUEST_METHOD'] ?? '') !== 'POST') respond(['error' => 'method_not_allowed'], 405);
	$blobs = is_array($body['blobs'] ?? null) ? $body['blobs'] : [];

	switch ($action) {
		case 'list':
			respond(['friends' => friends_list($pdo, $packId)]);
		case 'live':
			respond(['live' => friends_live($pdo, $packId)]);
		case 'checkins':
			respond(['checkins' => friends_checkins($pdo, $packId)]);
		case 'checkin':
			if (!rate_ok('checkin:' . $accountId, 60)) respond(['error' => 'rate_limited'], 429);
			store_blobs($pdo, $packId, 'checkin', $blobs, null);
			respond(['ok' => true]);
		case 'invite':
			if (!rate_ok('friend-invite:' . $accountId, 20)) respond(['error' => 'rate_limited'], 429);
			respond(create_friend_invite($pdo, $packId, $accountId));
		case 'accept':
			$secret = (string) ($body['invite'] ?? '');
			if (!preg_match('/^[A-Za-z0-9_-]{20,64}$/', $secret)) respond(['error' => 'invite_unknown'], 404);
			if (!rate_ok('friend-accept:' . $accountId, 30)) respond(['error' => 'rate_limited'], 429);
			$r = accept_friend_invite($pdo, $packId, $secret);
			if (isset($r['error'])) respond($r, $r['error'] === 'invite_unknown' ? 404 : 410);
			respond($r);
		case 'remove':
			remove_friend($pdo, $packId, (int) ($body['friend'] ?? 0));
			respond(['ok' => true]);
		case 'cards':
			if (!rate_ok('friend-cards:' . $accountId, 120)) respond(['error' => 'rate_limited'], 429);
			store_blobs($pdo, $packId, 'card', $blobs, null);
			respond(['ok' => true]);
		case 'position':
			if (!rate_ok('position:' . $accountId, 600)) respond(['error' => 'rate_limited'], 429);
			post_positions($pdo, $packId, $blobs, (int) ($body['started'] ?? time()));
			respond(['ok' => true]);
		case 'stop':
			stop_positions($pdo, $packId);
			respond(['ok' => true]);
		default:
			respond(['error' => 'unknown_action'], 400);
	}
} catch (Throwable $e) {
	error_log('[stella] friends: ' . $e->getMessage());
	respond(['error' => 'server'], 500);
}
