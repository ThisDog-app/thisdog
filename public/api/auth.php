<?php
declare(strict_types=1);

/**
 * Anmeldung ohne Passwort.
 *
 *   POST ?action=request   {email}  → verschickt einen Anmeldelink
 *   GET  ?action=verify&t=…         → prüft den Link, reicht ihn an die App
 *   POST ?action=confirm  {t}       → löst ihn ein, setzt die Sitzung
 *   POST ?action=start              → Konto ohne E-Mail für dieses Gerät, setzt die Sitzung
 *   GET  ?action=me                 → wer ist angemeldet (email kann null sein)
 *   POST ?action=logout             → Sitzung beenden
 *
 * Ein Passwort gibt es bewusst nicht: kein Zurücksetzen, keine Wiederverwendung
 * aus anderen Diensten, nichts, was gestohlen werden könnte. Wer Zugriff auf
 * das Postfach hat, hat Zugriff auf das Konto – mehr verspricht das Verfahren
 * nicht, und weniger leisten Passwörter in der Praxis auch selten.
 */

require_once __DIR__ . '/lib.php';
require_once __DIR__ . '/lib-db.php';
require_once __DIR__ . '/lib-mail.php';
require_once __DIR__ . '/auth-session.php';

const LOGIN_TTL = 1200;            // 20 Minuten für den Link aus der Mail
const PENDING_COOKIE = 'stella_pending';

handle_preflight();
guard_origin();

$action = (string) ($_GET['action'] ?? '');
$method = $_SERVER['REQUEST_METHOD'] ?? 'GET';

try {
	switch ($action) {
		case 'request': require_post($method); action_request(); break;
		case 'verify':  action_verify(); break;
		case 'confirm': require_post($method); action_confirm(); break;
		case 'code':    require_post($method); action_code(); break;
		case 'start':   require_post($method); action_start(); break;
		case 'me':      action_me(); break;
		case 'logout':  require_post($method); action_logout(); break;
		case 'delete':  require_post($method); action_delete(); break;
		default:        respond(['error' => 'unknown_action'], 404);
	}
} catch (MailError $e) {
	error_log('[stella] Mailversand: ' . $e->getMessage());
	respond(['error' => 'mail_failed'], 502);
} catch (Throwable $e) {
	error_log('[stella] Anmeldung: ' . $e->getMessage());
	respond(['error' => 'server_error'], 500);
}

function require_post(string $method): void
{
	if ($method !== 'POST') respond(['error' => 'method_not_allowed'], 405);
}

/** Liest den JSON-Rumpf einer Anfrage. */
function json_body(): array
{
	$raw = file_get_contents('php://input');
	if (!is_string($raw) || $raw === '') return [];
	$data = json_decode($raw, true);
	return is_array($data) ? $data : [];
}

/* ============================ Anfordern ============================ */

