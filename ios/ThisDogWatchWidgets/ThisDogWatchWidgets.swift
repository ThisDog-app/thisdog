import SwiftUI
import WidgetKit

/// Komplikationen der Watch: die Woche, Hitze und was beim Hund ansteht.
@main
struct ThisDogWatchWidgets: WidgetBundle {
    var body: some Widget { DigestWidget() }
}
