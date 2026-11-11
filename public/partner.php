<?php
declare(strict_types=1);

/**
 * Partnerplätze buchen und verwalten – für Betriebe, im Browser. Die App selbst verkauft nichts und verlinkt
 * nicht hierher (Apple verlangt sonst In-App-Kauf, Richtlinie 3.1.3(g)).
 *
 *   /partner                         Betrieb suchen, Gegend frei? → Text, Auftraggeber, E-Mail → Stripe-Kasse
 *   /partner?danke=<Checkout-ID>     zurück von der Kasse
 *   /partner/verwalten/<Geheimnis>   Zahlen der letzten 30 Tage, Text ändern, Rechnungen und Kündigung (Stripe)
 *
 * Der Platz gilt für eine Gegend (rund 3 × 3 km, lib-services.php) und läuft als Monatsabo. Erst die Meldung von
 * Stripe (api/stripe.php) schaltet ihn frei; bis dahin hält eine offene Kasse die Gegend eine halbe Stunde frei.
 */

require_once __DIR__ . '/api/lib-services.php';
require_once __DIR__ . '/api/lib-stripe.php';

header('Content-Type: text/html; charset=utf-8');
header('Cache-Control: no-store');
header('Referrer-Policy: no-referrer');
header('X-Frame-Options: DENY');

function h($s): string { return htmlspecialchars((string) $s, ENT_QUOTES, 'UTF-8'); }
function plain(string $s, int $max): string { return trim(mb_substr(preg_replace('/\s+/u', ' ', $s) ?? '', 0, $max)); }

$pdo = db();
$x = services_db();
$ready = stripe_ready();
$price = sponsor_price();
$error = '';
$manage = null;

// Verwaltung: das Geheimnis aus der Mail.
$token = (string) ($_GET['verwalten'] ?? '');
if ($token !== '') {
	$q = $pdo->prepare('SELECT * FROM sponsors WHERE manage_hash = ?');
	$q->execute([secret_hash($token)]);
	$manage = $q->fetch() ?: false;
	header('X-Robots-Tag: noindex');
}

if (($_SERVER['REQUEST_METHOD'] ?? '') === 'POST') {
	// Nur Formulare von dieser Seite.
	$host = (string) ($_SERVER['HTTP_HOST'] ?? '');
	$origin = (string) ($_SERVER['HTTP_ORIGIN'] ?? '');
	if ($origin !== 'https://' . $host && $origin !== 'http://' . $host) { http_response_code(403); exit('Nicht erlaubt.'); }
	$action = (string) ($_POST['action'] ?? '');

	if ($action === 'buchen') {
		$place = $x ? service_by_id($x, (string) ($_POST['ort'] ?? '')) : null;
		$text = plain((string) ($_POST['text'] ?? ''), 90);
		$advertiser = plain((string) ($_POST['auftraggeber'] ?? ''), 120);
		$email = clean_email((string) ($_POST['email'] ?? ''));
		if (!$ready) $error = 'Die Buchung ist noch nicht freigeschaltet.';
		elseif ($place === null) $error = 'Diesen Betrieb finden wir nicht mehr. Bitte noch einmal suchen.';
		elseif ($advertiser === '' || $email === null) $error = 'Bitte Auftraggeber und eine gültige E-Mail-Adresse angeben.';
		elseif (empty($_POST['bedingungen'])) $error = 'Bitte den Werbebedingungen zustimmen.';
		elseif (!rate_ok('partner_kasse', 10)) $error = 'Zu viele Versuche. Bitte in einer Stunde noch einmal.';
		else {
			$tile = sponsor_tile((float) $place['lat'], (float) $place['lon']);
			// Sofort sperren: Zwei, die gleichzeitig dieselbe freie Gegend buchen, bekämen sonst beide eine Kasse.
			$pdo->exec('BEGIN IMMEDIATE');
			if (tile_holder($pdo, $tile) !== null) {
				$pdo->exec('ROLLBACK');
				$error = 'Diese Gegend ist gerade vergeben.';
			} else {
				$now = time();
				$pdo->prepare('INSERT INTO sponsors (tile, place_id, kind, name, lat, lon, street, city, phone, website, hours, text, advertiser, email, created_at, updated_at)
					VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)')->execute([$tile, $place['id'], $place['kind'], $place['name'], $place['lat'], $place['lon'],
					$place['street'], $place['city'], $place['phone'], $place['website'], $place['hours'], $text, $advertiser, $email, $now, $now]);
				$id = (int) $pdo->lastInsertId();
				$pdo->exec('COMMIT');
				try {
					$co = stripe_checkout(['id' => $id, 'email' => $email, 'name' => $place['name']], $price, site_url());
					$pdo->prepare('UPDATE sponsors SET checkout_id = ? WHERE id = ?')->execute([$co['id'], $id]);
					header('Location: ' . $co['url'], true, 303);
					exit;
				} catch (Throwable $e) {
					error_log('[stella] Kasse: ' . $e->getMessage());
					$pdo->prepare("DELETE FROM sponsors WHERE id = ? AND status = 'pending'")->execute([$id]);
					$error = 'Die Kasse ist gerade nicht erreichbar. Bitte gleich noch einmal.';
				}
			}
		}
	} elseif ($manage && $action === 'text') {
		$text = plain((string) ($_POST['text'] ?? ''), 90);
		$pdo->prepare('UPDATE sponsors SET text = ?, updated_at = ? WHERE id = ?')->execute([$text, time(), $manage['id']]);
		header('Location: ' . site_url() . '/partner/verwalten/' . rawurlencode($token) . '?gespeichert=1', true, 303);
		exit;
	} elseif ($manage && $action === 'portal' && $manage['customer_id']) {
		try {
			header('Location: ' . stripe_portal((string) $manage['customer_id'], site_url() . '/partner/verwalten/' . rawurlencode($token)), true, 303);
			exit;
		} catch (Throwable $e) {
			error_log('[stella] Kundenbereich: ' . $e->getMessage());
			$error = 'Der Kundenbereich ist gerade nicht erreichbar. Bitte gleich noch einmal.';
		}
	}
}

