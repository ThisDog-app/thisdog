<?php
/**
 * Vorlage für die Konfiguration.
 *
 * Diese Datei nach «stella-daten/config.php» kopieren – also NEBEN den
 * Webordner, nicht hinein. Dort ist sie über das Netz nicht erreichbar und
 * überlebt jedes vollständige Hochladen.
 *
 *   /pfad/stella-daten/config.php   ← hierhin
 *   /pfad/httpdocs/                 ← Inhalt von public/
 *
 * Liegt sie noch unter api/, wird sie weiterhin gelesen und beim ersten
 * Zugriff automatisch an den sicheren Ort kopiert.
 *
 * Sie enthält Zugangsdaten und gehört niemals ins Repository.
 */

return [
	// Google Cloud Vision, für die Bilderkennung im Food-Check.
	// Schlüssel: https://console.cloud.google.com/apis/credentials
	'GOOGLE_VISION_API_KEY' => '',

	// Nur Anfragen von diesen Adressen dürfen die Schnittstellen nutzen.
	'ALLOWED_ORIGINS' => [
		'https://example.org',
		'https://www.example.org',
	],

	// Obergrenze für die Bildanalyse je IP und Stunde.
	'VISION_RATE_LIMIT' => 40,

	// Adresse der App. Steht im Anmeldelink, der per Mail verschickt wird.
	// Leer lassen: Dann wird der Hostname der Anfrage benutzt – hinter einem
	// Proxy ist das nicht immer die Adresse, unter der Besucher ankommen.
	'APP_URL' => 'https://example.org',

	// Postfach für die Anmeldemails. Gewöhnliches SMTP mit STARTTLS.
	// Benutzername ist die volle Adresse, das Passwort das des Postfachs.
	'SMTP_HOST' => 'smtp.example.org',
	'SMTP_PORT' => 587,
	'SMTP_USER' => 'app@example.org',
	'SMTP_PASS' => '',

	// Absender. Sollte zum Postfach oben passen, sonst weisen viele
	// Empfänger die Nachricht ab.
	'MAIL_FROM' => 'app@example.org',
	'MAIL_FROM_NAME' => 'ThisDog',

	// Wohin Nachrichten an den Betreiber gehen – etwa, wenn sich jemand zum
	// ersten Mal anmeldet. Leer lassen: Dann gilt der Absender von oben.
	// Auf «none» setzen, um sie ganz abzustellen.
	'NOTIFY_TO' => 'admin@example.org',

	// Wer die Übersicht unter /admin.php sehen darf. Maßgeblich ist die
	// Adresse, mit der man in der App angemeldet ist – ein eigenes Passwort
	// gibt es nicht. Leere Liste heißt: niemand, die Seite meldet «nicht
	// gefunden».
	'ADMIN_EMAILS' => [
		'admin@example.org',
	],

	// Ordner für Daten, die ein Hochladen überstehen müssen (Suchstatistik).
	// Leer lassen: Dann wird automatisch «stella-daten» neben dem Webordner
	// verwendet. Nur ausfüllen, wenn der Server einen anderen Pfad braucht –
	// dann einen absoluten Pfad ausserhalb des Webordners angeben.
	'DATA_DIR' => '',

	// Mitteilungen an die Rudelmitglieder (Apple Push). Der Schlüssel entsteht
	// unter developer.apple.com › Certificates, IDs & Profiles › Keys mit
	// „Apple Push Notifications service“. Die .p8-Datei nach stella-daten legen,
	// nie in den Webordner. Fehlt ein Wert, wird nichts verschickt; der
	// Abgleich funktioniert trotzdem.
	'APNS_KEY_ID' => '',
	'APNS_TEAM_ID' => '',    // Team-ID des Apple-Entwicklerkontos (wie DEVELOPMENT_TEAM in ios/project.yml)
	'APNS_KEY_FILE' => '',   // z. B. /home/kunde/stella-daten/AuthKey_ABC123.p8
	'APNS_TOPIC' => 'app.thisDog',   // Bundle-ID der iOS-App

	// Partnerplätze (thisdog.app/partner): Bezahlung über Stripe. Geheimer Schlüssel unter dashboard.stripe.com ›
	// Entwickler › API-Schlüssel (sk_live_…, zum Ausprobieren sk_test_…). Der Webhook-Schlüssel (whsec_…) entsteht
	// beim Anlegen des Endpunkts https://example.org/api/stripe.php mit den Ereignissen checkout.session.completed,
	// invoice.paid, customer.subscription.updated und customer.subscription.deleted. Fehlt einer, bleibt die Buchung zu.
	// Zahlarten (Karte, EPS, SEPA-Lastschrift, Apple Pay …) und den Kundenbereich stellt man im Dashboard ein.
	'STRIPE_SECRET_KEY' => '',
	'STRIPE_WEBHOOK_SECRET' => '',
	'SPONSOR_PRICE_CENTS' => 2900,      // Preis je Gegend und Monat in Cent
	'STRIPE_AUTOMATIC_TAX' => false,    // true, wenn Stripe Tax eingerichtet ist
];
