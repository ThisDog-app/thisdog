<?php
declare(strict_types=1);

/**
 * Support: der Gerätecode und die Anfragen.
 *
 * Gerätecode: 9 Zeichen in Dreiergruppen, z. B. „K7Q-M9X-A3T“, Crockford-Base32; die ersten acht
 * tragen 40 Bit, das neunte ist eine Prüfziffer (Summe der acht Werte, gewichtet 1–8, mod 31). Er nennt nur
 * App-Fassung, System und Geräteart – kein Gerät, kein Konto, keine Person.
 *
 *   Bit 39–38  Fassung des Codes (0)
 *   Bit 37–36  Plattform: 0 iOS, 1 iPadOS, 2 Android
 *   Bit 35–30  Hauptversion des Systems (0–63)
 *   Bit 29–27  Geräteart: 0 iPhone, 1 iPhone Duo, 2 iPad, 3 Android-Telefon, 4 Android-Tablet, 5 Android faltbar
 *   Bit 26–24  Arbeitsspeicher: 2^n GB (0 = 1 GB … 7 = 128 GB)
 *   Bit 23–20  App-Version, erste Zahl
 *   Bit 19–14  App-Version, zweite Zahl
 *   Bit 13–0   Build-Nummer
 */

const CODE_ALPHABET = '0123456789ABCDEFGHJKMNPQRSTVWXYZ';
const PLATFORMS = ['iOS', 'iPadOS', 'Android'];
const DEVICE_KINDS = ['iPhone', 'iPhone Duo', 'iPad', 'Android-Telefon', 'Android-Tablet', 'Android faltbar'];

function device_code_encode(int $platform, int $os, int $kind, int $ramLog2, int $major, int $minor, int $build): string
{
	$v = (0 << 38) | (($platform & 3) << 36) | (($os & 63) << 30) | (($kind & 7) << 27) | (($ramLog2 & 7) << 24)
		| (($major & 15) << 20) | (($minor & 63) << 14) | ($build & 16383);
	$chars = [];
	for ($i = 7; $i >= 0; $i--) $chars[] = ($v >> ($i * 5)) & 31;
	$sum = 0;
	foreach ($chars as $i => $c) $sum += $c * ($i + 1);
	$chars[] = $sum % 31;
	$s = implode('', array_map(fn($c) => CODE_ALPHABET[$c], $chars));
	return substr($s, 0, 3) . '-' . substr($s, 3, 3) . '-' . substr($s, 6, 3);
}

/** Gerätecode lesen; null, wenn er nicht stimmt. Verwechselbare Zeichen (O, I, L) werden wie bei Crockford gelesen. */
function device_code_decode(string $code): ?array
{
	$s = strtoupper(preg_replace('/[\s-]/', '', $code) ?? '');
	$s = strtr($s, ['O' => '0', 'I' => '1', 'L' => '1']);
	if (strlen($s) !== 9) return null;
	$vals = [];
	for ($i = 0; $i < 9; $i++) {
		$p = strpos(CODE_ALPHABET, $s[$i]);
		if ($p === false) return null;
		$vals[] = $p;
	}
	$sum = 0;
	for ($i = 0; $i < 8; $i++) $sum += $vals[$i] * ($i + 1);
	if ($sum % 31 !== $vals[8]) return null;
	$v = 0;
	for ($i = 0; $i < 8; $i++) $v = ($v << 5) | $vals[$i];
	if ((($v >> 38) & 3) !== 0) return null;
	$platform = ($v >> 36) & 3; $kind = ($v >> 27) & 7;
	return [
		'platform' => PLATFORMS[$platform] ?? '?',
		'os' => ($v >> 30) & 63,
		'device' => DEVICE_KINDS[$kind] ?? '?',
		'ram' => 1 << (($v >> 24) & 7),
		'version' => (($v >> 20) & 15) . '.' . (($v >> 14) & 63),
		'build' => $v & 16383,
	];
}

function device_code_text(?array $d): string
{
	return $d ? sprintf('ThisDog %s (%d), %s %d, %s, %d GB', $d['version'], $d['build'], $d['platform'], $d['os'], $d['device'], $d['ram']) : '';
}

const REQUEST_KINDS = ['frage' => 'Frage', 'problem' => 'Problem', 'idee' => 'Idee'];

/** Eine Anfrage anlegen: Nummer vergeben, Betreiber benachrichtigen (Antwort geht direkt an den Absender), Bestätigung schicken. */
function create_request(PDO $pdo, string $kind, string $email, string $text, string $code, ?int $account, string $via): string
{
	$device = device_code_decode($code);
	$pdo->prepare('INSERT INTO support_requests (kind, email, text, device_code, device, account_id, via, created_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?)')
		->execute([$kind, $email, $text, $device ? $code : '', device_code_text($device), $account, $via, time()]);
	$number = sprintf('T-%04d', (int) $pdo->lastInsertId());
	$pdo->prepare('UPDATE support_requests SET number = ? WHERE id = ?')->execute([$number, (int) $pdo->lastInsertId()]);

	$label = REQUEST_KINDS[$kind] ?? 'Anfrage';
	$body = "$label $number von $email\n" . ($device ? device_code_text($device) . " ($code)\n" : "Ohne Gerätecode\n") . ($via === 'app' ? "Aus der App\n" : "Über thisdog.app/support\n")
		. "\n" . $text . "\n\n— Antworten geht direkt an $email.\n" . rtrim((string) cfg('APP_URL', 'https://thisdog.app'), '/') . '/admin-support.php';
	notify_owner("[$number] $label: " . mb_strimwidth(preg_replace('/\s+/', ' ', $text), 0, 60, '…'), $body, $email);

	try {
		send_mail($email, "Deine Anfrage bei ThisDog ($number)",
			// Ohne den Text: Wer eine fremde Adresse einträgt, könnte sonst über thisdog.app beliebige Mails verschicken.
			"Hallo,\n\ndanke, deine Nachricht ist angekommen. Wir melden uns per E-Mail, meist innerhalb von zwei Tagen.\n\n"
			. "Nummer: $number\n\nThisDog");
	} catch (Throwable $e) {
		error_log('[stella] Bestätigung nicht zugestellt: ' . $e->getMessage());
	}
	return $number;
}
