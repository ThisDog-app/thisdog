<?php
declare(strict_types=1);

/**
 * Adressen rund um den Hund: Tierärzte, Hundefriseure, Tierbedarf, Hundeschulen, Tierheime, Pensionen, Lokale.
 * Aus dem eigenen OpenStreetMap-Auszug (Tabelle services in places.sqlite, server/orte-import.py).
 *
 * Dazu die Partnerplätze: Je Gegend – ein festes Raster von rund 3 × 3 km – kann ein Betrieb einen Platz oben
 * in den Adressen kaufen (partner.php). Er ist in der App immer als Anzeige gekennzeichnet; die übrige Liste
 * bleibt nach Entfernung sortiert und ist nicht käuflich.
 *
 * Gebraucht von api/services.php (App), partner.php (Buchung), api/stripe.php (Zahlung) und admin-orte.php.
 */

require_once __DIR__ . '/lib.php';
require_once __DIR__ . '/lib-db.php';

/** Arten in der Reihenfolge der App. Schlüssel wie in server/orte-import.py. */
const SERVICE_KINDS = [
	'vet' => 'Tierarzt',
	'groomer' => 'Hundefriseur',
	'shop' => 'Tierbedarf',
	'school' => 'Hundeschule',
	'shelter' => 'Tierheim',
	'boarding' => 'Hundepension',
	'cafe' => 'Hundefreundliches Lokal',
];

/** Umkreis der Liste in der App. */
const SERVICE_RADIUS = 5000;
/** Höchstens so viele Einträge je Antwort – die nächsten. */
const SERVICE_MAX = 300;
/** Namenssuche: weiter, aber weniger. */
const SERVICE_SEARCH_RADIUS = 30000;
const SERVICE_SEARCH_MAX = 60;

/** Raster der Gegenden: 0,03° Breite × 0,045° Länge, in Mitteleuropa rund 3,3 × 3,3 km. */
const TILE_LAT = 0.03;
const TILE_LON = 0.045;
/** Ein Partnerplatz erscheint, wenn er höchstens so weit weg ist (auch aus der Nachbargegend). */
const SPONSOR_REACH = 3000;
/** So lange ist eine Gegend reserviert, während jemand an der Kasse steht. */
const CHECKOUT_HOLD = 1800;
/** Nachfrist, falls eine Verlängerung ein paar Stunden später bezahlt wird als der Zeitraum endet. */
const PAID_GRACE = 172800;
/** „Läuft bis“ für selbst eingetragene Plätze ohne Ende (1.1.2100). */
const SPONSOR_FOREVER = 4102444800;

function services_db(): ?PDO
{
	$path = data_file('places.sqlite');
	if (!is_file($path)) return null;
	$x = new PDO('sqlite:' . $path, null, null, [PDO::ATTR_ERRMODE => PDO::ERRMODE_EXCEPTION, PDO::ATTR_DEFAULT_FETCH_MODE => PDO::FETCH_ASSOC]);
	// Ältere Auszüge haben noch keine Adressen.
	$has = $x->query("SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = 'services'")->fetchColumn();
	return $has ? $x : null;
}

/** Ein Eintrag im Format der App: leere Felder fehlen ganz. */
function service_out(array $r): ?array
{
	$kind = (string) $r['kind'];
	if (!isset(SERVICE_KINDS[$kind])) return null;
	$out = [
		'id' => (string) ($r['place_id'] ?? $r['id']),
		'kind' => $kind,
		'label' => SERVICE_KINDS[$kind],
		'name' => (string) $r['name'],
		'lat' => round((float) $r['lat'], 5),
		'lon' => round((float) $r['lon'], 5),
	];
	foreach (['street', 'city', 'phone', 'website', 'hours'] as $k) {
		$v = trim((string) ($r[$k] ?? ''));
		if ($v !== '') $out[$k] = $v;
	}
	if (!empty($r['emergency'])) $out['emergency'] = true;
	return $out;
}

/** Ist diese Gegend im Auszug? */
function services_covered(PDO $x, float $lat, float $lon): bool
{
	$q = $x->prepare('SELECT 1 FROM regions WHERE ? BETWEEN min_lat AND max_lat AND ? BETWEEN min_lon AND max_lon');
	$q->execute([$lat, $lon]);
	return (bool) $q->fetchColumn();
}

/** Rechteck um einen Punkt mit diesem Radius. */
function box_around(float $lat, float $lon, float $radius): array
{
	$dLat = $radius / 111320;
	$dLon = $radius / (111320 * max(0.1, cos(deg2rad($lat))));
	return [$lat - $dLat, $lat + $dLat, $lon - $dLon, $lon + $dLon];
}

/**
 * Adressen um einen Punkt, nach Entfernung. Mit Suchtext: Name, Art oder Straße enthält ihn, im weiteren Umkreis.
 */