function action_request(): void
{
	$body = json_body();
	$email = clean_email((string) ($body['email'] ?? ''));

	// Zwei Grenzen: eine gegen den einzelnen Absender, eine gegen breite
	// Versuche von derselben Leitung aus.
	if (!rate_ok('auth_ip', 12, 3600)) {
		respond(['error' => 'rate_limited'], 429);
	}

	// Die Antwort ist immer dieselbe. Sonst verrät sie, welche Adressen ein
	// Konto haben – und wird damit zum Verzeichnis.
	$answer = ['ok' => true, 'sent' => true];

	if ($email === null) {
		respond(['error' => 'invalid_email'], 422);
	}

	$pdo = db();
	db_gc($pdo);

	// Je Adresse und Anschluss, dazu eine weitere Grenze je Adresse über alle Anschlüsse: Wer fünfmal
	// fremde Adressen anfordert, sperrt so nur sich selbst aus, nicht den, dem die Adresse gehört.
	// Und eine Adresse bekommt von vielen Anschlüssen trotzdem nicht beliebig viele Mails.
	$mailKey = substr(sha1($email), 0, 12);
	if (!rate_ok('auth_mail_' . $mailKey, 5) || !rate_ok('auth_mail_alle_' . $mailKey, 20, 3600, false)) {
		respond($answer);
	}

	// Wer schon ein Konto ohne E-Mail hat (per Einladung gekommen), hängt die Adresse an dieses Konto –
	// erst beim Einlösen, damit ein Vertipper sie nicht belegt. Gehört die Adresse schon einem Konto,
	// meldet der Link dort an.
	$session = current_session($pdo);
	$account = find_account($pdo, $email)
		?? ($session !== null && $session['email'] === null ? ['id' => (int) $session['account_id']] : null)
		?? create_account($pdo, $email);

	// Zwei Wege zum selben Konto: der Link für den Browser, der Code für das
	// Gerät, auf dem jemand ihn eintippt. Aus einer Mail heraus öffnet sich
	// nie die installierte App – der Code ist dort der einzige Weg hinein.
	//
	// Kürzer als die übrigen Geheimnisse, weil dieses als Adresse in einer
	// Nachricht steht, die ein Mensch liest. 128 Bit sind dafür reichlich: Der
	// Vorgang gilt zwanzig Minuten, und weiter oben zählt eine Schranke mit,
	// wie oft jemand es versuchen darf.
	$secret = new_secret(16);
	$code = login_code();

	// Wo die Anmeldung begann, entscheidet später über den Klick auf den Link.
	$fromApp = !empty($body['app']);
	// Und eine Spur im Browser: Findet sie sich beim Klick wieder, teilen App
	// und Browser ihren Speicher – dann führt der Link direkt ans Ziel.
	$mark = new_secret(12);

	// Ob hier schon ein Hund liegt, entscheidet später darüber, ob ein Klick im
	// falschen Browser eine Warnung wert ist. Ein Ja oder Nein, sonst nichts.
	$hatDaten = !empty($body['hasData']);

	$stmt = $pdo->prepare(<<<'SQL'
		INSERT INTO login_tokens (token_hash, account_id, created_at, expires_at, code_hash, email, from_app, mark, had_data)
		VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
	SQL);
	$stmt->execute([
		secret_hash($secret), (int) $account['id'], time(), time() + LOGIN_TTL,
		secret_hash($code), $email, $fromApp ? 1 : 0, secret_hash($mark),
		$hatDaten ? 1 : 0,
	]);

	setcookie(PENDING_COOKIE, $mark, [
		'expires' => time() + LOGIN_TTL,
		'path' => '/',
		'secure' => is_https(),
		'httponly' => true,
		'samesite' => 'Lax',
	]);

	$link = login_link($secret);
	// Der Code gehört in die Nachricht, nicht in den Betreff: Eine Zeile aus
	// Ziffern ist ein Muster, nach dem Spamfilter suchen – und diese Mail hat
	// es nicht nötig, wie eine Massensendung auszusehen.
	send_mail($email, 'Deine Anmeldung bei ThisDog', login_mail_text($link, $code));

	// Auf dem Entwicklungsrechner steht der Link direkt in der Antwort –
	// dort gibt es kein Postfach, in das er sonst laufen könnte.
	if (!mail_configured() && is_local_request()) {
		$answer['devLink'] = $link;
		$answer['devCode'] = $code;
	}
	respond($answer);
}

/**
 * Die Adresse, die in der Mail steht.
 *
 * «/anmelden/<Geheimnis>» statt eines Skriptnamens mit zwei Parametern. Die
 * kurze Form ist kein Schmuck: Ein Link, der wie eine Maschinenadresse
 * aussieht, wird in einer Nachricht, die zum Anmelden auffordert, mit Recht
 * misstrauisch beäugt – und manche Postfächer brechen ihn mitten im Geheimnis
 * um, dann führt er ins Leere.
 *
 * Umgeschrieben wird der Pfad in der .htaccess; dahinter liegt unverändert
 * `?action=verify`. Die alte Adresse funktioniert weiter, damit Links aus
 * Mails, die schon unterwegs sind, nicht mit dieser Aktualisierung sterben.
 */
