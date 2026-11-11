import PhotosUI
import SwiftUI

/// Der erste Start: lernt den Hund kennen und bereitet alles vor, was später gebraucht wird:
/// Standort für die Runden, Mitteilungen für Erinnerungen, Konto fürs Rudel, Wiederherstellungsschlüssel.
/// Bis auf den Namen lässt sich alles überspringen und später nachholen.
struct OnboardingScreen: View {
    enum Step: Int, CaseIterable {
        case name, details, walks, reminders, pack, key, done
    }

    var finish: () -> Void

    @Environment(DogStore.self) private var store
    @Environment(Account.self) private var account
    @Environment(Services.self) private var services
    @Environment(WalkRecorder.self) private var recorder

    @State private var step: Step = OnboardingScreen.firstStep
    @State private var name = ""
    @State private var breed = ""
    @State private var sex = ""
    @State private var knowsBirth = false
    @State private var birth = Calendar.current.date(byAdding: .year, value: -2, to: Date()) ?? Date()
    @State private var photoItem: PhotosPickerItem?
    @State private var photo: UIImage?
    @State private var alreadyInPack = false
    @State private var recovery: String?
    @State private var keySaved = false
    @State private var scans = false
    @State private var showsEmail = false
    @FocusState private var nameFocus: Bool
    /// Wie viel Platz der Inhalt braucht und wie viel da ist: Das Logo nimmt sich nur, was übrig bleibt.
    @State private var contentHeight: CGFloat = 0
    @State private var regionHeight: CGFloat = 0

    private static var firstStep: Step {
        #if DEBUG
        let args = ProcessInfo.processInfo.arguments
        if let i = args.firstIndex(of: "-schritt"), i + 1 < args.count, let n = Int(args[i + 1]), let s = Step(rawValue: n) { return s }
        #endif
        return .name
    }

    private var dog: String { name.trimmingCharacters(in: .whitespaces).isEmpty ? String(localized: "dein Hund") : name.trimmingCharacters(in: .whitespaces) }
    private var dogGenitive: String { dog == String(localized: "dein Hund") ? String(localized: "deinen Hund") : dog }
    private var signedIn: Bool { if case .signedIn = account.state { true } else { false } }

