import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Profiles: sets of assignments, and when each is the one in use — chosen by hand, or
/// switched on by an app, a game, or the Dota 2 hero being played.
struct ProfilesPage: View {
    @ObservedObject var model: AppModel

    @State private var nameDraft = ""
    @FocusState private var nameFocused: Bool

    private var selection: Profile? { model.editing.flatMap { model.config.profile(named: $0) } }

    var body: some View {
        HStack(spacing: 0) {
            list.frame(width: 268)
            Rectangle().fill(Theme.stroke).frame(width: 1).padding(.top, -Theme.titleBarOverlap)
            ScrollView {
                Group {
                    if let profile = selection { detail(profile) } else { defaultDetail }
                }
                .padding(.horizontal, 28)
                .padding(.top, 18)
                .padding(.bottom, 28)
                .frame(maxWidth: 720, alignment: .leading)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .onAppear {
            nameDraft = selection?.name ?? ""
            model.refreshDotaLaunchOption()
        }
        .onChange(of: model.editingProfile) { nameDraft = selection?.name ?? "" }
    }

    // MARK: List

    private var list: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Profiles").font(.system(size: 24, weight: .bold))
                Spacer()
                Button { model.addProfile() } label: { Image(systemName: "plus").font(.system(size: 12, weight: .bold)).frame(width: 28, height: 28) }
                    .buttonStyle(.plain)
                    .background(Circle().fill(Theme.accent))
                    .help("New profile")
            }
            .padding(.horizontal, 20)
            .padding(.top, 18)
            .padding(.bottom, 16)
            ScrollView {
                VStack(spacing: 4) {
                    ProfileCard(
                        name: Profile.defaultName, detail: "What everything starts from",
                        isSelected: selection == nil, isActive: model.activeProfile == nil,
                        onSelect: { model.editingProfile = nil })
                    ForEach(Array(model.config.profiles.enumerated()), id: \.element.name) { index, profile in
                        ProfileCard(
                            name: profile.name, detail: model.rules(of: profile),
                            isSelected: selection?.name == profile.name, isActive: model.activeProfile == profile.name,
                            onSelect: { model.editingProfile = profile.name },
                            onMove: { model.moveProfile(profile.name, by: $0) },
                            canMoveUp: index > 0, canMoveDown: index < model.config.profiles.count - 1,
                            onDelete: { delete(profile) })
                    }
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 12)
            }
            Rectangle().fill(Theme.stroke).frame(height: 1)
            VStack(alignment: .leading, spacing: 8) {
                Toggle(isOn: $model.config.autoSwitch) {
                    Text("Switch profiles automatically").font(.system(size: 12.5, weight: .medium))
                }
                .toggleStyle(.switch)
                .controlSize(.small)
                Text(model.config.autoSwitch
                     ? "Apps, games and Dota heroes switch their profiles on. Where several want to, the one higher in this list wins."
                     : "Profiles change only when you change them: here, from the menu bar, or with a button.")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(14)
        }
        .background(Theme.sidebar.opacity(0.6).padding(.top, -Theme.titleBarOverlap))
    }

    private func delete(_ profile: Profile) {
        if !profile.bindings.isEmpty || profile.isAutomatic {
            let alert = NSAlert()
            alert.messageText = "Delete the “\(profile.name)” profile?"
            alert.informativeText = "Its \(profile.bindings.count) assignment\(profile.bindings.count == 1 ? "" : "s") go with it. This can't be undone."
            alert.addButton(withTitle: "Delete")
            alert.addButton(withTitle: "Cancel")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }
        model.deleteProfile(profile.name)
    }

    // MARK: In use

    /// Whether a profile is the one in use, with the means to make it so.
    private func useRow(_ name: String?) -> some View {
        let isActive = model.activeProfile == name
        return HStack(spacing: 8) {
            if isActive {
                StatusChip(text: "In use now — \(model.profileReason)", color: Theme.good, dot: true)
                if model.isOverruled {
                    Button("Back to Automatic") { model.resumeAutomaticProfile() }
                        .buttonStyle(PillButtonStyle(compact: true))
                        .help("You chose this profile by hand over the one the app or game in front asks for. This goes back to that one.")
                }
            } else {
                StatusChip(text: "Not in use", color: Theme.tertiary, dot: true)
                Button("Use Now") { model.useProfile(name) }
                    .buttonStyle(PillButtonStyle(kind: .primary, compact: true))
                    .help("Switch to this profile by hand. It stays until you switch again, or an app, game or hero switches its own profile on.")
            }
            Spacer(minLength: 0)
        }
    }

