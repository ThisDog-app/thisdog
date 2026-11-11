<?php
declare(strict_types=1);

/**
 * Router für den eingebauten PHP-Server.
 *
 *   php -S 127.0.0.1:8099 -t public quellen/router.php
 *
 * Der eingebaute Server liest keine .htaccess. Alles, was dort umgeschrieben
 * wird, gibt es lokal deshalb nicht – und der Anmeldelink aus der Mail läuft
 * ins Leere, obwohl im Netz alles stimmt. Ein Fehler, der nur zu Hause
 * auftritt, kostet mehr Zeit als dieses Skript je einsparen könnte.
 *
 * Was hier steht, muss zur .htaccess passen. Kommt dort eine Regel dazu,
 * gehört sie auch hierher.
 */

$pfad = (string) parse_url((string) ($_SERVER['REQUEST_URI'] ?? '/'), PHP_URL_PATH);

// Der sprechende Anmeldelink: /anmelden/<Geheimnis>
if (preg_match('#^/anmelden/([A-Za-z0-9_-]+)/?$#', $pfad, $treffer)) {
	$_GET = ['action' => 'verify', 't' => $treffer[1]];
	require __DIR__ . '/../public/api/auth.php';
	return true;
}

// Alles andere liefert der Server selbst aus.
return false;
