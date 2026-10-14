import Foundation

enum AppInfo {
    /// Numeric App Store ID, from the App Store Connect app record.
    static let appStoreID = "6793888936"

    static var writeReviewURL: URL? {
        URL(string: "https://apps.apple.com/app/id\(appStoreID)?action=write-review")
    }

    static var appVersion: String {
        "\(shortVersion) (\(buildNumber))"
    }

    /// `CFBundleShortVersionString` alone — the marketing version, "1.4".
/// Kept apart from `appVersion` so a record can store version and build as separate fields.
    static var shortVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
    }

    /// `CFBundleVersion` alone — the build number, "231".
    static var buildNumber: String {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
    }

    /// The iOS version this is running on, "26.0.1".
/// `ProcessInfo` keeps this UIKit-free; `operatingSystemVersionString` is prose, not sortable.
    static var osVersion: String {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        return v.patchVersion == 0
            ? "\(v.majorVersion).\(v.minorVersion)"
            : "\(v.majorVersion).\(v.minorVersion).\(v.patchVersion)"
    }
}
