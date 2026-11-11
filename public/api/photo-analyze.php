<?php
declare(strict_types=1);

/**
 * Bilderkennung für den Food-Check.
 *
 * Nimmt ein Bild entgegen, fragt Google Cloud Vision nach Bezeichnungen und
 * liefert den brauchbarsten Begriff zurück. Allgemeine Oberbegriffe wie
 * „Lebensmittel“ helfen bei der Suche nicht und werden übersprungen.
 */

require __DIR__ . '/lib.php';

guard_origin();
handle_preflight();

if (($_SERVER['REQUEST_METHOD'] ?? '') !== 'POST') {
	respond(['error' => 'method_not_allowed'], 405);
}

$apiKey = (string) cfg('GOOGLE_VISION_API_KEY', '');
if ($apiKey === '') {
	respond(['error' => 'no_api_key'], 500);
}

// Jede Anfrage kostet Geld – ohne Limit könnte das Kontingent leergeräumt werden.
if (!rate_ok('vision', (int) cfg('VISION_RATE_LIMIT', 40))) {
	respond(['error' => 'rate_limited'], 429);
}

$imgB64 = $_POST['file_b64'] ?? '';
if (!is_string($imgB64) || $imgB64 === '') {
	respond(['error' => 'no_image'], 400);
}

// Rohgröße begrenzen: base64 wächst um etwa ein Drittel, 8 MB decken jedes
// Handyfoto ab, das die App vor dem Senden bereits verkleinert.
if (strlen($imgB64) > 8 * 1024 * 1024) {
	respond(['error' => 'image_too_large'], 413);
}

$binary = base64_decode($imgB64, true);
if ($binary === false || strlen($binary) < 100) {
	respond(['error' => 'invalid_image'], 400);
}

// Nur echte Bilder weiterreichen.
$info = @getimagesizefromstring($binary);
if ($info === false || !in_array($info[2], [IMAGETYPE_JPEG, IMAGETYPE_PNG, IMAGETYPE_WEBP, IMAGETYPE_GIF], true)) {
	respond(['error' => 'unsupported_format'], 415);
}
unset($binary);

$body = [
	'requests' => [[
		'image' => ['content' => $imgB64],
		'features' => [['type' => 'LABEL_DETECTION', 'maxResults' => 8]],
		'imageContext' => ['languageHints' => ['de']],
	]],
];

$ch = curl_init('https://vision.googleapis.com/v1/images:annotate?key=' . urlencode($apiKey));
curl_setopt_array($ch, [
	CURLOPT_POST => true,
	CURLOPT_HTTPHEADER => ['Content-Type: application/json', 'Accept: application/json'],
	CURLOPT_POSTFIELDS => json_encode($body),
	CURLOPT_RETURNTRANSFER => true,
	CURLOPT_TIMEOUT => 25,
	CURLOPT_CONNECTTIMEOUT => 8,
]);

$resp = curl_exec($ch);
$http = (int) curl_getinfo($ch, CURLINFO_HTTP_CODE);
$err = curl_error($ch);
curl_close($ch);

if ($resp === false) {
	error_log('[stella] Vision nicht erreichbar: ' . $err);
	respond(['error' => 'vision_unreachable'], 502);
}
if ($http >= 400) {
	// Fehlermeldungen von Google können den Schlüssel enthalten – nur protokollieren.
	error_log('[stella] Vision HTTP ' . $http . ': ' . substr((string) $resp, 0, 500));
	respond(['error' => 'vision_error'], 502);
}

$json = json_decode((string) $resp, true);
$labels = $json['responses'][0]['labelAnnotations'] ?? [];
if (!$labels) {
	respond(['term' => '']);
}

// Oberbegriffe, die keinen Eintrag in der Datenbank treffen.
$generic = [
	'food', 'produce', 'ingredient', 'dish', 'meal', 'cuisine', 'recipe', 'snack',
	'lebensmittel', 'zutat', 'gericht', 'nahrung', 'nahrungsmittel', 'speise', 'essen',
	'fruit', 'obst', 'frucht', 'vegetable', 'gemüse', 'gemuese',
	'plant', 'pflanze', 'natural foods', 'whole food', 'superfood', 'staple food',
	'meat', 'fleisch', 'dairy', 'milchprodukt', 'tableware', 'geschirr', 'teller',
	'color', 'farbe', 'red', 'rot', 'green', 'grün', 'gruen', 'yellow', 'gelb',
	'close-up', 'nahaufnahme', 'still life photography', 'font', 'rectangle',
];
$genericMap = array_flip($generic);

$best = trim((string) ($labels[0]['description'] ?? ''));
foreach ($labels as $label) {
	$desc = trim((string) ($label['description'] ?? ''));
	if ($desc === '') continue;
	// Sehr unsichere Treffer überspringen.
	if (isset($label['score']) && (float) $label['score'] < 0.6) continue;
	if (!isset($genericMap[mb_strtolower($desc, 'UTF-8')])) {
		$best = $desc;
		break;
	}
}

respond(['term' => $best]);
