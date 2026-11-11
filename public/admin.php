<?php
declare(strict_types=1);

/**
 * Übersicht für den Betreiber.
 *
 *   /admin.php   → Konten, Hunde, Nutzung, Herkunft
 *
 * Kein eigenes Passwort: Wer hier hereinkommt, ist in der App angemeldet und
 * steht in `ADMIN_EMAILS`. Ein zweites Geheimnis wäre ein zweites, das
 * verloren gehen kann – die Anmeldung gibt es schon, und sie ist stärker als
 * jedes Passwort, das man sich für eine Statistikseite merken würde.
 *
 * Gezeigt werden Summen, keine Personen. Die Adressen der Konten stehen nur
 * angedeutet da: Was diese Seite beantworten soll – wie viele, woher, was
 * benutzen sie – braucht keinen einzigen vollständigen Namen. Wer eine Adresse
 * wirklich braucht, hat die Datenbank.
 */

require_once __DIR__ . '/api/lib.php';
require_once __DIR__ . '/api/lib-db.php';
require_once __DIR__ . '/api/auth-session.php';
require_once __DIR__ . '/api/lib-admin.php';

$pdo = db();
$email = admin_or_404($pdo);

header('Content-Type: text/html; charset=utf-8');
// Zahlen über Nutzer gehören in keinen Zwischenspeicher und in keinen Index.
header('Cache-Control: no-store, private');
header('X-Robots-Tag: noindex, nofollow');
header('Referrer-Policy: no-referrer');

/* ============================ Erheben ============================ */

$jetzt = time();
$tag = 86400;

/** Ein Skalar aus einer Abfrage, als ganze Zahl. */
function zahl(PDO $pdo, string $sql, array $args = []): int
{
	$stmt = $pdo->prepare($sql);
	$stmt->execute($args);
	return (int) $stmt->fetchColumn();
}

/* ---- Konten ---- */

$konten = [
	'gesamt' => zahl($pdo, 'SELECT COUNT(*) FROM accounts'),
	// Ein Konto entsteht schon beim Anfordern des Links. Angekommen ist erst,
	// wer ihn auch eingelöst hat – die Differenz sind Vertipper und Abbrüche.
	'angekommen' => zahl($pdo, 'SELECT COUNT(*) FROM accounts WHERE last_seen_at IS NOT NULL'),
	'neu7' => zahl($pdo, 'SELECT COUNT(*) FROM accounts WHERE created_at > ?', [$jetzt - 7 * $tag]),
	'neu30' => zahl($pdo, 'SELECT COUNT(*) FROM accounts WHERE created_at > ?', [$jetzt - 30 * $tag]),
	'aktiv7' => zahl($pdo, 'SELECT COUNT(*) FROM accounts WHERE last_seen_at > ?', [$jetzt - 7 * $tag]),
	'aktiv30' => zahl($pdo, 'SELECT COUNT(*) FROM accounts WHERE last_seen_at > ?', [$jetzt - 30 * $tag]),
	'sitzungen' => zahl($pdo, 'SELECT COUNT(*) FROM sessions WHERE expires_at > ?', [$jetzt]),
];

// Zwölf Wochen Zulauf. Rückwärts gezählt, damit die laufende Woche rechts steht.
$zulauf = [];
for ($i = 11; $i >= 0; $i--) {
	$von = $jetzt - ($i + 1) * 7 * $tag;
	$bis = $jetzt - $i * 7 * $tag;
	$zulauf[] = [
		'label' => $i === 0 ? 'jetzt' : '−' . $i . ' W',
		'wert' => zahl($pdo, 'SELECT COUNT(*) FROM accounts WHERE created_at > ? AND created_at <= ?', [$von, $bis]),
	];
}

/* ---- Hunde ---- */

/**
 * Die Profile, ausgepackt.
 * Grabsteine haben keinen Rumpf und zählen nicht mit – sie sind gelöschte
 * Profile und stünden sonst als Hunde in der Liste.
 */
