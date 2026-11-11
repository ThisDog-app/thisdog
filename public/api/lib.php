<?php
declare(strict_types=1);

/**
 * Gemeinsame Grundlage der Schnittstellen: Konfiguration, Antworten,
 * Herkunftsprüfung und ein einfaches Anfragelimit.
 */

/**
 * Findet die Konfigurationsdatei.
 *
 * Sie enthält Zugangsdaten und liegt deshalb außerhalb des Webordners – dort
 * kann kein Hochladen sie löschen und kein Browser sie anfordern. Der alte Ort
 * neben den Skripten wird noch gelesen, damit ältere Installationen laufen.
 */
/**
 * Das Heimatverzeichnis des Kontos, unter dem PHP läuft.
 *
 * Es liegt nicht zwingend über dem Webordner: Bei manchen Angeboten sind das
 * getrennte Zweige, etwa /usr/home/kunde neben /usr/www/users/kunde. Ob PHP
 * dort überhaupt lesen darf, entscheidet die Serverkonfiguration – deshalb
 * ist das hier nur ein Kandidat unter mehreren, kein Verlass.
 */
function home_dir(): ?string
{
	$home = getenv('HOME');
	if (!is_string($home) || $home === '') {
		if (function_exists('posix_getpwuid') && function_exists('posix_geteuid')) {
			$info = @posix_getpwuid(posix_geteuid());
			$home = is_array($info) ? ($info['dir'] ?? '') : '';
		}
	}
	$home = is_string($home) ? rtrim($home, '/') : '';
	return ($home !== '' && $home !== '/' && is_dir($home)) ? $home : null;
}

function config_path(): ?string
{
	static $resolved = false, $path = null;
	if ($resolved) return $path;
	$resolved = true;

	$candidates = [];
	$env = getenv('STELLA_CONFIG');
	if (is_string($env) && $env !== '') $candidates[] = $env;
	// Das Heimatverzeichnis liegt bei vielen Angeboten in einem ganz anderen
	// Zweig als der Webordner – vom Webordner aus führt kein Weg dorthin.
	$home = home_dir();
	if ($home !== null) $candidates[] = $home . '/stella-daten/config.php';
	// Der beste Ort: neben dem Webordner, für Besucher unerreichbar.
	$candidates[] = dirname(dirname(__DIR__)) . '/stella-daten/config.php';
	// Nicht jeder Hoster gibt eine Ebene über dem Webordner her. Bei manchen
	// ist der Webordner das Nutzerverzeichnis – dort liegt darüber nur der
	// gemeinsame Elternordner aller Kunden, in den niemand schreiben darf.
	// Dann tut es ein Unterordner im Webordner, den eine .htaccess sperrt.
	$candidates[] = dirname(__DIR__) . '/stella-daten/config.php';
	$candidates[] = __DIR__ . '/config.php';

	foreach ($candidates as $candidate) {
		if (is_readable($candidate)) return $path = $candidate;
	}
	return $path = null;
}

/** Liest die Konfiguration; fällt auf Umgebungsvariablen zurück. */
function cfg(string $key, $default = null)
{
	static $conf = null;
	if ($conf === null) {
		$file = config_path();
		$conf = ($file !== null) ? (require $file) : [];
		if (!is_array($conf)) $conf = [];
	}
	if (array_key_exists($key, $conf) && $conf[$key] !== '' && $conf[$key] !== []) {
		return $conf[$key];
	}
	$env = getenv($key);
	if ($env === false || $env === '') {
		$env = $_SERVER[$key] ?? '';
	}
	return $env !== '' ? $env : $default;
}

/**
 * Verzeichnis für Daten, die Aktualisierungen überleben müssen.
 *
 * Wird der Webordner beim Hochladen vollständig ersetzt – wie es viele
 * Editoren tun –, verschwindet alles, was darin liegt. Die Datenbank gehört
 * deshalb eine Ebene darüber, außerhalb des Bereichs, der überschrieben wird.
 *
 * Reihenfolge: ausdrücklich konfiguriert, sonst neben dem Webordner.
 */
function data_dir(): string
{
	static $dir = null;
	if ($dir !== null) return $dir;

	$candidates = [];

	$configured = (string) cfg('DATA_DIR', '');
	if ($configured !== '') $candidates[] = rtrim($configured, '/');

	// Das Heimatverzeichnis, wenn es erreichbar ist: nicht öffentlich und
	// vom Hochladen unberührt.
	$home = home_dir();
	if ($home !== null) $candidates[] = $home . '/stella-daten';

	// __DIR__ ist .../<webordner>/api – eine Ebene über dem Webordner ablegen.
	$candidates[] = dirname(dirname(__DIR__)) . '/stella-daten';
	// Wo das nicht geht, weil der Webordner selbst das Nutzerverzeichnis ist:
	// ein Unterordner darin. Er wird unten mit einer .htaccess gesperrt und
	// überlebt das Hochladen, weil er nicht Teil des ausgelieferten Ordners ist.
	$candidates[] = dirname(__DIR__) . '/stella-daten';

	foreach ($candidates as $path) {
		if (!is_dir($path)) {
			@mkdir($path, 0775, true);
		}
		if (is_dir($path) && is_writable($path)) {
			// Vor neugierigen Blicken schützen, falls der Ordner doch im Web liegt.
			if (!file_exists($path . '/.htaccess')) {
				@file_put_contents($path . '/.htaccess', "Require all denied\n");
			}
			$dir = $path;
			rescue_config();
			return $dir;
		}
	}

	// Notnagel: neben den Skripten. Überlebt kein vollständiges Hochladen.
	return $dir = __DIR__;
}

