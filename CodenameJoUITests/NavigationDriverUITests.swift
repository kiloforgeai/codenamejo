import XCTest

/// A UI test that takes its instructions at launch instead of at compile time.
///
/// The point is on-demand navigation. A conventional XCUITest hard-codes its taps,
/// so every new question about the app ("what's behind the gear?") costs an edit
/// and a rebuild. This target compiles **once**; what it does is decided by the
/// `UI_SCRIPT` environment variable, which Xcode forwards from any build setting
/// prefixed `TEST_RUNNER_`:
///
/// ```bash
/// xcodebuild test -project CodenameJo.xcodeproj -scheme CodenameJoUITests \
///   -destination 'id=<device-udid>' -allowProvisioningUpdates \
///   TEST_RUNNER_UI_SCRIPT='shot:launch;dump;tap:History;shot:history'
/// ```
///
/// `dump` is the load-bearing command: it attaches the accessibility tree, which
/// is how a caller that has never seen the screen learns what is tappable. Run
/// `dump` first, read the labels, then drive.
///
/// Commands are separated by `;`, arguments by `:` —
///
/// | Command | Effect |
/// |---|---|
/// | `dump` | attach the full accessibility hierarchy |
/// | `shot:<name>` | attach a screenshot |
/// | `tap:<label>` | tap the first element matching identifier or label, waiting for it to appear and become hittable |
/// | `press:<label>:<seconds>` | press and hold — the orb takes a tap now, but a long-press delete still needs it |
/// | `waitFor:<label>:<seconds>` | block until an element exists (fails if not) |
/// | `exists:<label>` | log whether an element is present, without failing |
/// | `type:<text>` | type into the focused field |
/// | `swipe:up\|down\|left\|right` | swipe the app window |
/// | `dismiss` | swipe a sheet down from the top edge |
/// | `back` | tap the first navigation-bar button |
/// | `wait:<seconds>` | sleep |
///
/// Nothing here is app-specific: no screen names, no assumptions about the
/// onboarding state. A device that is signed in and a fresh install both work,
/// because the caller reads `dump` and decides.
///
/// A step that can't find its target **fails the run** — `xcodebuild` exits
/// non-zero and the accessibility tree plus a screenshot are attached. `exists`
/// is the one deliberate exception, because probing is how a caller narrows down
/// a screen it can't see.
final class NavigationDriverUITests: XCTestCase {

    private var app: XCUIApplication!

    /// Long enough for a sheet to present, short enough that a wrong label
    /// doesn't cost a minute per step.
    private let defaultTimeout: TimeInterval = 8

    override func setUpWithError() throws {
        continueAfterFailure = false
        // UI_APP switches the target to another bundle, e.g. com.apple.shortcuts.
        if let bundle = ProcessInfo.processInfo.environment["UI_APP"], !bundle.isEmpty {
            app = XCUIApplication(bundleIdentifier: bundle)
        } else {
            app = XCUIApplication()
        }
        // Forwarded into the app under test rather than read there directly: the
        // runner gets `TEST_RUNNER_`-prefixed variables from `xcodebuild`, the app
        // it launches inherits nothing. Only names listed here cross the gap.
        for key in ["INJECT_AUDIO", "VALIDATION_RUN_ID", "VALIDATION_TURNS"] {
            if let value = ProcessInfo.processInfo.environment[key] {
                app.launchEnvironment[key] = value
            }
        }
        app.launch()
    }

    func testDriveScript() throws {
        // No script means "tour whatever is on screen and report" — the safe
        // default for a first run against an unknown state.
        let raw = ProcessInfo.processInfo.environment["UI_SCRIPT"]
            ?? "shot:launch;dump"
        log("script: \(raw)")

        for step in raw.split(separator: ";").map({ $0.trimmingCharacters(in: .whitespaces) })
        where !step.isEmpty {
            try perform(step)
        }
        attachScreenshot(named: "final")
    }

    // MARK: - Dispatch

