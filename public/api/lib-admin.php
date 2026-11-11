<?php
declare(strict_types=1);

/**
 * Zugang zu den Seiten für den Betreiber (admin.php, admin-orte.php).
 *
 * Kein eigenes Passwort: Wer hereinkommt, ist angemeldet und steht in `ADMIN_EMAILS`.
 */

require_once __DIR__ . '/lib.php';
require_once __DIR__ . '/lib-db.php';
require_once __DIR__ . '/auth-session.php';


/** Die Adressen, die hier hereindürfen. Ohne Eintrag: niemand. */
function admin_emails(): array
{
	$roh = cfg('ADMIN_EMAILS', []);
	if (is_string($roh)) $roh = explode(',', $roh);
	if (!is_array($roh)) return [];

	$liste = [];
	foreach ($roh as $eintrag) {
		$adresse = strtolower(trim((string) $eintrag));
		if ($adresse !== '') $liste[] = $adresse;
	}
	return $liste;
}

/** Die Adresse des angemeldeten Betreibers – sonst „Nicht gefunden“ und Ende. */
function admin_or_404(PDO $pdo): string
{
	$session = current_session($pdo);
	$erlaubte = admin_emails();
	$email = $session === null ? '' : strtolower((string) $session['email']);

	if ($session === null || !in_array($email, $erlaubte, true)) {
		// Wer nicht hereindarf, soll nicht erfahren, dass es hier etwas gibt.
		// Auch der Unterschied «nicht angemeldet» / «kein Zugang» bliebe eine
		// Auskunft: Er verriete, dass die Seite auf eine Liste schaut.
		http_response_code(404);
		header('Content-Type: text/html; charset=utf-8');
		$hinweis = '';
		if ($erlaubte === []) {
			// Nur auf dem Entwicklungsrechner: Eine leere Liste ist der häufigste
			// Grund, hier zu stehen, und im Netz darf sie niemand erklärt bekommen.
			$host = strtolower((string) ($_SERVER['HTTP_HOST'] ?? ''));
			if (preg_match('/^(localhost|127\.0\.0\.1|\[::1\])(:\d+)?$/', $host)) {
				$hinweis = '<p style="font:14px/1.5 system-ui;color:#746a5d">'
					. 'Es steht keine Adresse in <code>ADMIN_EMAILS</code>.</p>';
			}
		}
		echo "<!doctype html><meta charset=utf-8><title>Nicht gefunden</title>\n"
			. '<p style="font:16px/1.5 system-ui;padding:40px">Nicht gefunden.</p>' . $hinweis;
		exit;
	}
	return $email;
}