$profile = [];
$stmt = $pdo->query("SELECT payload FROM pack_records WHERE kind = 'profile' AND payload IS NOT NULL LIMIT 20000");
foreach ($stmt as $zeile) {
	$daten = json_decode((string) $zeile['payload'], true);
	if (is_array($daten)) $profile[] = $daten;
}

$hunde = ['mit_name' => 0, 'weiblich' => 0, 'maennlich' => 0, 'kastriert' => 0];
$rassen = [];
$alter = ['unter 1' => 0, '1–3' => 0, '4–7' => 0, '8–11' => 0, '12+' => 0];
$gewichte = [];

foreach ($profile as $p) {
	if (trim((string) ($p['name'] ?? '')) !== '') $hunde['mit_name']++;

	$geschlecht = (string) ($p['sex'] ?? '');
	if ($geschlecht === 'f') $hunde['weiblich']++;
	elseif ($geschlecht === 'm') $hunde['maennlich']++;
	if (!empty($p['neutered'])) $hunde['kastriert']++;

	// Rassen sind freier Text. Für die Rangliste wird kleingeschrieben
	// gruppiert, angezeigt aber die Schreibweise, die zuerst vorkam.
	$rasse = trim((string) ($p['breed'] ?? ''));
	if ($rasse !== '') {
		$schluessel = mb_strtolower($rasse, 'UTF-8');
		if (!isset($rassen[$schluessel])) $rassen[$schluessel] = ['name' => $rasse, 'anzahl' => 0];
		$rassen[$schluessel]['anzahl']++;
	}

	$geboren = (string) ($p['birthdate'] ?? '');
	if (preg_match('/^\d{4}-\d{2}-\d{2}$/', $geboren)) {
		$jahre = (int) ((new DateTimeImmutable($geboren))->diff(new DateTimeImmutable('@' . $jetzt))->y);
		$topf = match (true) {
			$jahre < 1 => 'unter 1',
			$jahre <= 3 => '1–3',
			$jahre <= 7 => '4–7',
			$jahre <= 11 => '8–11',
			default => '12+',
		};
		$alter[$topf]++;
	}

	$kg = $p['weightKg'] ?? null;
	if (is_numeric($kg) && $kg > 0 && $kg < 120) $gewichte[] = (float) $kg;
}

uasort($rassen, fn($a, $b) => $b['anzahl'] <=> $a['anzahl']);

sort($gewichte);
$gewicht = null;
if ($gewichte !== []) {
	$mitte = intdiv(count($gewichte), 2);
	$gewicht = [
		'median' => count($gewichte) % 2 ? $gewichte[$mitte] : ($gewichte[$mitte - 1] + $gewichte[$mitte]) / 2,
		'min' => $gewichte[0],
		'max' => $gewichte[count($gewichte) - 1],
		'anzahl' => count($gewichte),
	];
}

/* ---- Was benutzt wird ---- */

$arten = [
	'event' => 'Termine',
	'weight' => 'Messungen',
	'vaccinations' => 'Impfungen',
	'deworming' => 'Entwurmung',
	'meds' => 'Medikamente',
	'favorite' => 'Merkliste',
	'checks' => 'Häkchen',
];

$nutzung = [];
foreach ($arten as $art => $titel) {
	$stmt = $pdo->prepare(<<<'SQL'
		SELECT COUNT(*) AS eintraege, COUNT(DISTINCT pack_id) AS konten
		FROM pack_records WHERE kind = ? AND payload IS NOT NULL
	SQL);
	$stmt->execute([$art]);
	$zeile = $stmt->fetch() ?: ['eintraege' => 0, 'konten' => 0];
	$nutzung[] = [
		'titel' => $titel,
		'eintraege' => (int) $zeile['eintraege'],
		'konten' => (int) $zeile['konten'],
	];
}

$kalender = [
	'je_abgerufen' => zahl($pdo, 'SELECT COUNT(*) FROM accounts WHERE cal_fetched_at IS NOT NULL'),
	'aktiv7' => zahl($pdo, 'SELECT COUNT(*) FROM accounts WHERE cal_fetched_at > ?', [$jetzt - 7 * $tag]),
];

