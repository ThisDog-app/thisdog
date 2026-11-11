<?php
declare(strict_types=1);

/**
 * Bezahlung der Partnerplätze über Stripe – ohne Bibliothek, mit den drei Aufrufen, die es braucht:
 * Kasse öffnen (Checkout Session), Kundenbereich öffnen (Billing Portal) und ein Abo beenden (Sperre durch den
 * Betreiber). Was danach passiert, meldet Stripe an api/stripe.php.
 *
 * Konfiguration: STRIPE_SECRET_KEY, STRIPE_WEBHOOK_SECRET; SPONSOR_PRICE_CENTS (Monatspreis), STRIPE_AUTOMATIC_TAX
 * (true, wenn Stripe Tax eingerichtet ist). STRIPE_API_BASE nur für Tests.
 * Zahlarten (Karte, EPS, SEPA, Apple Pay …) stellt man im Stripe-Dashboard ein, nicht hier.
 */

require_once __DIR__ . '/lib.php';

final class StripeError extends RuntimeException {}

function stripe_ready(): bool
{
	return (string) cfg('STRIPE_SECRET_KEY', '') !== '' && (string) cfg('STRIPE_WEBHOOK_SECRET', '') !== '';
}

/** Ein Aufruf der Stripe-API. Parameter in Stripes Formularschreibweise (a[b][c]=…). */
function stripe_call(string $method, string $path, array $params = []): array
{
	$key = (string) cfg('STRIPE_SECRET_KEY', '');
	if ($key === '') throw new StripeError('STRIPE_SECRET_KEY fehlt.');
	$url = rtrim((string) cfg('STRIPE_API_BASE', 'https://api.stripe.com'), '/') . $path;
	$ch = curl_init($method === 'GET' && $params ? $url . '?' . http_build_query($params) : $url);
	curl_setopt_array($ch, [
		CURLOPT_CUSTOMREQUEST => $method,
		CURLOPT_RETURNTRANSFER => true,
		CURLOPT_TIMEOUT => 20,
		CURLOPT_CONNECTTIMEOUT => 8,
		CURLOPT_HTTPHEADER => ['Authorization: Bearer ' . $key, 'Stripe-Version: 2024-06-20'],
	]);
	if ($method !== 'GET') curl_setopt($ch, CURLOPT_POSTFIELDS, http_build_query($params));
	$body = curl_exec($ch);
	$status = (int) curl_getinfo($ch, CURLINFO_RESPONSE_CODE);
	$err = curl_error($ch);
	unset($ch);
	$data = is_string($body) ? json_decode($body, true) : null;
	if (!is_array($data) || $status >= 400) {
		throw new StripeError('Stripe ' . $path . ': ' . ($data['error']['message'] ?? ($err !== '' ? $err : "HTTP $status")));
	}
	return $data;
}

/** Kasse für einen Partnerplatz: Monatsabo, jederzeit zum Monatsende kündbar. Gibt die Adresse der Kasse zurück. */
function stripe_checkout(array $sponsor, int $priceCents, string $base): array
{
	$params = [
		'mode' => 'subscription',
		'customer_email' => $sponsor['email'],
		'client_reference_id' => (string) $sponsor['id'],
		'metadata' => ['sponsor' => (string) $sponsor['id']],
		'subscription_data' => ['metadata' => ['sponsor' => (string) $sponsor['id']]],
		'line_items' => [[
			'quantity' => 1,
			'price_data' => [
				'currency' => 'eur',
				'unit_amount' => $priceCents,
				'recurring' => ['interval' => 'month'],
				'product_data' => ['name' => 'ThisDog Partnerplatz: ' . $sponsor['name']],
			],
		]],
		'billing_address_collection' => 'required',
		'tax_id_collection' => ['enabled' => 'true'],
		'locale' => 'de',
		'expires_at' => time() + 1800,
		'success_url' => $base . '/partner?danke={CHECKOUT_SESSION_ID}',
		'cancel_url' => $base . '/partner?abgebrochen=' . $sponsor['id'],
	];
	if (filter_var(cfg('STRIPE_AUTOMATIC_TAX', false), FILTER_VALIDATE_BOOLEAN)) $params['automatic_tax'] = ['enabled' => 'true'];
	$s = stripe_call('POST', '/v1/checkout/sessions', $params);
	return ['id' => (string) $s['id'], 'url' => (string) $s['url']];
}

/** Stripes Kundenbereich: Zahlart ändern, Rechnungen, kündigen. */
function stripe_portal(string $customer, string $returnUrl): string
{
	$s = stripe_call('POST', '/v1/billing_portal/sessions', ['customer' => $customer, 'return_url' => $returnUrl]);
	return (string) $s['url'];
}

/** Ein Abo sofort beenden (Sperre durch den Betreiber). */
function stripe_cancel(string $subscription): void
{
	stripe_call('DELETE', '/v1/subscriptions/' . rawurlencode($subscription));
}

/**
 * Prüft die Unterschrift einer Meldung von Stripe (Kopf Stripe-Signature: t=…,v1=…). Höchstens fünf Minuten alt,
 * damit eine mitgeschnittene Meldung nicht später noch einmal eingespielt werden kann.
 */
function stripe_verify(string $payload, string $header, int $tolerance = 300): bool
{
	$secret = (string) cfg('STRIPE_WEBHOOK_SECRET', '');
	if ($secret === '' || $header === '') return false;
	$t = null; $sigs = [];
	foreach (explode(',', $header) as $part) {
		[$k, $v] = array_pad(explode('=', trim($part), 2), 2, '');
		if ($k === 't') $t = (int) $v;
		if ($k === 'v1') $sigs[] = $v;
	}
	if ($t === null || abs(time() - $t) > $tolerance) return false;
	$want = hash_hmac('sha256', $t . '.' . $payload, $secret);
	foreach ($sigs as $s) if (hash_equals($want, $s)) return true;
	return false;
}
