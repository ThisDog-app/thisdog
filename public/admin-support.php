<?php
declare(strict_types=1);

/**
 * Anfragen an den Support: aus der App und von thisdog.app/support.
 *
 * Antworten geht per E-Mail – die Benachrichtigung hat die Adresse des Absenders als Antwortadresse, und hier
 * führt jede Anfrage dorthin. Die Seite hält nur Status und eine Notiz fest.
 */

require_once __DIR__ . '/api/lib-admin.php';
require_once __DIR__ . '/api/lib-support.php';

$pdo = db();
$email = admin_or_404($pdo);

if (($_GET['action'] ?? '') !== '') {
	header('Cache-Control: no-store, private');
	$host = (string) ($_SERVER['HTTP_HOST'] ?? '');
	$origin = (string) ($_SERVER['HTTP_ORIGIN'] ?? '');
	if (($_SERVER['REQUEST_METHOD'] ?? '') !== 'POST' || ($origin !== 'https://' . $host && $origin !== 'http://' . $host)) respond(['error' => 'forbidden'], 403);
	$body = json_decode((string) file_get_contents('php://input'), true) ?: [];
	$id = (int) ($body['id'] ?? 0);
	switch ($_GET['action']) {
		case 'status':
			$st = (string) ($body['status'] ?? '');
			if (!in_array($st, ['neu', 'in_arbeit', 'erledigt'], true)) respond(['error' => 'invalid'], 422);
			$pdo->prepare('UPDATE support_requests SET status = ?, done_at = ? WHERE id = ?')->execute([$st, $st === 'erledigt' ? time() : null, $id]);
			respond(['ok' => true]);
		case 'note':
			$pdo->prepare('UPDATE support_requests SET note = ? WHERE id = ?')->execute([mb_substr((string) ($body['note'] ?? ''), 0, 2000), $id]);
			respond(['ok' => true]);
	}
	respond(['error' => 'unknown_action'], 400);
}

header('Content-Type: text/html; charset=utf-8');
header('Cache-Control: no-store, private');
header('X-Robots-Tag: noindex, nofollow');
header('Referrer-Policy: no-referrer');

