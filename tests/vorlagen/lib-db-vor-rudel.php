<?php
// Vorlage für tests/rudel-test.sh: public/api/lib-db.php im Stand vor dem Rudel. Nicht ändern.
declare(strict_types=1);

/**
 * Datenbank für Konten, Anmeldungen und Sitzungen.
 *
 * Liegt als eigene SQLite-Datei neben dem Webordner – getrennt von der
 * Suchstatistik, damit ein Problem mit der einen nie die andere mitreißt.
 * Das Schema wird beim ersten Zugriff angelegt und bei Bedarf erweitert.
 */

require_once __DIR__ . '/lib.php';

function db(): PDO
{
	static $pdo = null;
	if ($pdo instanceof PDO) return $pdo;

	$path = data_file('app.sqlite');
	$pdo = new PDO('sqlite:' . $path, null, null, [
		PDO::ATTR_ERRMODE => PDO::ERRMODE_EXCEPTION,
		PDO::ATTR_DEFAULT_FETCH_MODE => PDO::FETCH_ASSOC,
		PDO::ATTR_EMULATE_PREPARES => false,
	]);

	// WAL hält Lesen und Schreiben auseinander; ohne busy_timeout scheitert
	// bei gleichzeitigen Zugriffen sonst sofort einer von beiden.
	$pdo->exec('PRAGMA journal_mode = WAL');
	$pdo->exec('PRAGMA busy_timeout = 4000');
	$pdo->exec('PRAGMA foreign_keys = ON');

	db_migrate($pdo);
	return $pdo;
}

function db_migrate(PDO $pdo): void
{
	$version = (int) $pdo->query('PRAGMA user_version')->fetchColumn();

	if ($version < 1) {
		$pdo->exec(<<<'SQL'
			CREATE TABLE IF NOT EXISTS accounts (
				id          INTEGER PRIMARY KEY AUTOINCREMENT,
				email       TEXT    NOT NULL UNIQUE,
				created_at  INTEGER NOT NULL,
				last_seen_at INTEGER,
				cal_token   TEXT    UNIQUE
			);

			CREATE TABLE IF NOT EXISTS login_tokens (
				token_hash  TEXT    PRIMARY KEY,
				account_id  INTEGER NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
				created_at  INTEGER NOT NULL,
				expires_at  INTEGER NOT NULL,
				used_at     INTEGER
			);

			CREATE TABLE IF NOT EXISTS sessions (
				token_hash   TEXT    PRIMARY KEY,
				account_id   INTEGER NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
				created_at   INTEGER NOT NULL,
				expires_at   INTEGER NOT NULL,
				last_seen_at INTEGER NOT NULL,
				user_agent   TEXT
			);

			CREATE INDEX IF NOT EXISTS idx_login_tokens_account ON login_tokens(account_id);
			CREATE INDEX IF NOT EXISTS idx_sessions_account ON sessions(account_id);
		SQL);
		$pdo->exec('PRAGMA user_version = 1');
	}

	if ($version < 2) {
		// Ein Datensatz je Termin, Messung, Impfung … statt eines Gesamtstands
		// pro Konto: Nur so behalten zwei Geräte, die unabhängig voneinander
		// etwas anlegen, am Ende beide Einträge.
		$pdo->exec(<<<'SQL'
			CREATE TABLE IF NOT EXISTS records (
				account_id  INTEGER NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
				kind        TEXT    NOT NULL,
				record_id   TEXT    NOT NULL,
				payload     TEXT,
				updated_at  INTEGER NOT NULL,
				rev         INTEGER NOT NULL,
				PRIMARY KEY (account_id, kind, record_id)
			);

			CREATE INDEX IF NOT EXISTS idx_records_rev ON records(account_id, rev);
		SQL);
		$pdo->exec('PRAGMA user_version = 2');
	}

	if ($version < 3) {
		// Antworten der Kartenabfrage, je Rasterzelle. Parks wandern nicht –
		// einmal geholt, hält der Eintrag wochenlang und erspart dem
		// öffentlichen Overpass-Server eine Anfrage je Besucher.
		$pdo->exec(<<<'SQL'
			CREATE TABLE IF NOT EXISTS places_cache (
				cell       TEXT PRIMARY KEY,
				payload    TEXT NOT NULL,
				fetched_at INTEGER NOT NULL
			);
		SQL);
		$pdo->exec('PRAGMA user_version = 3');
	}

	if ($version < 4) {
		// Berechnete Fußwege. Der Schlüssel enthält den gerundeten Start und
		// das Ziel – zwischen denselben Punkten ändert sich der Weg nicht von
		// einer Woche zur nächsten.
		$pdo->exec(<<<'SQL'
			CREATE TABLE IF NOT EXISTS routes_cache (
				route_key  TEXT PRIMARY KEY,
				payload    TEXT NOT NULL,
				fetched_at INTEGER NOT NULL
			);
		SQL);
		$pdo->exec('PRAGMA user_version = 4');
	}

	if ($version < 5) {
		// Ein Anmeldelink hilft nur dort, wo er geöffnet wird – und aus einer
		// Mail heraus ist das der Browser, nie die installierte App. Deshalb
		// zusätzlich ein kurzer Code zum Abtippen: Er meldet das Gerät an,
		// auf dem jemand ihn eingibt.
		$pdo->exec('ALTER TABLE login_tokens ADD COLUMN code_hash TEXT');
		$pdo->exec('ALTER TABLE login_tokens ADD COLUMN tries INTEGER NOT NULL DEFAULT 0');
		$pdo->exec('ALTER TABLE login_tokens ADD COLUMN email TEXT');
		$pdo->exec('CREATE INDEX IF NOT EXISTS idx_login_tokens_email ON login_tokens(email)');
		$pdo->exec('PRAGMA user_version = 5');
	}

	if ($version < 6) {
		// Wo die Anmeldung begann: in der installierten App oder im Browser.
		// Davon hängt ab, ob ein Klick auf den Link anmeldet oder den Code
		// zeigt – siehe auth.php.
		$pdo->exec('ALTER TABLE login_tokens ADD COLUMN from_app INTEGER NOT NULL DEFAULT 0');
		$pdo->exec('ALTER TABLE login_tokens ADD COLUMN mark TEXT');
		$pdo->exec('PRAGMA user_version = 6');
	}

	if ($version < 7) {
		// Drei Angaben für die Übersicht, die sich sonst nirgends ablesen
		// lassen. Alle drei entstehen aus dem, was ohnehin vorbeikommt –
		// keine zusätzliche Abfrage beim Nutzer, keine IP-Adresse.
		//
		// `region` und `platform` werden einmal beim ersten Anmelden
		// festgehalten und danach nicht mehr angefasst: Sie sollen sagen, wer
		// dazugekommen ist, nicht, mit welchem Gerät jemand zuletzt unterwegs
		// war. `cal_fetched_at` verrät als Einziges, ob ein Kalenderabo
		// wirklich benutzt wird – eine Adresse hat jedes Konto, abgerufen
		// werden nur wenige.
		$pdo->exec('ALTER TABLE accounts ADD COLUMN region TEXT');
		$pdo->exec('ALTER TABLE accounts ADD COLUMN platform TEXT');
		$pdo->exec('ALTER TABLE accounts ADD COLUMN cal_fetched_at INTEGER');
		$pdo->exec('PRAGMA user_version = 7');
	}

	if ($version < 8) {
		// Lag im anfordernden Browser schon ein Hund?
		//
		// Davon hängt ab, wie schlimm es ist, wenn der Link woanders geöffnet
		// wird. Auf einem leeren Browser ist es folgenlos; auf einem, in dem
		// Profil und Termine liegen, meldet sich sonst der falsche Browser an
		// und die Daten bleiben herrenlos zurück.
		$pdo->exec('ALTER TABLE login_tokens ADD COLUMN had_data INTEGER NOT NULL DEFAULT 0');
		$pdo->exec('PRAGMA user_version = 8');
	}
}

