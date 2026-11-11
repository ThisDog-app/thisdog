<?php
declare(strict_types=1);

/**
 * Anonyme Zählung der Suchbegriffe.
 *
 * Speichert ausschließlich den Begriff, die Anzahl und den Zeitpunkt –
 * keine IP-Adressen, keine Kennungen, keine Verknüpfung zu Personen.
 * Die Liste der häufigen Suchen auf der Startseite kommt von hier.
 */

require __DIR__ . '/lib.php';

guard_origin();
handle_preflight();

$DB = data_file('searches.sqlite');

function term_norm(string $s): string
{
	$s = mb_strtolower(trim($s), 'UTF-8');
	$s = preg_replace('/[^\p{L}\p{N}\s\-\/]/u', '', $s) ?? '';
	return trim(preg_replace('/\s+/', ' ', $s) ?? '');
}

try {
	$pdo = new PDO('sqlite:' . $DB, null, null, [
		PDO::ATTR_ERRMODE => PDO::ERRMODE_EXCEPTION,
		PDO::ATTR_DEFAULT_FETCH_MODE => PDO::FETCH_ASSOC,
	]);
	$pdo->exec('PRAGMA journal_mode=WAL');
	$pdo->exec("
		CREATE TABLE IF NOT EXISTS terms (
			term TEXT PRIMARY KEY,
			count INTEGER NOT NULL DEFAULT 0,
			last_ts INTEGER NOT NULL DEFAULT 0
		);
		CREATE TABLE IF NOT EXISTS hits (
			ts INTEGER NOT NULL,
			term TEXT NOT NULL
		);
		CREATE INDEX IF NOT EXISTS idx_hits_ts ON hits(ts);
	");

	$now = time();

	if (($_SERVER['REQUEST_METHOD'] ?? '') === 'POST') {
		if (!rate_ok('log', 120, 60)) {
			respond(['ok' => false, 'msg' => 'rate_limited'], 429);
		}

		$raw = file_get_contents('php://input');
		if ($raw === false || strlen($raw) > 2000) {
			respond(['ok' => false, 'msg' => 'bad_request'], 400);
		}
		$in = json_decode($raw ?: '{}', true);
		if (!is_array($in)) $in = [];

		$type = (string) ($in['type'] ?? 'search');
		$value = (string) ($in['value'] ?? ($in['term'] ?? ''));

		if ($type === 'search') {
			$term = term_norm($value);
		} else {
			// Andere Ereignisse bekommen ein Präfix und tauchen in der
			// öffentlichen Rangliste nicht auf.
			$type = preg_replace('/[^a-z_]/', '', mb_strtolower($type, 'UTF-8')) ?: 'event';
			$term = '@' . $type . ':' . preg_replace('/[^\p{L}\p{N}\s\:\-\/\.]/u', '', $value);
		}

		$term = mb_substr(trim($term), 0, 120, 'UTF-8');
		if ($term === '' || mb_strlen($term, 'UTF-8') < 2) {
			respond(['ok' => false, 'msg' => 'term_short'], 400);
		}

		$pdo->beginTransaction();
		$pdo->prepare('INSERT INTO terms(term, count, last_ts) VALUES(:t, 1, :ts)
			ON CONFLICT(term) DO UPDATE SET count = count + 1, last_ts = excluded.last_ts')
			->execute([':t' => $term, ':ts' => $now]);
		$pdo->prepare('INSERT INTO hits(ts, term) VALUES(:ts, :t)')
			->execute([':ts' => $now, ':t' => $term]);
		$pdo->commit();

		// Rohdaten älter als ein Jahr werden nicht mehr gebraucht.
		if (random_int(1, 200) === 1) {
			$pdo->prepare('DELETE FROM hits WHERE ts < :cut')->execute([':cut' => $now - 365 * 86400]);
		}

		respond(['ok' => true]);
	}

	if (isset($_GET['top'])) {
		$limit = max(1, min(50, (int) ($_GET['limit'] ?? 8)));
		$days = max(1, min(90, (int) ($_GET['days'] ?? 7)));
		$lambda = log(2) / ($days * 86400);

		// Begriffe mit @ sind interne Ereignisse und bleiben außen vor.
		$rows = $pdo->query("SELECT term, count, last_ts FROM terms
			WHERE term NOT LIKE '@%' AND count > 0")->fetchAll();

		$scored = [];
		foreach ($rows as $r) {
			$age = max(0.0, (float) $now - (float) $r['last_ts']);
			$score = (float) $r['count'] * exp(-$lambda * $age);
			// Was länger als vier Halbwertszeiten zurückliegt, ist nicht mehr aktuell.
			if ($score < 0.05) continue;
			$scored[] = [
				'term' => $r['term'],
				'score' => round($score, 4),
				'count' => (int) $r['count'],
				'last' => (int) $r['last_ts'],
			];
		}
		usort($scored, fn($a, $b) => $b['score'] <=> $a['score']);
		respond(array_slice($scored, 0, $limit));
	}

	if (isset($_GET['status'])) {
		// Pfade und Einrichtung des Servers: nur für den Betreiber, angemeldet.
		require_once __DIR__ . '/lib-admin.php';
		admin_or_404(db());
		$imWebordner = str_starts_with(data_dir(), dirname(__DIR__) . '/');
		// Liegt der Datenordner im Webordner, hängt sein Schutz an der
		// .htaccess. Wo die nicht ausgewertet wird, stünden Konten und
		// Sitzungen offen im Netz – deshalb hier die Adresse zum Nachsehen.
		$pruefUrl = $imWebordner
			? '/' . ltrim(str_replace(dirname(__DIR__), '', data_dir()), '/') . '/'
			: null;

		respond([
			'ok' => true,
			'datenordner' => data_dir(),
			'ausserhalb_webordner' => !$imWebordner,
			'sperre_pruefen_unter' => $pruefUrl,
			'sperre_vorhanden' => file_exists(data_dir() . '/.htaccess'),
			'beschreibbar' => is_writable(data_dir()),
			'konfiguration' => config_path() ?? 'nicht gefunden',
			'konfiguration_sicher' => config_path() !== null
				&& !str_starts_with(config_path(), dirname(__DIR__) . '/'),
			'schluessel_gesetzt' => cfg('GOOGLE_VISION_API_KEY', '') !== '',
			// Nur ja oder nein – die Zugangsdaten selbst haben hier nichts
			// verloren. Steht hier «false», meldet die Anmeldung zwar «schau
			// in dein Postfach», verschickt aber nichts.
			'mail_konfiguriert' => (string) cfg('SMTP_USER', cfg('SES_SMTP_USER', '')) !== ''
				&& (string) cfg('SMTP_PASS', cfg('SES_SMTP_PASS', '')) !== '',
			'mail_host' => (string) cfg('SMTP_HOST', cfg('SES_SMTP_HOST', '(nicht gesetzt)')),
			'datenbank' => basename($DB),
			'datenbank_vorhanden' => file_exists($DB),
			'groesse_bytes' => file_exists($DB) ? filesize($DB) : 0,
			'begriffe' => (int) $pdo->query('SELECT COUNT(*) c FROM terms')->fetch()['c'],
		]);
	}

	respond(['ok' => true, 'msg' => 'noop']);
} catch (Throwable $e) {
	error_log('[stella] search-log: ' . $e->getMessage());
	respond(['ok' => false, 'error' => 'server_error'], 500);
}