    var body: some View {
        @Bindable var account = account
        VStack(spacing: 0) {
            ProgressLeash(progress: CGFloat(step.rawValue + 1) / CGFloat(Step.allCases.count))
                .frame(height: 44)
                .padding(.top, 8)
            ZStack(alignment: .bottom) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        content
                    }
                    .padding(.horizontal, 24)
                    .padding(.top, 24)
                    .frame(maxWidth: 520, alignment: .leading)
                    .frame(maxWidth: .infinity)
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { contentHeight = $0 }
                    .id(step)
                    .transition(.asymmetric(insertion: .move(edge: .trailing).combined(with: .opacity),
                                            removal: .move(edge: .leading).combined(with: .opacity)))
                }
                .scrollDismissesKeyboard(.interactively)
                // Stella begleitet durch den ganzen Ablauf; wo der Platz nicht reicht, tritt sie zurück.
                if logoSide >= 90 {
                    StellaMark(wiggle: name.count + step.rawValue * 1000)
                        .frame(width: logoSide, height: logoSide)
                        .padding(.bottom, 12)
                        .transition(.opacity)
                        .allowsHitTesting(false)
                }
            }
            .frame(maxHeight: .infinity)
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { regionHeight = $0 }
            .animation(.snappy, value: logoSide)
            buttons
                .padding(.horizontal, 24)
                .padding(.bottom, 16)
                .frame(maxWidth: 520)
        }
        .background(Palette.soft.ignoresSafeArea())
        .tint(Palette.accent)
        #if DEBUG
        .onAppear {
            let args = ProcessInfo.processInfo.arguments
            if let i = args.firstIndex(of: "-hundname"), i + 1 < args.count { name = args[i + 1] }
        }
        #endif
        .onChange(of: photoItem) {
            Task {
                guard let data = try? await photoItem?.loadTransferable(type: Data.self) else { return }
                photo = PickedPhoto.image(data, maxPixel: 1200)
                store.setAvatar(Avatar.dog, photo: data)
            }
        }
        // Anmeldelink aus der Mail: Sobald das Konto steht, geht es weiter.
        .onChange(of: signedIn) { _, now in
            // Entsteht das Konto beim Einladen im Rudel-Bildschirm, geht es erst nach dessen Schließen weiter.
            if now, step == .pack, !account.presentsPack { Task { await afterSignIn() } }
        }
        // Ein Einladungslink öffnet das Rudel auch hier.
        .sheet(isPresented: $account.presentsPack) {
            PackScreen()
        }
        .onChange(of: account.presentsPack) { _, open in
            guard !open, signedIn else { return }
            if alreadyInPack || account.currentPack.map({ $0.members.count > 1 }) == true, store.hasProfile {
                finish()
            } else if !alreadyInPack, step == .pack {
                // Eingeladen: jetzt den Schlüssel sichern, falls alle Telefone einmal weg sind.
                go(account.recoveryCode != nil ? .key : .done)
            }
        }
        .sheet(isPresented: $scans) {
            // Erst schließen, dann den Link öffnen: Zwei Blätter zugleich zeigt iOS nicht.
            InviteScannerSheet { url in
                Task { try? await Task.sleep(for: .milliseconds(500)); account.open(url) }
            }
        }
        .sheet(isPresented: Binding(get: { recovery != nil }, set: { if !$0 { recovery = nil } })) {
            if let recovery { RecoverySheet(code: recovery) { keySaved = true } }
        }
    }

    /// Wunschgröße je Schritt, begrenzt durch den Platz unter dem Inhalt.
    private var logoSide: CGFloat {
        let wish: CGFloat = switch step {
        case .name: 300
        case .details: 220
        case .walks, .reminders: 340
        case .pack: 200
        case .key: 300
        case .done: 240
        }
        return min(wish, regionHeight - contentHeight - 28)
    }

    // MARK: Inhalt

    @ViewBuilder
    private var content: some View {
        switch step {
        case .name: nameStep
        case .details: detailsStep
        case .walks:
            title(String(localized: "Zeit für eure erste Runde."))
            copy(String(localized: "ThisDog merkt sich euren Weg und zeigt dir Wiesen und Hundezonen in der Nähe. Dafür fragen wir gleich nach deinem Standort. Aufgezeichnet wird nur, wenn du eine Runde startest."))
        case .reminders:
            title(String(localized: "Damit nichts untergeht."))
            copy(String(localized: "Impfung, Wurmkur, Tierarzt: ThisDog erinnert dich rechtzeitig. Dafür fragen wir gleich, ob wir dir Mitteilungen schicken dürfen."))
        case .pack: packStep
        case .key:
            title(String(localized: "Falls alle Telefone weg sind."))
            copy(String(localized: "Eure Daten sind so verschlüsselt, dass nicht einmal wir sie lesen können. Darum gibt es einen Schlüssel, mit dem du jederzeit wieder an alles kommst. Heb ihn einmal gut auf."))
            if keySaved {
                Label("Gesichert", icon: "haken").font(.body.weight(.semibold)).foregroundStyle(Palette.accent)
            }
        case .done: doneStep
        }
    }

    private func title(_ text: String) -> some View {
        Text(text)
            .font(.display(34, weight: .medium))
            .foregroundStyle(Palette.ink)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func copy(_ text: String) -> some View {
        Text(text)
            .font(.body)
            .foregroundStyle(Palette.ink2)
            .fixedSize(horizontal: false, vertical: true)
    }

    /// Der erste Eindruck: Stella schaut zu dir hoch und will wissen, mit wem sie es zu tun hat.
    private var nameStep: some View {
        let typed = name.trimmingCharacters(in: .whitespaces)
        return Group {
            title(typed.isEmpty ? String(localized: "Wie heißt dein Hund?") : String(localized: "Hallo, \(typed)!"))
                .animation(.snappy, value: typed)
            copy(String(localized: "Schön, dass ihr da seid. Der Rest geht schnell, und alles andere kannst du auch später eintragen."))
            HStack(spacing: 14) {
                PhotosPicker(selection: $photoItem, matching: .images, preferredItemEncoding: .compatible) {
                    AvatarView(image: photo, name: name.isEmpty ? " " : name, size: 64, isDog: true)
                        .overlay(Circle().strokeBorder(Palette.accent.opacity(0.35), lineWidth: 1.5))
                        .overlay(alignment: .bottomTrailing) {
                            LineIcon("kamera", size: 22)
                                .foregroundStyle(.white)
                                .padding(6)
                                .background(Palette.accent, in: Circle())
                        }
                }
                .accessibilityLabel("Foto auswählen")
                TextField("Name", text: $name)
                    .font(.display(24, weight: .medium))
                    .textContentType(.name)
                    .submitLabel(.next)
                    .focused($nameFocus)
                    .padding(14)
                    .background(Palette.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .onSubmit { if canContinue { next() } }
            }
            .padding(.top, 6)
            Button("Wir sind schon in einem Rudel") {
                alreadyInPack = true
                go(.pack)
            }
            .font(.subheadline.weight(.medium))
            .padding(.top, 6)
        }
    }

    private var detailsStep: some View {
        Group {
            title(String(localized: "Erzähl uns von \(dog)."))
            copy(String(localized: "Damit Futtermenge, Ratgeber und Erinnerungen zu \(dogGenitive) passen. Ungefähr reicht."))
            TextField("Rasse, zum Beispiel Schnauzer", text: $breed)
                .padding(14)
                .background(Palette.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            Picker("Geschlecht", selection: $sex) {
                Text("Hündin").tag("f")
                Text("Rüde").tag("m")
                Text("Keine Angabe").tag("")
            }
            .pickerStyle(.segmented)
            Toggle("Geburtstag bekannt", isOn: $knowsBirth.animation(.snappy))
                .padding(.top, 4)
            if knowsBirth {
                DatePicker("Geboren am", selection: $birth, in: ...Date(), displayedComponents: .date)
            }
        }
    }

    @ViewBuilder
    private var packStep: some View {
        title(alreadyInPack ? String(localized: "Dann holen wir euch dazu.") : String(localized: "Wer kümmert sich noch um \(dogGenitive)?"))
        if alreadyInPack {
            copy(String(localized: "Scanne den QR-Code auf einem Telefon, das schon im Rudel ist. Oder öffne den Einladungslink, den du bekommen hast."))
            if showsEmail || account.codeFor != nil {
                SignInForm(intro: String(localized: "Mit deiner E-Mail-Adresse kommst du an dein bisheriges Konto. Ein Passwort brauchst du nicht."))
            } else {
                Button("Ich habe schon ein Konto mit E-Mail") { withAnimation(.snappy) { showsEmail = true } }
                    .font(.subheadline.weight(.medium))
            }
        } else {
            copy(String(localized: "Partner, Eltern, Hundesitter: Im Rudel seht ihr alle dieselben Termine und Runden. Ein Link oder QR-Code genügt, ohne Passwort und ohne E-Mail."))
        }
    }

    private var doneStep: some View {
        Group {
            title(String(localized: "\(dog.prefix(1).uppercased() + dog.dropFirst()) wartet schon."))
            copy(String(localized: "Zwei Dinge für später, wenn du magst:"))
            VStack(alignment: .leading, spacing: 14) {
                hint(String(localized: "Notfallpass"), String(localized: "Ein QR-Code am Halsband, falls \(dog) einmal wegläuft. Du findest ihn im Reiter Hund."))
                hint(String(localized: "Hund in der Nähe"), String(localized: "Spielt \(dog) auf der Wiese mit einem anderen Hund? Tippt beide unter Gassi im Reiter Freunde darauf, dann seid ihr verbunden."))
            }
            .padding(.top, 4)
        }
    }

    private func hint(_ head: String, _ text: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(head).font(.display(18, weight: .medium, relativeTo: .body)).foregroundStyle(Palette.ink)
            Text(text).font(.subheadline).foregroundStyle(Palette.ink2).fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: Knöpfe

    @ViewBuilder
    private var buttons: some View {
        VStack(spacing: 10) {
            switch step {
            case .name:
                primary(String(localized: "Weiter"), enabled: canContinue) { next() }
            case .details:
                primary(String(localized: "Weiter")) { next() }
            case .walks:
                primary(String(localized: "Standort erlauben")) { recorder.locateOnce(); next() }
                later { next() }
            case .reminders:
                primary(String(localized: "Mitteilungen erlauben")) {
                    Task {
                        _ = await services.reminders.enable()
                        services.apply(store)
                        next()
                    }
                }
                later { next() }
            case .pack:
                if alreadyInPack {
                    if signedIn, account.currentPack.map({ $0.members.count > 1 }) == true {
                        primary(String(localized: "Weiter")) { Task { await afterSignIn() } }
                    } else {
                        primary(String(localized: "QR-Code scannen")) { scans = true }
                    }
                    Button("Zurück") { alreadyInPack = false; go(.name) }
                        .font(.subheadline.weight(.medium))
                        .frame(minHeight: 36)
                } else {
                    primary(String(localized: "Jemanden einladen")) { account.presentsPack = true }
                    later { go(signedIn && account.recoveryCode != nil ? .key : .done) }
                }
            case .key:
                if keySaved {
                    primary(String(localized: "Weiter")) { next() }
                } else {
                    primary(String(localized: "Schlüssel ansehen")) { recovery = account.recoveryCode ?? demoCode }
                    later { next() }
                }
            case .done:
                primary(String(localized: "Los geht's")) { finish() }
            }
        }
    }

    private var demoCode: String? {
        #if DEBUG
        RecoveryCode.encode(.init(size: .bits256))
        #else
        nil
        #endif
    }

    private func primary(_ text: String, enabled: Bool = true, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(text).frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
        .disabled(!enabled)
    }

    private func later(action: @escaping () -> Void) -> some View {
        Button("Später", action: action)
            .font(.subheadline.weight(.medium))
            .frame(minHeight: 36)
    }

    private var canContinue: Bool { !name.trimmingCharacters(in: .whitespaces).isEmpty }

    // MARK: Ablauf

    private func go(_ s: Step) {
        withAnimation(.snappy) { step = s }
    }

    private func next() {
        if step == .details || step == .name { saveProfile() }
        var target = Step(rawValue: step.rawValue + 1) ?? .done
        // Ohne Konto gibt es keinen Schlüssel zu sichern.
        if target == .key, !signedIn { target = .done }
        go(target)
    }

    private func saveProfile() {
        var p = store.profile
        p.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        p.breed = breed.trimmingCharacters(in: .whitespaces)
        p.sex = sex
        p.birthdate = knowsBirth ? Day(date: birth).iso : ""
        store.save(p)
    }

    /// Nach dem Anmelden: abgleichen. War der Hund schon im Rudel, ist alles da; sonst weiter zum Schlüssel.
    private func afterSignIn() async {
        await account.sync()
        // Im Rudel kommt der Hund vom Rudel: Nie nach seinem Namen fragen – wer gerade „Wie heißt du?“ beantwortet hat,
        // tippt sonst den eigenen ein, und der ginge an alle. Fehlt das Profil noch, kommt es mit dem nächsten Abgleich.
        if alreadyInPack {
            finish()
        } else {
            go(account.recoveryCode != nil ? .key : .done)
        }
    }
}

/// Der Fortschritt als Leine: Sie wächst von links nach rechts, an der Spitze ein Punkt.
private struct ProgressLeash: View {
    var progress: CGFloat

    var body: some View {
        GeometryReader { g in
            let points = Self.points(size: g.size)
            ZStack {
                LeashShape(points: points)
                    .stroke(Palette.accent.opacity(0.25), style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
                LeashShape(points: points)
                    .trim(from: 0, to: progress)
                    .stroke(Palette.accent, style: StrokeStyle(lineWidth: 2, lineCap: .round))
            }
            .animation(.easeInOut(duration: 0.5), value: progress)
        }
        .accessibilityHidden(true)
    }

    private static func points(size: CGSize) -> [CGPoint] {
        let mid = size.height / 2, left: CGFloat = 24, width = size.width - 48
        return (0...28).map { i in
            let u = CGFloat(i) / 28
            return CGPoint(x: left + width * u, y: mid + sin(u * 11) * 5 + sin(u * 4.3 + 1) * 6)
        }
    }
}

/// Stella als Logo aus einer Linie. Sie wippt leicht und freut sich über jeden Buchstaben und jeden
/// Schritt; bei „Bewegung reduzieren“ bleibt sie still.
struct StellaMark: View {
    var wiggle: Int

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var breathes = false

    var body: some View {
        Image("StellaMark")
            .resizable()
            .scaledToFit()
            .foregroundStyle(Palette.accent)
            .rotationEffect(.degrees(breathes ? 1.5 : -1.5), anchor: .bottom)
            .keyframeAnimator(initialValue: 0.0, trigger: wiggle) { view, angle in
                view.rotationEffect(.degrees(angle), anchor: .bottom)
            } keyframes: { _ in
                KeyframeTrack {
                    SpringKeyframe(reduceMotion ? 0 : -5, duration: 0.1)
                    SpringKeyframe(reduceMotion ? 0 : 4, duration: 0.14)
                    SpringKeyframe(0, duration: 0.2)
                }
            }
            .accessibilityHidden(true)
            .onAppear {
                guard !reduceMotion else { return }
                withAnimation(.easeInOut(duration: 1.6).repeatForever(autoreverses: true)) { breathes = true }
            }
    }
}