/* ---- Geräte und Herkunft ---- */

$plattformen = [];
$stmt = $pdo->query('SELECT platform, COUNT(*) AS n FROM accounts WHERE platform IS NOT NULL GROUP BY platform ORDER BY n DESC');
foreach ($stmt as $zeile) $plattformen[(string) $zeile['platform']] = (int) $zeile['n'];

$regionen = [];
$stmt = $pdo->query('SELECT region, COUNT(*) AS n FROM accounts WHERE region IS NOT NULL GROUP BY region ORDER BY n DESC LIMIT 12');
foreach ($stmt as $zeile) $regionen[(string) $zeile['region']] = (int) $zeile['n'];

// Die laufenden Sitzungen sagen, womit gerade gearbeitet wird – anders als die
// Spalte oben, die den Anfang festhält.
$geraete = [];
$stmt = $pdo->prepare('SELECT user_agent FROM sessions WHERE expires_at > ?');
$stmt->execute([$jetzt]);
foreach ($stmt as $zeile) {
	$topf = platform_from_ua($zeile['user_agent'] ?? null);
	$geraete[$topf] = ($geraete[$topf] ?? 0) + 1;
}
arsort($geraete);

/* ---- Zähler aus dem Suchprotokoll ---- */

/**
 * Die Ereignisse, die die App meldet – abgelegt als «@typ:wert».
 * Eine eigene Datenbank neben der Kontodatenbank: Was hier steht, hat mit
 * Personen nichts zu tun und soll auch nicht neben ihnen liegen.
 */
function ereignisse(string $typ, int $limit = 20): array
{
	static $pdo = null;
	if ($pdo === null) {
		$datei = data_file('searches.sqlite');
		if (!file_exists($datei)) return [];
		try {
			$pdo = new PDO('sqlite:' . $datei, null, null, [
				PDO::ATTR_ERRMODE => PDO::ERRMODE_EXCEPTION,
				PDO::ATTR_DEFAULT_FETCH_MODE => PDO::FETCH_ASSOC,
			]);
		} catch (Throwable $e) {
			return [];
		}
	}

	try {
		$stmt = $pdo->prepare('SELECT term, count FROM terms WHERE term LIKE ? ORDER BY count DESC LIMIT ?');
		$stmt->execute(['@' . $typ . ':%', $limit]);
	} catch (Throwable $e) {
		return [];
	}

	$aus = [];
	foreach ($stmt as $zeile) {
		$name = substr((string) $zeile['term'], strlen($typ) + 2);
		if ($name !== '') $aus[$name] = (int) $zeile['count'];
	}
	return $aus;
}

/**
 * Aus Router-Schlüsseln werden lesbare Namen.
 * Was nicht in der Liste steht, bleibt stehen wie es ist – ein unbekannter
 * Bereich soll auffallen, nicht verschwinden.
 */
function benannt(array $werte, array $namen): array
{
	$aus = [];
	foreach ($werte as $schluessel => $wert) {
		$name = $namen[$schluessel] ?? $schluessel;
		$aus[$name] = ($aus[$name] ?? 0) + $wert;
	}
	arsort($aus);
	return $aus;
}

$bereiche = benannt(ereignisse('bereich'), [
	'home' => 'Start',
	'food' => 'Food-Check',
	'tips' => 'Tipps',
	'tipsDetail' => 'Tipps',
	'dog' => 'Hund',
	'calendar' => 'Termine',
	'tools' => 'Werkzeuge',
	'places' => 'Karte',
	'notfall' => 'Notfallkarte',
	'daten' => 'Daten und Konto',
	'legal' => 'Impressum',
]);

$modus = benannt(ereignisse('modus'), [
	'installiert' => 'Installiert',
	'browser' => 'Im Browser',
]);

$herkunft = ereignisse('herkunft', 15);
$auswaerts = ereignisse('outbound');

