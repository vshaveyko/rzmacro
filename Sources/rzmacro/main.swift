import AppKit

let arguments = Array(CommandLine.arguments.dropFirst())

func usage() -> Never {
    print("""
    rzmacro \(Daemon.version) — macro keys and synced lighting for Razer keyboards and mice on macOS

    Open RZMacro.app to configure everything in a window. From the command line:

      show                   open the configuration window
      status                 devices, permissions, loaded bindings
      reload                 re-read the config file now
      check [file]           validate the config file without touching the driver
      light <effect> [colours] [period=<s>] [brightness=<0-100>] [reverse]
                             set lighting on all devices in sync, until the config changes:
                             off | static <colour> | breathing <colour…> | spectrum | wave
      light brightness <N|+N|-N>
      press <button> [ms]    run what a button is assigned to, as if it were held that long
      sniff [seconds] [all]  print button events as you press them ("all" adds raw reports
                             of ordinary typing, for bringing up a new device)
      mode <keyboard|mouse|all> <normal|driver|auto>
                             temporarily force a device mode
      raw <keyboard|mouse> <class> <id> <size> [args…]
                             send a raw Razer protocol command (hex bytes)
      keys                   list key names usable in shortcuts
      config                 print the config file path
      daemon                 run the driver without opening the window
      quit                   stop the driver

    config: \(Paths.configFile.path)
    log:    \(Paths.logFile.path)
    """)
    exit(64)
}

/// Kept alive for the life of the process; NSApplication only holds its delegate weakly.
private var appDelegate: AppDelegate?

func runApp(showWindow: Bool) -> Never {
    // One driver per login session. Launching the app again just brings up the window.
    if let fd = Client.connect() {
        close(fd)
        if showWindow { _ = Client.run(["show"]) } else { print("rzmacro is already running") }
        exit(0)
    }
    let app = NSApplication.shared
    let daemon = Daemon()
    daemon.start()
    let delegate = AppDelegate(daemon: daemon, showWindowAtLaunch: showWindow)
    appDelegate = delegate
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    app.run()
    exit(0)
}

switch arguments.first {
case "daemon":
    runApp(showWindow: false)
case nil where isatty(STDIN_FILENO) == 0:
    // Launched as an app (Finder, `open`, login item).
    runApp(showWindow: true)
case "status", "reload", "quit", "sniff", "mode", "raw", "light", "show", "snapshot", "press":
    exit(Client.run(arguments))
case "check":
    do {
        let file = arguments[safe: 1].map { URL(fileURLWithPath: $0) } ?? Paths.configFile
        let config = try Config.load(from: file)
        // What the app would write back must read as the same configuration.
        let written = try JSONSerialization.data(withJSONObject: config.jsonObject)
        guard try Config.parse(written) == config else { throw ConfigError("internal error: the configuration does not survive being saved") }
        print("ok: \(config.bindings.count) bindings, \(config.apps.count) app profiles, \(config.macros.count) macros")
    } catch {
        print("error: \(error)")
        exit(1)
    }
case "keys":
    print("modifiers: " + Keys.modifiers.map(\.name).joined(separator: " "))
    print("keys:      " + Keys.table.map(\.0).joined(separator: " "))
    print("aliases:   " + (Keys.aliases.map { "\($0.key)=\($0.value)" } + Keys.modifierAliases.map { "\($0.key)=\($0.value)" }).sorted().joined(separator: " "))
    print("media:     " + MediaKey.allCases.map(\.name).joined(separator: " "))
case "config":
    print(Paths.configFile.path)
case "version", "--version":
    print(Daemon.version)
default:
    usage()
}
