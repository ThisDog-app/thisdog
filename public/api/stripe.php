<?php
declare(strict_types=1);

/**
 * Meldungen von Stripe (Webhook) zu den Partnerplätzen. Im Stripe-Dashboard als Endpunkt
 * https://thisdog.app/api/stripe.php eintragen, mit den Ereignissen:
 *
 *   checkout.session.completed      bezahlt → Platz läuft, Verwaltungslink per Mail
 *   invoice.paid                    Monat bezahlt (auch jede Verlängerung) → läuft bis Ende des Zeitraums
 *   customer.subscription.updated   zum Monatsende gekündigt (oder Kündigung zurückgenommen)
 *   customer.subscription.deleted   Abo vorbei → Platz endet
 *
 * Jede Meldung trägt eine Unterschrift mit STRIPE_WEBHOOK_SECRET; ohne gültige wird nichts geändert. Stripe schickt
 * Meldungen mitunter doppelt oder in anderer Reihenfolge – jeder Schritt verträgt das.
 */

require_once __DIR__ . '/lib-services.php';
require_once __DIR__ . '/lib-stripe.php';
require_once __DIR__ . '/lib-mail.php';

$payload = (string) file_get_contents('php://input');
if (!stripe_verify($payload, (string) ($_SERVER['HTTP_STRIPE_SIGNATURE'] ?? ''))) respond(['error' => 'bad_signature'], 400);

$event = json_decode($payload, true);
$o = $event['data']['object'] ?? null;
if (!is_array($o)) respond(['error' => 'bad_payload'], 400);

$pdo = db();
$now = time();

/** Der Platz zu einer Meldung: über das Abo, sonst über die mitgegebene Nummer. */
function sponsor_of(PDO $pdo, ?string $subscription, $metaId): ?array
{
	if ($subscription) {
		$q = $pdo->prepare('SELECT * FROM sponsors WHERE subscription_id = ?');
		$q->execute([$subscription]);
		if ($r = $q->fetch()) return $r;
	}
	if ((int) $metaId > 0) {
		$q = $pdo->prepare('SELECT * FROM sponsors WHERE id = ?');
		$q->execute([(int) $metaId]);
		if ($r = $q->fetch()) return $r;
	}
	return null;
}

/** Ein Platz, der eben bezahlt wurde, läuft – außer der Betreiber hat ihn gesperrt. */
function activate(PDO $pdo, array $s, ?string $sub, ?string $customer, int $until): void
{
	$pdo->prepare("UPDATE sponsors SET status = CASE WHEN status = 'blocked' THEN status ELSE 'active' END,
		subscription_id = COALESCE(?, subscription_id), customer_id = COALESCE(?, customer_id),
		paid_until = MAX(COALESCE(paid_until, 0), ?), updated_at = ? WHERE id = ?")
		->execute([$sub, $customer, $until, time(), $s['id']]);
}

try {
	switch ((string) ($event['type'] ?? '')) {
		case 'checkout.session.completed':
			if (!in_array($o['payment_status'] ?? '', ['paid', 'no_payment_required'], true)) break;
			$s = sponsor_of($pdo, null, $o['metadata']['sponsor'] ?? $o['client_reference_id'] ?? 0);
			if ($s === null || $s['checkout_id'] !== ($o['id'] ?? null)) break;
			$first = $s['status'] === 'pending';
			// Bis die erste Rechnung gemeldet ist, gilt ein Monat; invoice.paid setzt das genaue Ende.
			activate($pdo, $s, $o['subscription'] ?? null, $o['customer'] ?? null, $now + 32 * 86400);
			if ($first) {
				$secret = new_secret();
				$pdo->prepare('UPDATE sponsors SET manage_hash = ? WHERE id = ?')->execute([secret_hash($secret), $s['id']]);
				$link = site_url() . '/partner/verwalten/' . $secret;
				try {
					send_mail($s['email'], 'Dein Partnerplatz bei ThisDog läuft',
						"Danke! „{$s['name']}“ steht ab sofort oben in den Adressen der ThisDog-App, gekennzeichnet als Anzeige.\n\n"
						. "Hier siehst du, wie oft der Platz gezeigt und geöffnet wurde, änderst deinen Text und kommst zu Rechnungen und Kündigung:\n$link\n\n"
						. "Bewahre den Link gut auf – er ist dein Zugang. Das Abo verlängert sich monatlich und ist jederzeit zum Monatsende kündbar.\n\nThisDog");
				} catch (Throwable $e) {
					error_log('[stella] Partner-Mail: ' . $e->getMessage());
				}
				notify_owner('Neuer Partnerplatz: ' . $s['name'], "{$s['advertiser']} hat einen Partnerplatz für „{$s['name']}“ gebucht (Gegend {$s['tile']}).\nText: {$s['text']}\n\nAnsehen und notfalls sperren: " . site_url() . '/admin-orte.php#partner');
			}
			break;

		case 'invoice.paid':
			$sub = $o['subscription'] ?? $o['parent']['subscription_details']['subscription'] ?? null;
			$meta = $o['subscription_details']['metadata']['sponsor'] ?? $o['parent']['subscription_details']['metadata']['sponsor'] ?? 0;
			$s = sponsor_of($pdo, is_string($sub) ? $sub : null, $meta);
			if ($s === null) break;
			$end = 0;
			foreach ($o['lines']['data'] ?? [] as $line) $end = max($end, (int) ($line['period']['end'] ?? 0));
			activate($pdo, $s, is_string($sub) ? $sub : null, $o['customer'] ?? null, $end > 0 ? $end : $now + 32 * 86400);
			break;

		case 'customer.subscription.updated':
			$s = sponsor_of($pdo, $o['id'] ?? null, $o['metadata']['sponsor'] ?? 0);
			if ($s === null) break;
			$cancels = !empty($o['cancel_at_period_end']) ? (int) ($o['current_period_end'] ?? $o['items']['data'][0]['current_period_end'] ?? 0) : (int) ($o['cancel_at'] ?? 0);
			$pdo->prepare('UPDATE sponsors SET cancels_at = ?, updated_at = ? WHERE id = ?')->execute([$cancels ?: null, $now, $s['id']]);
			break;

		case 'customer.subscription.deleted':
			$s = sponsor_of($pdo, $o['id'] ?? null, $o['metadata']['sponsor'] ?? 0);
			if ($s === null) break;
			$pdo->prepare("UPDATE sponsors SET status = CASE WHEN status = 'blocked' THEN status ELSE 'ended' END,
				paid_until = MIN(COALESCE(paid_until, ?), ?), updated_at = ? WHERE id = ?")->execute([$now, $now, $now, $s['id']]);
			break;
	}
} catch (Throwable $e) {
	error_log('[stella] Stripe-Meldung: ' . $e->getMessage());
	// 500: Stripe versucht es später noch einmal.
	respond(['error' => 'failed'], 500);
}
respond(['ok' => true]);
