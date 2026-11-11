import PhotosUI
import SwiftUI

/// Ein rundes Bild – oder, solange keins da ist, der Anfangsbuchstabe (Person) bzw. eine Pfote (Hund).
struct AvatarView: View {
    let image: UIImage?
    var name: String = ""
    var size: CGFloat = 42
    var isDog = false

    var body: some View {
        ZStack {
            if let image {
                Image(uiImage: image).resizable().scaledToFill()
            } else {
                Palette.soft
                if isDog || name.isEmpty {
                    LineIcon("hund", size: size * 0.56)
                        .foregroundStyle(Palette.accent)
                } else {
                    Text(String(name.prefix(1)).uppercased())
                        .font(.display(size * 0.45, weight: .semibold, relativeTo: .headline))
                        .foregroundStyle(Palette.accent)
                }
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .overlay(Circle().strokeBorder(Palette.line.opacity(image == nil ? 0 : 1), lineWidth: 1))
        .accessibilityHidden(true)
    }
}

/// Ein Avatar, den man antippt, um ein Foto zu wählen. Ist eins gesetzt, lässt es sich auch entfernen.
struct AvatarPicker: View {
    @Environment(DogStore.self) private var store
    let id: String
    var name: String = ""
    var size: CGFloat = 42
    var isDog = false
    var label: String

    @State private var item: PhotosPickerItem?
    @State private var asksAction = false
    @State private var picks = false

    var body: some View {
        let image = store.avatarImage(id)
        Button {
            if image == nil { picks = true } else { asksAction = true }
        } label: {
            AvatarView(image: image, name: name, size: size, isDog: isDog)
                .overlay(alignment: .bottomTrailing) {
                    LineIcon(image == nil ? "plus" : "kamera", size: max(14, size * 0.2))
                        .foregroundStyle(.white)
                        .frame(width: max(20, size * 0.3), height: max(20, size * 0.3))
                        .background(Palette.accent, in: Circle())
                        .overlay(Circle().strokeBorder(Palette.paper, lineWidth: 2))
                        .offset(x: size * 0.02, y: size * 0.02)
                }
                .contentTransition(.opacity)
                .animation(.snappy, value: image)
                .contentShape(.hoverEffect, Circle())
                .hoverEffect(.lift)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .accessibilityHint(image == nil ? String(localized: "Foto wählen") : String(localized: "Foto ändern oder entfernen"))
        .confirmationDialog(label, isPresented: $asksAction) {
            Button("Anderes Foto wählen") { picks = true }
            Button("Foto entfernen", role: .destructive) { withAnimation(.snappy) { store.setAvatar(id, photo: nil) } }
        }
        .photosPicker(isPresented: $picks, selection: $item, matching: .images, preferredItemEncoding: .compatible)
        .onChange(of: item) { _, new in
            guard let new else { return }
            Task {
                if let data = try? await new.loadTransferable(type: Data.self) {
                    withAnimation(.snappy) { store.setAvatar(id, photo: data) }
                }
                item = nil
            }
        }
    }
}
