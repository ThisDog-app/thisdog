<?php
declare(strict_types=1);

/**
 * Notfallpass verwalten (nur Mitglieder des Rudels).
 *
 *   GET  ?action=status&pack=<id>                 → {active, url, updatedAt, views, lastViewAt}
 *   POST ?action=publish  {pack, card, photo?}    → wie status; legt an oder aktualisiert
 *   POST ?action=revoke   {pack}                  → {active: false}
 */

require_once __DIR__ . '/lib.php';
require_once __DIR__ . '/lib-db.php';
require_once __DIR__ . '/lib-pack.php';
require_once __DIR__ . '/lib-emergency.php';
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

	switch ($action) {
		case 'status':
			respond(emergency_status(emergency_get($pdo, $packId)));
		case 'publish':
			if (($_SERVER['REQUEST_METHOD'] ?? '') !== 'POST') respond(['error' => 'method_not_allowed'], 405);
			if (!rate_ok('emergency:' . $accountId, 120)) respond(['error' => 'rate_limited'], 429);
			$card = is_array($body['card'] ?? null) ? $body['card'] : [];
			if (trim((string) ($card['name'] ?? '')) === '') respond(['error' => 'name_missing'], 400);
			$photo = isset($body['photo']) && is_string($body['photo']) ? $body['photo'] : null;
			respond(emergency_status(emergency_publish($pdo, $packId, $card, $photo, $accountId)));
		case 'revoke':
			if (($_SERVER['REQUEST_METHOD'] ?? '') !== 'POST') respond(['error' => 'method_not_allowed'], 405);
			// Sperren macht gedruckte QR-Codes am Halsband wertlos – das entscheiden Besitzer.
			if (!is_owner($pdo, $packId, $accountId)) respond(['error' => 'not_owner'], 403);
			emergency_revoke($pdo, $packId);
			respond(['active' => false]);
		default:
			respond(['error' => 'unknown_action'], 400);
	}
} catch (Throwable $e) {
	error_log('[stella] emergency: ' . $e->getMessage());
	respond(['error' => 'server'], 500);
}