/**
 * Bringt eine noch neben den Skripten liegende Konfiguration in Sicherheit.
 * Ohne das wäre sie beim nächsten vollständigen Hochladen verloren – samt
 * Zugangsdaten, die dann niemand mehr zur Hand hat.
 */
function rescue_config(): void
{
	$current = config_path();
	if ($current === null || $current !== __DIR__ . '/config.php') return;

	$target = data_dir() . '/config.php';
	if (file_exists($target)) return;

	if (@copy($current, $target)) {
		@chmod($target, 0640);
		error_log('[stella] Konfiguration gesichert nach ' . $target
			. ' – die Kopie unter api/ kann gelöscht werden.');
	}
}

/**
 * Zieht eine SQLite-Datenbank um.
 *
 * Ein schlichtes Kopieren der Datei genügt nicht: Im WAL-Modus stehen die
 * jüngsten Schreibvorgänge noch in einer Begleitdatei und würden fehlen.
 * «VACUUM INTO» erzeugt stattdessen eine in sich geschlossene Kopie.
 */
function migrate_sqlite(string $from, string $to): bool
{
	try {
		$pdo = new PDO('sqlite:' . $from, null, null, [PDO::ATTR_ERRMODE => PDO::ERRMODE_EXCEPTION]);
		try {
			$stmt = $pdo->prepare('VACUUM INTO ?');
			$stmt->execute([$to]);
		} catch (Throwable $e) {
			// Ältere SQLite-Fassungen kennen VACUUM INTO nicht. Dann den WAL
			// zurückschreiben und erst danach die Datei kopieren.
			$pdo->exec('PRAGMA wal_checkpoint(TRUNCATE)');
			$pdo = null;
			if (!@copy($from, $to)) return false;
		}
		$pdo = null;
		error_log('[stella] Datenbank umgezogen nach ' . $to);
		return true;
	} catch (Throwable $e) {
		error_log('[stella] Umzug der Datenbank fehlgeschlagen: ' . $e->getMessage());
		return false;
	}
}

/**
 * Pfad zu einer Datendatei. Eine noch am alten Ort liegende Datei
 * zieht beim ersten Zugriff mit um, damit keine Zählstände verloren gehen.
 */
function data_file(string $name): string
{
	$target = data_dir() . '/' . $name;
	$legacy = __DIR__ . '/' . $name;

	if (!file_exists($target) && file_exists($legacy) && data_dir() !== __DIR__) {
		if (str_ends_with($name, '.sqlite')) {
			migrate_sqlite($legacy, $target);
		} elseif (@copy($legacy, $target)) {
			error_log('[stella] Datei umgezogen nach ' . $target);
		}
	}
	return $target;
}

function respond($data, int $code = 200): void
{
	http_response_code($code);
	header('Content-Type: application/json; charset=utf-8');
	header('Cache-Control: no-store');
	header('X-Content-Type-Options: nosniff');
	echo json_encode($data, JSON_UNESCAPED_UNICODE);
	exit;
}

/**
 * Erlaubt Anfragen nur von den konfigurierten Adressen.
 * Ohne Origin-Kopf (etwa direkte Aufrufe) wird durchgelassen, damit
 * die App auch bei gleichem Ursprung ohne CORS funktioniert.
 */
function guard_origin(): void
{
	$origin = $_SERVER['HTTP_ORIGIN'] ?? '';
	if ($origin === '') return;

	$allowed = cfg('ALLOWED_ORIGINS', []);
	if (is_string($allowed)) $allowed = array_filter(array_map('trim', explode(',', $allowed)));
	// Lokale Entwicklung ist immer erlaubt.
	$isLocal = (bool) preg_match('#^https?://(localhost|127\.0\.0\.1|\[::1\])(:\d+)?$#', $origin);

	/**
	 * Die eigene Seite braucht keine Erlaubnis.
	 *
	 * Die Liste ist für fremde Herkünfte gedacht. Ruft die App ihre eigene
	 * Schnittstelle auf, ist das keine fremde Anfrage – ein Eintrag darf
	 * darüber nicht entscheiden. Fehlte er, stand die App still: Anmeldung,
	 * Abgleich und Vorschläge antworteten mit 403, ohne dass am Code etwas
	 * falsch war. Genau das passierte nach dem Domainwechsel.
	 */
	$host = (string) ($_SERVER['HTTP_HOST'] ?? '');
	$isSelf = $host !== '' && ($origin === 'https://' . $host || $origin === 'http://' . $host);

	if ($isSelf || $isLocal || in_array($origin, $allowed, true)) {
		header('Vary: Origin');
		header('Access-Control-Allow-Origin: ' . $origin);
		return;
	}
	respond(['error' => 'origin_not_allowed'], 403);
}

