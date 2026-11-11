<?php
declare(strict_types=1);

/**
 * Geräte für Mitteilungen an- und abmelden.
 *
 *   POST ?action=register   {token, environment: "sandbox"|"production"}
 *   POST ?action=unregister {token}
 *   POST ?action=live_start {token, environment, state: {meters, banked, runningSince?}}
 *        Startet die Live-Aktivität einer Runde, die auf der Watch begonnen hat. Das iPhone darf sie aus dem
 *        Hintergrund nicht selbst starten; mit seiner Push-to-Start-Kennung geht es über Apple.
 */

require_once __DIR__ . '/lib.php';
require_once __DIR__ . '/lib-db.php';
require_once __DIR__ . '/lib-push.php';
require_once __DIR__ . '/auth-session.php';

handle_preflight();
guard_origin();

try {
	if (($_SERVER['REQUEST_METHOD'] ?? '') !== 'POST') respond(['error' => 'method_not_allowed'], 405);
	$pdo = db();
	$raw = file_get_contents('php://input');
	$body = is_string($raw) && $raw !== '' ? (json_decode($raw, true) ?: []) : [];
	$token = (string) ($body['token'] ?? '');
	// APNs-Kennungen sind Hex, 64 Zeichen heute; Spielraum für längere.
	if (!preg_match('/^[0-9a-f]{32,400}$/', $token)) respond(['error' => 'bad_token'], 422);

	$action = (string) ($_GET['action'] ?? '');
	if ($action === 'live_start') {
		$session = current_session($pdo);
		if ($session === null) respond(['error' => 'not_signed_in'], 401);
		if (!push_configured()) respond(['ok' => false, 'configured' => false]);
		if (!rate_ok('live-start:' . (int) $session['account_id'], 30, 3600)) respond(['error' => 'rate_limited'], 429);
		$env = ($body['environment'] ?? '') === 'production' ? 'production' : 'sandbox';
		$in = is_array($body['state'] ?? null) ? $body['state'] : [];
		$state = ['meters' => (float) ($in['meters'] ?? 0), 'banked' => (float) ($in['banked'] ?? 0)];
		if (is_numeric($in['runningSince'] ?? null)) $state['runningSince'] = (float) $in['runningSince'];
		$status = apns_live_start($token, $env, $state);
		respond(['ok' => $status === 200, 'status' => $status]);
	}
	if ($action === 'unregister') {
		unregister_device($pdo, $token);
		respond(['ok' => true]);
	}
	if ($action === 'register') {
		$session = current_session($pdo);
		if ($session === null) respond(['error' => 'not_signed_in'], 401);
		$env = ($body['environment'] ?? '') === 'production' ? 'production' : 'sandbox';
		register_device($pdo, (int) $session['account_id'], $token, $env);
		respond(['ok' => true, 'configured' => push_configured()]);
	}
	respond(['error' => 'unknown_action'], 404);
} catch (Throwable $e) {
	error_log('[stella] Geräte: ' . $e->getMessage());
	respond(['error' => 'server_error'], 500);
}
