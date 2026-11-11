<?php
declare(strict_types=1);

/**
 * Mailversand über SMTP.
 *
 * Der Client spricht gewöhnliches SMTP mit STARTTLS – damit läuft jedes
 * Postfach, vom Hoster-Konto bis zum Versanddienst. Nur die Zugangsdaten in
 * der Konfiguration entscheiden, wer die Nachricht ausliefert.
 *
 * Ohne hinterlegte Zugangsdaten geht die Nachricht nicht verloren, sondern in
 * ein Protokoll neben dem Webordner. So lässt sich die Anmeldung auf einem
 * Entwicklungsrechner vollständig durchspielen.
 */

require_once __DIR__ . '/lib.php';

class MailError extends RuntimeException {}

/**
 * Zugangsdaten des Postfachs.
 * Die früheren `SES_SMTP_*`-Namen werden weiter gelesen, damit ein Wechsel
 * des Anbieters keine Umbenennung in der Konfiguration erzwingt.
 */
function smtp_setting(string $name, $default = '')
{
	$value = cfg('SMTP_' . $name, '');
	if ($value === '' || $value === null) $value = cfg('SES_SMTP_' . $name, '');
	return ($value === '' || $value === null) ? $default : $value;
}

/** Sind Zugangsdaten für den echten Versand hinterlegt? */
function mail_configured(): bool
{
	return (string) smtp_setting('USER') !== '' && (string) smtp_setting('PASS') !== '';
}

/**
 * Der Absender.
 *
 * Fehlt `MAIL_FROM`, gilt das angemeldete Postfach – das existiert
 * nachweislich, sonst hätte die Anmeldung nicht geklappt. Eine aus der
 * Domain zusammengesetzte Adresse wäre geraten: Postfächer weisen fremde
 * Absender ab, und beim Empfänger landet so etwas im besten Fall im Spam.
 */
function mail_from(): string
{
	$konfiguriert = trim((string) cfg('MAIL_FROM', ''));
	if ($konfiguriert !== '') return $konfiguriert;

	$user = (string) smtp_setting('USER');
	if (str_contains($user, '@')) return $user;

	return 'stella@' . request_domain();
}

/**
 * Läuft die Anfrage auf einem Entwicklungsrechner? Der Host-Kopf allein reicht nicht – den setzt, wer fragt.
 * Deshalb muss auch die Gegenstelle der eigene Rechner sein (hinter einem Proxy ist sie das nie).
 */
function mail_local_request(): bool
{
	$host = strtolower((string) ($_SERVER['HTTP_HOST'] ?? ''));
	$addr = (string) ($_SERVER['REMOTE_ADDR'] ?? '');
	return in_array($addr, ['127.0.0.1', '::1'], true)
		&& (bool) preg_match('/^(localhost|127\.0\.0\.1|\[::1\])(:\d+)?$/', $host);
}

/**
 * Verschickt eine Nachricht als reinen Text.
 * Wirft MailError, wenn der Server die Annahme verweigert.
 */
function send_mail(string $to, string $subject, string $body, ?string $replyTo = null): void
{
	$fromMail = mail_from();
	$fromName = (string) cfg('MAIL_FROM_NAME', 'ThisDog');

	$message = build_message($fromMail, $fromName, $to, $subject, $body, $replyTo);

	if (!mail_configured()) {
		log_mail($to, $subject, $body, $replyTo);
		// Auf dem Entwicklungsrechner ist das Protokoll der Zustellweg. Im
		// Netz wäre es eine Lüge: Die App meldete «schau in dein Postfach»,
		// während die Nachricht in einer Datei liegt, die niemand liest.
		if (!mail_local_request()) {
			throw new MailError('Kein SMTP-Zugang hinterlegt – Nachricht nur protokolliert.');
		}
		return;
	}

	smtp_send($fromMail, $to, $message);
}

/**
 * Eine Nachricht an den Betreiber, nicht an einen Nutzer.
 *
 * Ohne eigenen Eintrag geht sie an den Absender der App – dessen Postfach
 * existiert nachweislich, sonst käme keine Anmeldemail durch.
 *
 * Sie schluckt jeden Fehler. Was hier verschickt wird, ist Beiwerk: Niemand
 * wartet darauf, und ein streikender Mailserver darf nicht den Vorgang kippen,
 * an dem ein Mensch gerade sitzt.
 */
function notify_owner(string $subject, string $body, ?string $replyTo = null): void
{
	// Ein leerer Eintrag lässt sich nicht von einem fehlenden unterscheiden –
	// beides fällt auf den Absender zurück. Wer die Nachrichten nicht will,
	// schreibt «none» hin.
	$to = trim((string) cfg('NOTIFY_TO', mail_from()));
	if ($to === '' || strcasecmp($to, 'none') === 0) return;

	try {
		send_mail($to, $subject, $body, $replyTo);
	} catch (Throwable $e) {
		error_log('[stella] Benachrichtigung nicht zugestellt: ' . $e->getMessage());
	}
}

/**
 * Baut die Nachricht nach RFC 5322.
 *
 * Betreff und Absendername können Umlaute enthalten und werden deshalb
 * kodiert; der Rumpf geht als UTF-8 mit base64 raus, damit keine Zeile
 * zu lang wird und nichts an Zeilenenden zerbricht.
 */