    private func editButtons(_ name: String?) -> some View {
        HStack(spacing: 8) {
            Button { model.editingProfile = name; model.page = .keyboard } label: { Label("Edit Keyboard", systemImage: "keyboard") }
                .buttonStyle(PillButtonStyle())
            Button { model.editingProfile = name; model.page = .mouse } label: { Label("Edit Mouse", systemImage: "computermouse") }
                .buttonStyle(PillButtonStyle())
        }
    }

    private func counted(_ bindings: [Trigger: Assignment]) -> String {
        if bindings.isEmpty { return "Nothing assigned yet." }
        let keys = bindings.keys.filter(\.isOrdinaryKey).count
        let buttons = bindings.count - keys
        var parts: [String] = []
        if buttons > 0 { parts.append("\(buttons) button\(buttons == 1 ? "" : "s")") }
        if keys > 0 { parts.append("\(keys) key\(keys == 1 ? "" : "s")") }
        return parts.joined(separator: " and ") + " assigned."
    }

    // MARK: Default

    private var defaultDetail: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 10) {
                Text(Profile.defaultName).font(.system(size: 22, weight: .bold))
                // With nothing else to be in use, there is nothing to say.
                if !model.config.profiles.isEmpty { useRow(nil) }
            }
            section("Assignments") {
                Text(counted(model.config.bindings)).font(.system(size: 13, weight: .medium))
                Text("What the buttons and keys do when no other profile is in use — and what other profiles start from, unless they are told not to.")
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                editButtons(nil)
            }
            if model.config.profiles.isEmpty {
                section("Profiles") {
                    Text("A profile is another set of assignments: one for work, one for a game, one for a single Dota hero. Switch between them from the menu bar or with a button, or let them switch on by themselves when their app or game is in front.")
                        .font(.system(size: 12.5))
                        .foregroundStyle(Theme.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Button { model.addProfile() } label: { Label("New Profile", systemImage: "plus") }
                        .buttonStyle(PillButtonStyle(kind: .primary))
                }
            } else {
                quickSwitching
            }
        }
    }

    private var quickSwitching: some View {
        section("Switching by hand") {
            Text("From the keyboard icon in the menu bar; with any button or key given the **Profile** action (next, previous, or a particular one); or from a terminal with `rzmacro profile next`.")
                .font(.system(size: 12))
                .foregroundStyle(Theme.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: A profile

    private func detail(_ profile: Profile) -> some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 10) {
                TextField("Profile name", text: $nameDraft)
                    .textFieldStyle(.plain)
                    .font(.system(size: 22, weight: .bold))
                    .focused($nameFocused)
                    .onSubmit { commitName(profile.name) }
                    .onChange(of: nameFocused) { _, focused in if !focused { commitName(profile.name) } }
                useRow(profile.name)
            }

            section("Assignments") {
                Text(counted(profile.bindings)).font(.system(size: 13, weight: .medium))
                HStack(spacing: 10) {
                    Text("Based on").font(.system(size: 12.5)).foregroundStyle(Theme.secondary)
                    Picker("", selection: Binding(get: { profile.basedOn ?? "" }, set: { new in model.updateProfile(profile.name) { $0.basedOn = new.isEmpty ? nil : new } })) {
                        Text(Profile.defaultName).tag(Profile.defaultName)
                        ForEach(bases(for: profile), id: \.self) { Text($0).tag($0) }
                        Divider()
                        Text("Nothing").tag("")
                    }
                    .labelsHidden()
                    .fixedSize()
                }
                Text(profile.basedOn == nil
                     ? "This profile stands alone: a button it doesn't mention does what it does out of the box."
                     : "A button this profile doesn't mention does what \(profile.basedOn!) says. Only what you change here is different.")
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                editButtons(profile.name)
            }

            section("Switch it on automatically") {
                appRules(profile)
                Rectangle().fill(Theme.stroke).frame(height: 1)
                heroRules(profile)
            }
            .opacity(model.config.autoSwitch ? 1 : 0.5)
            .overlay(alignment: .topTrailing) {
                if !model.config.autoSwitch {
                    Text("Automatic switching is off").font(.system(size: 11, weight: .medium)).foregroundStyle(Theme.warning)
                }
            }

            quickSwitching

            Button("Delete Profile") { delete(profile) }.buttonStyle(PillButtonStyle(kind: .danger))
        }
    }

    /// The profiles this one could be based on: any that isn't itself, or based on it.
    private func bases(for profile: Profile) -> [String] {
        model.config.profiles.map(\.name).filter { name in
            name != profile.name && !model.config.chain(for: name).contains(profile.name)
        }
    }

    /// Applies the name field; an empty or already-used name is put back.
    private func commitName(_ name: String) {
        guard nameDraft != name else { return }
        if !model.renameProfile(name, to: nameDraft) { nameDraft = name }
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionLabel(title)
            VStack(alignment: .leading, spacing: 12) { content() }.panel()
        }
    }

    // MARK: Apps and games

    private func appRules(_ profile: Profile) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Apps and games").font(.system(size: 13, weight: .medium))
                Spacer()
                addAppMenu(profile)
            }
            if profile.apps.isEmpty {
                Text("Add an app or a game, and this profile is in use whenever it is.")
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.tertiary)
            } else {
                VStack(spacing: 2) {
                    ForEach(profile.apps, id: \.self) { bundleID in
                        HStack(spacing: 9) {
                            BundleIcon(bundleID: bundleID)
                            Text(AppModel.appName(bundleID)).font(.system(size: 12.5, weight: .medium))
                            if runningIDs.contains(bundleID) {
                                Text(NSWorkspace.shared.frontmostApplication?.bundleIdentifier == bundleID ? "in front" : "running")
                                    .font(.system(size: 11))
                                    .foregroundStyle(Theme.good)
                            }
                            Spacer()
                            IconButton(symbol: "xmark", help: "Remove") { model.updateProfile(profile.name) { $0.apps.removeAll { $0 == bundleID } } }
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                    }
                }
                .padding(4)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.black.opacity(0.28)))
                HStack(spacing: 10) {
                    Segmented(options: [(false, "While it is in front"), (true, "While it is running")],
                              selection: Binding(get: { profile.whileRunning }, set: { new in model.updateProfile(profile.name) { $0.whileRunning = new } }))
                        .frame(width: 330)
                    Spacer(minLength: 0)
                }
                Text(profile.whileRunning
                     ? "In use from the moment it starts until it quits, also while you are in another app."
                     : "In use only while it is the app you are in; switch to another app and the profile steps aside.")
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var runningIDs: Set<String> {
        Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
    }

    /// What is running now, games first — the quickest way to say "this one".
    private func addAppMenu(_ profile: Profile) -> some View {
        let running = NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular && $0.bundleIdentifier != nil && $0.bundleIdentifier != Bundle.main.bundleIdentifier && !profile.apps.contains($0.bundleIdentifier!) }
        var seen = Set<String>()
        let unique = running.filter { seen.insert($0.bundleIdentifier!).inserted }
            .sorted { ($0.localizedName ?? "").localizedCaseInsensitiveCompare($1.localizedName ?? "") == .orderedAscending }
        let games = unique.filter(isGame)
        let apps = unique.filter { !isGame($0) }
        let offersDota = model.dota.found && !profile.apps.contains(DotaWatcher.bundleID) && !games.contains { $0.bundleIdentifier == DotaWatcher.bundleID }
        func add(_ bundleID: String) { model.updateProfile(profile.name) { $0.apps.append(bundleID) } }
        return Menu {
            if !games.isEmpty || offersDota {
                Section("Games") {
                    ForEach(games, id: \.processIdentifier) { app in
                        Button("\(app.localizedName ?? app.bundleIdentifier!) — running now") { add(app.bundleIdentifier!) }
                    }
                    if offersDota { Button("Dota 2") { add(DotaWatcher.bundleID) } }
                }
            }
            Section("Running now") {
                ForEach(apps, id: \.processIdentifier) { app in
                    Button(app.localizedName ?? app.bundleIdentifier!) { add(app.bundleIdentifier!) }
                }
            }
            Divider()
            Button("Choose an App…") {
                let panel = NSOpenPanel()
                panel.allowedContentTypes = [.application]
                panel.directoryURL = URL(fileURLWithPath: "/Applications")
                guard panel.runModal() == .OK, let url = panel.url, let bundleID = Bundle(url: url)?.bundleIdentifier, !profile.apps.contains(bundleID) else { return }
                add(bundleID)
            }
        } label: {
            AddLabel()
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
    }

    // MARK: Dota 2 heroes

    private func heroRules(_ profile: Profile) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Dota 2 heroes").font(.system(size: 13, weight: .medium))
                Spacer()
                addHeroMenu(profile)
            }
            if profile.heroes.isEmpty {
                Text("Add heroes, and this profile is in use while you are playing one of them. It comes before a profile for Dota 2 itself.")
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                FlowLayout(spacing: 6) {
                    ForEach(profile.heroes, id: \.self) { hero in
                        HStack(spacing: 5) {
                            Text(DotaHeroes.title(hero)).font(.system(size: 12, weight: .medium))
                            Button { model.updateProfile(profile.name) { $0.heroes.removeAll { $0 == hero } } } label: {
                                Image(systemName: "xmark").font(.system(size: 8, weight: .bold)).foregroundStyle(Theme.secondary)
                            }
                            .buttonStyle(.plain)
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(Capsule().fill(model.dota.hero == hero ? Theme.good.opacity(0.25) : Theme.accent.opacity(0.22)))
                    }
                }
            }
            if !profile.heroes.isEmpty || model.dota.installed { DotaPanel(model: model) }
        }
    }

    private func addHeroMenu(_ profile: Profile) -> some View {
        let available = DotaHeroes.all.filter { !profile.heroes.contains($0.name) }
        func add(_ hero: String) { model.updateProfile(profile.name) { $0.heroes.append(hero) } }
        // A hundred and some heroes: by first letter, a handful of letters at a time.
        let ranges: [ClosedRange<Character>] = ["A"..."C", "D"..."K", "L"..."N", "O"..."R", "S"..."S", "T"..."Z"]
        return Menu {
            if let hero = model.dota.hero, !profile.heroes.contains(hero) {
                Button("\(DotaHeroes.title(hero)) — playing now") { add(hero) }
                Divider()
            }
            ForEach(ranges, id: \.lowerBound) { range in
                Menu(range.lowerBound == range.upperBound ? String(range.lowerBound) : "\(range.lowerBound) – \(range.upperBound)") {
                    ForEach(available.filter { range.contains($0.title.first ?? " ") }, id: \.name) { hero in
                        Button(hero.title) { add(hero.name) }
                    }
                }
            }
        } label: {
            AddLabel()
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
    }
}

