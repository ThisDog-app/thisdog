<?php
declare(strict_types=1);

/**
 * Eigene Ziele für die Gassirunde pflegen.
 *
 *   /admin-orte.php   → Karte: Orte aus dem OpenStreetMap-Auszug und eigene; antippen zum Anlegen
 *
 * Eigene Orte stehen in app.sqlite (own_places) und überstehen jeden monatlichen Import. Ein Ort aus
 * dem Auszug lässt sich ausblenden (falsch eingetragen, Hunde nicht erwünscht) – das ist ein eigener
 * Eintrag ohne Namen, der ihn ersetzt.
 */

require_once __DIR__ . '/api/lib-admin.php';
require_once __DIR__ . '/api/lib-places.php';

$pdo = db();
$email = admin_or_404($pdo);

/* ============================ Schnittstelle der Seite ============================ */

/** Abgelehnte Fotos: Datei und Eintrag weg. */
function drop_rejected(PDO $pdo): void
{
	foreach ($pdo->query("SELECT id, file FROM place_photos WHERE status = 'rejected'") as $r) @unlink(photo_dir() . '/' . basename($r['file']));
	$pdo->exec("DELETE FROM place_photos WHERE status = 'rejected'");
}

/** Was bisher über einen Ort gilt: Auszug (OSM, Wien), darüber die letzte freigegebene Prüfung. */
function current_facts(PDO $pdo, string $id): array
{
	$out = [];
	if (is_file(data_file('places.sqlite'))) {
		$x = new PDO('sqlite:' . data_file('places.sqlite'));
		try {
			$q = $x->prepare('SELECT key, value, source FROM place_facts WHERE place_id = ?');
			$q->execute([$id]);
			foreach ($q->fetchAll(PDO::FETCH_ASSOC) as $r) $out[$r['key']] = [(int) $r['value'], $r['source']];
		} catch (PDOException $e) {}
	}
	$q = $pdo->prepare("SELECT answers FROM place_checks WHERE place_id = ? AND status = 'ok' ORDER BY checked_at DESC LIMIT 1");
	$q->execute([$id]);
	foreach (json_decode((string) $q->fetchColumn(), true) ?: [] as $k => $v) $out[$k] = [(int) $v, 'thisdog'];
	return $out;
}

