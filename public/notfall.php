<?php
declare(strict_types=1);

/**
 * Der Notfallpass hinter dem QR-Code (thisdog.app/notfall/<Schlüssel>).
 *
 * Wer einen Hund gefunden hat, scannt den Code am Halsband und sieht ohne App
 * und ohne Anmeldung, wen er anrufen soll. Die Seite zeigt nur, was die Halter
 * in der App freigegeben haben. Sie wird nicht von Suchmaschinen erfasst.
 */
require_once __DIR__ . '/api/lib.php';
require_once __DIR__ . '/api/lib-db.php';
require_once __DIR__ . '/api/lib-emergency.php';

header('Content-Type: text/html; charset=utf-8');
header('Cache-Control: no-store');
header('Referrer-Policy: no-referrer');
header('X-Robots-Tag: noindex, nofollow');

$row = null;
try {
	$pdo = db();
	$row = emergency_by_token($pdo, (string) ($_GET['t'] ?? ''));
	// Vorschauen von Messengern und Suchmaschinen zählen nicht als „geöffnet“.
	$ua = (string) ($_SERVER['HTTP_USER_AGENT'] ?? '');
	if ($row !== null && !preg_match('/bot|crawl|spider|preview|facebookexternalhit|whatsapp|telegram|slack|discord|skype/i', $ua)) {
		emergency_viewed($pdo, $row);
	}
} catch (Throwable $e) {
	error_log('[stella] notfall: ' . $e->getMessage());
}
if ($row === null) http_response_code(404);