/// Dota 2 hero detection: whether it is set up, what it hears, and what it still needs.
private struct DotaPanel: View {
    @ObservedObject var model: AppModel

    private var status: DotaWatcher.Status { model.dota }

    private var state: (text: String, color: Color) {
        if !status.found { return ("Dota 2 was not found in the Steam library on this Mac.", Theme.tertiary) }
        if !status.installed { return ("Hero detection is not set up yet.", Theme.warning) }
        if let error = status.error { return ("Can't listen for the game on port \(status.port.map(String.init) ?? "?"): \(error)", Theme.danger) }
        if let hero = status.hero { return ("Playing \(DotaHeroes.title(hero)).", Theme.good) }
        if status.receiving { return ("Connected to the game. The hero shows once you have picked one.", Theme.good) }
        if status.running { return ("Dota 2 is running but not reporting.", Theme.warning) }
        return ("Ready. Waiting for Dota 2 to start.", Theme.secondary)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Circle().fill(state.color).frame(width: 7, height: 7)
                Text(state.text).font(.system(size: 12, weight: .medium)).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                if status.found && !status.installed {
                    Button("Set Up") { model.setUpDota() }.buttonStyle(PillButtonStyle(kind: .primary, compact: true))
                } else if status.installed {
                    Button("Remove") { model.removeDota() }
                        .buttonStyle(PillButtonStyle(compact: true))
                        .help("Take RZMacro's settings file out of the game again and stop listening.")
                }
            }
            if let error = model.dotaError {
                Text(error).font(.system(size: 11.5)).foregroundStyle(Theme.danger).fixedSize(horizontal: false, vertical: true)
            }
            if status.found && !status.installed {
                Text("Dota 2 can tell other programs what is happening in your match — Valve's own Game State Integration, the one stream overlays use. Set Up adds a small settings file to the game that makes it tell RZMacro, on this Mac only, which hero you are playing. Nothing else is asked for, and nothing leaves the Mac.")
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else if status.installed {
                launchOption
                if status.running && !status.receiving && status.error == nil {
                    Text("The game reads the settings file when it starts: quit and start Dota 2 once after setting this up.")
                        .font(.system(size: 11.5))
                        .foregroundStyle(Theme.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.black.opacity(0.28)))
    }

    /// The game only reports when started with its launch option; whether it is, where that can be told.
    @ViewBuilder private var launchOption: some View {
        if model.dotaLaunchOption == true {
            Label("Launch option \(DotaWatcher.launchOption) is set.", systemImage: "checkmark.circle.fill")
                .font(.system(size: 11.5))
                .foregroundStyle(Theme.secondary)
        } else {
            VStack(alignment: .leading, spacing: 6) {
                Label(
                    model.dotaLaunchOption == false
                        ? "One thing is missing: the game only reports when started with a launch option."
                        : "The game only reports when started with a launch option.",
                    systemImage: model.dotaLaunchOption == false ? "exclamationmark.triangle.fill" : "info.circle")
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(model.dotaLaunchOption == false ? Theme.warning : Theme.secondary)
                Text("In Steam, right-click Dota 2 → Properties → General → Launch Options, add the text below, and restart the game.")
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 8) {
                    Text(DotaWatcher.launchOption)
                        .font(.system(size: 12, design: .monospaced))
                        .textSelection(.enabled)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Color.white.opacity(0.07)))
                    Button("Copy") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(DotaWatcher.launchOption, forType: .string)
                    }
                    .buttonStyle(PillButtonStyle(compact: true))
                    Button("Check Again") { model.refreshDotaLaunchOption() }.buttonStyle(PillButtonStyle(compact: true))
                }
            }
        }
    }
}