/** Die häufigsten Suchbegriffe – ohne die internen Ereignisse. */
function suchbegriffe(int $limit = 15): array
{
	$datei = data_file('searches.sqlite');
	if (!file_exists($datei)) return [];
	try {
		$pdo = new PDO('sqlite:' . $datei, null, null, [
			PDO::ATTR_ERRMODE => PDO::ERRMODE_EXCEPTION,
			PDO::ATTR_DEFAULT_FETCH_MODE => PDO::FETCH_ASSOC,
		]);
		$stmt = $pdo->prepare("SELECT term, count FROM terms WHERE term NOT LIKE '@%' ORDER BY count DESC LIMIT ?");
		$stmt->execute([$limit]);
		$aus = [];
		foreach ($stmt as $zeile) $aus[(string) $zeile['term']] = (int) $zeile['count'];
		return $aus;
	} catch (Throwable $e) {
		return [];
	}
}

$suchen = suchbegriffe();

/* ---- Die jüngsten Konten ---- */

$stmt = $pdo->prepare(<<<'SQL'
	SELECT email, created_at, last_seen_at, region, platform
	FROM accounts ORDER BY created_at DESC LIMIT 12
SQL);
$stmt->execute();
$neueste = $stmt->fetchAll();

/* ============================ Darstellen ============================ */

function h(?string $text): string
{
	return htmlspecialchars((string) $text, ENT_QUOTES, 'UTF-8');
}

/** Eine Adresse, so weit angedeutet, dass sie sich nicht ablesen lässt. */
function angedeutet(?string $email): string
{
	if ($email === null) return 'ohne E-Mail';
	$at = strrpos($email, '@');
	if ($at === false || $at === 0) return '…';
	$name = substr($email, 0, $at);
	$domain = substr($email, $at + 1);
	return h(mb_substr($name, 0, 1, 'UTF-8') . str_repeat('·', min(6, max(2, mb_strlen($name, 'UTF-8') - 1))) . '@' . $domain);
}

function wann(?int $zeit): string
{
	if (!$zeit) return '–';
	$her = time() - $zeit;
	return match (true) {
		$her < 3600 => 'vor ' . max(1, intdiv($her, 60)) . ' Min',
		$her < 86400 => 'vor ' . intdiv($her, 3600) . ' Std',
		$her < 86400 * 30 => 'vor ' . intdiv($her, 86400) . ' T',
		default => date('d.m.Y', $zeit),
	};
}

/** Eine Rangliste als Balken. Ohne Werte bleibt die Karte ehrlich leer. */
function balken(array $werte, string $leer = 'Noch nichts gezählt.'): string
{
	if ($werte === []) return '<p class="leer">' . h($leer) . '</p>';

	$max = max($werte);
	$aus = '<div class="balken">';
	foreach ($werte as $name => $wert) {
		$breite = $max > 0 ? max(2, (int) round($wert / $max * 100)) : 0;
		$aus .= '<div class="zeile">'
			. '<span class="name">' . h((string) $name) . '</span>'
			. '<span class="spur"><span class="fuellung" style="width:' . $breite . '%"></span></span>'
			. '<span class="wert">' . number_format($wert, 0, ',', '.') . '</span>'
			. '</div>';
	}
	return $aus . '</div>';
}

