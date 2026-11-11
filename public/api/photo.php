<?php
declare(strict_types=1);

/**
 * Ein Foto eines Ortes: GET ?id=<Foto>[&klein=1]. Gemeldete Fotos sieht bis zur Entscheidung nur der Betreiber
 * (admin-orte.php) und wer sie hochgeladen hat.
 */

require_once __DIR__ . '/lib.php';
require_once __DIR__ . '/lib-db.php';
require_once __DIR__ . '/lib-places.php';
require_once __DIR__ . '/lib-admin.php';

$pdo = db();
$q = $pdo->prepare('SELECT * FROM place_photos WHERE id = ?');
$q->execute([(int) ($_GET['id'] ?? 0)]);
$f = $q->fetch();
$session = current_session($pdo);
$me = $session ? (int) $session['account_id'] : null;
$admin = $session && in_array(strtolower((string) $session['email']), admin_emails(), true);
if (!$f || ($f['status'] !== 'ok' && !$admin && $me !== (int) $f['account_id'])) { http_response_code(404); exit; }
$path = photo_dir() . '/' . basename($f['file']);
if (!is_file($path)) { http_response_code(404); exit; }

header('Content-Type: image/webp');
header('Cache-Control: ' . ($f['status'] === 'ok' ? 'public, max-age=2592000, immutable' : 'private, no-store'));
header('X-Content-Type-Options: nosniff');
if (!empty($_GET['klein'])) {
	$src = imagecreatefromwebp($path);
	$k = 480 / max(imagesx($src), imagesy($src));
	$dst = imagescale($src, (int) round(imagesx($src) * $k), (int) round(imagesy($src) * $k));
	imagewebp($dst, null, 72);
	exit;
}
readfile($path);