function login_link(string $secret): string
{
	return app_url() . '/anmelden/' . rawurlencode($secret);
}

/**
 * Sechs Ziffern, gut abzutippen.
 *
 * Nicht als Ersatz für den Link gedacht, sondern für den Fall, dass er dort
 * nicht hilft: Wer die App auf dem Telefon installiert hat, landet über die
 * Mail immer im Browser – und der teilt seine Anmeldung nicht mit der App.
 */
function login_code(): string
{
	return str_pad((string) random_int(0, 999999), 6, '0', STR_PAD_LEFT);
}

function login_mail_text(string $link, string $code): string
{
	$minutes = (int) round(LOGIN_TTL / 60);
	return <<<TEXT
	Hallo,

	dein Code für ThisDog lautet:

	    $code

	Gib ihn in der App ein – dann meldet sich genau das Gerät an, auf dem du
	tippst. Nutzt du ThisDog im Browser, genügt auch dieser Link:

	$link

	Er führt dich auf eine Seite, auf der du die Anmeldung mit einem Button
	bestätigst. Code und Link gelten $minutes Minuten und lassen sich einmal
	verwenden.

	Wenn du dich nicht angemeldet hast, ist nichts passiert – dann kannst du
	diese Nachricht einfach löschen.

	Viele Grüße
	ThisDog
	TEXT;
}

/* ============================ Einlösen ============================ */

/**
 * Der Klick auf den Link – und warum er noch nichts anmeldet.
 *
 * Zwischen Absender und Postfach sitzen Prüfdienste, die jeden Link in einer
 * Nachricht selbst aufrufen, bevor ein Mensch sie überhaupt sieht. Wer das
 * Öffnen als Anmeldung wertet, verschenkt sie an einen Virenscanner: Der
 * Vorgang ist verbraucht, und der Empfänger liest «abgelaufen».
 *
 * Deshalb prüft dieser Aufruf nur und reicht das Geheimnis an die App weiter.
 * Eingelöst wird es erst durch `confirm` – ein POST, ausgelöst von einem
 * Button. Dahin folgt kein Scanner: Sie rufen Adressen ab, sie bedienen keine
 * Oberflächen.
 */
function action_verify(): void
{
	$secret = (string) ($_GET['t'] ?? '');
	if ($secret === '') redirect_to_app('fehlt');

	if (!rate_ok('auth_verify', 60, 3600)) {
		redirect_to_app('zuviel');
	}

	$token = find_login_token($secret);
	if ($token === null) redirect_to_app('abgelaufen');

	/**
	 * Ist das überhaupt der Browser, in dem die Anmeldung begann?
	 *
	 * Wer zwei Browser benutzt, klickt den Link in dem, den sein Mailprogramm
	 * öffnet – und das ist der voreingestellte, nicht der, in dem er gerade
	 * sein Profil angelegt hat. Ohne diese Prüfung meldete sich hier der
	 * falsche an: leeres Konto auf der einen Seite, herrenlose Daten auf der
	 * anderen, und beides sieht aus wie ein Fehler der App.
	 *
	 * Gewarnt wird nur, wenn drüben wirklich etwas liegt. Ein leerer Browser
	 * verliert nichts, und eine Warnung ohne Verlust ist bloß eine Hürde.
	 *
	 * Wer aus der installierten App kommt, bleibt ebenfalls außen vor: Für ihn
	 * gibt es den besseren Weg weiter unten – anmelden und den Code für die App
	 * gleich mitgeben. Eine Warnung stünde dem nur im Weg.
	 *
	 * Der Vorgang wird dabei nicht verbraucht: Wer die Warnung liest und
	 * hinübergeht, kann den Code aus derselben Mail dort noch eintippen.
	 */
	$spur = (string) ($_COOKIE[PENDING_COOKIE] ?? '');
	$gleicherBrowser = $spur !== '' && $token['mark'] !== null
		&& hash_equals((string) $token['mark'], secret_hash($spur));

	if (!$gleicherBrowser && (int) $token['had_data'] === 1 && (int) $token['from_app'] === 0) {
		redirect_to_app('anderer-browser', ['t' => $secret]);
	}

	redirect_to_app('bestaetigen', ['t' => $secret]);
}

