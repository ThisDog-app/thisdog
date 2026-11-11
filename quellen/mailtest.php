<?php
/**
 * Prüft den Mailversand Schritt für Schritt – ohne eine Nachricht zu senden.
 *
 * Nach api/ hochladen, im Browser aufrufen, Ausgabe kopieren, Datei wieder
 * löschen. Sie liest die Zugangsdaten aus der Konfiguration, gibt sie aber
 * niemals aus; nur, ob der jeweilige Schritt gelungen ist.
 *
 * Beantwortet die Frage, die von außen niemand beantworten kann: Kommt der
 * Server überhaupt nach draußen, und mag ihn das Postfach?
 */

require_once __DIR__ . '/lib.php';
require_once __DIR__ . '/lib-mail.php';

header('Content-Type: text/plain; charset=utf-8');
@set_time_limit(40);

$host = (string) smtp_setting('HOST', '');
$port = (int) smtp_setting('PORT', 587);
$user = (string) smtp_setting('USER');
$pass = (string) smtp_setting('PASS');
$konfiguriert = trim((string) cfg('MAIL_FROM', ''));
$from = mail_from();   // fällt auf das angemeldete Postfach zurück

echo "Konfiguration\n";
echo "  Host:      $host\n";
echo "  Port:      $port\n";
echo "  Benutzer:  " . ($user !== '' ? $user : '(leer)') . "\n";
echo "  Passwort:  " . ($pass !== '' ? '(gesetzt, ' . strlen($pass) . ' Zeichen)' : '(LEER)') . "\n";
echo "  Absender:  $from" . ($konfiguriert === '' ? '   ← nicht konfiguriert, abgeleitet vom Postfach' : '') . "\n\n";

if ($user === '' || $pass === '') {
	echo "ABBRUCH: Ohne Benutzer und Passwort kann nichts verschickt werden.\n";
	exit;
}

echo "Namensauflösung\n";
$ip = @gethostbyname($host);
echo '  ' . ($ip !== $host ? "$host → $ip" : "FEHLGESCHLAGEN – $host ist nicht auflösbar") . "\n\n";

echo "Verbindung\n";
$t0 = microtime(true);
$socket = @stream_socket_client("tcp://$host:$port", $errno, $errstr, 15);
if ($socket === false) {
	echo "  FEHLGESCHLAGEN nach " . round((microtime(true) - $t0), 1) . " s: $errstr (Code $errno)\n";
	echo "\n  Häufigster Grund: Der Hoster lässt keine ausgehenden Verbindungen\n";
	echo "  auf diesem Port zu. Dann hilft nur ein anderer Port (465) oder ein\n";
	echo "  Versanddienst über HTTPS.\n";
	exit;
}
stream_set_timeout($socket, 15);
echo '  offen nach ' . round((microtime(true) - $t0) * 1000) . " ms\n\n";

/** Liest eine vollständige Antwort und gibt die letzte Zeile zurück. */
$lies = static function () use ($socket): string {
	$zeilen = [];
	while (true) {
		$zeile = fgets($socket, 1024);
		if ($zeile === false) return 'KEINE ANTWORT';
		$zeilen[] = rtrim($zeile, "\r\n");
		if (strlen($zeile) < 4 || $zeile[3] !== '-') break;
	}
	return end($zeilen);
};
$sag = static function (string $befehl) use ($socket, $lies): string {
	fwrite($socket, $befehl . "\r\n");
	return $lies();
};

echo "Gespräch\n";
echo '  Begrüßung:  ' . $lies() . "\n";
echo '  EHLO:       ' . substr($sag('EHLO ' . mail_domain($from ?: $user)), 0, 60) . "\n";

$tls = $sag('STARTTLS');
echo "  STARTTLS:   $tls\n";
if (!str_starts_with($tls, '220')) {
	echo "\n  Ohne Verschlüsselung wird die Anmeldung abgelehnt. Manche Postfächer\n";
	echo "  erwarten stattdessen Port 465 mit sofortiger Verschlüsselung.\n";
	exit;
}

if (!@stream_socket_enable_crypto($socket, true, STREAM_CRYPTO_METHOD_TLS_CLIENT)) {
	echo "  TLS:        FEHLGESCHLAGEN – Zertifikat oder Protokoll passt nicht\n";
	exit;
}
echo "  TLS:        steht\n";
echo '  EHLO:       ' . substr($sag('EHLO ' . mail_domain($from ?: $user)), 0, 60) . "\n";

echo '  AUTH LOGIN: ' . $sag('AUTH LOGIN') . "\n";
echo '  Benutzer:   ' . $sag(base64_encode($user)) . "\n";
$auth = $sag(base64_encode($pass));
echo "  Passwort:   $auth\n";

if (str_starts_with($auth, '235')) {
	echo "\nERGEBNIS: Anmeldung erfolgreich. Der Versand sollte funktionieren.\n";
	// Prüfen, ob das Postfach diesen Absender überhaupt annimmt – das ist
	// die häufigste Stelle, an der eine Nachricht später doch verschwindet.
	echo '  Absender annehmbar: ' . $sag('MAIL FROM:<' . $from . '>') . "\n";
	$sag('RSET');
} else {
	echo "\nERGEBNIS: Anmeldung abgelehnt. Benutzername oder Passwort stimmen nicht,\n";
	echo "oder das Postfach verlangt einen anderen Anmeldenamen.\n";
}

@fwrite($socket, "QUIT\r\n");
@fclose($socket);
echo "\nDatei nach dem Ablesen bitte wieder löschen.\n";
