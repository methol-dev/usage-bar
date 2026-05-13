import Foundation

private final class BundleLocator {}

func usageBarResourceBundle(
    mainBundle: Bundle = .main,
    finderBundle: Bundle = Bundle(for: BundleLocator.self)
) -> Bundle? {
    let bundleName = "UsageBar_UsageBar.bundle"
    let candidates: [URL?] = [
        mainBundle.resourceURL?.appendingPathComponent(bundleName),
        mainBundle.bundleURL.appendingPathComponent(bundleName),
        finderBundle.resourceURL?.appendingPathComponent(bundleName),
        mainBundle.executableURL?.deletingLastPathComponent().appendingPathComponent(bundleName),
    ]

    for case let candidate? in candidates {
        if let bundle = Bundle(url: candidate) {
            return bundle
        }
    }

    return nil
}