/// The small "+ Add" capsule that opens a menu.
private struct AddLabel: View {
    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "plus").font(.system(size: 9, weight: .bold))
            Text("Add").font(.system(size: 11.5, weight: .medium))
        }
        .foregroundStyle(Theme.text)
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(Capsule().fill(Color.white.opacity(0.08)))
        .contentShape(Capsule())
    }
}

/// An app's icon, from its bundle identifier.
struct BundleIcon: View {
    let bundleID: String
    var size: CGFloat = 22

    var body: some View {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: url.path)).resizable().frame(width: size, height: size)
        } else {
            Image(systemName: "app.dashed").foregroundStyle(Theme.tertiary).frame(width: size, height: size)
        }
    }
}

/// A profile in the list: its name, when it comes on, and whether it is in use.
private struct ProfileCard: View {
    let name: String
    let detail: String
    let isSelected: Bool
    let isActive: Bool
    let onSelect: () -> Void
    var onMove: ((Int) -> Void)?
    var canMoveUp = false
    var canMoveDown = false
    var onDelete: (() -> Void)?

    @State private var hovering = false

    var body: some View {
        HStack(spacing: 8) {
            Circle().fill(isActive ? Theme.good : Color.clear).frame(width: 7, height: 7)
                .help(isActive ? "In use now" : "")
            VStack(alignment: .leading, spacing: 4) {
                Text(name).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                Text(detail)
                    .font(.system(size: 11))
                    .foregroundStyle(isSelected ? Theme.text.opacity(0.75) : Theme.tertiary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            if hovering, let onMove {
                HStack(spacing: 0) {
                    IconButton(symbol: "arrow.up", help: "Move up: wins over the profiles below when several want to switch on") { onMove(-1) }.disabled(!canMoveUp)
                    IconButton(symbol: "arrow.down", help: "Move down") { onMove(1) }.disabled(!canMoveDown)
                    if let onDelete { IconButton(symbol: "trash", help: "Delete this profile", action: onDelete) }
                }
            }
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(isSelected ? Theme.accent.opacity(0.24) : (hovering ? Color.white.opacity(0.05) : Color.clear)))
        .contentShape(Rectangle())
        .onTapGesture(perform: onSelect)
        .onHover { hovering = $0 }
    }
}