$action = (string) ($_GET['action'] ?? '');
if ($action !== '') {
	header('Cache-Control: no-store, private');
	if ($action === 'near') {
		$lat = (float) ($_GET['lat'] ?? 0); $lon = (float) ($_GET['lon'] ?? 0);
		$own = $pdo->query('SELECT * FROM own_places ORDER BY created_at DESC')->fetchAll();
		respond(['places' => extract_places($lat, $lon) ?? [], 'own' => $own]);
	}

	// Ändern nur von dieser Seite aus: Ein fremdes Formular bekäme die Sitzung sonst mitgeschickt.
	$host = (string) ($_SERVER['HTTP_HOST'] ?? '');
	$origin = (string) ($_SERVER['HTTP_ORIGIN'] ?? '');
	if (($_SERVER['REQUEST_METHOD'] ?? '') !== 'POST' || ($origin !== 'https://' . $host && $origin !== 'http://' . $host)) {
		respond(['error' => 'forbidden'], 403);
	}
	$body = json_decode((string) file_get_contents('php://input'), true) ?: [];
	$account = (int) (current_session($pdo)['account_id'] ?? 0) ?: null;

	switch ($action) {
		case 'add':
			$kind = (string) ($body['kind'] ?? '');
			$name = trim((string) ($body['name'] ?? ''));
			$lat = (float) ($body['lat'] ?? 0); $lon = (float) ($body['lon'] ?? 0);
			if (!in_array($kind, array_column(KINDS, 'key'), true) || $name === '' || abs($lat) > 90 || abs($lon) > 180 || ($lat == 0 && $lon == 0)) {
				respond(['error' => 'invalid'], 422);
			}
			$pdo->prepare('INSERT INTO own_places (name, kind, lat, lon, off_leash, fenced, replaces, note, created_by, created_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)')
				->execute([mb_substr($name, 0, 80), $kind, round($lat, 6), round($lon, 6), empty($body['offLeash']) ? 0 : 1, empty($body['fenced']) ? 0 : 1,
					($body['replaces'] ?? '') !== '' ? (string) $body['replaces'] : null, mb_substr(trim((string) ($body['note'] ?? '')), 0, 300), $account, time()]);
			respond(['ok' => true]);
		case 'hide':
			$id = (string) ($body['id'] ?? '');
			if (!preg_match('#^(node|way|relation)/\d+$#', $id)) respond(['error' => 'invalid'], 422);
			$pdo->prepare('INSERT INTO own_places (name, kind, lat, lon, replaces, note, created_by, created_at) VALUES (\'\', \'park\', ?, ?, ?, ?, ?, ?)')
				->execute([(float) ($body['lat'] ?? 0), (float) ($body['lon'] ?? 0), $id, mb_substr(trim((string) ($body['note'] ?? '')), 0, 300), $account, time()]);
			respond(['ok' => true]);
		case 'resolve':
			// Alle offenen Meldungen zu diesem Ort sind erledigt.
			$pdo->prepare('UPDATE place_reports SET resolved_at = ? WHERE place_id = ? AND resolved_at IS NULL')->execute([time(), (string) ($body['id'] ?? '')]);
			respond(['ok' => true]);
		case 'reviewed':
			$pdo->prepare('UPDATE own_places SET reviewed_at = ? WHERE id = ?')->execute([time(), (int) ($body['id'] ?? 0)]);
			respond(['ok' => true]);
		case 'photo_ok':
		case 'photo_no':
			// Gesehen bzw. gemeldet und für gut befunden: bleibt. Löschen: Datei und Eintrag weg.
			$st = $action === 'photo_ok' ? 'ok' : 'rejected';
			$pdo->prepare('UPDATE place_photos SET status = ?, reviewed_at = ?, reported_at = NULL WHERE id = ?')->execute([$st, time(), (int) ($body['id'] ?? 0)]);
			if ($st === 'rejected') drop_rejected($pdo);
			respond(['ok' => true]);
		case 'check_ok':
		case 'check_no':
			// Gesehen bzw. zurückziehen: Eine zurückgezogene Prüfung gilt nicht mehr, ihre Fotos verschwinden.
			$st = $action === 'check_ok' ? 'ok' : 'rejected';
			$cid = (int) ($body['id'] ?? 0);
			$pdo->prepare('UPDATE place_checks SET status = ?, reviewed_at = ? WHERE id = ?')->execute([$st, time(), $cid]);
			// Die Fotos einer Prüfung gehen mit ihr.
			if ($st === 'rejected') $pdo->prepare("UPDATE place_photos SET status = 'rejected', reviewed_at = ? WHERE check_id = ?")->execute([time(), $cid]);
			if ($st === 'rejected') drop_rejected($pdo);
			respond(['ok' => true]);
		case 'scout_add':
			$mail = strtolower(trim((string) ($body['email'] ?? '')));
			$q = $pdo->prepare('SELECT id FROM accounts WHERE email = ?');
			$q->execute([$mail]);
			$aid = (int) $q->fetchColumn();
			if (!$aid) respond(['error' => 'unknown_account'], 404);
			$pdo->prepare('INSERT OR IGNORE INTO scouts (account_id, created_at) VALUES (?, ?)')->execute([$aid, time()]);
			respond(['ok' => true]);
		case 'scout_remove':
			$pdo->prepare('DELETE FROM scouts WHERE account_id = ?')->execute([(int) ($body['id'] ?? 0)]);
			respond(['ok' => true]);
		case 'delete':
			$pdo->prepare('DELETE FROM own_places WHERE id = ?')->execute([(int) ($body['id'] ?? 0)]);
			respond(['ok' => true]);
	}
	respond(['error' => 'unknown_action'], 400);
}

header('Content-Type: text/html; charset=utf-8');
header('Cache-Control: no-store, private');
header('X-Robots-Tag: noindex, nofollow');
header('Referrer-Policy: no-referrer');

$regionen = [];
if (is_file(data_file('places.sqlite'))) {
	$x = new PDO('sqlite:' . data_file('places.sqlite'));
	$regionen = $x->query('SELECT name, data_at, (SELECT COUNT(*) FROM places) AS orte FROM regions ORDER BY name')->fetchAll(PDO::FETCH_ASSOC);
}
$arten = array_map(fn($k) => ['key' => $k['key'], 'label' => $k['label']], KINDS);
$artName = array_column($arten, 'label', 'key');

// Offene Meldungen, je Ort zusammengefasst.
$gruende = ['gibt_es_nicht' => 'Gibt es nicht', 'falscher_ort' => 'Liegt woanders', 'hunde_verboten' => 'Hunde verboten', 'falscher_name' => 'Name falsch', 'anderes' => 'Etwas anderes'];
$meldungen = [];
foreach ($pdo->query('SELECT place_id, reason, COUNT(*) AS n, MAX(created_at) AS last FROM place_reports WHERE resolved_at IS NULL GROUP BY place_id, reason ORDER BY last DESC') as $r) {
	$m = &$meldungen[$r['place_id']];
	$m['id'] = $r['place_id'];
	$m['last'] = max($m['last'] ?? 0, (int) $r['last']);
	$m['gruende'][] = ($gruende[$r['reason']] ?? $r['reason']) . ($r['n'] > 1 ? ' (' . $r['n'] . ')' : '');
	unset($m);
}
foreach ($meldungen as &$m) $m['ort'] = place_lookup($pdo, $m['id']);
unset($m);