/**
 * Die eigentliche Anmeldung, ausgelöst vom Button in der App.
 */
function action_confirm(): void
{
	if (!rate_ok('auth_confirm', 30, 3600)) respond(['error' => 'rate_limited'], 429);

	$secret = (string) (json_body()['t'] ?? '');
	$token = $secret === '' ? null : find_login_token($secret);
	if ($token === null) respond(['error' => 'expired'], 410);

	/**
	 * Braucht die App daneben noch einen Code?
	 *
	 * Der Klick landet immer im Browser; aus einer Mail heraus öffnet sich
	 * keine installierte App. Wer die Anmeldung dort begonnen hat, bekommt
	 * hier zwar eine gültige Sitzung – in der App bliebe er trotzdem draußen.
	 *
	 * Es sei denn, beide teilen ihren Speicher: Auf Android ist das die
	 * Regel, auf iOS ausgeschlossen. Ob es zutrifft, muss man nicht raten –
	 * findet sich die beim Anfordern gesetzte Spur wieder, ist es derselbe
	 * Speicher, und die App ist mit angemeldet.
	 */
	$spur = (string) ($_COOKIE[PENDING_COOKIE] ?? '');
	$gleicherSpeicher = $spur !== '' && $token['mark'] !== null
		&& hash_equals((string) $token['mark'], secret_hash($spur));
	$brauchtCode = (int) $token['from_app'] === 1 && !$gleicherSpeicher;

	$pdo = db();
	$now = time();

	// Erst entwerten, dann anmelden. Zwei Geräte, die denselben Link im selben
	// Moment bestätigen, teilen sich sonst nicht eine Sitzung, sondern schaffen
	// zwei – die Bedingung in der Abfrage lässt nur eines gewinnen.
	// Eine Adresse für ein Gerätekonto: nur in dessen App (dort den Code eintippen), nicht in einem fremden Browser.
	if (!attach_allowed($pdo, $token)) respond(['error' => 'use_code'], 409);

	$used = $pdo->prepare('UPDATE login_tokens SET used_at = ? WHERE token_hash = ? AND used_at IS NULL');
	$used->execute([$now, $token['token_hash']]);
	if ($used->rowCount() !== 1) respond(['error' => 'expired'], 410);

	$erstesMal = mark_seen($pdo, (int) $token['account_id'], $now);
	attach_email($pdo, (int) $token['account_id'], (string) $token['email']);

	start_session($pdo, (int) $token['account_id']);

	// Die Spur hat ihren Zweck erfüllt und verfällt sofort, statt noch zwanzig
	// Minuten im Browser zu liegen.
	setcookie(PENDING_COOKIE, '', [
		'expires' => time() - 3600, 'path' => '/',
		'secure' => is_https(), 'httponly' => true, 'samesite' => 'Lax',
	]);

	$answer = ['ok' => true, 'email' => (string) $token['email']];

	// Der eingelöste Vorgang ist verbraucht – auch sein Code. Für die App
	// entsteht deshalb ein eigener, der nur dort gebraucht wird.
	if ($brauchtCode) {
		$answer['code'] = new_login_code($pdo, (int) $token['account_id'], (string) $token['email']);
	}

	if ($erstesMal) melde_neues_konto($pdo, (string) $token['email']);

	respond($answer);
}

