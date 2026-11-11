<?php
declare(strict_types=1);

/**
 * Sitzungen: erkennen, anlegen, beenden.
 *
 * Getrennt vom Endpunkt `auth.php`, damit andere Schnittstellen – etwa der
 * Abgleich – die Sitzung prüfen können, ohne den Anmeldeablauf mitzuladen.
 */

require_once __DIR__ . '/lib-db.php';

const SESSION_COOKIE = 'stella_session';
const SESSION_TTL = 15552000;      // 180 Tage
const SESSION_REFRESH = 604800;    // wöchentlich verlängern

/** Die Sitzung hinter dem Cookie, oder null. */
function current_session(PDO $pdo): ?array
{
	$secret = (string) ($_COOKIE[SESSION_COOKIE] ?? '');
	if ($secret === '') return null;

	$stmt = $pdo->prepare(<<<'SQL'
		SELECT s.token_hash, s.account_id, s.expires_at, s.last_seen_at, a.email, a.cal_token
		FROM sessions s JOIN accounts a ON a.id = s.account_id
		WHERE s.token_hash = ?
	SQL);
	$stmt->execute([secret_hash($secret)]);
	$row = $stmt->fetch();

	if (!$row || (int) $row['expires_at'] < time()) return null;
	return $row;
}

function start_session(PDO $pdo, int $accountId): void
{
	$secret = new_secret();
	$now = time();

	$stmt = $pdo->prepare('INSERT INTO sessions (token_hash, account_id, created_at, expires_at, last_seen_at, user_agent) VALUES (?, ?, ?, ?, ?, ?)');
	$stmt->execute([
		secret_hash($secret), $accountId, $now, $now + SESSION_TTL, $now,
		substr((string) ($_SERVER['HTTP_USER_AGENT'] ?? ''), 0, 200),
	]);

	set_session_cookie($secret, $now + SESSION_TTL);
}

function end_session(PDO $pdo): void
{
	$secret = (string) ($_COOKIE[SESSION_COOKIE] ?? '');
	if ($secret !== '') {
		$pdo->prepare('DELETE FROM sessions WHERE token_hash = ?')->execute([secret_hash($secret)]);
	}
	set_session_cookie('', time() - 3600);
}

function set_session_cookie(string $value, int $expires): void
{
	setcookie(SESSION_COOKIE, $value, [
		'expires' => $expires,
		'path' => '/',
		'secure' => is_https(),
		'httponly' => true,
		'samesite' => 'Lax',
	]);
}

/**
 * Hält eine benutzte Sitzung am Leben.
 * Höchstens wöchentlich, damit nicht jeder Aufruf schreibt.
 */
function touch_session(PDO $pdo, array $session): void
{
	$now = time();
	if ($now - (int) $session['last_seen_at'] <= SESSION_REFRESH) return;

	$pdo->prepare('UPDATE sessions SET last_seen_at = ?, expires_at = ? WHERE token_hash = ?')
		->execute([$now, $now + SESSION_TTL, $session['token_hash']]);
	$pdo->prepare('UPDATE accounts SET last_seen_at = ? WHERE id = ?')
		->execute([$now, (int) $session['account_id']]);
}

function is_https(): bool
{
	if (($_SERVER['HTTPS'] ?? '') !== '' && ($_SERVER['HTTPS'] ?? '') !== 'off') return true;
	return ($_SERVER['HTTP_X_FORWARDED_PROTO'] ?? '') === 'https';
}