function services_near(PDO $x, float $lat, float $lon, string $q = ''): array
{
	$search = $q !== '';
	[$a, $b, $c, $d] = box_around($lat, $lon, $search ? SERVICE_SEARCH_RADIUS : SERVICE_RADIUS);
	$sql = 'SELECT * FROM services WHERE lat BETWEEN ? AND ? AND lon BETWEEN ? AND ?';
	$args = [$a, $b, $c, $d];
	if ($search) {
		$like = '%' . strtr($q, ['\\' => '\\\\', '%' => '\%', '_' => '\_']) . '%';
		$kinds = array_keys(array_filter(SERVICE_KINDS, fn($l) => mb_stripos($l, $q) !== false));
		$sql .= " AND (name LIKE ? ESCAPE '\\' OR street LIKE ? ESCAPE '\\'" . ($kinds ? ' OR kind IN (' . implode(',', array_fill(0, count($kinds), '?')) . ')' : '') . ')';
		array_push($args, $like, $like, ...$kinds);
	}
	$st = $x->prepare($sql);
	$st->execute($args);
	$found = [];
	foreach ($st as $r) {
		$dist = distance_between($lat, $lon, (float) $r['lat'], (float) $r['lon']);
		if ($dist > ($search ? SERVICE_SEARCH_RADIUS : SERVICE_RADIUS)) continue;
		$o = service_out($r);
		if ($o !== null) $found[] = [$dist, $o];
	}
	usort($found, fn($m, $n) => $m[0] <=> $n[0]);
	return array_map(fn($e) => $e[1], array_slice($found, 0, $search ? SERVICE_SEARCH_MAX : SERVICE_MAX));
}

function distance_between(float $lat1, float $lon1, float $lat2, float $lon2): float
{
	$p1 = deg2rad($lat1); $p2 = deg2rad($lat2);
	$h = sin(($p2 - $p1) / 2) ** 2 + cos($p1) * cos($p2) * sin(deg2rad($lon2 - $lon1) / 2) ** 2;
	return 2 * 6371000 * asin(min(1.0, sqrt($h)));
}

/** Ein Betrieb aus dem Auszug – für die Buchung. */
function service_by_id(PDO $x, string $id): ?array
{
	$q = $x->prepare('SELECT * FROM services WHERE id = ?');
	$q->execute([$id]);
	$r = $q->fetch();
	return $r ?: null;
}

/** Betriebe nach Name (und Ort/PLZ) im ganzen Auszug – für die Buchungsseite. */
function services_by_name(PDO $x, string $name, string $where = '', int $max = 20): array
{
	$esc = fn($s) => '%' . strtr($s, ['\\' => '\\\\', '%' => '\%', '_' => '\_']) . '%';
	$sql = "SELECT * FROM services WHERE name LIKE ? ESCAPE '\\'";
	$args = [$esc($name)];
	if ($where !== '') {
		$sql .= " AND (city LIKE ? ESCAPE '\\' OR street LIKE ? ESCAPE '\\')";
		array_push($args, $esc($where), $esc($where));
	}
	$st = $x->prepare($sql . ' ORDER BY name LIMIT ' . (int) $max);
	$st->execute($args);
	return $st->fetchAll();
}

/* ============================ Gegenden und Partnerplätze ============================ */

function sponsor_tile(float $lat, float $lon): string
{
	return sprintf('%d:%d', (int) floor($lat / TILE_LAT), (int) floor($lon / TILE_LON));
}

/**
 * Läuft dieser Platz gerade (bezahlt, nicht gesperrt)? Ein Platzhalter: die aktuelle Zeit. Gebuchte Plätze bekommen
 * zwei Tage Nachfrist, falls Stripes Meldung zur Verlängerung spät kommt; selbst eingetragene enden pünktlich.
 */
function sponsor_live_sql(): string
{
	// CAST: PDO bindet als Text, und ohne Spalte auf einer Seite vergleicht SQLite sonst Zahl mit Text.
	return "status = 'active' AND paid_until > CAST(? AS INTEGER) - CASE WHEN subscription_id IS NULL THEN 0 ELSE " . PAID_GRACE . " END";
}

function sponsor_runs(array $r): bool
{
	return $r['status'] === 'active' && (int) $r['paid_until'] + ($r['subscription_id'] === null ? 0 : PAID_GRACE) > time();
}

/**
 * Wer die Gegend gerade belegt: ein laufender Platz oder jemand, der seit weniger als einer halben Stunde an der
 * Kasse steht. Null: frei.
 */
function tile_holder(PDO $pdo, string $tile, ?int $except = null): ?array
{
	$now = time();
	$q = $pdo->prepare("SELECT * FROM sponsors WHERE tile = ? AND id IS NOT ? AND ((" . sponsor_live_sql() . ") OR (status = 'pending' AND created_at > ?)) ORDER BY id LIMIT 1");
	$q->execute([$tile, $except, $now, $now - CHECKOUT_HOLD]);
	return $q->fetch() ?: null;
}

