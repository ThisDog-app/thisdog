import XCTest

/// Keine Prüfung, sondern ein Werkzeug für Bildschirmfotos: Es startet die App mit Vorführdaten und dreht das
/// Gerät ins Querformat – das kann sonst nur Device Hub. Danach hält es 20 Sekunden still, damit
/// `simctl io screenshot` aufnehmen kann. Startargumente kommen aus der Umgebung `AUFNAHME_ARGS`.
final class Aufnahmen: XCTestCase {
    @MainActor
    func testQuerformat() throws {
        let app = XCUIApplication()
        app.launchArguments = (ProcessInfo.processInfo.environment["AUFNAHME_ARGS"] ?? "-beispiel -tab hund")
            .split(separator: " ").map(String.init)
        XCUIDevice.shared.orientation = ProcessInfo.processInfo.environment["AUFNAHME_LAGE"] == "hoch" ? .portrait : .landscapeLeft
        app.launch()
        sleep(20)
    }

    /// Startet die App, scrollt um `AUFNAHME_SCROLL` (Anteil der Bildschirmhöhe) nach oben und schreibt das
    /// Bildschirmfoto nach `AUFNAHME_DATEI` – für Listen, deren Anfang hinter einer Karte liegt.
    @MainActor
    func testGescrollt() throws {
        let env = ProcessInfo.processInfo.environment
        let app = XCUIApplication()
        app.launchArguments = (env["AUFNAHME_ARGS"] ?? "-beispiel -tab gassi").split(separator: " ").map(String.init)
        XCUIDevice.shared.orientation = .portrait
        app.launch()
        sleep(10)
        let amount = Double(env["AUFNAHME_SCROLL"] ?? "0.3") ?? 0.3
        let from = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.75))
        from.press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.75 - amount)),
                   withVelocity: .slow, thenHoldForDuration: 0.6)
        sleep(2)
        if let path = env["AUFNAHME_DATEI"] {
            try XCUIScreen.main.screenshot().pngRepresentation.write(to: URL(fileURLWithPath: path))
        }
    }

    /// Tippt nacheinander auf Knöpfe mit den Beschriftungen aus `AUFNAHME_TIPPEN` (mit „|“ getrennt) und schreibt nach
    /// jedem Schritt ein Bildschirmfoto nach `AUFNAHME_DATEI`-<n>.png – um einen Ablauf wie das Onboarding anzusehen.
    @MainActor
    func testTippen() throws {
        let env = ProcessInfo.processInfo.environment
        let app = XCUIApplication()
        app.launchArguments = (env["AUFNAHME_ARGS"] ?? "").split(separator: " ").map(String.init)
        XCUIDevice.shared.orientation = .portrait
        app.launch()
        sleep(3)
        let base = env["AUFNAHME_DATEI"] ?? NSTemporaryDirectory() + "tippen"
        try XCUIScreen.main.screenshot().pngRepresentation.write(to: URL(fileURLWithPath: base + "-0.png"))
        for (i, label) in (env["AUFNAHME_TIPPEN"] ?? "").split(separator: "|").enumerated() {
            // Systemabfragen (Mitteilungen, Standort) gehören dem Springboard, nicht der App.
            let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
            let button = app.buttons[String(label)].firstMatch
            let system = springboard.buttons[String(label)].firstMatch
            if button.waitForExistence(timeout: 8) { button.tap() }
            else if system.exists { system.tap() }
            else { print("Nicht gefunden: \(label)") }
            sleep(UInt32(env["AUFNAHME_WARTEN"] ?? "4") ?? 4)
            try XCUIScreen.main.screenshot().pngRepresentation.write(to: URL(fileURLWithPath: base + "-\(i + 1).png"))
        }
    }

    /// Safari (eine Seite ist schon offen): scrollt um `AUFNAHME_SCROLL` und schreibt zwei Bildschirmfotos im Abstand
    /// von zwei Sekunden nach `AUFNAHME_DATEI`-1.png und -2.png – um zu sehen, ob sich ein Video bewegt.
    @MainActor
    func testSafari() throws {
        let env = ProcessInfo.processInfo.environment
        let safari = XCUIApplication(bundleIdentifier: "com.apple.mobilesafari")
        safari.activate()
        sleep(3)
        let amount = Double(env["AUFNAHME_SCROLL"] ?? "0.3") ?? 0.3
        safari.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.8))
            .press(forDuration: 0.05, thenDragTo: safari.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.8 - amount)),
                   withVelocity: .slow, thenHoldForDuration: 0.6)
        sleep(4)
        let base = env["AUFNAHME_DATEI"] ?? "/tmp/safari"
        try XCUIScreen.main.screenshot().pngRepresentation.write(to: URL(fileURLWithPath: base + "-1.png"))
        sleep(2)
        try XCUIScreen.main.screenshot().pngRepresentation.write(to: URL(fileURLWithPath: base + "-2.png"))
    }

    /// Erlaubt Mitteilungen im Simulator (der Dialog lässt sich sonst nur von Hand bestätigen).
    @MainActor
    func testMitteilungenErlauben() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-beispiel", "-mitteilungen"]
        app.launch()
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let allow = springboard.buttons["Erlauben"]
        if allow.waitForExistence(timeout: 8) { allow.tap() }
        sleep(2)
    }
}
