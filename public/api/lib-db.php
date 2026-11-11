<?php
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

	if ($version < 9) {
		// Das Rudel: Die Daten gehören einem Hund, nicht einem Konto.
		//
		// Bis hierher lag jeder Datensatz an genau einem Konto. Damit zwei
		// Menschen denselben Kalender haben, gehört er jetzt einem Rudel, und
		// ein Konto kann Mitglied in mehreren sein. Jedes bestehende Konto
		// bekommt sein eigenes Rudel, seine Datensätze ziehen dorthin um – für
		// die Web-App ändert sich dadurch nichts.
		//
		// `changed_by` hält fest, wer einen Datensatz zuletzt geändert hat:
		// Im Rudel ist „Anna hat den Termin verschoben“ eine Auskunft, die man
		// braucht.
		$pdo->beginTransaction();
		$pdo->exec(<<<'SQL'
			CREATE TABLE packs (
				id          INTEGER PRIMARY KEY AUTOINCREMENT,
				created_at  INTEGER NOT NULL,
				created_by  INTEGER REFERENCES accounts(id) ON DELETE SET NULL
			);

			CREATE TABLE pack_members (
				pack_id      INTEGER NOT NULL REFERENCES packs(id) ON DELETE CASCADE,
				account_id   INTEGER NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
				display_name TEXT,
				joined_at    INTEGER NOT NULL,
				PRIMARY KEY (pack_id, account_id)
			);
			CREATE INDEX idx_pack_members_account ON pack_members(account_id);

			CREATE TABLE pack_invites (
				token_hash  TEXT    PRIMARY KEY,
				pack_id     INTEGER NOT NULL REFERENCES packs(id) ON DELETE CASCADE,
				created_by  INTEGER REFERENCES accounts(id) ON DELETE SET NULL,
				created_at  INTEGER NOT NULL,
				expires_at  INTEGER NOT NULL,
				used_at     INTEGER,
				used_by     INTEGER REFERENCES accounts(id) ON DELETE SET NULL
			);

			CREATE TABLE pack_records (
				pack_id     INTEGER NOT NULL REFERENCES packs(id) ON DELETE CASCADE,
				kind        TEXT    NOT NULL,
				record_id   TEXT    NOT NULL,
				payload     TEXT,
				updated_at  INTEGER NOT NULL,
				rev         INTEGER NOT NULL,
				changed_by  INTEGER REFERENCES accounts(id) ON DELETE SET NULL,
				PRIMARY KEY (pack_id, kind, record_id)
			);
			CREATE INDEX idx_pack_records_rev ON pack_records(pack_id, rev);

			-- Geräte, die eine Mitteilung bekommen, wenn im Rudel etwas geändert wird.
			CREATE TABLE push_devices (
				token        TEXT    PRIMARY KEY,
				account_id   INTEGER NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
				platform     TEXT    NOT NULL,
				environment  TEXT    NOT NULL,
				created_at   INTEGER NOT NULL,
				last_seen_at INTEGER NOT NULL
			);
			CREATE INDEX idx_push_devices_account ON push_devices(account_id);
		SQL);

		$now = time();
		$accounts = $pdo->query('SELECT id, created_at FROM accounts ORDER BY id')->fetchAll();
		$newPack = $pdo->prepare('INSERT INTO packs (created_at, created_by) VALUES (?, ?)');
		$member = $pdo->prepare('INSERT INTO pack_members (pack_id, account_id, joined_at) VALUES (?, ?, ?)');
		$move = $pdo->prepare(<<<'SQL'
			INSERT INTO pack_records (pack_id, kind, record_id, payload, updated_at, rev, changed_by)
			SELECT ?, kind, record_id, payload, updated_at, rev, account_id FROM records WHERE account_id = ?
		SQL);
		foreach ($accounts as $a) {
			$newPack->execute([(int) $a['created_at'] ?: $now, (int) $a['id']]);
			$packId = (int) $pdo->lastInsertId();
			$member->execute([$packId, (int) $a['id'], (int) $a['created_at'] ?: $now]);
			$move->execute([$packId, (int) $a['id']]);
		}
		// Die alte Tabelle bleibt als Sicherung liegen, bis das Rudel sich bewährt hat.
		$pdo->exec('ALTER TABLE records RENAME TO records_vor_rudel');
		$pdo->exec('PRAGMA user_version = 9');
		$pdo->commit();
	}

	// Der Notfallpass: eine Seite je Rudel (Hund), erreichbar über einen
	// zufälligen Schlüssel im QR-Code. Gespeichert ist eine Momentaufnahme
	// dessen, was die App freigibt – nicht die Daten des Rudels selbst.
	if ($version < 10) {
		$pdo->exec(<<<'SQL'
			CREATE TABLE emergency_cards (
				pack_id      INTEGER PRIMARY KEY REFERENCES packs(id) ON DELETE CASCADE,
				token        TEXT NOT NULL UNIQUE,
				payload      TEXT NOT NULL,
				photo        TEXT,
				updated_at   INTEGER NOT NULL,
				views        INTEGER NOT NULL DEFAULT 0,
				last_view_at INTEGER,
				notified_at  INTEGER
			);
		SQL);
		$pdo->exec('PRAGMA user_version = 10');
	}

	// Ende-zu-Ende-Verschlüsselung und Hundefreunde.
	//
	// `sealed_at`: Ab diesem Zeitpunkt nimmt das Rudel nur noch verschlüsselte
	// Datensätze an; den Schlüssel hat nur die App. Die alte Sicherung aus der
	// Zeit vor dem Rudel liegt im Klartext und verschwindet.
	//
	// Hundefreunde: Rudel, die sich während einer Runde auf der Karte sehen.
	// Auch hier liegt nur Verschlüsseltes: Steckbrief (Name, Foto) und Standort
	// je Freundschaft mit deren eigenem Schlüssel, den der Server nie sieht.
	if ($version < 11) {
		$pdo->beginTransaction();
		$pdo->exec('ALTER TABLE packs ADD COLUMN sealed_at INTEGER');
		$pdo->exec('ALTER TABLE packs ADD COLUMN rev INTEGER');
		$pdo->exec('UPDATE packs SET rev = (SELECT MAX(rev) FROM pack_records WHERE pack_id = packs.id)');
		$pdo->exec('DROP TABLE IF EXISTS records_vor_rudel');
		$pdo->exec(<<<'SQL'
			CREATE TABLE friend_invites (
				secret      TEXT PRIMARY KEY,
				pack_id     INTEGER NOT NULL REFERENCES packs(id) ON DELETE CASCADE,
				created_by  INTEGER REFERENCES accounts(id) ON DELETE SET NULL,
				created_at  INTEGER NOT NULL,
				expires_at  INTEGER NOT NULL,
				used_at     INTEGER
			);
			CREATE TABLE friendships (
				pack_a      INTEGER NOT NULL REFERENCES packs(id) ON DELETE CASCADE,
				pack_b      INTEGER NOT NULL REFERENCES packs(id) ON DELETE CASCADE,
				invite      TEXT NOT NULL,
				created_at  INTEGER NOT NULL,
				PRIMARY KEY (pack_a, pack_b),
				CHECK (pack_a < pack_b)
			);
			CREATE TABLE friend_blobs (
				from_pack   INTEGER NOT NULL REFERENCES packs(id) ON DELETE CASCADE,
				to_pack     INTEGER NOT NULL REFERENCES packs(id) ON DELETE CASCADE,
				kind        TEXT NOT NULL,
				blob        TEXT NOT NULL,
				started_at  INTEGER,
				updated_at  INTEGER NOT NULL,
				PRIMARY KEY (from_pack, to_pack, kind)
			);
			CREATE TABLE nearby_notices (
				from_pack   INTEGER NOT NULL,
				to_pack     INTEGER NOT NULL,
				started_at  INTEGER NOT NULL,
				PRIMARY KEY (from_pack, to_pack, started_at)
			);
		SQL);
		$pdo->exec('PRAGMA user_version = 11');
		$pdo->commit();
	}

	// Eigene Ziele für die Gassirunde, neben dem OpenStreetMap-Auszug in places.sqlite. Der Auszug wird
	// jeden Monat ganz ersetzt; was hier steht, bleibt. `replaces` blendet einen Ort des Auszugs aus
	// (OSM-Kennung wie „way/123“) – mit Namen ersetzt ihn dieser Eintrag, ohne Namen fällt er nur weg.
	if ($version < 12) {
		$pdo->exec(<<<'SQL'
			CREATE TABLE own_places (
				id          INTEGER PRIMARY KEY AUTOINCREMENT,
				name        TEXT NOT NULL DEFAULT '',
				kind        TEXT NOT NULL DEFAULT 'dog_park',
				lat         REAL NOT NULL,
				lon         REAL NOT NULL,
				off_leash   INTEGER NOT NULL DEFAULT 0,
				fenced      INTEGER NOT NULL DEFAULT 0,
				replaces    TEXT,
				note        TEXT NOT NULL DEFAULT '',
				created_by  INTEGER REFERENCES accounts(id) ON DELETE SET NULL,
				created_at  INTEGER NOT NULL
			);
			CREATE INDEX own_places_pos ON own_places(lat, lon);
		SQL);
		$pdo->exec('PRAGMA user_version = 12');
	}

	// Bewertungen von Orten: eine Stimme je Konto, Ort und Merkmal (1 gibt es, 0 gibt es nicht), dazu welche
	// Hunde man dort meist trifft, und Meldungen („Stimmt etwas nicht?“). Nach außen gehen nur Zählungen;
	// das Konto steht dabei, damit jede Stimme einmal zählt, und mit dem Konto verschwinden seine Stimmen.
	// `own_places.by_user`: von einem Nutzer eingetragen (sonst über admin-orte.php).
	if ($version < 13) {
		$pdo->beginTransaction();
		$pdo->exec('ALTER TABLE own_places ADD COLUMN by_user INTEGER NOT NULL DEFAULT 0');
		$pdo->exec(<<<'SQL'
			CREATE TABLE place_votes (
				place_id    TEXT NOT NULL,
				account_id  INTEGER NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
				key         TEXT NOT NULL,
				value       INTEGER NOT NULL,
				updated_at  INTEGER NOT NULL,
				PRIMARY KEY (place_id, account_id, key)
			);
			CREATE TABLE place_sizes (
				place_id    TEXT NOT NULL,
				account_id  INTEGER NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
				small       INTEGER NOT NULL DEFAULT 0,
				medium      INTEGER NOT NULL DEFAULT 0,
				large       INTEGER NOT NULL DEFAULT 0,
				updated_at  INTEGER NOT NULL,
				PRIMARY KEY (place_id, account_id)
			);
			CREATE TABLE place_reports (
				id          INTEGER PRIMARY KEY AUTOINCREMENT,
				place_id    TEXT NOT NULL,
				account_id  INTEGER REFERENCES accounts(id) ON DELETE SET NULL,
				reason      TEXT NOT NULL,
				created_at  INTEGER NOT NULL,
				resolved_at INTEGER
			);
		SQL);
		$pdo->exec('PRAGMA user_version = 13');
		$pdo->commit();
	}

	// Durchgesehen: Orte, die Nutzer eingetragen haben, verschwinden nach dem Ansehen aus der Liste „Neu von Nutzern“.
	if ($version < 14) {
		$pdo->exec('ALTER TABLE own_places ADD COLUMN reviewed_at INTEGER');
		$pdo->exec('PRAGMA user_version = 14');
	}

	// Fotos von Orten (jeder darf hochladen, sichtbar erst nach Freigabe), Prüfungen vor Ort durch Erkunder
	// und wer Erkunder ist. Fotos liegen als Datei außerhalb des Webordners (DATA_DIR/fotos).
	if ($version < 15) {
		$pdo->exec(<<<'SQL'
			CREATE TABLE place_photos (
				id          INTEGER PRIMARY KEY AUTOINCREMENT,
				place_id    TEXT NOT NULL,
				account_id  INTEGER REFERENCES accounts(id) ON DELETE SET NULL,
				check_id    INTEGER,
				file        TEXT NOT NULL,
				width       INTEGER NOT NULL,
				height      INTEGER NOT NULL,
				label       TEXT NOT NULL DEFAULT '',
				status      TEXT NOT NULL DEFAULT 'pending',
				created_at  INTEGER NOT NULL,
				reviewed_at INTEGER
			);
			CREATE INDEX place_photos_place ON place_photos(place_id, status);
			CREATE TABLE place_checks (
				id          INTEGER PRIMARY KEY AUTOINCREMENT,
				place_id    TEXT NOT NULL,
				account_id  INTEGER REFERENCES accounts(id) ON DELETE SET NULL,
				answers     TEXT NOT NULL,
				lat         REAL,
				lon         REAL,
				distance_m  INTEGER,
				checked_at  INTEGER NOT NULL,
				status      TEXT NOT NULL DEFAULT 'pending',
				created_at  INTEGER NOT NULL,
				reviewed_at INTEGER
			);
			CREATE INDEX place_checks_place ON place_checks(place_id, status);
			CREATE TABLE scouts (
				account_id  INTEGER PRIMARY KEY REFERENCES accounts(id) ON DELETE CASCADE,
				created_at  INTEGER NOT NULL
			);
		SQL);
		$pdo->exec('PRAGMA user_version = 15');
	}

	// Fotos und Prüfungen erscheinen sofort; der Betreiber sieht stichprobenartig nach (reviewed_at).
	// Ein gemeldetes Foto ist bis zu seiner Entscheidung verborgen (status „reported“).
	if ($version < 16) {
		$pdo->beginTransaction();
		$pdo->exec('ALTER TABLE place_photos ADD COLUMN report_reason TEXT');
		$pdo->exec('ALTER TABLE place_photos ADD COLUMN reported_at INTEGER');
		$pdo->exec("UPDATE place_photos SET status = 'ok' WHERE status = 'pending'");
		$pdo->exec("UPDATE place_checks SET status = 'ok' WHERE status = 'pending'");
		$pdo->exec('PRAGMA user_version = 16');
		$pdo->commit();
	}

	// Anfragen an den Support (aus der App oder über thisdog.app/support), Nummer „T-0001“.
	if ($version < 17) {
		$pdo->exec(<<<'SQL'
			CREATE TABLE support_requests (
				id          INTEGER PRIMARY KEY AUTOINCREMENT,
				number      TEXT,
				kind        TEXT NOT NULL,
				email       TEXT NOT NULL,
				text        TEXT NOT NULL,
				device_code TEXT NOT NULL DEFAULT '',
				device      TEXT NOT NULL DEFAULT '',
				account_id  INTEGER REFERENCES accounts(id) ON DELETE SET NULL,
				via         TEXT NOT NULL,
				status      TEXT NOT NULL DEFAULT 'neu',
				note        TEXT NOT NULL DEFAULT '',
				created_at  INTEGER NOT NULL,
				done_at     INTEGER
			);
		SQL);
		$pdo->exec('PRAGMA user_version = 17');
	}

	// Konten ohne E-Mail: Wer per Einladung oder QR-Code ins Rudel kommt, braucht keine Adresse.
	// Sie lässt sich später hinzufügen, um auf ein neues Telefon umzuziehen. SQLite kann NOT NULL
	// nicht nachträglich entfernen, deshalb wird die Tabelle neu angelegt (Verfahren laut sqlite.org:
	// Fremdschlüssel aus, sonst räumte DROP TABLE alle Mitgliedschaften und Sitzungen mit ab).
	if ($version < 18) {
		$pdo->exec('PRAGMA foreign_keys = OFF');
		$pdo->beginTransaction();
		try {
			// Zwei Anfragen zugleich: Die zweite findet den Umbau schon erledigt.
			if ((int) $pdo->query('PRAGMA user_version')->fetchColumn() >= 18) {
				$pdo->commit();
				$pdo->exec('PRAGMA foreign_keys = ON');
				return;
			}
			$pdo->exec(<<<'SQL'
				CREATE TABLE accounts_neu (
					id             INTEGER PRIMARY KEY AUTOINCREMENT,
					email          TEXT    UNIQUE,
					created_at     INTEGER NOT NULL,
					last_seen_at   INTEGER,
					cal_token      TEXT    UNIQUE,
					region         TEXT,
					platform       TEXT,
					cal_fetched_at INTEGER
				);
				INSERT INTO accounts_neu (id, email, created_at, last_seen_at, cal_token, region, platform, cal_fetched_at)
					SELECT id, email, created_at, last_seen_at, cal_token, region, platform, cal_fetched_at FROM accounts;
				DROP TABLE accounts;
				ALTER TABLE accounts_neu RENAME TO accounts;
			SQL);
			if ($pdo->query('PRAGMA foreign_key_check')->fetch() !== false) throw new RuntimeException('Fremdschlüssel nach Umbau von accounts verletzt');
			$pdo->exec('PRAGMA user_version = 18');
			$pdo->commit();
		} catch (Throwable $e) {
			$pdo->rollBack();
			$pdo->exec('PRAGMA foreign_keys = ON');
			throw $e;
		}
		$pdo->exec('PRAGMA foreign_keys = ON');
	}

	// Rollen im Rudel: Besitzer und Hundesitter. Wer schon dabei ist, ist Besitzer. Dazu je Mitglied,
	// welche Mitteilungen es bekommen darf (legen Besitzer fest) und welche es will (legt es selbst fest).
	// NULL heißt: wie es die Rolle vorsieht (siehe lib-pack.php, notify_defaults).
	if ($version < 19) {
		$pdo->beginTransaction();
		$pdo->exec("ALTER TABLE pack_members ADD COLUMN role TEXT NOT NULL DEFAULT 'owner'");
		$pdo->exec('ALTER TABLE pack_members ADD COLUMN notify_allowed TEXT');
		$pdo->exec('ALTER TABLE pack_members ADD COLUMN notify_wanted TEXT');
		$pdo->exec("ALTER TABLE pack_invites ADD COLUMN role TEXT NOT NULL DEFAULT 'owner'");
		$pdo->exec('PRAGMA user_version = 19');
		$pdo->commit();
	}

	// Wer den Schlüssel anlegen durfte: Dieses Konto darf es nach einem Absturz sofort wieder, andere erst später.
	if ($version < 20) {
		$pdo->beginTransaction();
		$pdo->exec('ALTER TABLE packs ADD COLUMN sealed_by INTEGER');
		$pdo->exec('PRAGMA user_version = 20');
		$pdo->commit();
	}

	// Wer ohne E-Mail einen Ort einträgt, sieht ihn sofort; alle anderen erst nach dem Ansehen (admin-orte.php).
	// Gemeldete Fotos: wer gemeldet hat, damit eine einzelne anonyme Meldung nicht reicht.
	if ($version < 21) {
		$pdo->beginTransaction();
		$pdo->exec('ALTER TABLE own_places ADD COLUMN hidden INTEGER NOT NULL DEFAULT 0');
		$pdo->exec(<<<'SQL'
			CREATE TABLE place_photo_reports (
				photo_id    INTEGER NOT NULL,
				account_id  INTEGER NOT NULL,
				created_at  INTEGER NOT NULL,
				PRIMARY KEY (photo_id, account_id)
			);
		SQL);
		$pdo->exec('PRAGMA user_version = 21');
		$pdo->commit();
	}

	// Partnerplätze: Je Gegend (lib-services.php, sponsor_tile) kann ein Betrieb einen Platz oben in den Adressen
	// kaufen (partner.php, bezahlt über Stripe). Name und Adresse sind eine Abschrift aus dem Auszug – der wird jeden
	// Monat neu gebaut, der Platz soll das überstehen. Zählungen nur als Summen je Tag, ohne Personenbezug.
	if ($version < 22) {
		$pdo->beginTransaction();
		$pdo->exec(<<<'SQL'
			CREATE TABLE sponsors (
				id              INTEGER PRIMARY KEY AUTOINCREMENT,
				tile            TEXT NOT NULL,
				place_id        TEXT NOT NULL,
				kind            TEXT NOT NULL,
				name            TEXT NOT NULL,
				lat             REAL NOT NULL,
				lon             REAL NOT NULL,
				street          TEXT,
				city            TEXT,
				phone           TEXT,
				website         TEXT,
				hours           TEXT,
				text            TEXT NOT NULL DEFAULT '',
				advertiser      TEXT NOT NULL,
				email           TEXT NOT NULL,
				status          TEXT NOT NULL DEFAULT 'pending',
				checkout_id     TEXT,
				customer_id     TEXT,
				subscription_id TEXT,
				paid_until      INTEGER,
				cancels_at      INTEGER,
				manage_hash     TEXT,
				created_at      INTEGER NOT NULL,
				updated_at      INTEGER NOT NULL
			);
			CREATE INDEX sponsors_tile ON sponsors(tile, status);
			CREATE INDEX sponsors_sub ON sponsors(subscription_id);
			CREATE TABLE sponsor_stats (
				sponsor_id  INTEGER NOT NULL,
				day         TEXT NOT NULL,
				views       INTEGER NOT NULL DEFAULT 0,
				taps        INTEGER NOT NULL DEFAULT 0,
				PRIMARY KEY (sponsor_id, day)
			);
		SQL);
		$pdo->exec('PRAGMA user_version = 22');
		$pdo->commit();
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
	// Standorte aus Runden, die nie beendet wurden (App beendet, kein Netz), und alte Einladungen.
	$pdo->prepare("DELETE FROM friend_blobs WHERE kind = 'pos' AND updated_at < ?")->execute([$now - 3600]);
	// Erledigte Anfragen nach zwei Jahren löschen.
	$pdo->prepare("DELETE FROM support_requests WHERE status = 'erledigt' AND done_at < ?")->execute([$now - 730 * 86400]);
	// Check-ins sehen Freunde drei Stunden lang; danach braucht sie niemand mehr.
	$pdo->prepare("DELETE FROM friend_blobs WHERE kind = 'checkin' AND updated_at < ?")->execute([$now - 3 * 3600]);
	$pdo->prepare('DELETE FROM friend_invites WHERE expires_at < ?')->execute([$now - 86400]);
	$pdo->prepare('DELETE FROM nearby_notices WHERE started_at < ?')->execute([$now - 7 * 86400]);
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

/** Ein Konto ohne E-Mail – für alle, die per Einladung oder einfach so ins Rudel kommen. */
function create_device_account(PDO $pdo): int
{
	$pdo->prepare('INSERT INTO accounts (email, created_at, cal_token) VALUES (NULL, ?, ?)')->execute([time(), new_secret(18)]);
	return (int) $pdo->lastInsertId();
}

function create_account(PDO $pdo, string $email): array
{
	$stmt = $pdo->prepare('INSERT INTO accounts (email, created_at, cal_token) VALUES (?, ?, ?)');
	$stmt->execute([$email, time(), new_secret(18)]);
	$account = find_account($pdo, $email);
	if ($account === null) throw new RuntimeException('Konto konnte nicht angelegt werden');
	return $account;
}