// Orte von Nutzern, noch nicht durchgesehen.
$neu = $pdo->query('SELECT o.*, (SELECT COUNT(*) FROM own_places x WHERE x.created_by = o.created_by AND x.by_user = 1) AS vom_konto
	FROM own_places o WHERE o.by_user = 1 AND o.reviewed_at IS NULL ORDER BY o.created_at DESC LIMIT 100')->fetchAll();
$wann = fn(int $t) => date('j.n.Y, H:i', $t);

$merkmal = ['off_leash' => 'Freilaufen', 'fenced' => 'Eingezäunt', 'water' => 'Trinkwasser', 'clean' => 'Sauber', 'grass' => 'Rasen', 'shade' => 'Schatten', 'bench' => 'Bänke'];
$quelle = ['osm' => 'OpenStreetMap', 'wien' => 'Stadt Wien', 'thisdog' => 'frühere Prüfung', 'eigen' => 'ThisDog'];
$wer = fn($aid) => ($aid && ($r = $pdo->query('SELECT email FROM accounts WHERE id = ' . (int) $aid)->fetchColumn())) ? (string) $r : 'gelöschtes Konto';

$pruefungen = $pdo->query("SELECT * FROM place_checks WHERE status = 'ok' AND reviewed_at IS NULL ORDER BY created_at DESC LIMIT 50")->fetchAll();
foreach ($pruefungen as &$c) {
	$c['ort'] = place_lookup($pdo, $c['place_id']);
	$c['answers'] = json_decode($c['answers'], true) ?: [];
	$c['fotos'] = $pdo->query('SELECT id FROM place_photos WHERE check_id = ' . (int) $c['id'])->fetchAll(PDO::FETCH_COLUMN);
	$bisher = current_facts($pdo, $c['place_id']);
	$c['abweichung'] = [];
	foreach ($merkmal as $k => $label) {
		if (isset($bisher[$k]) && $bisher[$k][0] !== ($c['answers'][$k] ?? null) && $bisher[$k][0] !== 2) {
			$c['abweichung'][] = $label . ': ' . ($c['answers'][$k] ? 'ja' : 'nein') . ' (bisher ' . ($bisher[$k][0] ? 'ja' : 'nein') . ', ' . ($quelle[$bisher[$k][1]] ?? $bisher[$k][1]) . ')';
		}
	}
}
unset($c);
$gemeldeteFotos = $pdo->query("SELECT * FROM place_photos WHERE status = 'reported' ORDER BY reported_at DESC")->fetchAll();
$fotos = $pdo->query("SELECT * FROM place_photos WHERE status = 'ok' AND reviewed_at IS NULL AND check_id IS NULL ORDER BY created_at DESC LIMIT 60")->fetchAll();
foreach ($gemeldeteFotos as &$f) $f['ort'] = place_lookup($pdo, $f['place_id']);
unset($f);
$fotoGrund = ['person' => 'Person erkennbar', 'unpassend' => 'Unpassend', 'falscher_ort' => 'Falscher Ort', 'anderes' => 'Etwas anderes'];
foreach ($fotos as &$f) $f['ort'] = place_lookup($pdo, $f['place_id']);
unset($f);
$erkunder = $pdo->query("SELECT s.account_id, a.email, (SELECT COUNT(*) FROM place_checks c WHERE c.account_id = s.account_id AND c.status = 'ok') AS frei,
	(SELECT COUNT(*) FROM place_checks c WHERE c.account_id = s.account_id AND c.status = 'ok' AND c.reviewed_at IS NULL) AS wartet
	FROM scouts s JOIN accounts a ON a.id = s.account_id ORDER BY a.email")->fetchAll();
?>
<!doctype html>
<html lang="de">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<meta name="robots" content="noindex, nofollow">
<title>Eigene Orte – ThisDog</title>
<link rel="stylesheet" href="https://unpkg.com/maplibre-gl@4.7.1/dist/maplibre-gl.css">
<style>
	:root {
		--paper: #f6f6f8; --surface: #ffffff; --ink: #241e2b; --ink-2: #5d5566; --ink-3: #a29caf;
		--line: #e8e6ee; --accent: #ee6a24; --soft: #fdeadf; --r: 16px;
	}
	@media (prefers-color-scheme: dark) {
		:root { --paper: #141217; --surface: #1d1a21; --ink: #f2eff5; --ink-2: #b9b2c2; --ink-3: #7f788b; --line: #302b37; --accent: #ff8746; --soft: #3a2519; }
	}
	* { box-sizing: border-box; }
	body { margin: 0; padding: 24px 16px 64px; background: var(--paper); color: var(--ink);
		font: 16px/1.5 ui-sans-serif, system-ui, -apple-system, "Segoe UI", Roboto, sans-serif; }
	.wrap { max-width: 1080px; margin: 0 auto; }
	header { display: flex; flex-wrap: wrap; gap: 8px 16px; align-items: baseline; margin-bottom: 16px; }
	h1 { font-size: 22px; margin: 0; }
	header .wer { color: var(--ink-3); font-size: 14px; }
	header a { margin-left: auto; color: var(--accent); text-decoration: none; font-size: 14px; }
	.lage { display: grid; gap: 16px; grid-template-columns: minmax(0, 1fr) 320px; }
	@media (max-width: 820px) { .lage { grid-template-columns: 1fr; } }
	#karte { height: 62vh; min-height: 380px; border-radius: var(--r); overflow: hidden; border: 1px solid var(--line); }
	.feld { background: var(--surface); border: 1px solid var(--line); border-radius: var(--r); padding: 18px; }
	.feld h2 { font-size: 17px; margin: 0 0 4px; }
	.feld p { margin: 0 0 14px; color: var(--ink-2); font-size: 14px; }
	label { display: block; font-size: 13px; color: var(--ink-2); margin: 10px 0 4px; }
	input[type=text], select, textarea { width: 100%; font: inherit; padding: 9px 11px; border-radius: 10px; border: 1px solid var(--line); background: var(--paper); color: var(--ink); }
	.haken { display: flex; gap: 16px; margin-top: 12px; font-size: 14px; }
	.haken label { display: flex; gap: 6px; align-items: center; margin: 0; color: var(--ink); font-size: 14px; }
	button { font: inherit; font-weight: 600; border: 0; border-radius: 999px; padding: 10px 18px; cursor: pointer; }
	button.haupt { background: var(--accent); color: #fff; width: 100%; margin-top: 16px; }
	button.leise { background: var(--soft); color: var(--accent); }
	button:disabled { opacity: .45; cursor: default; }
	.ort { font-variant-numeric: tabular-nums; color: var(--ink-3); font-size: 13px; }
	.meldung { margin-top: 10px; font-size: 14px; color: var(--ink-2); min-height: 1.4em; }
	table { width: 100%; border-collapse: collapse; font-size: 14px; margin-top: 8px; }
	th, td { text-align: left; padding: 8px 10px 8px 0; border-bottom: 1px solid var(--line); vertical-align: top; }
	th { color: var(--ink-3); font-weight: 600; font-size: 13px; }
	.liste { margin-top: 16px; }
	.leer { color: var(--ink-3); font-size: 14px; }
	.aktionen { white-space: nowrap; text-align: right; } .aktionen button { margin-left: 6px; }
	.mini { display: flex; gap: 4px; } .mini img { width: 56px; height: 56px; object-fit: cover; border-radius: 8px; display: block; }
	.fotogitter { display: grid; grid-template-columns: repeat(auto-fill, minmax(180px, 1fr)); gap: 14px; margin-top: 8px; }
	.foto { display: flex; flex-direction: column; gap: 4px; font-size: 14px; } .foto img { width: 100%; aspect-ratio: 4 / 3; object-fit: cover; border-radius: 12px; display: block; }
	.foto button { margin: 4px 6px 0 0; }
	button.haupt2 { background: var(--accent); color: #fff; padding: 6px 14px; font-size: 13.5px; }
	button.leise { padding: 6px 14px; font-size: 13.5px; }
	.zeile { display: flex; gap: 10px; } .zeile input { flex: 1; }
	td.zeigen { cursor: pointer; } td.zeigen:hover { color: var(--accent); }
	.fuss { color: var(--ink-3); font-size: 13px; margin-top: 18px; }
	.maplibregl-popup-content { background: var(--surface); color: var(--ink); border-radius: 12px; font: 14px/1.45 system-ui; padding: 12px 14px; }
	.maplibregl-popup-content b { display: block; }
	.maplibregl-popup-content button { margin-top: 8px; padding: 6px 12px; font-size: 13px; }
</style>
</head>
<body>
<div class="wrap">
<header>
	<h1>Eigene Orte</h1>
	<span class="wer"><?= htmlspecialchars($email) ?></span>
	<a href="/admin-support.php">Anfragen</a> <a href="/admin.php" style="margin-left:14px">Übersicht</a>
</header>

<div class="lage">
	<div id="karte" role="application" aria-label="Karte: antippen, um dort einen Ort anzulegen"></div>
	<form class="feld" id="neu">
		<h2>Neuer Ort</h2>
		<p>Auf der Karte die Stelle antippen.</p>
		<div class="ort" id="stelle">Noch keine Stelle gewählt</div>
		<label for="name">Name</label>
		<input type="text" id="name" maxlength="80" required placeholder="z. B. Hundewiese am Kanal">
		<label for="art">Art</label>
		<select id="art"><?php foreach ($arten as $a): ?><option value="<?= $a['key'] ?>"><?= htmlspecialchars($a['label']) ?></option><?php endforeach; ?></select>
		<div class="haken">
			<label><input type="checkbox" id="frei"> ohne Leine</label>
			<label><input type="checkbox" id="zaun"> eingezäunt</label>
		</div>
		<label for="notiz">Notiz (nur hier sichtbar)</label>
		<textarea id="notiz" rows="2" maxlength="300"></textarea>
		<button class="haupt" id="anlegen" disabled>Ort anlegen</button>
		<div class="meldung" id="meldung" role="status"></div>
	</form>
</div>

<section class="feld liste" id="pruefungen">
	<h2>Neue Prüfungen</h2>
	<?php if (!$pruefungen): ?><p class="leer">Alle Prüfungen angesehen.</p><?php else: ?>
	<table><thead><tr><th>Ort</th><th>Wer, wann</th><th>Fotos</th><th>Anders als bisher</th><th></th></tr></thead><tbody>
	<?php foreach ($pruefungen as $c): $o = $c['ort']; ?>
		<tr data-id="<?= (int) $c['id'] ?>" data-lat="<?= $o['lat'] ?? '' ?>" data-lon="<?= $o['lon'] ?? '' ?>">
			<td class="zeigen"><?= htmlspecialchars($o['name'] ?? $c['place_id']) ?><br><span class="ort"><?= htmlspecialchars($c['place_id']) ?></span></td>
			<td><?= htmlspecialchars($wer($c['account_id'])) ?><br><span class="ort"><?= $wann((int) $c['checked_at']) ?>, <?= (int) $c['distance_m'] ?> m vom Ort</span></td>
			<td><div class="mini"><?php foreach ($c['fotos'] as $fid): ?><a href="api/photo.php?id=<?= (int) $fid ?>" target="_blank"><img src="api/photo.php?id=<?= (int) $fid ?>&amp;klein=1" alt=""></a><?php endforeach; ?></div></td>
			<td><?= $c['abweichung'] ? htmlspecialchars(implode('; ', $c['abweichung'])) : '<span class="ort">nichts</span>' ?></td>
			<td class="aktionen"><button class="haupt2" data-tu="check_ok">Gesehen</button><button class="leise" data-tu="check_no">Zurückziehen</button></td>
		</tr>
	<?php endforeach; ?>
	</tbody></table>
	<?php endif; ?>
</section>

<section class="feld liste" id="fotos">
	<h2>Gemeldete Fotos</h2>
	<?php if (!$gemeldeteFotos): ?><p class="leer">Keine Meldungen.</p><?php else: ?>
	<div class="fotogitter">
	<?php foreach ($gemeldeteFotos as $f): ?>
		<div class="foto" data-id="<?= (int) $f['id'] ?>">
			<a href="api/photo.php?id=<?= (int) $f['id'] ?>" target="_blank"><img src="api/photo.php?id=<?= (int) $f['id'] ?>&amp;klein=1" alt=""></a>
			<b><?= htmlspecialchars($f['ort']['name'] ?? $f['place_id']) ?></b>
			<span class="ort"><?= htmlspecialchars($fotoGrund[$f['report_reason']] ?? '') ?>, <?= $wann((int) $f['reported_at']) ?></span>
			<div><button class="haupt2" data-tu="photo_ok">Behalten</button><button class="leise" data-tu="photo_no">Löschen</button></div>
		</div>
	<?php endforeach; ?>
	</div>
	<?php endif; ?>
	<h2 style="margin-top:22px">Neue Fotos</h2>
	<?php if (!$fotos): ?><p class="leer">Alle Fotos angesehen.</p><?php else: ?>
	<div class="fotogitter">
	<?php foreach ($fotos as $f): ?>
		<div class="foto" data-id="<?= (int) $f['id'] ?>">
			<a href="api/photo.php?id=<?= (int) $f['id'] ?>" target="_blank"><img src="api/photo.php?id=<?= (int) $f['id'] ?>&amp;klein=1" alt=""></a>
			<b><?= htmlspecialchars($f['ort']['name'] ?? $f['place_id']) ?></b>
			<span class="ort"><?= $wann((int) $f['created_at']) ?></span>
			<div><button class="haupt2" data-tu="photo_ok">Gesehen</button><button class="leise" data-tu="photo_no">Löschen</button></div>
		</div>
	<?php endforeach; ?>
	</div>
	<?php endif; ?>
</section>

<section class="feld liste" id="erkunder">
	<h2>Erkunder</h2>
	<p>Wer hier steht, sieht in der App auf jeder Ortsseite „Vor Ort prüfen“.</p>
	<form id="erkunder-neu" class="zeile"><input type="text" id="erkunder-mail" placeholder="E-Mail-Adresse des Kontos" autocomplete="off"><button class="haupt2">Hinzufügen</button></form>
	<div class="meldung" id="erkunder-meldung" role="status"></div>
	<?php if ($erkunder): ?>
	<table><thead><tr><th>Konto</th><th>Geprüft</th><th>Nicht angesehen</th><th></th></tr></thead><tbody>
	<?php foreach ($erkunder as $e): ?>
		<tr data-id="<?= (int) $e['account_id'] ?>"><td><?= htmlspecialchars($e['email']) ?></td><td><?= (int) $e['frei'] ?> Orte</td><td><?= (int) $e['wartet'] ?></td>
		<td class="aktionen"><button class="leise" data-tu="scout_remove">Entfernen</button></td></tr>
	<?php endforeach; ?>
	</tbody></table>
	<?php endif; ?>
</section>

<section class="feld liste" id="gemeldet">
	<h2>Gemeldet</h2>
	<?php if (!$meldungen): ?><p class="leer">Keine offenen Meldungen.</p><?php else: ?>
	<table><thead><tr><th>Ort</th><th>Was gemeldet wurde</th><th>Zuletzt</th><th></th></tr></thead><tbody>
	<?php foreach ($meldungen as $m): $o = $m['ort']; ?>
		<tr data-id="<?= htmlspecialchars($m['id']) ?>" data-lat="<?= $o['lat'] ?? '' ?>" data-lon="<?= $o['lon'] ?? '' ?>">
			<td class="zeigen"><?= htmlspecialchars($o['name'] ?? $m['id']) ?><br><span class="ort"><?= htmlspecialchars($artName[$o['kind'] ?? ''] ?? '') ?> · <?= htmlspecialchars($m['id']) ?></span></td>
			<td><?= htmlspecialchars(implode(', ', $m['gruende'])) ?></td>
			<td class="ort"><?= $wann($m['last']) ?></td>
			<td class="aktionen">
				<?php if ($o && !str_starts_with($m['id'], 'eigen/')): ?><button class="leise" data-tu="ausblenden">Ausblenden</button><?php endif; ?>
				<?php if (str_starts_with($m['id'], 'eigen/')): ?><button class="leise" data-tu="loeschen">Löschen</button><?php endif; ?>
				<button class="leise" data-tu="erledigt">Stimmt so</button>
			</td>
		</tr>
	<?php endforeach; ?>
	</tbody></table>
	<?php endif; ?>
</section>

<section class="feld liste" id="neu-von-nutzern">
	<h2>Neu von Nutzern</h2>
	<?php if (!$neu): ?><p class="leer">Nichts Neues.</p><?php else: ?>
	<table><thead><tr><th>Ort</th><th>Art</th><th>Eingetragen</th><th></th></tr></thead><tbody>
	<?php foreach ($neu as $o): ?>
		<tr data-id="<?= (int) $o['id'] ?>" data-lat="<?= $o['lat'] ?>" data-lon="<?= $o['lon'] ?>">
			<td class="zeigen"><?= htmlspecialchars($o['name']) ?></td>
			<td><?= htmlspecialchars($artName[$o['kind']] ?? $o['kind']) ?></td>
			<td class="ort"><?= $wann((int) $o['created_at']) ?><?= $o['vom_konto'] > 1 ? ' · ' . (int) $o['vom_konto'] . ' Orte von diesem Konto' : '' ?></td>
			<td class="aktionen"><button class="leise" data-tu="passt">Passt</button><button class="leise" data-tu="weg">Löschen</button></td>
		</tr>
	<?php endforeach; ?>
	</tbody></table>
	<?php endif; ?>
</section>

<section class="feld liste">
	<h2>Eigene Einträge</h2>
	<table><thead><tr><th>Name</th><th>Art</th><th>Notiz</th><th></th></tr></thead><tbody id="eigene"></tbody></table>
</section>

<p class="fuss">
	OpenStreetMap-Auszug:
	<?= $regionen ? htmlspecialchars(implode(', ', array_map(fn($r) => $r['name'] . ' (Stand ' . substr((string) $r['data_at'], 0, 10) . ')', $regionen))) . ', ' . number_format((int) $regionen[0]['orte'], 0, ',', '.') . ' Orte' : 'noch nicht importiert' ?>.
	Neu jeden Monat; eigene Einträge bleiben dabei erhalten. Kartendaten © OpenStreetMap-Mitwirkende.
</p>
</div>

<script src="https://unpkg.com/maplibre-gl@4.7.1/dist/maplibre-gl.js"></script>
<script>
const ARTEN = <?= json_encode(array_column($arten, 'label', 'key'), JSON_UNESCAPED_UNICODE) ?>;
const dunkel = matchMedia('(prefers-color-scheme: dark)').matches;
const karte = new maplibregl.Map({
	container: 'karte',
	style: 'https://tiles.openfreemap.org/styles/' + (dunkel ? 'dark' : 'positron'),
	center: [16.38, 48.21], zoom: 13,
});
karte.addControl(new maplibregl.NavigationControl({ showCompass: false }));
karte.addControl(new maplibregl.GeolocateControl());

let stelle = null, marke = null;
const $ = id => document.getElementById(id);
const leer = { type: 'FeatureCollection', features: [] };

function punkt(lon, lat, props) { return { type: 'Feature', geometry: { type: 'Point', coordinates: [lon, lat] }, properties: props }; }

async function post(action, body) {
	const r = await fetch('?action=' + action, { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(body) });
	if (!r.ok) throw new Error((await r.json().catch(() => ({}))).error || r.status);
}

async function laden() {
	const c = karte.loaded() ? karte.getCenter() : { lat: 48.21, lng: 16.38 };
	const r = await fetch(`?action=near&lat=${c.lat.toFixed(5)}&lon=${c.lng.toFixed(5)}`);
	const d = await r.json();
	const versteckt = new Set(d.own.filter(o => o.replaces).map(o => o.replaces));
	if (karte.getSource('osm')) karte.getSource('osm').setData({ type: 'FeatureCollection', features: d.places.filter(p => !p.id.startsWith('eigen/')).map(p =>
		punkt(p.lon, p.lat, { id: p.id, name: p.name, art: p.label, lat: p.lat, lon: p.lon, weg: versteckt.has(p.id) })) });
	if (karte.getSource('eigen')) karte.getSource('eigen').setData({ type: 'FeatureCollection', features: d.own.filter(o => o.name).map(o =>
		punkt(o.lon, o.lat, { id: o.id, name: o.name, art: ARTEN[o.kind] || o.kind })) });
	const zeilen = d.own.map(o => {
		const tr = document.createElement('tr');
		const name = o.name || ('Ausgeblendet: ' + o.replaces);
		tr.innerHTML = '<td></td><td></td><td></td><td><button class="leise">Löschen</button></td>';
		tr.children[0].textContent = name;
		tr.children[1].textContent = o.name ? (ARTEN[o.kind] || o.kind) + (o.off_leash ? ', ohne Leine' : '') + (o.fenced ? ', eingezäunt' : '') : '–';
		tr.children[2].textContent = o.note || '';
		tr.querySelector('button').onclick = async () => { await post('delete', { id: o.id }); laden(); };
		tr.children[0].style.cursor = 'pointer';
		tr.children[0].onclick = () => karte.flyTo({ center: [o.lon, o.lat], zoom: 16 });
		return tr;
	});
	$('eigene').replaceChildren(...zeilen);
	if (!zeilen.length) $('eigene').innerHTML = '<tr><td colspan="4" class="leer">Noch keine eigenen Orte.</td></tr>';
}

karte.on('load', () => {
	const akzent = getComputedStyle(document.documentElement).getPropertyValue('--accent').trim();
	karte.addSource('osm', { type: 'geojson', data: leer });
	karte.addSource('eigen', { type: 'geojson', data: leer });
	karte.addLayer({ id: 'osm', type: 'circle', source: 'osm', paint: {
		'circle-radius': 6, 'circle-color': '#fff', 'circle-stroke-width': 1.6,
		'circle-stroke-color': ['case', ['get', 'weg'], '#bbb', '#241e2b'], 'circle-opacity': ['case', ['get', 'weg'], .4, 1] } });
	karte.addLayer({ id: 'eigen', type: 'circle', source: 'eigen', paint: {
		'circle-radius': 8, 'circle-color': akzent, 'circle-stroke-width': 3, 'circle-stroke-color': '#fff' } });
	laden();
});
karte.on('moveend', laden);
laden();  // Die Liste kommt auch, wenn die Karte (WebGL) nicht startet.

karte.on('click', e => {
	const getroffen = karte.queryRenderedFeatures(e.point, { layers: ['osm', 'eigen'] });
	if (getroffen.length) {
		const f = getroffen[0], p = f.properties, box = document.createElement('div');
		box.innerHTML = '<b></b><span></span>';
		box.querySelector('b').textContent = p.name;
		box.querySelector('span').textContent = (f.layer.id === 'osm' ? 'OpenStreetMap, ' : 'eigener Ort, ') + p.art;
		if (f.layer.id === 'osm' && !p.weg) {
			const b = document.createElement('button'); b.className = 'leise'; b.textContent = 'In der App ausblenden';
			b.onclick = async () => { await post('hide', { id: p.id, lat: p.lat, lon: p.lon }); popup.remove(); laden(); };
			box.append(document.createElement('br'), b);
		}
		const popup = new maplibregl.Popup({ closeButton: false }).setLngLat(f.geometry.coordinates).setDOMContent(box).addTo(karte);
		return;
	}
	stelle = e.lngLat;
	$('stelle').textContent = stelle.lat.toFixed(5) + ', ' + stelle.lng.toFixed(5);
	(marke ||= new maplibregl.Marker({ color: getComputedStyle(document.documentElement).getPropertyValue('--accent').trim() })).setLngLat(stelle).addTo(karte);
	$('anlegen').disabled = false;
	$('name').focus();
});

// Prüfungen, Fotos, Erkunder: ein Button, eine Aktion; danach verschwindet der Eintrag.
for (const el of document.querySelectorAll('#pruefungen tbody tr, #fotos .foto, #erkunder tbody tr')) {
	const show = el.querySelector('.zeigen');
	if (show) show.onclick = () => el.dataset.lat && karte.flyTo({ center: [+el.dataset.lon, +el.dataset.lat], zoom: 17 });
	for (const b of el.querySelectorAll('button')) b.onclick = async () => {
		b.disabled = true;
		try { await post(b.dataset.tu, { id: +el.dataset.id }); el.remove(); } catch (err) { b.disabled = false; b.textContent = 'Nicht geklappt'; }
	};
}
$('erkunder-neu').addEventListener('submit', async e => {
	e.preventDefault();
	try { await post('scout_add', { email: $('erkunder-mail').value }); location.reload(); }
	catch (err) { $('erkunder-meldung').textContent = err.message === 'unknown_account' ? 'Zu dieser Adresse gibt es kein Konto. Wer Erkunder wird, meldet sich zuerst in der App an.' : 'Nicht gespeichert.'; }
});

// Gemeldet und Neu von Nutzern: Zeile antippen zeigt den Ort, die Buttons erledigen ihn.
for (const tr of document.querySelectorAll('#gemeldet tbody tr, #neu-von-nutzern tbody tr')) {
	tr.querySelector('.zeigen').onclick = () => tr.dataset.lat && karte.flyTo({ center: [+tr.dataset.lon, +tr.dataset.lat], zoom: 17 });
	for (const b of tr.querySelectorAll('button')) b.onclick = async () => {
		const id = tr.dataset.id, was = b.dataset.tu;
		b.disabled = true;
		try {
			if (was === 'ausblenden') { await post('hide', { id, lat: +tr.dataset.lat, lon: +tr.dataset.lon }); await post('resolve', { id }); }
			if (was === 'loeschen') { await post('delete', { id: +id.slice(6) }); await post('resolve', { id }); }
			if (was === 'erledigt') await post('resolve', { id });
			if (was === 'passt') await post('reviewed', { id: +id });
			if (was === 'weg') await post('delete', { id: +id });
			tr.remove();
			laden();
		} catch (err) { b.disabled = false; b.textContent = 'Nicht geklappt'; }
	};
}

$('neu').addEventListener('submit', async e => {
	e.preventDefault();
	if (!stelle) return;
	try {
		await post('add', { name: $('name').value, kind: $('art').value, lat: stelle.lat, lon: stelle.lng,
			offLeash: $('frei').checked, fenced: $('zaun').checked, note: $('notiz').value });
		$('meldung').textContent = '„' + $('name').value + '“ angelegt. Die App zeigt den Ort ab sofort.';
		$('neu').reset(); marke?.remove(); marke = null; stelle = null; $('anlegen').disabled = true;
		$('stelle').textContent = 'Noch keine Stelle gewählt';
		laden();
	} catch (err) {
		$('meldung').textContent = err.message === 'invalid' ? 'Name und Stelle fehlen.' : 'Nicht gespeichert (' + err.message + ').';
	}
});
</script>
</body>
</html>
