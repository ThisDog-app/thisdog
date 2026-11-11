<?php
/**
 * Einmalige Standortbestimmung auf dem Server.
 *
 * Nach api/ hochladen, im Browser aufrufen, Ausgabe kopieren – und die Datei
 * danach wieder löschen. Sie verrät Serverpfade und gehört nicht dauerhaft
 * ins Netz.
 *
 * Beantwortet, was sich von außen nicht feststellen lässt: wo dieses Skript
 * liegt, wie weit PHP hinaufschauen darf und welche der gesuchten Orte
 * tatsächlich existieren, lesbar oder beschreibbar sind.
 */

header('Content-Type: text/plain; charset=utf-8');

$web = dirname(__DIR__);          // Webordner, wenn dieses Skript in api/ liegt
$darueber = dirname($web);        // eine Ebene darüber

function befund(string $pfad): string
{
	$teile = [];
	$teile[] = file_exists($pfad) ? 'existiert' : 'fehlt';
	if (file_exists($pfad)) {
		$teile[] = is_readable($pfad) ? 'lesbar' : 'NICHT lesbar';
		$teile[] = is_writable($pfad) ? 'beschreibbar' : 'NICHT beschreibbar';
		if (is_dir($pfad)) $teile[] = 'Ordner';
	}
	return implode(', ', $teile);
}

$home = getenv('HOME');
if (!is_string($home) || $home === '') {
	if (function_exists('posix_getpwuid') && function_exists('posix_geteuid')) {
		$info = @posix_getpwuid(posix_geteuid());
		$home = is_array($info) ? ($info['dir'] ?? '') : '';
	}
}
$home = is_string($home) ? rtrim($home, '/') : '';

echo "PHP-Version:      " . PHP_VERSION . "\n";
echo "open_basedir:     " . (ini_get('open_basedir') ?: '(nicht gesetzt)') . "\n";
echo "Skript liegt in:  " . __DIR__ . "\n";
echo "Webordner:        $web\n";
echo "Eine Ebene höher: $darueber\n";
echo "Heimatverzeichnis:" . ($home !== '' ? " $home" : ' (nicht ermittelbar)') . "\n";
echo "\n--- Gesuchte Orte ---\n";

$orte = [
	'darüber/stella-daten'      => $darueber . '/stella-daten',
	'darüber/stella-daten/config.php' => $darueber . '/stella-daten/config.php',
	'web/stella-daten'          => $web . '/stella-daten',
	'web/stella-daten/config.php' => $web . '/stella-daten/config.php',
	'api/config.php'            => __DIR__ . '/config.php',
];
if ($home !== '') {
	$orte['home'] = $home;
	$orte['home/stella-daten'] = $home . '/stella-daten';
	$orte['home/stella-daten/config.php'] = $home . '/stella-daten/config.php';
}
foreach ($orte as $name => $pfad) {
	printf("%-32s %s\n", $name, befund($pfad));
}

echo "\n--- Schreibversuche ---\n";
foreach (array_filter(['Heimatverzeichnis' => $home, 'über dem Webordner' => $darueber]) as $was => $wo) {
	$probe = $wo . '/stella-daten-probe';
	if (@mkdir($probe, 0775)) {
		echo "$was: Anlegen hat funktioniert (Ordner wird wieder entfernt)\n";
		@rmdir($probe);
	} else {
		$fehler = error_get_last();
		echo "$was: nicht möglich – " . ($fehler['message'] ?? 'unbekannter Grund') . "\n";
	}
}

echo "\n--- Wo die App sucht ---\n";
echo "Diese Reihenfolge gilt ab Version 1.6.6:\n";
echo "1. Umgebungsvariable STELLA_CONFIG\n";
if ($home !== '') echo "2. $home/stella-daten/config.php\n";
echo "3. $darueber/stella-daten/config.php\n";
echo "4. $web/stella-daten/config.php\n";
echo "5. " . __DIR__ . "/config.php\n";
echo "\nDatei nach dem Ablesen bitte wieder löschen.\n";