/** Der Partnerplatz für diesen Punkt: zuerst die eigene Gegend, sonst der nächste aus einer Nachbargegend in Reichweite. */
function sponsor_for(PDO $pdo, float $lat, float $lon): ?array
{
	$tiles = [];
	$ti = (int) floor($lat / TILE_LAT); $tj = (int) floor($lon / TILE_LON);
	for ($i = -1; $i <= 1; $i++) for ($j = -1; $j <= 1; $j++) $tiles[] = sprintf('%d:%d', $ti + $i, $tj + $j);
	$q = $pdo->prepare('SELECT * FROM sponsors WHERE tile IN (' . implode(',', array_fill(0, 9, '?')) . ') AND ' . sponsor_live_sql());
	$q->execute([...$tiles, time()]);
	$own = sponsor_tile($lat, $lon);
	$best = null; $bestKey = null;
	foreach ($q as $r) {
		$dist = distance_between($lat, $lon, (float) $r['lat'], (float) $r['lon']);
		$mine = $r['tile'] === $own;
		if (!$mine && $dist > SPONSOR_REACH) continue;
		$key = [$mine ? 0 : 1, $dist];
		if ($bestKey === null || $key < $bestKey) { $best = $r; $bestKey = $key; }
	}
	return $best;
}

/** Ein Partnerplatz im Format der App. */
function sponsor_out(array $r): array
{
	$o = service_out($r) ?? [];
	$o['id'] = (int) $r['id'];
	$o['place'] = (string) $r['place_id'];
	if (trim((string) $r['text']) !== '') $o['text'] = (string) $r['text'];
	$o['advertiser'] = (string) $r['advertiser'];
	return $o;
}

/** Summen je Tag – mehr erfährt ein Partner nicht, und mehr wird nicht gespeichert. */
function sponsor_count(PDO $pdo, int $id, string $what): void
{
	$col = $what === 'taps' ? 'taps' : 'views';
	$pdo->prepare("INSERT INTO sponsor_stats (sponsor_id, day, $col) VALUES (?, ?, 1)
		ON CONFLICT(sponsor_id, day) DO UPDATE SET $col = $col + 1")->execute([$id, date('Y-m-d')]);
}

/** Selbst eingetragen (im Admin), nicht über Stripe gebucht. */
function sponsor_manual(array $r): bool
{
	return (string) ($r['checkout_id'] ?? '') === '' && (string) ($r['subscription_id'] ?? '') === '';
}

/**
 * Neuer Verwaltungslink für einen Platz: Das alte Geheimnis gilt danach nicht mehr. Schickt ihn an die hinterlegte
 * Adresse und gibt ihn zurück (für den Admin, falls die Mail nicht ankommt).
 */
function sponsor_send_link(PDO $pdo, array $s, string $tail): string
{
	require_once __DIR__ . '/lib-mail.php';
	$secret = new_secret();
	$pdo->prepare('UPDATE sponsors SET manage_hash = ? WHERE id = ?')->execute([secret_hash($secret), $s['id']]);
	$link = site_url() . '/partner/verwalten/' . $secret;
	if (filter_var($s['email'], FILTER_VALIDATE_EMAIL)) {
		try {
			send_mail($s['email'], 'Dein Partnerplatz bei ThisDog läuft',
				"Danke! „{$s['name']}“ steht ab sofort oben in den Adressen der ThisDog-App, gekennzeichnet als Anzeige.\n\n"
				. "Hier siehst du, wie oft der Platz gezeigt und geöffnet wurde, und änderst deinen Text:\n$link\n\n"
				. "Bewahre den Link gut auf – er ist dein Zugang. $tail\n\nThisDog");
		} catch (Throwable $e) {
			error_log('[stella] Partner-Mail: ' . $e->getMessage());
		}
	}
	return $link;
}

/** Preis je Monat in Cent. */
function sponsor_price(): int
{
	return max(100, (int) cfg('SPONSOR_PRICE_CENTS', 2900));
}

function euro(int $cents): string
{
	return number_format($cents / 100, $cents % 100 ? 2 : 0, ',', '.') . ' €';
}

/** Grundadresse für Links in Mails und für die Rückkehr von der Kasse. */
function site_url(): string
{
	$url = rtrim((string) cfg('APP_URL', ''), '/');
	if ($url !== '') return $url;
	require_once __DIR__ . '/lib-mail.php';
	if (mail_local_request()) return 'http://' . $_SERVER['HTTP_HOST'];
	throw new RuntimeException('APP_URL fehlt in der Konfiguration.');
}

/** Normalisiert eine Website für Links: ohne Schema → https://. Null, wenn es keine taugliche Adresse ist. */
function web_link(?string $raw): ?string
{
	$raw = trim((string) $raw);
	if ($raw === '') return null;
	if (!preg_match('#^https?://#i', $raw)) $raw = 'https://' . $raw;
	return filter_var($raw, FILTER_VALIDATE_URL) ? $raw : null;
}