// Kasse abgebrochen: Die Gegend wird sofort wieder frei.
if (isset($_GET['abgebrochen'])) {
	$pdo->prepare("DELETE FROM sponsors WHERE id = ? AND status = 'pending'")->execute([(int) $_GET['abgebrochen']]);
}

$thanks = null;
if (isset($_GET['danke'])) {
	$q = $pdo->prepare('SELECT * FROM sponsors WHERE checkout_id = ?');
	$q->execute([(string) $_GET['danke']]);
	$thanks = $q->fetch() ?: false;
}

$name = plain((string) ($_GET['name'] ?? ''), 80);
$where = plain((string) ($_GET['ort'] ?? ''), 60);
// Nach einem Fehler beim Buchen bleibt das Formular stehen.
$platz = (string) ($_GET['platz'] ?? '');
if ($platz === '' && ($_POST['action'] ?? '') === 'buchen') $platz = (string) ($_POST['ort'] ?? '');
$chosen = ($x && $platz !== '') ? service_by_id($x, $platz) : null;
$results = ($x && mb_strlen($name) >= 2 && $chosen === null) ? services_by_name($x, $name, $where) : [];

$live = $pdo->prepare('SELECT name, kind, city FROM sponsors WHERE ' . sponsor_live_sql() . ' ORDER BY city, name');
$live->execute([time() - PAID_GRACE]);
$live = $live->fetchAll();

function place_line(array $p): string
{
	return implode(' · ', array_filter([SERVICE_KINDS[$p['kind']] ?? '', $p['street'] ?? '', $p['city'] ?? '']));
}