$anteil = fn(int $teil, int $ganz) => $ganz > 0 ? round($teil / $ganz * 100) . ' %' : '–';
?>
<!doctype html>
<html lang="de">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<meta name="robots" content="noindex, nofollow">
<title>Übersicht – ThisDog</title>
<style>
	:root {
		--paper: #fbf6ea; --surface: #fffdf8; --surface-2: #f7f1e4;
		--ink: #191510; --ink-2: #4a4238; --ink-3: #746a5d;
		--line: #e3d9c6; --brand: #bc5527; --brand-soft: #f6e6dc;
		--r: 16px; --r-sm: 12px;
	}
	@media (prefers-color-scheme: dark) {
		:root {
			--paper: #16130f; --surface: #1e1a15; --surface-2: #262019;
			--ink: #f4efe4; --ink-2: #cdc4b5; --ink-3: #9a9084;
			--line: #332c23; --brand: #e0764a; --brand-soft: #3a2419;
		}
	}
	* { box-sizing: border-box; }
	body {
		margin: 0; padding: 24px 16px 64px;
		background: var(--paper); color: var(--ink);
		font: 16px/1.55 ui-sans-serif, system-ui, -apple-system, "Segoe UI", Roboto, sans-serif;
		-webkit-font-smoothing: antialiased;
	}
	.wrap { max-width: 1080px; margin: 0 auto; }
	header.kopf { display: flex; flex-wrap: wrap; gap: 8px 16px; align-items: baseline; margin-bottom: 20px; }
	h1 { font-size: 22px; margin: 0; letter-spacing: -0.01em; }
	.kopf .wer { color: var(--ink-3); font-size: 14px; }
	.kopf .zurueck { margin-left: auto; color: var(--brand); text-decoration: none; font-size: 14px; }
	.kopf .zurueck:hover { text-decoration: underline; }

	.raster { display: grid; gap: 16px; grid-template-columns: repeat(auto-fit, minmax(280px, 1fr)); }
	section {
		background: var(--surface); border: 1px solid var(--line);
		border-radius: var(--r); padding: 18px 18px 20px;
	}
	section.breit { grid-column: 1 / -1; }
	h2 { font-size: 15px; margin: 0 0 14px; letter-spacing: 0.02em; text-transform: uppercase; color: var(--ink-3); }

	.kacheln { display: grid; gap: 10px; grid-template-columns: repeat(auto-fit, minmax(110px, 1fr)); }
	.kachel { background: var(--surface-2); border-radius: var(--r-sm); padding: 12px 14px; }
	.kachel b { display: block; font-size: 26px; font-weight: 700; letter-spacing: -0.02em; line-height: 1.1; }
	.kachel span { display: block; font-size: 12.5px; color: var(--ink-3); margin-top: 2px; }
	.kachel .neben { font-size: 12.5px; color: var(--ink-3); }

	.balken { display: grid; gap: 7px; }
	.zeile { display: grid; grid-template-columns: minmax(90px, 34%) 1fr auto; gap: 10px; align-items: center; font-size: 14px; }
	.zeile .name { overflow: hidden; text-overflow: ellipsis; white-space: nowrap; color: var(--ink-2); }
	.zeile .spur { background: var(--surface-2); border-radius: 999px; height: 9px; overflow: hidden; }
	.zeile .fuellung { display: block; height: 100%; background: var(--brand); border-radius: 999px; }
	.zeile .wert { font-variant-numeric: tabular-nums; color: var(--ink-3); font-size: 13px; min-width: 3ch; text-align: right; }

	.saeulen { display: flex; align-items: flex-end; gap: 6px; height: 120px; margin-top: 4px; }
	.saeulen div { flex: 1; display: flex; flex-direction: column; justify-content: flex-end; height: 100%; gap: 4px; }
	/* Keine Mindesthöhe: Eine Woche ohne Zulauf muss leer aussehen, sonst
	   liest sich der Sockel wie ein kleiner Wert. */
	.saeulen i {
		display: block; background: var(--brand); border-radius: 4px 4px 0 0;
		font-style: normal;
	}
	.saeulen small { display: block; text-align: center; font-size: 10.5px; color: var(--ink-3); }
	.saeulen b { display: block; text-align: center; font-size: 11px; font-variant-numeric: tabular-nums; }

	table { width: 100%; border-collapse: collapse; font-size: 13.5px; }
	th, td { text-align: left; padding: 7px 10px 7px 0; border-bottom: 1px solid var(--line); }
	th { color: var(--ink-3); font-weight: 600; font-size: 12px; text-transform: uppercase; letter-spacing: 0.03em; }
	tr:last-child td { border-bottom: 0; }
	td.zahl { font-variant-numeric: tabular-nums; color: var(--ink-3); }

	.leer { color: var(--ink-3); font-size: 13.5px; margin: 0; }
	.fuss { color: var(--ink-3); font-size: 12.5px; margin: 22px 0 0; line-height: 1.6; }
	.fuss code { background: var(--surface-2); padding: 1px 5px; border-radius: 5px; }
	.scroll { overflow-x: auto; }