/**
 * Die Adresse des Besuchers für Limits: bei IPv6 das ganze /64 – sonst hätte jeder Anschluss Milliarden Versuche.
 */
function client_net(): string
{
	$ip = (string) ($_SERVER['REMOTE_ADDR'] ?? '0');
	$bin = @inet_pton($ip);
	if ($bin !== false && strlen($bin) === 16) return bin2hex(substr($bin, 0, 8)) . '::/64';
	return $ip;
}

/**
 * Zählt Anfragen je IP (bzw. IPv6-Netz) in einem Zeitfenster; mit `$perIp = false` über alle zusammen.
 * Gibt false zurück, wenn das Limit überschritten ist.
 */
function rate_ok(string $bucket, int $limit, int $windowSeconds = 3600, bool $perIp = true): bool
{
	$ip = $perIp ? client_net() : 'alle';
	$file = sys_get_temp_dir() . '/stella_' . $bucket . '_' . sha1($ip . date('YmdH'));
	$now = time();

	$data = ['t' => $now, 'c' => 0];
	if (is_readable($file)) {
		$raw = @json_decode((string) @file_get_contents($file), true);
		if (is_array($raw) && isset($raw['t'], $raw['c']) && ($now - (int) $raw['t']) < $windowSeconds) {
			$data = ['t' => (int) $raw['t'], 'c' => (int) $raw['c']];
		}
	}
	if ($data['c'] >= $limit) return false;

	$data['c']++;
	@file_put_contents($file, json_encode($data), LOCK_EX);
	return true;
}

/* ==================== Was die Anfrage nebenbei verrät ==================== */

/**
 * Die Sprachregion des Besuchers, etwa «de-AT».
 *
 * Aus dem Kopf, den jeder Browser ohnehin mitschickt. Das ist keine Ortung –
 * wer sein System auf Englisch stellt, erscheint hier als «en», und wer aus
 * Wien mit deutscher Voreinstellung kommt, als «de». Für die Frage, ob die App
 * über Österreich hinaus benutzt wird, reicht es; für mehr wäre eine
 * IP-Auswertung nötig, und die soll es hier nicht geben.
 *
 * Gibt null zurück, wenn nichts Brauchbares dasteht.
 */
function request_region(): ?string
{
	$header = (string) ($_SERVER['HTTP_ACCEPT_LANGUAGE'] ?? '');
	if ($header === '') return null;

	// Die erste Angabe ist die bevorzugte; alles ab dem Semikolon ist Gewicht.
	$erste = trim(explode(',', $header)[0]);
	$erste = trim(explode(';', $erste)[0]);

	if (!preg_match('/^([a-z]{2,3})(?:-([a-z0-9]{2,4}))?$/i', $erste, $t)) return null;

	return isset($t[2]) && $t[2] !== ''
		? strtolower($t[1]) . '-' . strtoupper($t[2])
		: strtolower($t[1]);
}

/**
 * Das Betriebssystem hinter einer Kennung – gröber, als die Kennung hergibt.
 *
 * Absichtlich nur eine Handvoll Töpfe: Aus der vollen Kennung ließe sich ein
 * Gerät wiedererkennen, aus «iPhone» nicht. Für die Frage, wofür sich das
 * Gestalten lohnt, genügt der Topf.
 */
function platform_from_ua(?string $ua): string
{
	$ua = (string) $ua;
	if ($ua === '') return 'unbekannt';

	// Reihenfolge zählt: iPadOS nennt sich Macintosh, und jedes Android
	// schreibt Linux mit in die Kennung.
	return match (true) {
		(bool) preg_match('/iPhone|iPod/i', $ua) => 'iPhone',
		(bool) preg_match('/iPad/i', $ua) => 'iPad',
		(bool) preg_match('/Android/i', $ua) => 'Android',
		(bool) preg_match('/Macintosh|Mac OS X/i', $ua) => 'Mac',
		(bool) preg_match('/Windows/i', $ua) => 'Windows',
		(bool) preg_match('/Linux|X11/i', $ua) => 'Linux',
		default => 'anderes',
	};
}

/** Beantwortet Preflight-Anfragen einheitlich. */
function handle_preflight(): void
{
	if (($_SERVER['REQUEST_METHOD'] ?? '') !== 'OPTIONS') return;
	header('Access-Control-Allow-Methods: GET, POST, OPTIONS');
	header('Access-Control-Allow-Headers: Content-Type');
	header('Access-Control-Max-Age: 86400');
	http_response_code(204);
	exit;
}