/**
 * Vermerkt den Besuch – und sagt, ob es der erste war.
 *
 * Die Bedingung steht in der Abfrage, nicht davor: Zwei Anmeldungen im selben
 * Moment fänden sonst beide ein leeres Feld vor, und die Benachrichtigung käme
 * doppelt.
 *
 * Beim ersten Mal werden Region und Gerät mitgeschrieben – nur dann. Später
 * überschriebe jede Anmeldung vom Rechner die Angabe vom Telefon, und die
 * Übersicht zeigte, womit zuletzt jemand da war statt womit er anfing.
 */
function mark_seen(PDO $pdo, int $accountId, int $now): bool
{
	$erste = $pdo->prepare(<<<'SQL'
		UPDATE accounts SET last_seen_at = ?, region = ?, platform = ?
		WHERE id = ? AND last_seen_at IS NULL
	SQL);
	$erste->execute([
		$now,
		request_region(),
		platform_from_ua($_SERVER['HTTP_USER_AGENT'] ?? null),
		$accountId,
	]);
	if ($erste->rowCount() === 1) return true;

	$pdo->prepare('UPDATE accounts SET last_seen_at = ? WHERE id = ?')->execute([$now, $accountId]);
	return false;
}

/**
 * Der Betreiber erfährt von einem neuen Konto.
 *
 * Gemeldet wird die erste eingelöste Anmeldung, nicht das Anlegen: Ein Konto
 * entsteht schon beim Anfordern des Links, also auch bei jedem Vertipper und
 * jeder fremden Adresse, die jemand ins Formular schreibt. Erst wer den Link
 * oder den Code auch benutzt hat, ist wirklich da.
 */
function melde_neues_konto(PDO $pdo, string $email): void
{
	$anzahl = (int) $pdo->query('SELECT COUNT(*) FROM accounts')->fetchColumn();

	// Server laufen üblicherweise auf UTC, gelesen wird die Nachricht aber
	// hier. Nur für diese eine Zeile umgerechnet – die globale Zone zu
	// verstellen würde alles andere mit betreffen, was Zeit misst.
	$wann = (new DateTimeImmutable('now', new DateTimeZone('Europe/Berlin')))
		->format('d.m.Y, H:i');

	$stand = $anzahl === 1
		? 'Das erste Konto überhaupt.'
		: "Damit sind es $anzahl Konten.";

	notify_owner('Neues Konto bei ThisDog', <<<TEXT
	Jemand hat sich zum ersten Mal angemeldet.

	    $email
	    $wann Uhr

	$stand
	TEXT);
}

/**
 * Ein Konto ohne E-Mail bekommt die bestätigte Adresse. Hat sie inzwischen ein anderes Konto
 * (zwei Anmeldungen zugleich), bleibt es ohne – angemeldet ist man trotzdem.
 */
/**
 * Hängt der Vorgang eine Adresse an ein Gerätekonto (es hatte beim Anfordern keine)? Dann gilt er nur in der
 * Sitzung genau dieses Kontos. Sonst könnte jemand mit seinem Gerätekonto eine fremde Adresse anfordern – und wer
 * den unerwarteten Code eintippt, landete samt Adresse in dessen Konto.
 */
function attach_allowed(PDO $pdo, array $token): bool
{
	$s = $pdo->prepare('SELECT email FROM accounts WHERE id = ?');
	$s->execute([(int) $token['account_id']]);
	$email = $s->fetchColumn();
	if ($email !== null && $email !== false) return true;   // Konto mit Adresse: normale Anmeldung
	$session = current_session($pdo);
	return $session !== null && (int) $session['account_id'] === (int) $token['account_id'];
}

function attach_email(PDO $pdo, int $accountId, string $email): void
{
	if ($email === '') return;
	try {
		$pdo->prepare('UPDATE accounts SET email = ? WHERE id = ? AND email IS NULL')->execute([$email, $accountId]);
	} catch (PDOException $e) {
		error_log('[stella] Adresse schon vergeben: ' . $e->getMessage());
	}
}

