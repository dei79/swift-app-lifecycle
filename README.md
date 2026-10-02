# swift-app-lifecycle

Launch at login and automatic crash recovery for macOS apps, distributed as a Swift package.

Requires macOS 13 or later and Swift 6.0 or later. No third-party dependencies.

## Products

- **AppLifecycle**: `LoginItem` and an observable `CrashRecovery` controller.
- **AppLifecycleRecoveryHelper**: a separate executable embedded in your application bundle.

The helper must run outside the main process so it can survive an application crash. Adding the library dependency alone does not embed the helper.

## Add the package

For local development, add the package to your app's `Package.swift`:

```swift
dependencies: [
    .package(path: "../swift-app-lifecycle")
]
```

Add its library product to the application target:

```swift
.product(name: "AppLifecycle", package: "swift-app-lifecycle")
```

Adjust the path to your checkout. For a published repository, replace the path dependency with that repository's Git URL and a release version. In Xcode, add the local package and select the `AppLifecycle` product for the app target.

## Connect the application lifecycle

Keep one recovery controller alive for the lifetime of the app. Start it early in application initialization so subsequent startup crashes can be recovered.

```swift
import AppKit
import AppLifecycle

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let recovery = CrashRecovery()

    func applicationDidFinishLaunching(_ notification: Notification) {
        recovery.start()
        // Initialize the remaining application services here.
    }

    func setLaunchAtLogin(_ enabled: Bool) throws {
        try LoginItem.setEnabled(enabled, recovery: recovery)
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // Disarm only after your application has decided to allow termination.
        recovery.shutdown()
        return .terminateNow
    }

    func applicationWillTerminate(_ notification: Notification) {
        recovery.shutdown()
    }
}
```

Call `shutdown()` before an updater deliberately terminates the process. It is idempotent and permanently stops that controller; create a new controller if a previously approved exit is later cancelled and monitoring must resume. Call it before releasing the controller to remove its timer and notification observer.

`CrashRecovery` conforms to `ObservableObject`. Observe `errorMessage` and `isMonitoring` to display status. `helperProcessIdentifier` is available for diagnostics.

## Login item state

```swift
switch LoginItem.state {
case .enabled:
    break // macOS permits launch at login.
case .requiresApproval:
    LoginItem.openSystemSettings() // Call in response to the user's settings action.
case .disabled:
    break
}
```

`LoginItem.isEnabled` includes pending approval, which is useful for a settings toggle. Recovery only runs when `LoginItem.state == .enabled`. Enable login items in response to a user action. Registration errors are thrown to the caller.

Pass the recovery controller to `setEnabled` for immediate updates. Otherwise the controller checks the system status every five seconds. Autostart can also be used independently of recovery.

## Embed and sign the helper

After assembling your `.app` bundle, run this script from the package checkout. It builds, copies and signs the helper:

```sh
bash /path/to/swift-app-lifecycle/Tools/embed-helper.sh \
    /path/to/Example.app '-'
```

For a universal production build, supply the same signing identity and architectures as the host application:

```sh
bash /path/to/swift-app-lifecycle/Tools/embed-helper.sh \
    /path/to/Example.app 'Developer ID Application: Your Name (TEAMID)' \
    --arch arm64 --arch x86_64
```

Set `SANDBOX=1` for a sandboxed host. This applies the included app-sandbox and inheritance entitlements to the child executable. The host app needs its own sandbox entitlements and must use the same signing team.

**Sign the containing app after embedding the helper**, then follow your application's normal distribution and notarization process. The script does not sign the outer bundle. Ad-hoc signing (`-`) is intended for local tests.

If your existing build already handles copying and signing executables, build `AppLifecycleRecoveryHelper` and copy it into `Contents/MacOS/AppLifecycleRecoveryHelper`. Do not place it in a resource bundle. `CrashRecovery(helperName:)` supports a custom executable filename if your build requires one. The helper's command-line protocol is internal; build the library and helper from the same package revision.

## Migrating an existing implementation

1. Replace the application's local login item and recovery types with `import AppLifecycle`.
2. Replace global recovery singleton calls with the retained controller owned by your app delegate or service container.
3. Pass that controller to `LoginItem.setEnabled` and retain the existing start and intentional-shutdown hooks.
4. Replace the old helper build, copy and signing steps with the package helper.
5. Remove the duplicated monitor and budget targets after migrating their consumers.

The history remains at `Application Support/<host bundle identifier>/crash-recovery.json`, inside the host container when sandboxed. Its format is a JSON array of timestamps. Keep the existing host bundle identifier and history file to preserve restart counts across migration.

## Recovery behavior

- Monitoring is disabled in Debug builds and outside `.app` bundles.
- The helper confirms readiness before `start()` returns, with a two-second timeout. This bounded wait occurs on the main thread.
- Kernel process events distinguish crash signals (`SIGABRT`, `SIGBUS`, `SIGFPE`, `SIGILL`, `SIGSEGV`, `SIGTRAP`, `SIGSYS`) from normal termination.
- Normal exit, nonzero normal exit, `SIGTERM`, and `SIGKILL` do not trigger recovery. Hangs are not detected.
- After a crash, the helper waits two seconds and rechecks login authorization, bundle existence and whether the app is already running.
- The helper records each attempt before reopening the app without activating it. At most three automatic starts are allowed within a rolling 60-second window.
- Both processes observe logout/shutdown. If logout is cancelled, a surviving app can resume monitoring after 30 seconds.
- A failed helper is retried after a 30-second cooldown.

There is no recovery before the helper is armed, or if the helper and host both die. macOS controls login authorization and application launching; the package does not suppress system crash reports.

## Tests

```sh
swift test
swift test -c release
swift build -c release --product AppLifecycleRecoveryHelper
```

The tests cover actual kernel process exits, disarming, pipe EOF, crash classification, persisted restart limits and the startup handshake.

An optional end-to-end smoke test creates and registers a temporary app, exercises real crashes and relaunches, and unregisters it afterwards:

```sh
python3 Tools/recovery/smoke.py \
    "$(swift build -c release --show-bin-path)/AppLifecycleRecoveryHelper"

python3 Tools/recovery/smoke.py \
    "$(swift build -c release --show-bin-path)/AppLifecycleRecoveryHelper" --sandbox
```

Run this in an interactive macOS session. It changes only the temporary fixture's login registration and may require approval in System Settings. Test your actual signed application separately, including its updater and distribution environment.
