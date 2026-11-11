# Sicherheitslücken melden

Bitte **keine öffentlichen Issues, Pull Requests oder Diskussionen** für Sicherheitsprobleme. Eine Lücke,
die öffentlich beschrieben ist, bevor sie behoben ist, gefährdet die Daten aller, die ThisDog benutzen.

Stattdessen eine Mail an **hey@thisdog.app** mit dem Betreff „Sicherheit“:

- was betroffen ist (iOS, watchOS, Android, Server unter `public/`, Webseite),
- wie es sich nachstellen lässt, mit Version bzw. Commit,
- welche Folgen du erwartest (etwa: fremde Rudeldaten lesbar, Anmeldung ohne Mail, Schlüssel abgreifbar).

Wir bestätigen den Eingang so bald wie möglich, halten dich über die Behebung auf dem Laufenden und nennen
dich auf Wunsch, wenn die Lücke geschlossen ist. Bitte gib uns angemessen Zeit, bevor du etwas
veröffentlichst.

## Was dazugehört

Besonders interessiert sind wir an allem, was die Ende-zu-Ende-Verschlüsselung der Rudeldaten aushebelt
(`ios/ThisDog/Crypto/`, `android/app/src/main/java/app/thisdog/crypto/`), an Zugriffen auf fremde Konten,
Rudel oder Notfallpässe (`public/api/`) und an Wegen, die Anmeldung oder die Betreiberseiten
(`public/admin*.php`) zu umgehen.

Bitte teste nur mit eigenen Konten und auf einem eigenen Server (siehe README, „Server lokal“), nicht mit
Daten anderer auf thisdog.app, und ohne Last, die den Betrieb stört.