    private func perform(_ step: String) throws {
        let parts = step.split(separator: ":", maxSplits: 2).map(String.init)
        let command = parts[0]
        let argument = parts.count > 1 ? parts[1] : ""
        let extra = parts.count > 2 ? parts[2] : ""
        log("→ \(step)")

        switch command {
        case "dump":
            attach(name: "hierarchy", string: app.debugDescription)

        case "shot":
            attachScreenshot(named: argument.isEmpty ? "shot" : argument)

        case "tap":
            let element = try require(argument)
            element.tap()

        case "press":
            let element = try require(argument)
            element.press(forDuration: TimeInterval(extra) ?? 1.5)

        case "waitFor":
            let timeout = TimeInterval(extra) ?? defaultTimeout
            if waitForElement(argument, timeout: timeout) == nil {
                attach(name: "hierarchy-at-failure", string: app.debugDescription)
                attachScreenshot(named: "failure")
                XCTFail("no element matching '\(argument)' after \(timeout)s")
                throw DriverError.notFound(argument)
            }

        case "exists":
            // Deliberately non-fatal: probing is how a caller narrows down a
            // screen it can't see, and a miss is information, not a failure.
            let element = find(argument)
            log("exists('\(argument)') = \(element?.exists ?? false)")

        case "type":
            app.typeText(argument)

        case "swipe":
            switch argument {
            case "up": app.swipeUp()
            case "down": app.swipeDown()
            case "left": app.swipeLeft()
            case "right": app.swipeRight()
            default: XCTFail("unknown swipe direction '\(argument)'")
            }

        case "dismiss":
            // Sheets here are presented modally with no visible close control on
            // every screen, so the gesture is the reliable route.
            let top = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.08))
            let bottom = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.9))
            top.press(forDuration: 0.05, thenDragTo: bottom)

        case "back":
            let button = app.navigationBars.buttons.firstMatch
            if button.exists { button.tap() } else { log("no navigation-bar button") }

        case "allowPermission":
            let alert = XCUIApplication(bundleIdentifier: "com.apple.springboard").alerts.firstMatch
            if alert.waitForExistence(timeout: 3) {
                guard !argument.isEmpty,
                      alert.staticTexts.matching(NSPredicate(format: "label CONTAINS[c] %@", argument)).firstMatch.exists,
                      alert.buttons["Allow"].exists else {
                    XCTFail("Unexpected system permission alert"); return
                }
                alert.buttons["Allow"].tap()
            }

        case "wait":
            Thread.sleep(forTimeInterval: TimeInterval(argument) ?? 1)

        case "tapAt":
            // Normalised x,y for controls that expose no usable label.
            let xy = argument.split(separator: ",").compactMap { Double($0) }
            guard xy.count == 2 else { XCTFail("tapAt wants x,y"); return }
            app.coordinate(withNormalizedOffset: CGVector(dx: xy[0], dy: xy[1])).tap()

        case "tapNth":
            // tapNth:<label>:<index> — the nth element matching a label or identifier.
            let index = Int(extra) ?? 0
            let matches = app.descendants(matching: .any)
                .matching(NSPredicate(format: "label == %@ OR identifier == %@", argument, argument))
            guard matches.count > index else {
                attach(name: "hierarchy-at-failure", string: app.debugDescription)
                XCTFail("only \(matches.count) matches for '\(argument)'")
                throw DriverError.notFound(argument)
            }
            matches.element(boundBy: index).tap()

        default:
            XCTFail("unknown command '\(command)' in step '\(step)'")
        }
    }

    // MARK: - Element lookup

    /// Find by accessibility identifier first, then by label, across the element
    /// types a SwiftUI screen actually exposes.
    ///
    /// SwiftUI is inconsistent about what an icon-only `Button` becomes — it can
    /// surface as a button, an image, or a bare `other` — so a single query is
    /// not enough. Ordered cheapest and most specific first.
    ///
    /// Returns only elements that exist *now*. Anything that needs to tolerate a
    /// screen still animating in goes through `waitForElement` instead.
    private func find(_ needle: String) -> XCUIElement? {
        let queries: [XCUIElementQuery] = [
            app.buttons, app.staticTexts, app.images, app.switches,
            app.textFields, app.secureTextFields, app.cells, app.otherElements
        ]
        for query in queries {
            let byIdentifier = query[needle]
            if byIdentifier.exists { return byIdentifier }
            // `matching` tests the element's own label. `containing` — which this
            // used to call — tests its *descendants*, so it silently missed every
            // element whose label is on the element itself, which for SwiftUI is
            // most of them.
            let byLabel = query.matching(NSPredicate(format: "label == %@", needle)).firstMatch
            if byLabel.exists { return byLabel }
        }
        // Last resort: a substring match, which catches labels that carry state
        // ("Settings, 2 items") without the caller having to guess the suffix.
        for query in queries {
            let fuzzy = query.matching(
                NSPredicate(format: "label CONTAINS[c] %@", needle)).firstMatch
            if fuzzy.exists { return fuzzy }
        }
        return nil
    }

    /// Poll `find` until something matches or the deadline passes.
    ///
    /// A single `XCUIElement.waitForExistence` can't do this job: which of the
    /// eight queries will match isn't known until one does, so there is no single
    /// element to wait on. Polling the whole lookup is the only version that
    /// actually waits.
    private func waitForElement(_ needle: String, timeout: TimeInterval) -> XCUIElement? {
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            if let element = find(needle) { return element }
            guard Date() < deadline else { return nil }
            Thread.sleep(forTimeInterval: 0.25)
        }
    }

    private func waitUntilHittable(_ element: XCUIElement, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            if element.isHittable { return true }
            guard Date() < deadline else { return false }
            Thread.sleep(forTimeInterval: 0.25)
        }
    }

    /// Resolve a target, waiting for it, or fail the run.
    ///
    /// Failure is a failure, not an `XCTSkip`. A skip leaves `xcodebuild` exiting
    /// 0, so a script that mistargeted its first tap and navigated nowhere would
    /// report success — the exact lie this driver exists to catch.
    private func require(_ needle: String) throws -> XCUIElement {
        guard let element = waitForElement(needle, timeout: defaultTimeout) else {
            // Attach the tree on failure — without it the log says "not found"
            // and the next run is another blind guess.
            attach(name: "hierarchy-at-failure", string: app.debugDescription)
            attachScreenshot(named: "failure")
            XCTFail("no element matching '\(needle)' after \(defaultTimeout)s; hierarchy attached")
            throw DriverError.notFound(needle)
        }
        guard waitUntilHittable(element, timeout: defaultTimeout) else {
            attach(name: "hierarchy-at-failure", string: app.debugDescription)
            attachScreenshot(named: "failure")
            XCTFail("'\(needle)' exists but never became hittable within \(defaultTimeout)s")
            throw DriverError.notHittable(needle)
        }
        return element
    }

    private enum DriverError: Error {
        case notFound(String)
        case notHittable(String)
    }

    // MARK: - Reporting

    private func log(_ message: String) {
        // Printed as well as attached: `xcodebuild` streams stdout, so a caller
        // watching the run sees progress without unpacking the result bundle.
        print("UIDRIVE \(message)")
    }

    private func attachScreenshot(named name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func attach(name: String, string: String) {
        print("UIDRIVE ---- \(name) ----\n\(string)")
        let attachment = XCTAttachment(string: string)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