$filter = in_array($_GET['status'] ?? '', ['neu', 'in_arbeit', 'erledigt', 'alle'], true) ? $_GET['status'] : 'offen';
$where = match ($filter) { 'offen' => "status != 'erledigt'", 'alle' => '1', default => 'status = ' . $pdo->quote($filter) };
$list = $pdo->query("SELECT * FROM support_requests WHERE $where ORDER BY created_at DESC LIMIT 200")->fetchAll();
$counts = [];
foreach ($pdo->query('SELECT status, COUNT(*) AS n FROM support_requests GROUP BY status') as $r) $counts[$r['status']] = (int) $r['n'];
$statusName = ['neu' => 'Neu', 'in_arbeit' => 'In Arbeit', 'erledigt' => 'Erledigt'];
$h = fn($t) => htmlspecialchars((string) $t);
?>
<!doctype html>
<html lang="de">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<meta name="robots" content="noindex, nofollow">
<title>Anfragen – ThisDog</title>
<style>
	:root { --paper: #f6f6f8; --surface: #fff; --ink: #241e2b; --ink-2: #5d5566; --ink-3: #a29caf; --line: #e8e6ee; --accent: #ee6a24; --soft: #fdeadf; }
	@media (prefers-color-scheme: dark) { :root { --paper: #141217; --surface: #1d1a21; --ink: #f2eff5; --ink-2: #b9b2c2; --ink-3: #7f788b; --line: #302b37; --accent: #ff8746; --soft: #3a2519; } }
	* { box-sizing: border-box; }
	body { margin: 0; padding: 24px 16px 64px; background: var(--paper); color: var(--ink); font: 16px/1.5 ui-sans-serif, system-ui, -apple-system, sans-serif; }
	.wrap { max-width: 980px; margin: 0 auto; }
	header { display: flex; flex-wrap: wrap; gap: 8px 16px; align-items: baseline; margin-bottom: 16px; }
	h1 { font-size: 22px; margin: 0; }
	header a { color: var(--accent); text-decoration: none; font-size: 14px; } header .wer { color: var(--ink-3); font-size: 14px; } header .rechts { margin-left: auto; display: flex; gap: 14px; }
	.filter { display: flex; gap: 8px; flex-wrap: wrap; margin-bottom: 16px; }
	.filter a { padding: 6px 14px; border-radius: 99px; background: var(--surface); border: 1px solid var(--line); color: var(--ink-2); text-decoration: none; font-size: 14px; }
	.filter a.an { background: var(--soft); border-color: transparent; color: var(--accent); font-weight: 600; }
	.anfrage { background: var(--surface); border: 1px solid var(--line); border-radius: 16px; padding: 16px 18px; margin-bottom: 12px; }
	.kopf { display: flex; flex-wrap: wrap; gap: 6px 14px; align-items: baseline; }
	.kopf b { font-size: 16px; } .kopf span { color: var(--ink-3); font-size: 13.5px; }
	.text { white-space: pre-wrap; margin: 10px 0; }
	.geraet { color: var(--ink-2); font-size: 13.5px; }
	.zeile { display: flex; gap: 10px; flex-wrap: wrap; align-items: center; margin-top: 10px; }
	select, textarea { font: inherit; font-size: 14px; color: var(--ink); background: var(--paper); border: 1px solid var(--line); border-radius: 10px; padding: 6px 10px; }
	textarea { width: 100%; min-height: 44px; margin-top: 8px; }
	a.antwort { background: var(--accent); color: #fff; padding: 6px 14px; border-radius: 99px; text-decoration: none; font-weight: 600; font-size: 14px; }
	.leer { color: var(--ink-3); }
</style>
</head>
<body>
<div class="wrap">
<header><h1>Anfragen</h1><span class="wer"><?= $h($email) ?></span><span class="rechts"><a href="/admin-orte.php">Orte</a><a href="/admin.php">Übersicht</a></span></header>
<nav class="filter">
	<?php foreach (['offen' => 'Offen (' . (($counts['neu'] ?? 0) + ($counts['in_arbeit'] ?? 0)) . ')', 'neu' => 'Neu (' . ($counts['neu'] ?? 0) . ')', 'in_arbeit' => 'In Arbeit (' . ($counts['in_arbeit'] ?? 0) . ')', 'erledigt' => 'Erledigt (' . ($counts['erledigt'] ?? 0) . ')', 'alle' => 'Alle'] as $k => $t): ?>
		<a href="?status=<?= $k ?>" class="<?= $filter === $k ? 'an' : '' ?>"><?= $h($t) ?></a>
	<?php endforeach; ?>
</nav>
<?php if (!$list): ?><p class="leer">Keine Anfragen.</p><?php endif; ?>
<?php foreach ($list as $r): $subject = rawurlencode('Re: [' . $r['number'] . '] Deine Anfrage bei ThisDog'); ?>
<article class="anfrage" data-id="<?= (int) $r['id'] ?>">
	<div class="kopf"><b><?= $h($r['number']) ?> · <?= $h(REQUEST_KINDS[$r['kind']] ?? $r['kind']) ?></b>
		<span><?= $h($r['email']) ?></span><span><?= date('j.n.Y, H:i', (int) $r['created_at']) ?></span><span><?= $r['via'] === 'app' ? 'aus der App' : 'über thisdog.app/support' ?></span></div>
	<div class="text"><?= $h($r['text']) ?></div>
	<div class="geraet"><?= $r['device'] !== '' ? $h($r['device']) . ' · ' . $h($r['device_code']) : 'Ohne Gerätecode' ?></div>
	<div class="zeile">
		<a class="antwort" href="mailto:<?= $h($r['email']) ?>?subject=<?= $subject ?>">Antworten</a>
		<select aria-label="Status"><?php foreach ($statusName as $k => $t): ?><option value="<?= $k ?>"<?= $r['status'] === $k ? ' selected' : '' ?>><?= $t ?></option><?php endforeach; ?></select>
	</div>
	<textarea placeholder="Notiz (nur hier sichtbar)" aria-label="Notiz"><?= $h($r['note']) ?></textarea>
</article>
<?php endforeach; ?>
</div>
<script>
async function post(action, body) {
	const r = await fetch('?action=' + action, { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(body) });
	if (!r.ok) throw new Error(r.status);
}
for (const a of document.querySelectorAll('.anfrage')) {
	const id = +a.dataset.id;
	a.querySelector('select').onchange = e => post('status', { id, status: e.target.value });
	a.querySelector('textarea').onchange = e => post('note', { id, note: e.target.value });
}
</script>
</body>
</html>
