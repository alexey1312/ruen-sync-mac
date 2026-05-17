import Carbon.HIToolbox.TextInputSources
import Foundation

// MARK: - LayoutWatcher

/// Watches macOS keyboard layout changes via the Carbon TIS API and forwards
/// the resolved `idx` (per `config.layouts`) to a callback.
///
/// Event-driven: uses `DistributedNotificationCenter` subscription to
/// `kTISNotifySelectedKeyboardInputSourceChanged`. Replaces the 100 ms polling
/// loop that qmk-hid-host uses on macOS.
@MainActor
final class LayoutWatcher {
    private let layouts: [String]
    private var observer: NSObjectProtocol?

    /// Last resolved index. `nil` until the first detection. Useful to replay
    /// after a device reconnect.
    private(set) var lastIndex: UInt8?

    var onLayoutChanged: ((UInt8) -> Void)?

    init(layouts: [String]) {
        self.layouts = layouts
    }

    /// Subscribe to layout-change notifications and read the current state.
    func start() {
        let nc = DistributedNotificationCenter.default()
        let name = Notification.Name(kTISNotifySelectedKeyboardInputSourceChanged as String)

        observer = nc.addObserver(
            forName: name,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            // queue: .main already runs us on the main thread; hop into the
            // main actor explicitly to satisfy Swift 6 strict concurrency.
            MainActor.assumeIsolated {
                self?.readAndDispatch()
            }
        }

        // Read the current layout on start so we report state even when no
        // notification has fired yet (e.g. boot, app first launch).
        readAndDispatch()
    }

    /// Reads the current input source and dispatches the resolved index. Logs
    /// (but does not crash) when the suffix isn't in `config.layouts`.
    func readAndDispatch() {
        guard
            let unmanaged = TISCopyCurrentKeyboardLayoutInputSource(),
            let inputSource = unmanaged.takeRetainedValue() as TISInputSource?
        else {
            Log.layout.error("TISCopyCurrentKeyboardLayoutInputSource returned nil")
            return
        }

        guard
            let rawID = TISGetInputSourceProperty(inputSource, kTISPropertyInputSourceID)
        else {
            Log.layout.error("kTISPropertyInputSourceID returned nil")
            return
        }
        let id = Unmanaged<CFString>.fromOpaque(rawID).takeUnretainedValue() as String

        guard let idx = LayoutResolver.resolveIndex(inputSourceID: id, layouts: layouts) else {
            let layoutList = layouts
            Log.layout
                .warning("input source '\(id, privacy: .public)' not in \(layoutList, privacy: .public) — ignored")
            return
        }

        lastIndex = idx
        Log.layout.info("layout '\(id, privacy: .public)' → idx=\(idx)")
        onLayoutChanged?(idx)
    }

    /// Cancels the distributed-notification subscription. Same rationale as
    /// `HIDLink.stop()` — Swift 6 forbids touching non-Sendable fields from
    /// the (always-nonisolated) `deinit`.
    func stop() {
        if let observer {
            DistributedNotificationCenter.default().removeObserver(observer)
            self.observer = nil
        }
    }

    /// Why a programmatic input-source switch couldn't happen. Carried back
    /// to the caller (`AppModel.handleAppActivated`) so the activity log and
    /// future UI badges can distinguish "rule references a layout the user
    /// hasn't enabled in System Settings" from "the TIS call itself failed",
    /// and so the failure surfaces somewhere other than `.warning`/`.error`
    /// logs which the user almost never reads.
    enum SelectError: Error, Equatable {
        /// `TISCreateInputSourceList` returned nil — never observed in
        /// practice, but distinct so it doesn't get classified as
        /// "rule references missing layout".
        case listFailed
        /// No enabled keyboard input source has the requested suffix.
        /// Almost always means: the user defined a rule pointing at e.g.
        /// `RussianPhonetic` but hasn't enabled that layout in System
        /// Settings → Keyboard → Input Sources.
        case notEnabled
        /// `TISSelectInputSource` rejected the call with a non-noErr status.
        case tisFailed(OSStatus)
    }

    /// Programmatically switches the macOS keyboard layout to the one whose
    /// `kTISPropertyInputSourceID` ends with `layoutName` (e.g. `"Russian"`).
    /// macOS will then fire `kTISNotifySelectedKeyboardInputSourceChanged`,
    /// which `readAndDispatch()` will pick up and forward through the normal
    /// HIDLink path — no special branch for per-app overrides.
    ///
    /// Returns `.success` on a successful switch, `.failure` with the
    /// specific reason otherwise. Logs every branch.
    @discardableResult
    func selectInputSource(layoutName: String) -> Result<Void, SelectError> {
        // Match by suffix to mirror LayoutResolver.resolveIndex: the user
        // writes `"Russian"` in config and we look up
        // `com.apple.keylayout.Russian`. Keeps the config format symmetric
        // for read (LayoutResolver) and write (this method).
        let filter: [CFString: Any] = [
            kTISPropertyInputSourceCategory: kTISCategoryKeyboardInputSource as Any,
        ]
        guard
            let unmanaged = TISCreateInputSourceList(filter as CFDictionary, false),
            let sources = unmanaged.takeRetainedValue() as? [TISInputSource]
        else {
            Log.layout.error("TISCreateInputSourceList returned nil")
            return .failure(.listFailed)
        }

        for source in sources {
            guard let rawID = TISGetInputSourceProperty(source, kTISPropertyInputSourceID) else { continue }
            let id = Unmanaged<CFString>.fromOpaque(rawID).takeUnretainedValue() as String
            let suffix = id.split(separator: ".").last.map(String.init) ?? id
            guard suffix == layoutName else { continue }

            let result = TISSelectInputSource(source)
            if result == noErr {
                Log.layout.info("selected input source '\(id, privacy: .public)' programmatically")
                return .success(())
            }
            Log.layout
                .error(
                    "TISSelectInputSource('\(id, privacy: .public)') failed: \(result, privacy: .public)"
                )
            return .failure(.tisFailed(result))
        }

        Log.layout.warning("no enabled keyboard input source matches '\(layoutName, privacy: .public)'")
        return .failure(.notEnabled)
    }
}

extension LayoutWatcher.SelectError {
    /// Short label safe to include in `ActivityKind.appLayoutOverrideFailed`.
    /// Kept localizable so the activity row reads naturally.
    var activityLabel: String {
        switch self {
        case .listFailed:
            String(localized: "input source list unavailable")
        case .notEnabled:
            String(localized: "layout not enabled in System Settings")
        case let .tisFailed(status):
            String(localized: "TIS error \(String(format: "0x%08X", Int(status)))")
        }
    }
}