/**
 * Ein Konto für dieses Gerät, ohne E-Mail und ohne Mail.
 *
 * So kommt man mit einem Tipp ins Rudel: Einladung öffnen, fertig. Die Sitzung hält 180 Tage und
 * verlängert sich bei jeder Benutzung; wer auf ein neues Telefon umzieht, fügt vorher eine E-Mail
 * hinzu oder lässt sich neu einladen. Ist schon jemand angemeldet, bleibt es bei diesem Konto.
 */
function action_start(): void
{
	$pdo = db();
	$session = current_session($pdo);
	if ($session !== null) {
		respond(['ok' => true, 'signedIn' => true, 'email' => $session['email']]);
	}
	// Gegen Massenanlage von einer Leitung aus. Ein Haushalt mit ein paar Telefonen kommt weit darunter.
	if (!rate_ok('auth_start', 10, 3600)) respond(['error' => 'rate_limited'], 429);
	db_gc($pdo);

	$id = create_device_account($pdo);
	mark_seen($pdo, $id, time());
	start_session($pdo, $id);
	melde_neues_konto($pdo, 'ohne E-Mail (Gerät)');
	respond(['ok' => true, 'signedIn' => true, 'email' => null]);
}

/** Der offene Vorgang zu einem Geheimnis – oder null, wenn er nicht (mehr) gilt. */
function find_login_token(string $secret): ?array
{
	$stmt = db()->prepare('SELECT * FROM login_tokens WHERE token_hash = ?');
	$stmt->execute([secret_hash($secret)]);
	$token = $stmt->fetch();

	if (!$token || $token['used_at'] !== null || (int) $token['expires_at'] < time()) {
		return null;
	}
	return $token;
}

/**
 * Ein eigenständiger Vorgang, der nur über den Code läuft.
 *
 * Wird gebraucht, wenn die Anmeldung in der App begann, der Link aber im
 * Browser landete: Dort ist man jetzt angemeldet, die App noch nicht.
 */
function new_login_code(PDO $pdo, int $accountId, string $email): string
{
	$code = login_code();
	$stmt = $pdo->prepare(<<<'SQL'
		INSERT INTO login_tokens (token_hash, account_id, created_at, expires_at, code_hash, email, from_app)
		VALUES (?, ?, ?, ?, ?, ?, 0)
	SQL);
	// Ohne Link: Der Platzhalter füllt nur die Spalte, zu ihm gibt es kein
	// Geheimnis, das jemand kennen könnte.
	$stmt->execute([
		secret_hash(new_secret()), $accountId, time(), time() + LOGIN_TTL,
		secret_hash($code), $email,
	]);
	return $code;
}

/**
 * Anmeldung über den Code aus der Mail.
 *
 * Anders als der Link meldet er das Gerät an, auf dem er eingetippt wird –
 * der einzige Weg in eine installierte App, denn aus dem Postfach heraus
 * öffnet sich immer der Browser.
 *
 * Sechs Ziffern sind wenig; drei Fehlversuche entwerten den Code deshalb,
 * und die Adresse muss dazu passen.
 */