</style>
</head>
<body>
<div class="wrap">

<header class="kopf">
	<h1>Übersicht</h1>
	<span class="wer"><?= h($email) ?></span>
	<a class="zurueck" href="/admin-support.php">Anfragen</a> <a class="zurueck" style="margin-left:14px" href="/admin-orte.php">Orte</a>
</header>

<div class="raster">

	<section class="breit">
		<h2>Konten</h2>
		<div class="kacheln">
			<div class="kachel">
				<b><?= $konten['angekommen'] ?></b>
				<span>angemeldet<br><span class="neben"><?= $konten['gesamt'] ?> angelegt</span></span>
			</div>
			<div class="kachel"><b><?= $konten['neu7'] ?></b><span>neu, 7 Tage</span></div>
			<div class="kachel"><b><?= $konten['neu30'] ?></b><span>neu, 30 Tage</span></div>
			<div class="kachel"><b><?= $konten['aktiv7'] ?></b><span>aktiv, 7 Tage</span></div>
			<div class="kachel"><b><?= $konten['aktiv30'] ?></b><span>aktiv, 30 Tage</span></div>
			<div class="kachel"><b><?= $konten['sitzungen'] ?></b><span>offene Sitzungen</span></div>
		</div>

		<h2 style="margin-top:20px">Zulauf, zwölf Wochen</h2>
		<?php $maxZulauf = max(1, max(array_column($zulauf, 'wert'))); ?>
		<div class="saeulen">
			<?php foreach ($zulauf as $woche): ?>
				<div>
					<b><?= $woche['wert'] ?: '' ?></b>
					<i style="height:<?= $woche['wert'] > 0 ? max(3, (int) round($woche['wert'] / $maxZulauf * 100)) : 0 ?>%"></i>
					<small><?= h($woche['label']) ?></small>
				</div>
			<?php endforeach; ?>
		</div>
	</section>

	<section>
		<h2>Hunde</h2>
		<div class="kacheln">
			<div class="kachel"><b><?= $hunde['mit_name'] ?></b><span>mit Namen</span></div>
			<div class="kachel"><b><?= $hunde['weiblich'] ?>&thinsp;/&thinsp;<?= $hunde['maennlich'] ?></b><span>weiblich / männlich</span></div>
			<div class="kachel">
				<b><?= $anteil($hunde['kastriert'], max(1, count($profile))) ?></b>
				<span>kastriert</span>
			</div>
			<?php if ($gewicht !== null): ?>
				<div class="kachel">
					<b><?= number_format($gewicht['median'], 1, ',', '.') ?> kg</b>
					<span>Median<br><span class="neben"><?= number_format($gewicht['min'], 1, ',', '.') ?>–<?= number_format($gewicht['max'], 1, ',', '.') ?> kg</span></span>
				</div>
			<?php endif; ?>
		</div>

		<h2 style="margin-top:18px">Alter</h2>
		<?= balken(array_filter($alter), 'Kein Geburtsdatum eingetragen.') ?>
	</section>

	<section>
		<h2>Rassen</h2>
		<?php
		$rassenBalken = [];
		foreach (array_slice($rassen, 0, 12) as $eintrag) {
			$rassenBalken[$eintrag['name']] = $eintrag['anzahl'];
		}
		echo balken($rassenBalken, 'Keine Rasse eingetragen.');
		if (count($rassen) > 12) {
			echo '<p class="leer" style="margin-top:10px">und ' . (count($rassen) - 12) . ' weitere</p>';
		}
		?>
	</section>

	<section class="breit">
		<h2>Was benutzt wird</h2>
		<div class="scroll">
			<table>
				<tr><th>Bereich</th><th>Rudel</th><th>Einträge</th><th>je Rudel</th></tr>
				<?php foreach ($nutzung as $z): ?>
					<tr>
						<td><?= h($z['titel']) ?></td>
						<td class="zahl"><?= $z['konten'] ?><?= $konten['angekommen'] > 0 ? ' <span style="opacity:.6">(' . $anteil($z['konten'], $konten['angekommen']) . ')</span>' : '' ?></td>
						<td class="zahl"><?= number_format($z['eintraege'], 0, ',', '.') ?></td>
						<td class="zahl"><?= $z['konten'] > 0 ? number_format($z['eintraege'] / $z['konten'], 1, ',', '.') : '–' ?></td>
					</tr>
				<?php endforeach; ?>
				<tr>
					<td>Kalenderabo</td>
					<td class="zahl"><?= $kalender['je_abgerufen'] ?><?= $konten['angekommen'] > 0 ? ' <span style="opacity:.6">(' . $anteil($kalender['je_abgerufen'], $konten['angekommen']) . ')</span>' : '' ?></td>
					<td class="zahl" colspan="2"><?= $kalender['aktiv7'] ?> in den letzten 7 Tagen abgerufen</td>
				</tr>
			</table>
		</div>
	</section>

	<section>
		<h2>Geöffnete Bereiche</h2>
		<?= balken($bereiche, 'Noch nichts gezählt – die Zähler laufen erst ab dieser Fassung.') ?>
	</section>

	<section>
		<h2>Herkunft</h2>
		<?= balken($herkunft, 'Noch nichts gezählt – wird beim ersten Aufruf je Gerät erfasst.') ?>
		<?php if ($auswaerts !== []): ?>
			<h2 style="margin-top:18px">Klicks nach draußen</h2>
			<?= balken($auswaerts) ?>
		<?php endif; ?>
	</section>

	<section>
		<h2>Sprache der Konten</h2>
		<?= balken($regionen, 'Wird ab jetzt beim ersten Anmelden festgehalten.') ?>
	</section>

	<section>
		<h2>Geräte</h2>
		<?= balken($geraete, 'Keine offenen Sitzungen.') ?>
		<?php if ($modus !== []): ?>
			<h2 style="margin-top:18px">Installiert oder im Browser</h2>
			<?= balken($modus) ?>
		<?php endif; ?>
	</section>

	<section>
		<h2>Häufig gesucht</h2>
		<?= balken($suchen, 'Noch nichts gesucht.') ?>
	</section>

	<section class="breit">
		<h2>Zuletzt dazugekommen</h2>
		<div class="scroll">
			<table>
				<tr><th>Konto</th><th>angelegt</th><th>zuletzt da</th><th>Sprache</th><th>Gerät</th></tr>
				<?php foreach ($neueste as $k): ?>
					<tr>
						<td><?= angedeutet($k['email']) ?></td>
						<td class="zahl"><?= h(wann((int) $k['created_at'])) ?></td>
						<td class="zahl"><?= h(wann($k['last_seen_at'] === null ? null : (int) $k['last_seen_at'])) ?></td>
						<td class="zahl"><?= h((string) ($k['region'] ?? '–')) ?></td>
						<td class="zahl"><?= h((string) ($k['platform'] ?? '–')) ?></td>
					</tr>
				<?php endforeach; ?>
				<?php if ($neueste === []): ?>
					<tr><td colspan="5" class="leer">Noch keine Konten.</td></tr>
				<?php endif; ?>
			</table>
		</div>
	</section>

</div>

<p class="fuss">
	Gezählt wird ohne IP-Adressen und ohne Kennungen: Bereiche und Herkunft
	kommen als bloße Wörter aus der App und liegen in <code>searches.sqlite</code>,
	getrennt von den Konten. Wer in den Einstellungen das Protokollieren
	abschaltet, taucht dort nicht auf. Sprache und Gerät stehen einmalig am
	Konto, festgehalten bei der ersten Anmeldung.
	<br>
	Zulauf und Nutzung stammen aus den abgeglichenen Daten – wer nie angemeldet
	war, ist hier unsichtbar, seine Daten liegen nur auf seinem Gerät.
</p>

</div>
</body>
</html>
