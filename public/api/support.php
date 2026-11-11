<?php
declare(strict_types=1);

/**
 * Support: eine Frage, ein Problem oder eine Idee schicken.
 *
 *   POST {kind: frage|problem|idee, email, text, code, website (leer lassen)}  → {number}
 *
 * Aus der App mit dem Gerätecode; aus dem Formular auf thisdog.app/support mit dem Code, den man eintippt.
 */

require_once __DIR__ . '/lib.php';
require_once __DIR__ . '/lib-db.php';
require_once __DIR__ . '/lib-mail.php';
require_once __DIR__ . '/lib-support.php';
require_once __DIR__ . '/auth-session.php';

handle_preflight();
guard_origin();

try {
	if (($_SERVER['REQUEST_METHOD'] ?? '') !== 'POST') respond(['error' => 'method_not_allowed'], 405);
	$body = json_decode((string) file_get_contents('php://input'), true) ?: $_POST;
	// Ein verstecktes Feld, das nur Programme ausfüllen.
	if (trim((string) ($body['website'] ?? '')) !== '') respond(['number' => 'T-0000']);
	if (!rate_ok('support', 5, 900)) respond(['error' => 'rate_limited'], 429);

	$kind = (string) ($body['kind'] ?? '');
	$email = strtolower(trim((string) ($body['email'] ?? '')));
	$text = trim((string) ($body['text'] ?? ''));
	$code = strtoupper(trim((string) ($body['code'] ?? '')));
	if (!isset(REQUEST_KINDS[$kind])) respond(['error' => 'invalid_kind'], 422);
	if (!filter_var($email, FILTER_VALIDATE_EMAIL)) respond(['error' => 'invalid_email'], 422);
	if (mb_strlen($text) < 5 || mb_strlen($text) > 5000) respond(['error' => 'invalid_text'], 422);
	if ($code !== '' && device_code_decode($code) === null) respond(['error' => 'invalid_code'], 422);

	$pdo = db();
	$session = current_session($pdo);
	$number = create_request($pdo, $kind, $email, $text, $code, $session ? (int) $session['account_id'] : null, ($body['via'] ?? '') === 'app' ? 'app' : 'web');
	respond(['number' => $number]);
} catch (Throwable $e) {
	error_log('[stella] support: ' . $e->getMessage());
	respond(['error' => 'server'], 500);
}