function build_message(string $fromMail, string $fromName, string $to, string $subject, string $body, ?string $replyTo = null): string
{
	$headers = [
		'From: ' . mime_word($fromName) . ' <' . $fromMail . '>',
		'To: ' . $to,
		'Subject: ' . mime_word($subject),
		'Date: ' . date(DATE_RFC2822),
		'Message-ID: <' . bin2hex(random_bytes(12)) . '@' . mail_domain($fromMail) . '>',
		'MIME-Version: 1.0',
		'Content-Type: text/plain; charset=utf-8',
		'Content-Transfer-Encoding: base64',
		'Auto-Submitted: auto-generated',
	];
	// Bei Anfragen an den Betreiber: Eine Antwort geht direkt an den, der gefragt hat.
	if ($replyTo !== null && filter_var($replyTo, FILTER_VALIDATE_EMAIL)) $headers[] = 'Reply-To: ' . $replyTo;

	$encoded = chunk_split(base64_encode($body), 76, "\r\n");
	return implode("\r\n", $headers) . "\r\n\r\n" . $encoded;
}

function mime_word(string $text): string
{
	if (preg_match('/^[\x20-\x7E]*$/', $text)) return $text;
	return '=?UTF-8?B?' . base64_encode($text) . '?=';
}

function mail_domain(string $address): string
{
	$at = strrpos($address, '@');
	return $at === false ? request_domain() : substr($address, $at + 1);
}

/**
 * Die Domain, unter der die App gerade läuft.
 * Nirgends fest verdrahtet – ein Domainwechsel soll keine Codeänderung sein.
 */
function request_domain(): string
{
	$host = (string) ($_SERVER['HTTP_HOST'] ?? '');
	$host = preg_replace('/:\d+$/', '', $host);
	return $host !== '' ? $host : 'localhost';
}

/** Schreibt die Nachricht ins Protokoll statt sie zu verschicken. */
function log_mail(string $to, string $subject, string $body, ?string $replyTo = null): void
{
	$file = data_dir() . '/mail-dev.log';
	$entry = sprintf("[%s] an %s\nBetreff: %s\n%s%s\n%s\n\n",
		date('c'), $to, $subject, $replyTo ? "Reply-To: $replyTo\n" : '', str_repeat('-', 60), $body);
	@file_put_contents($file, $entry, FILE_APPEND | LOCK_EX);
	error_log('[stella] Kein SMTP eingerichtet – Nachricht steht in ' . $file);
}

/* ============================ SMTP ============================ */

/**
 * Spricht so viel SMTP, wie für SES nötig ist: EHLO, STARTTLS, AUTH LOGIN,
 * eine Nachricht, QUIT. Kein Pipelining, keine Warteschlange – bei einer
 * Anmeldemail pro Vorgang wäre beides überflüssiger Aufwand.
 */
function smtp_send(string $from, string $to, string $message): void
{
	$host = (string) smtp_setting('HOST', '');
	$port = (int) smtp_setting('PORT', 587);
	$user = (string) smtp_setting('USER');
	$pass = (string) smtp_setting('PASS');
	$timeout = 15;

	$socket = @stream_socket_client("tcp://$host:$port", $errno, $errstr, $timeout);
	if ($socket === false) {
		throw new MailError("Keine Verbindung zu $host:$port – $errstr");
	}
	stream_set_timeout($socket, $timeout);

	try {
		smtp_expect($socket, 220);

		$ehloName = mail_domain($from);
		smtp_cmd($socket, 'EHLO ' . $ehloName, 250);

		// Verschlüsselt oder gar nicht: Zugangsdaten gehören nicht im Klartext
		// über das Netz, und die meisten Postfächer lehnen die Anmeldung ohne
		// STARTTLS ohnehin ab.
		smtp_cmd($socket, 'STARTTLS', 220);
		$crypto = STREAM_CRYPTO_METHOD_TLS_CLIENT;
		if (!@stream_socket_enable_crypto($socket, true, $crypto)) {
			throw new MailError('TLS-Verschlüsselung fehlgeschlagen');
		}
		smtp_cmd($socket, 'EHLO ' . $ehloName, 250);

		smtp_cmd($socket, 'AUTH LOGIN', 334);
		smtp_cmd($socket, base64_encode($user), 334);
		smtp_cmd($socket, base64_encode($pass), 235);

		smtp_cmd($socket, 'MAIL FROM:<' . $from . '>', 250);
		smtp_cmd($socket, 'RCPT TO:<' . $to . '>', 250);
		smtp_cmd($socket, 'DATA', 354);

		// Ein Punkt allein auf einer Zeile beendet die Nachricht – steht er im
		// Text, muss er verdoppelt werden, sonst bricht die Übertragung ab.
		$payload = preg_replace('/^\./m', '..', $message);
		fwrite($socket, $payload . "\r\n.\r\n");
		smtp_expect($socket, 250);

		@fwrite($socket, "QUIT\r\n");
	} finally {
		@fclose($socket);
	}
}

function smtp_cmd($socket, string $command, int $expected): string
{
	fwrite($socket, $command . "\r\n");
	return smtp_expect($socket, $expected);
}

/**
 * Liest eine vollständige Antwort und prüft ihren Code.
 * Mehrzeilige Antworten tragen bis zur letzten Zeile einen Bindestrich.
 */
function smtp_expect($socket, int $expected): string
{
	$lines = [];
	while (true) {
		$line = fgets($socket, 1024);
		if ($line === false) {
			throw new MailError('Verbindung abgebrochen, erwartet war ' . $expected);
		}
		$lines[] = rtrim($line, "\r\n");
		if (strlen($line) < 4 || $line[3] !== '-') break;
	}

	$response = implode(' | ', $lines);
	$code = (int) substr($lines[count($lines) - 1], 0, 3);
	if ($code !== $expected) {
		// Zugangsdaten dürfen niemals im Protokoll landen.
		throw new MailError("SMTP antwortete $code statt $expected: $response");
	}
	return $response;
}