function holder_note(PDO $pdo, array $p): array
{
	$h = tile_holder($pdo, sponsor_tile((float) $p['lat'], (float) $p['lon']));
	if ($h === null) return [true, 'Gegend frei'];
	if ($h['status'] === 'pending') return [false, 'Gegend wird gerade gebucht'];
	return [false, 'Gegend vergeben' . ($h['cancels_at'] ? ' bis ' . date('j.n.Y', (int) $h['cancels_at']) : '')];
}
?>
<!doctype html>
<html lang="de">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Partnerplatz · ThisDog</title>
<?php if ($manage !== null): ?><meta name="robots" content="noindex"><?php endif; ?>
<style>
	@font-face { font-family: Bri; src: url(/fonts/bricolage-grotesque-latin.woff2) format("woff2"); font-weight: 200 800; }
	:root { --bg: #F6F6F8; --surface: #FFFFFF; --ink: #241E2B; --ink2: #69627A; --accent: #EE6A24; --soft: #FDEBDF; --line: #E8E6EE; --bad: #B3261E; }
	@media (prefers-color-scheme: dark) { :root { --bg: #16141A; --surface: #211E26; --ink: #F1EEF4; --ink2: #B3ACBF; --accent: #FF8746; --soft: #3A2A20; --line: #302B37; --bad: #FF8A80; } }
	* { box-sizing: border-box; margin: 0; }
	body { background: var(--bg); color: var(--ink); font: 17px/1.5 -apple-system, system-ui, sans-serif; padding: 32px 16px 64px; }
	main { max-width: 36rem; margin: 0 auto; }
	h1 { font-family: Bri, system-ui; font-weight: 700; font-size: 2.3rem; line-height: 1.05; letter-spacing: -0.02em; margin: 20px 0 12px; }
	h2 { font-family: Bri, system-ui; font-weight: 650; font-size: 1.35rem; margin: 32px 0 10px; }
	p, li { color: var(--ink2); }
	p { margin-bottom: 12px; }
	ul.plain { list-style: none; padding: 0; }
	.mark { color: var(--accent); width: 56px; }
	.mark svg { width: 100%; height: auto; display: block; }
	.card { background: var(--surface); border: 1px solid var(--line); border-radius: 18px; padding: 16px 18px; margin: 10px 0; }
	.row { display: flex; justify-content: space-between; gap: 12px; align-items: center; }
	.row b { color: var(--ink); }
	.small { font-size: 14px; color: var(--ink2); }
	.free { color: var(--accent); font-weight: 600; font-size: 14px; white-space: nowrap; }
	.taken { color: var(--ink2); font-size: 14px; white-space: nowrap; }
	.ad { display: inline-block; font-size: 13px; font-weight: 600; color: var(--ink2); border: 1px solid var(--line); border-radius: 6px; padding: 0 6px; }
	label { display: block; font-weight: 600; margin: 14px 0 4px; }
	input[type=text], input[type=email] { width: 100%; font: inherit; padding: 12px 14px; border-radius: 12px; border: 1px solid var(--line); background: var(--surface); color: var(--ink); }
	.check { display: flex; gap: 10px; align-items: flex-start; font-weight: 400; color: var(--ink2); }
	.check input { margin-top: 5px; }
	button, .button { display: inline-block; font: inherit; font-weight: 600; border: 0; cursor: pointer; background: var(--accent); color: #fff; text-decoration: none; padding: 13px 22px; border-radius: 999px; margin-top: 16px; }
	button.quiet { background: var(--soft); color: var(--ink); }
	button:disabled { opacity: .45; cursor: not-allowed; }
	.error { color: var(--bad); font-weight: 600; }
	.search { display: grid; grid-template-columns: 1fr 1fr auto; gap: 8px; align-items: end; }
	.search button { margin-top: 0; }
	@media (max-width: 520px) { .search { grid-template-columns: 1fr; } }
	a { color: var(--accent); }
	table { width: 100%; border-collapse: collapse; font-size: 15px; }
	td, th { text-align: left; padding: 6px 4px; border-bottom: 1px solid var(--line); }
	td.n, th.n { text-align: right; font-variant-numeric: tabular-nums; }
</style>
</head>
<body>
<main>
	<div class="mark" aria-hidden="true"><?= @file_get_contents(__DIR__ . '/icons/v2/stella-mark.svg') ?: '' ?></div>

<?php if ($manage === false): ?>
	<h1>Dieser Link gilt nicht.</h1>
	<p>Schau in der Mail nach, die du nach der Buchung bekommen hast, oder schreib uns über <a href="/support">den Support</a>.</p>

<?php elseif ($manage): ?>
	<?php
	$st = $pdo->prepare('SELECT COALESCE(SUM(views), 0) v, COALESCE(SUM(taps), 0) t FROM sponsor_stats WHERE sponsor_id = ? AND day >= ?');
	$st->execute([$manage['id'], date('Y-m-d', time() - 30 * 86400)]);
	$sum = $st->fetch();
	$days = $pdo->prepare('SELECT day, views, taps FROM sponsor_stats WHERE sponsor_id = ? ORDER BY day DESC LIMIT 14');
	$days->execute([$manage['id']]);
	$runs = $manage['status'] === 'active' && (int) $manage['paid_until'] > time() - PAID_GRACE;
	?>
	<h1><?= h($manage['name']) ?></h1>
	<p><?= h(place_line($manage)) ?></p>
	<div class="card">
		<div class="row"><b><?= $runs ? 'Läuft' : ($manage['status'] === 'blocked' ? 'Gesperrt' : ($manage['status'] === 'pending' ? 'Wartet auf die Zahlung' : 'Beendet')) ?></b>
			<span class="small"><?php if ($runs && $manage['cancels_at']): ?>gekündigt zum <?= date('j.n.Y', (int) $manage['cancels_at']) ?><?php elseif ($runs): ?>verlängert sich am <?= date('j.n.Y', (int) $manage['paid_until']) ?><?php endif; ?></span></div>
		<?php if ($manage['status'] === 'blocked'): ?><p class="small" style="margin-top:8px">Wir haben den Platz gesperrt und das Abo beendet. Fragen beantworten wir über <a href="/support">den Support</a>.</p><?php endif; ?>
	</div>
	<h2>Letzte 30 Tage</h2>
	<div class="card">
		<div class="row"><span>Gezeigt</span><b><?= (int) $sum['v'] ?></b></div>
		<div class="row"><span>Geöffnet</span><b><?= (int) $sum['t'] ?></b></div>
		<p class="small" style="margin:8px 0 0">Gezeigt zählt höchstens einmal je Stunde und Anschluss, geöffnet höchstens dreimal. Wer etwas sieht oder öffnet, erfahren wir nicht – und du auch nicht.</p>
	</div>
	<?php $rows = $days->fetchAll(); if ($rows): ?>
	<table><tr><th>Tag</th><th class="n">Gezeigt</th><th class="n">Geöffnet</th></tr>
	<?php foreach ($rows as $d): ?><tr><td><?= h(date('j.n.', strtotime($d['day']))) ?></td><td class="n"><?= (int) $d['views'] ?></td><td class="n"><?= (int) $d['taps'] ?></td></tr><?php endforeach; ?>
	</table>
	<?php endif; ?>
	<h2>Text</h2>
	<?php if (isset($_GET['gespeichert'])): ?><p>Gespeichert. Die App zeigt ihn beim nächsten Laden.</p><?php endif; ?>
	<form method="post">
		<input type="hidden" name="action" value="text">
		<label for="text">Ein Satz unter dem Namen (höchstens 90 Zeichen)</label>
		<input type="text" id="text" name="text" maxlength="90" value="<?= h($manage['text']) ?>">
		<button class="quiet">Speichern</button>
	</form>
	<?php if ($manage['customer_id']): ?>
	<h2>Rechnungen und Kündigung</h2>
	<p>Bei Stripe, unserem Zahlungsdienst: Rechnungen herunterladen, Zahlart ändern, zum Monatsende kündigen.</p>
	<form method="post"><input type="hidden" name="action" value="portal"><button class="quiet">Zum Kundenbereich</button></form>
	<?php endif; ?>
	<?php if ($error): ?><p class="error"><?= h($error) ?></p><?php endif; ?>

<?php elseif ($thanks !== null): ?>
	<?php if ($thanks): ?>
	<h1>Danke!</h1>
	<p>„<?= h($thanks['name']) ?>“ steht <?= $thanks['status'] === 'active' ? 'ab sofort' : 'in wenigen Minuten, sobald die Zahlung bestätigt ist,' ?> oben in den Adressen der ThisDog-App – gekennzeichnet als Anzeige.</p>
	<p>Den Link zur Verwaltung mit den Zahlen, deinem Text und den Rechnungen schicken wir an <?= h($thanks['email']) ?>.</p>
	<?php else: ?>
	<h1>Fast geschafft.</h1>
	<p>Die Zahlung ist bei uns noch nicht angekommen. Sobald sie bestätigt ist, bekommst du eine Mail mit dem Verwaltungslink.</p>
	<?php endif; ?>

<?php elseif ($chosen): ?>
	<?php [$free, $note] = holder_note($pdo, $chosen); ?>
	<h1>Partnerplatz für <?= h($chosen['name']) ?></h1>
	<p>Gegend rund um <?= h($chosen['street'] ?: $chosen['city'] ?: $chosen['name']) ?>, etwa 3 × 3 km. Wer dort in ThisDog unter „Adressen“ schaut, sieht deinen Betrieb ganz oben.</p>
	<div class="card">
		<div class="row"><b><?= h($chosen['name']) ?></b><span class="ad">Anzeige</span></div>
		<div class="small"><?= h(place_line($chosen)) ?></div>
		<div class="small" id="vorschau" style="color:var(--ink)"></div>
	</div>
	<?php if (!$free): ?>
	<p class="error"><?= h($note) ?>. Je Gegend gibt es nur einen Platz.</p>
	<p><a href="/partner">Anderen Betrieb suchen</a></p>
	<?php else: ?>
	<form method="post">
		<input type="hidden" name="action" value="buchen">
		<input type="hidden" name="ort" value="<?= h($chosen['id']) ?>">
		<label for="text">Ein Satz unter dem Namen (freiwillig, höchstens 90 Zeichen)</label>
		<input type="text" id="text" name="text" maxlength="90" placeholder="z. B. Erste Pflege für Welpen gratis" oninput="document.getElementById('vorschau').textContent=this.value">
		<label for="auftraggeber">Auftraggeber (Firma, wie auf der Rechnung)</label>
		<input type="text" id="auftraggeber" name="auftraggeber" maxlength="120" required>
		<label for="email">E-Mail für Rechnung und Verwaltungslink</label>
		<input type="email" id="email" name="email" required>
		<label class="check"><input type="checkbox" name="bedingungen" value="1" required> <span>Ich buche als Unternehmen und stimme den <a href="/werbebedingungen" target="_blank">Werbebedingungen</a> zu.</span></label>
		<p class="small" style="margin-top:12px"><?= h(euro($price)) ?> im Monat, monatlich kündbar. Den Endbetrag und die Zahlarten zeigt die Kasse von Stripe.</p>
		<button<?= $ready ? '' : ' disabled' ?>>Weiter zur Kasse</button>
		<?php if (!$ready): ?><p class="small">Die Buchung ist in Kürze möglich. Bis dahin: <a href="/support">schreib uns</a>.</p><?php endif; ?>
	</form>
	<?php endif; ?>
	<?php if ($error): ?><p class="error"><?= h($error) ?></p><?php endif; ?>

<?php else: ?>
	<h1>Ganz oben, wenn jemand in deiner Gegend sucht.</h1>
	<p>ThisDog zeigt Hundemenschen Tierärzte, Hundefriseure, Tierbedarf, Hundeschulen, Tierheime, Pensionen und hundefreundliche Lokale in der Nähe. Je Gegend – rund 3 × 3 km – gibt es <b>einen</b> Partnerplatz ganz oben in der Liste und auf der Karte.</p>
	<ul>
		<li>Immer als <span class="ad">Anzeige</span> gekennzeichnet. Die übrige Liste bleibt nach Entfernung sortiert; Bewertungen und Daten sind nicht käuflich.</li>
		<li><?= h(euro($price)) ?> im Monat, jederzeit zum Monatsende kündbar.</li>
		<li>Du siehst, wie oft dein Platz gezeigt und geöffnet wurde – als Summe, ohne Daten über einzelne Menschen.</li>
	</ul>
	<?php if (isset($_GET['abgebrochen'])): ?><p>Die Buchung ist abgebrochen, es wurde nichts berechnet.</p><?php endif; ?>
	<h2>Deinen Betrieb finden</h2>
	<form method="get" class="search">
		<div><label for="name">Name</label><input type="text" id="name" name="name" value="<?= h($name) ?>" required minlength="2"></div>
		<div><label for="ort">PLZ oder Ort (freiwillig)</label><input type="text" id="ort" name="ort" value="<?= h($where) ?>"></div>
		<button>Suchen</button>
	</form>
	<?php if ($x === null): ?><p class="error">Die Adressen werden gerade aufgebaut. Bitte später noch einmal.</p><?php endif; ?>
	<?php if ($name !== '' && !$results && $x): ?>
	<p>Nichts gefunden. Die Adressen stammen aus OpenStreetMap: Ist dein Betrieb dort noch nicht eingetragen, kannst du das auf <a href="https://www.openstreetmap.org" rel="noopener">openstreetmap.org</a> selbst tun – nach dem nächsten monatlichen Abgleich findest du ihn hier. Oder <a href="/support">schreib uns</a>.</p>
	<?php endif; ?>
	<?php foreach ($results as $r): [$free, $note] = holder_note($pdo, $r); ?>
	<a class="card row" style="text-decoration:none" href="/partner?platz=<?= rawurlencode($r['id']) ?>">
		<span><b><?= h($r['name']) ?></b><br><span class="small"><?= h(place_line($r)) ?></span></span>
		<span class="<?= $free ? 'free' : 'taken' ?>"><?= h($note) ?></span>
	</a>
	<?php endforeach; ?>
	<?php if ($live): ?>
	<h2>Aktuelle Partner</h2>
	<p class="small">Wer gerade einen Platz hat – damit niemand rätseln muss, was in ThisDog bezahlt ist.</p>
	<ul class="plain"><?php foreach ($live as $l): ?><li><?= h($l['name']) ?> <span class="small">· <?= h(SERVICE_KINDS[$l['kind']] ?? '') ?><?= $l['city'] ? ' · ' . h($l['city']) : '' ?></span></li><?php endforeach; ?></ul>
	<?php endif; ?>
	<?php if ($error): ?><p class="error"><?= h($error) ?></p><?php endif; ?>
<?php endif; ?>
	<p class="small" style="margin-top:40px"><a href="/werbebedingungen">Werbebedingungen</a> · <a href="/datenschutz">Datenschutz</a> · <a href="/impressum">Impressum</a></p>
</main>
</body>
</html>
