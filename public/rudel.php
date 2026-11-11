<?php
declare(strict_types=1);

/**
 * Die Seite hinter einem Einladungslink (thisdog.app/rudel/<Geheimnis>).
 *
 * Ist ThisDog installiert, öffnet iOS den Link in der App, und diese Seite
 * erscheint gar nicht. Sonst sagt sie, was zu tun ist. Sie verrät nichts über
 * das Rudel – kein Hundename, keine Mitglieder: Wer den Link nur abgefangen
 * hat, soll nicht erfahren, wessen Hund dahintersteht.
 */
header('Content-Type: text/html; charset=utf-8');
header('Cache-Control: no-store');
header('Referrer-Policy: no-referrer');
$secret = preg_match('/^[A-Za-z0-9_-]{20,64}$/', (string) ($_GET['t'] ?? '')) ? (string) $_GET['t'] : '';
?>
<!doctype html>
<html lang="de">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<meta name="robots" content="noindex">
<title>Einladung ins Rudel · ThisDog</title>
<style>
	@font-face { font-family: Bri; src: url(/fonts/bricolage-grotesque-latin.woff2) format("woff2"); font-weight: 200 800; }
	:root { --bg: #F6F6F8; --ink: #241E2B; --ink2: #69627A; --accent: #EE6A24; --line: #E8E6EE; }
	@media (prefers-color-scheme: dark) { :root { --bg: #16141A; --ink: #F1EEF4; --ink2: #B3ACBF; --accent: #FF8746; --line: #302B37; } }
	* { box-sizing: border-box; margin: 0; }
	body { background: var(--bg); color: var(--ink); font: 17px/1.5 -apple-system, system-ui, sans-serif; min-height: 100svh; display: grid; place-items: center; padding: 24px 16px; }
	main { max-width: 30rem; }
	h1 { font-family: Bri, system-ui; font-weight: 700; font-size: 2.4rem; line-height: 1.05; letter-spacing: -0.02em; margin: 28px 0 12px; }
	p { color: var(--ink2); margin-bottom: 14px; }
	ol { padding-left: 1.2em; color: var(--ink); }
	li { margin: 6px 0; }
	.mark { color: var(--accent); width: 72px; }
	.mark svg { width: 100%; height: auto; display: block; }
	.bad { color: var(--ink2); }
	.open { display: inline-block; background: var(--accent); color: #fff; font-weight: 600; text-decoration: none; padding: 14px 22px; border-radius: 999px; margin: 6px 0 18px; }
</style>
</head>
<body>
<main>
	<div class="mark" aria-hidden="true"><?= @file_get_contents(__DIR__ . '/icons/v2/stella-mark.svg') ?: '' ?></div>
<?php if ($secret === ''): ?>
	<h1>Dieser Link ist unvollständig.</h1>
	<p class="bad">Bitte das Rudelmitglied, das dich eingeladen hat, um einen neuen Link.</p>
<?php else: ?>
	<h1>Du bist ins Rudel eingeladen.</h1>
	<p>Im Rudel teilt ihr euch Kalender, Termine und Gesundheitsdaten eines Hundes. Was einer einträgt, haben alle.</p>
	<ol>
		<li>Installiere ThisDog auf deinem iPhone, iPad oder Android-Telefon.</li>
		<li>Öffne diesen Link noch einmal auf dem Gerät. Er führt direkt in die App.</li>
	</ol>
	<?php // Android öffnet den Link nicht immer selbst in der App (etwa bei Testfassungen): Dieser Knopf tut es. ?>
	<?php if (stripos((string) ($_SERVER['HTTP_USER_AGENT'] ?? ''), 'Android') !== false): ?>
	<p><a class="open" id="open" href="intent://thisdog.app/rudel/<?= htmlspecialchars($secret) ?>#Intent;scheme=https;package=app.thisdog;end">In ThisDog öffnen</a></p>
	<script>
		// Der Rudel-Schlüssel steht hinter dem „#“ und erreicht den Server nie. Ein intent://-Link
		// kann kein „#“ weitergeben, deshalb reist er hier als Zusatz „k“ mit.
		(function () {
			var k = new URLSearchParams(location.hash.slice(1)).get('k');
			if (k && /^[A-Za-z0-9_-]{20,64}$/.test(k)) {
				var a = document.getElementById('open');
				a.href = a.href.replace(';end', ';S.k=' + k + ';end');
			}
		})();
	</script>
	<?php endif; ?>
	<p>Der Link gilt sieben Tage und für alle, denen er geschickt wurde.</p>
<?php endif; ?>
</main>
</body>
</html>
