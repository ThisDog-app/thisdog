/**
 * Die Web-App von ThisDog gibt es nicht mehr; an ihrer Stelle steht die Webseite zur App.
 *
 * Wer die Web-App einmal geöffnet hatte, hat noch ihren Service Worker, der die alte App aus dem Speicher
 * des Browsers ausliefert. Dieser hier ersetzt ihn beim nächsten Besuch: Er löscht alles, was die alte App
 * zwischengespeichert hat, meldet sich ab und lädt die offenen Seiten neu.
 */
self.addEventListener('install', () => self.skipWaiting());
self.addEventListener('activate', (event) => {
	event.waitUntil((async () => {
		for (const key of await caches.keys()) await caches.delete(key);
		await self.registration.unregister();
		for (const client of await self.clients.matchAll({ type: 'window' })) client.navigate(client.url);
	})());
});