function action_code(): void
{
	if (!rate_ok('auth_code', 30, 3600)) respond(['error' => 'rate_limited'], 429);

	$body = json_body();
	$email = clean_email((string) ($body['email'] ?? ''));
	$code = preg_replace('/\D/', '', (string) ($body['code'] ?? ''));

	if ($email === null || strlen((string) $code) !== 6) {
		respond(['error' => 'bad_code'], 422);
	}

	$pdo = db();
	$now = time();

	// Der Code gehört zu dem Gerät, das ihn angefordert hat: Dort liegt die Spur aus dem Cookie. So macht eine
	// fremde Anforderung für dieselbe Adresse den Code nicht ungültig, und Fremde verbrauchen nicht dessen Versuche.
	// Ohne Spur (Cookie verloren) gilt wie früher der jüngste offene Code, nur ohne dessen Versuche anzutasten.
	$spur = (string) ($_COOKIE[PENDING_COOKIE] ?? '');
	$token = false;
	if ($spur !== '') {
		$stmt = $pdo->prepare(<<<'SQL'
			SELECT * FROM login_tokens
			WHERE email = ? AND mark = ? AND used_at IS NULL AND expires_at > ? AND code_hash IS NOT NULL
			ORDER BY created_at DESC LIMIT 1
		SQL);
		$stmt->execute([$email, secret_hash($spur), $now]);
		$token = $stmt->fetch();
	}
	$gebunden = $token !== false;
	if (!$gebunden) {
		$stmt = $pdo->prepare(<<<'SQL'
			SELECT * FROM login_tokens
			WHERE email = ? AND used_at IS NULL AND expires_at > ? AND code_hash IS NOT NULL
			ORDER BY created_at DESC LIMIT 1
		SQL);
		$stmt->execute([$email, $now]);
		$token = $stmt->fetch();
	}

	if (!$token) respond(['error' => 'bad_code'], 422);

	// Fehlversuche je Adresse: vom selben Anschluss höchstens zehn, insgesamt höchstens zwanzig pro Stunde.
	// Wer von einem Anschluss aus rät, sperrt damit nur sich selbst.
	$failKey = 'auth_fail_' . substr(sha1($email), 0, 12);
	if (rate_full($failKey, 10) || rate_full($failKey . '_alle', 20, 3600, false)) respond(['error' => 'too_many_tries'], 429);

	if ($gebunden) {
		// Erst zählen, dann vergleichen – in einem Schritt: Parallele Anfragen bekämen sonst alle den Stand „0 Versuche“.
		$try = $pdo->prepare('UPDATE login_tokens SET tries = tries + 1 WHERE token_hash = ? AND tries < 3 AND used_at IS NULL');
		$try->execute([$token['token_hash']]);
		if ($try->rowCount() !== 1) {
			// Verbraucht: Sonst ließe sich der Code in Ruhe durchprobieren.
			$pdo->prepare('UPDATE login_tokens SET used_at = ? WHERE token_hash = ?')
				->execute([$now, $token['token_hash']]);
			respond(['error' => 'too_many_tries'], 429);
		}
	}

	if (!hash_equals((string) $token['code_hash'], secret_hash((string) $code))) {
		rate_ok($failKey, PHP_INT_MAX);
		rate_ok($failKey . '_alle', PHP_INT_MAX, 3600, false);
		respond(['error' => 'bad_code'], 422);
	}
	if (!attach_allowed($pdo, $token)) respond(['error' => 'bad_code'], 422);

	$used = $pdo->prepare('UPDATE login_tokens SET used_at = ? WHERE token_hash = ? AND used_at IS NULL');
	$used->execute([$now, $token['token_hash']]);
	if ($used->rowCount() !== 1) respond(['error' => 'bad_code'], 422);

	$erstesMal = mark_seen($pdo, (int) $token['account_id'], $now);
	attach_email($pdo, (int) $token['account_id'], $email);

	start_session($pdo, (int) $token['account_id']);

	if ($erstesMal) melde_neues_konto($pdo, $email);

	respond(['ok' => true, 'signedIn' => true]);
}

/* ============================ Status ============================ */

function action_me(): void
{
	$pdo = db();
	$session = current_session($pdo);

	if ($session === null) {
		respond(['signedIn' => false]);
	}

	// Wer die App benutzt, soll nicht mitten im Jahr hinausfliegen.
	touch_session($pdo, $session);

	respond([
		'signedIn' => true,
		'email' => $session['email'],
	]);
}

function action_logout(): void
{
	end_session(db());
	respond(['ok' => true, 'signedIn' => false]);
}


/**
 * Löscht das Konto samt allem, was daran hängt.
 *
 * Die Daten auf dem Gerät bleiben davon unberührt – gelöscht wird, was auf
 * dem Server liegt. Wer sein Konto loswerden will, will selten auch seinen
 * Hundekalender verlieren.
 */