$c = $row ? (json_decode((string) $row['payload'], true) ?: []) : [];
$h = fn(string $k): string => htmlspecialchars((string) ($c[$k] ?? ''), ENT_QUOTES, 'UTF-8');
$tel = fn(string $k): string => preg_replace('/[^0-9+]/', '', (string) ($c[$k] ?? ''));
$facts = implode(', ', array_filter([$c['breed'] ?? '', $c['sex'] ?? '', $c['age'] ?? ''], fn($v) => $v !== ''));
$photo = $row && !empty($row['photo']) ? 'data:image/jpeg;base64,' . $row['photo'] : null;
$updated = $row ? date('j.n.Y', (int) $row['updated_at']) : '';
// Entlaufen: Die Seite wird zum Steckbrief.
$lost = ($c['lostSince'] ?? '') !== '';
$lostWhen = '';
if ($lost) {
	try {
		$d = new DateTimeImmutable((string) $c['lostSince'], new DateTimeZone('Europe/Berlin'));
		$tage = ['So.', 'Mo.', 'Di.', 'Mi.', 'Do.', 'Fr.', 'Sa.'];
		$lostWhen = $tage[(int) $d->format('w')] . ' ' . $d->format('j.n.') . (str_contains((string) $c['lostSince'], 'T') ? ', ' . $d->format('H:i') . ' Uhr' : '');
	} catch (Throwable $e) {
		$lostWhen = '';
	}
}
?>
<!doctype html>
<html lang="de">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover">
<meta name="robots" content="noindex, nofollow">
<meta name="theme-color" content="#F6F6F8" media="(prefers-color-scheme: light)">
<meta name="theme-color" content="#16141A" media="(prefers-color-scheme: dark)">
<title><?= $row ? ($lost ? $h('name') . ' wird vermisst' : 'Notfallpass von ' . $h('name')) : 'Notfallpass' ?></title>
<?php if ($row && $lost): ?>
<meta property="og:title" content="<?= $h('name') ?> wird vermisst">
<meta property="og:description" content="<?= htmlspecialchars(trim(($lostWhen !== '' ? 'Seit ' . $lostWhen . '. ' : '') . (($c['lostWhere'] ?? '') !== '' ? 'Zuletzt gesehen: ' . $c['lostWhere'] . '. ' : '') . 'Bitte melde dich, wenn du ' . ($c['name'] ?? '') . ' siehst.'), ENT_QUOTES, 'UTF-8') ?>">
<?php endif; ?>
<style>
	@font-face { font-family: Bri; src: url(/fonts/bricolage-grotesque-latin.woff2) format("woff2"); font-weight: 200 800; font-display: swap; }
	:root {
		--bg: #F6F6F8; --surface: #FFFFFF; --ink: #241E2B; --ink2: #69627A; --ink3: #A29CAF; --line: #E8E6EE;
		--accent: #EE6A24; --soft: #FDEADF; --alarm: #D33A2C; --alarm-soft: #FBE7E4;
	}
	@media (prefers-color-scheme: dark) {
		:root { --bg: #16141A; --surface: #211E26; --ink: #F1EEF4; --ink2: #B3ACBF; --ink3: #7F788B; --line: #302B37;
			--accent: #FF8746; --soft: #3A2519; --alarm: #FF6B5C; --alarm-soft: #3B1D1A; }
	}
	* { box-sizing: border-box; margin: 0; padding: 0; }
	body { background: var(--bg); color: var(--ink); font: 17px/1.45 -apple-system, BlinkMacSystemFont, system-ui, sans-serif;
		-webkit-text-size-adjust: 100%; padding: max(20px, env(safe-area-inset-top)) 16px max(32px, env(safe-area-inset-bottom)); }
	main { max-width: 28rem; margin: 0 auto; }
	.tag { display: inline-flex; align-items: center; gap: 8px; font-weight: 600; font-size: 15px; color: var(--alarm); }
	.tag b { font-size: 22px; line-height: 1; }
	header { display: flex; align-items: center; gap: 18px; margin: 22px 0 8px; }
	header img { width: 96px; height: 96px; border-radius: 50%; object-fit: cover; flex: none; background: var(--soft); }
	h1 { font-family: Bri, system-ui, sans-serif; font-weight: 700; font-size: clamp(34px, 9vw, 44px); line-height: 1.02; letter-spacing: -0.02em; }
	.facts { color: var(--ink2); font-size: 16px; margin-top: 4px; }
	.lead { color: var(--ink2); margin: 18px 0 20px; }
	.call { display: flex; align-items: center; justify-content: center; gap: 10px; min-height: 58px; border-radius: 29px;
		background: var(--accent); color: #fff; font-weight: 600; font-size: 19px; text-decoration: none; }
	.call:active { transform: scale(0.98); }
	.call small { font-weight: 400; opacity: .85; font-size: 16px; }
	section { background: var(--surface); border-radius: 22px; margin-top: 14px; padding: 4px 18px; }
	.row { padding: 14px 0; border-bottom: 1px solid var(--line); }
	.row:last-child { border-bottom: 0; }
	.label { font-size: 13px; font-weight: 600; color: var(--ink2); margin-bottom: 2px; }
	.value { font-size: 18px; font-weight: 600; overflow-wrap: anywhere; white-space: pre-line; }
	.chip { font-variant-numeric: tabular-nums; letter-spacing: .06em; }
	.row a { color: var(--accent); font-weight: 600; text-decoration: none; display: inline-block; margin-top: 4px; }
	.alarm { background: var(--alarm-soft); }
	.alarm .label { color: var(--alarm); }
	footer { color: var(--ink3); font-size: 13px; margin-top: 26px; line-height: 1.5; }
	.gone h1 { margin-top: 24px; font-size: 34px; }
	.missing { background: var(--alarm); color: #fff; border-radius: 22px; padding: 16px 18px; margin: 18px 0 4px; }
	.missing strong { display: block; font-family: Bri, system-ui, sans-serif; font-size: 26px; line-height: 1.1; }
	.missing p { margin-top: 6px; font-size: 16px; }
</style>
</head>
<body>
<main>
<?php if ($row === null): ?>
	<div class="gone">
		<span class="tag"><b aria-hidden="true">✱</b>Notfallpass</span>
		<h1>Dieser Notfallpass ist nicht aktiv.</h1>
		<p class="lead">Die Halter haben ihn gesperrt oder ersetzt. Wenn du einen Hund gefunden hast, hilft jede Tierarztpraxis oder das Tierheim: Sie können den Chip auslesen.</p>
	</div>
<?php else: ?>
	<span class="tag"><b aria-hidden="true">✱</b><?= $lost ? 'Vermisst' : 'Notfallpass' ?></span>
	<?php if ($lost): ?>
	<div class="missing" role="alert">
		<strong><?= $h('name') ?> wird vermisst<?= $lostWhen !== '' ? ' seit ' . htmlspecialchars($lostWhen, ENT_QUOTES, 'UTF-8') : '' ?>.</strong>
		<?php if (($c['lostWhere'] ?? '') !== ''): ?><p>Zuletzt gesehen: <?= $h('lostWhere') ?></p><?php endif; ?>
		<p>Siehst du mich? Bitte ruf sofort an. Nicht hinterherrennen – ängstliche Hunde laufen sonst weiter weg.</p>
	</div>
	<?php endif; ?>
	<header>
		<?php if ($photo): ?><img src="<?= $photo ?>" alt="Foto von <?= $h('name') ?>"><?php endif; ?>
		<div>
			<h1>Ich heiße <?= $h('name') ?>.</h1>
			<?php if ($facts !== ''): ?><p class="facts"><?= htmlspecialchars($facts, ENT_QUOTES, 'UTF-8') ?></p><?php endif; ?>
		</div>
	</header>
	<p class="lead">Danke, dass du mir hilfst. Bitte ruf meine Menschen an, sie holen mich ab.</p>

	<?php if ($tel('ownerPhone') !== ''): ?>
		<a class="call" href="tel:<?= $tel('ownerPhone') ?>"><?= $h('ownerName') !== '' ? $h('ownerName') . ' anrufen' : 'Anrufen' ?> <small><?= $h('ownerPhone') ?></small></a>
	<?php endif; ?>

	<?php if (($c['important'] ?? '') !== '' || ($c['meds'] ?? '') !== '' || ($lost && ($c['lostNote'] ?? '') !== '')): ?>
	<section class="alarm">
		<?php if ($lost && ($c['lostNote'] ?? '') !== ''): ?><div class="row"><div class="label">Wichtig beim Finden</div><div class="value"><?= $h('lostNote') ?></div></div><?php endif; ?>
		<?php if (($c['important'] ?? '') !== ''): ?><div class="row"><div class="label">Wichtig</div><div class="value"><?= $h('important') ?></div></div><?php endif; ?>
		<?php if (($c['meds'] ?? '') !== ''): ?><div class="row"><div class="label">Medikamente</div><div class="value"><?= $h('meds') ?></div></div><?php endif; ?>
	</section>
	<?php endif; ?>

	<section>
		<?php if (($c['chip'] ?? '') !== ''): ?><div class="row"><div class="label">Chipnummer</div><div class="value chip"><?= $h('chip') ?></div></div><?php endif; ?>
		<?php if (($c['vetName'] ?? '') !== '' || $tel('vetPhone') !== ''): ?>
			<div class="row"><div class="label">Tierarzt</div><div class="value"><?= $h('vetName') ?></div>
			<?php if ($tel('vetPhone') !== ''): ?><a href="tel:<?= $tel('vetPhone') ?>"><?= $h('vetPhone') ?> anrufen</a><?php endif; ?></div>
		<?php endif; ?>
		<?php if (($c['note'] ?? '') !== ''): ?><div class="row"><div class="label">Hinweis</div><div class="value"><?= $h('note') ?></div></div><?php endif; ?>
	</section>

	<footer>Notfallpass aus der App ThisDog, zuletzt aktualisiert am <?= $updated ?>.</footer>
<?php endif; ?>
</main>
</body>
</html>