/**
 * Räumt abgelaufene Token und Sitzungen weg.
 *
 * Kein eigener Cron: Ein Bruchteil der Anfragen erledigt es nebenbei, das
 * genügt bei dieser Größenordnung und braucht keine Serverkonfiguration.
 */
function db_gc(PDO $pdo, int $chance = 20): void
{
	if (random_int(1, $chance) !== 1) return;
	$now = time();
	$pdo->prepare('DELETE FROM login_tokens WHERE expires_at < ? OR used_at IS NOT NULL AND used_at < ?')
		->execute([$now, $now - 86400]);
	$pdo->prepare('DELETE FROM sessions WHERE expires_at < ?')->execute([$now]);
}

/* ============================ Geheimnisse ============================ */

/** Zufälliges Geheimnis in URL-tauglicher Schreibweise. */
function new_secret(int $bytes = 32): string
{
	return rtrim(strtr(base64_encode(random_bytes($bytes)), '+/', '-_'), '=');
}

/**
 * In der Datenbank steht nur der Hash.
 *
 * Wer die Datei in die Hände bekommt, hält damit keine gültigen Anmeldelinks
 * oder Sitzungen. SHA-256 genügt: Das Geheimnis ist bereits 256 Bit stark,
 * hier ist nichts zu raten, was ein langsames Verfahren bremsen müsste.
 */
function secret_hash(string $secret): string
{
	return hash('sha256', $secret);
}

/* ============================ Konten ============================ */

/**
 * Prüft eine E-Mail-Adresse und bringt sie auf eine einheitliche Form.
 * Gibt null zurück, wenn sie nicht brauchbar ist.
 */
function clean_email(string $raw): ?string
{
	$email = trim($raw);
	if ($email === '' || strlen($email) > 254) return null;

	// Nur der Domänenteil darf gefahrlos kleingeschrieben werden – der lokale
	// Teil ist laut Norm unterscheidend, auch wenn es in der Praxis selten zählt.
	$at = strrpos($email, '@');
	if ($at === false) return null;
	$email = substr($email, 0, $at) . '@' . strtolower(substr($email, $at + 1));

	return filter_var($email, FILTER_VALIDATE_EMAIL) ? $email : null;
}

function find_account(PDO $pdo, string $email): ?array
{
	$stmt = $pdo->prepare('SELECT * FROM accounts WHERE email = ?');
	$stmt->execute([$email]);
	$row = $stmt->fetch();
	return $row ?: null;
}

function create_account(PDO $pdo, string $email): array
{
	$stmt = $pdo->prepare('INSERT INTO accounts (email, created_at, cal_token) VALUES (?, ?, ?)');
	$stmt->execute([$email, time(), new_secret(18)]);
	$account = find_account($pdo, $email);
	if ($account === null) throw new RuntimeException('Konto konnte nicht angelegt werden');
	return $account;
}