function action_delete(): void
{
	$pdo = db();
	$session = current_session($pdo);
	if ($session === null) respond(['error' => 'not_signed_in'], 401);

	$accountId = (int) $session['account_id'];
	$pdo->beginTransaction();
	try {
		// Rudel, in denen niemand sonst ist, verschwinden mit allem, was daran hängt (Datensätze,
		// Notfallpass, Freundschaften). Rudel mit weiteren Mitgliedern bleiben – die gemeinsamen
		// Daten gehören auch ihnen.
		$alone = $pdo->prepare(<<<'SQL'
			SELECT m.pack_id FROM pack_members m
			WHERE m.account_id = ? AND (SELECT COUNT(*) FROM pack_members o WHERE o.pack_id = m.pack_id) = 1
		SQL);
		$alone->execute([$accountId]);
		$dropPack = $pdo->prepare('DELETE FROM packs WHERE id = ?');
		foreach ($alone->fetchAll(PDO::FETCH_COLUMN) as $packId) $dropPack->execute([(int) $packId]);
		// Gemeldete Fotos gehen mit; die übrigen bleiben am Ort, ohne Bezug zum Konto.
		$pending = $pdo->prepare("SELECT file FROM place_photos WHERE account_id = ? AND status != 'ok'");
		$pending->execute([$accountId]);
		$files = $pending->fetchAll(PDO::FETCH_COLUMN);
		$pdo->prepare("DELETE FROM place_photos WHERE account_id = ? AND status != 'ok'")->execute([$accountId]);
		$pdo->prepare("DELETE FROM place_checks WHERE account_id = ? AND status != 'ok'")->execute([$accountId]);
		// Fremdschlüssel räumen Sitzungen, Token, Mitgliedschaften und Gerätekennungen mit ab.
		$pdo->prepare('DELETE FROM accounts WHERE id = ?')->execute([$accountId]);
		$pdo->commit();
	} catch (Throwable $e) {
		$pdo->rollBack();
		throw $e;
	}

	foreach ($files ?? [] as $f) @unlink(data_dir() . '/fotos/' . basename((string) $f));
	end_session($pdo);
	respond(['ok' => true, 'signedIn' => false]);
}

/* ============================ Umgebung ============================ */

function is_local_request(): bool
{
	return mail_local_request();
}

/**
 * Adresse der App. Konfiguriert schlägt geraten – hinter einem Proxy ist der
 * Kopf der Anfrage nicht immer die Adresse, unter der Besucher ankommen.
 */
function app_url(): string
{
	$configured = trim((string) cfg('APP_URL', ''));
	if ($configured !== '') return rtrim($configured, '/');

	// Ohne APP_URL nur auf dem eigenen Rechner raten: Sonst bestimmte der Host-Kopf, wohin der Anmeldelink
	// in der Mail zeigt – und wer ihn fälscht, bekäme das Geheimnis eines anderen.
	if (!mail_local_request()) throw new RuntimeException('APP_URL fehlt in config.php');
	return (is_https() ? 'https://' : 'http://') . (string) $_SERVER['HTTP_HOST'];
}

/**
 * Zurück in die App, mit einem Vermerk für die Oberfläche.
 *
 * Der Vermerk steht vor der Raute, nicht dahinter: Hinter der Raute liest ihn
 * der Router der App als Teil des Ansichtsnamens und findet die Seite nicht.
 */
function redirect_to_app(string $status, array $extra = []): void
{
	// Zusätzliche Angaben gehören als eigene Parameter in die Adresse. Sie an
	// den Status zu hängen hiesse, das Trennzeichen mitzukodieren – der Client
	// bekäme einen Wert, der aussieht wie zwei.
	$query = ['anmeldung' => $status] + $extra;
	header('Location: ' . app_url() . '/?' . http_build_query($query) . '#daten');
	http_response_code(302);
	exit;
}
