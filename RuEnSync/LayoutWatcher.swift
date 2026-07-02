import Carbon.HIToolbox.TextInputSources
import Foundation

// MARK: - LayoutWatcher

/// Watches macOS keyboard layout changes via the Carbon TIS API and forwards
/// the resolved `idx` (per `config.layouts`) to a callback.
///
/// Event-driven with a reconciliation poll: the fast path is a
/// `DistributedNotificationCenter` subscription to
/// `kTISNotifySelectedKeyboardInputSourceChanged` (vs the 100 ms polling loop
/// qmk-hid-host uses on macOS); a slow `pollInterval` poll backstops it,
/// because DNC delivery is best-effort and the TIS cache can lag the
/// notification — either miss used to leave host + firmware stale until the
/// next layout change.
@MainActor
final class LayoutWatcher {
    private let layouts: [String]
    private var observer: NSObjectProtocol?

    /// Last resolved index. `nil` until the first detection. Useful to replay
    /// after a device reconnect.
    private(set) var lastIndex: UInt8?

    var onLayoutChanged: ((UInt8) -> Void)?

    /// Test seam mirroring `TISCreateInputSourceList`'s signature. Tests inject
    /// a closure to force the nil / empty-list failure paths deterministically;
    /// production leaves it `nil`, so the real Carbon call is used.
    var inputSourceListProvider: ((CFDictionary?, Bool) -> Unmanaged<CFArray>?)?

    /// Test seam mirroring the TIS current-source read. Tests inject a closure
    /// to drive `readAndDispatch` / the reconciliation poll deterministically;
    /// production leaves it `nil`, so the real Carbon call is used.
    var currentSourceIDProvider: (() -> String?)?

    /// Reconciliation-poll cadence. Overridable in tests to keep them fast.
    var pollInterval: Duration = .seconds(1)
    private var pollTask: Task<Void, Never>?

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

        // Reconciliation poll on top of the event path. DNC delivery is
        // best-effort (bursts / App Nap can drop it) and the in-process TIS
        // cache can lag the notification, so an event-only watcher can go
        // stale silently — pill and firmware then stay on the old layout
        // until the NEXT change. The poll bounds that window to ~pollInterval.
        // readAndDispatch() is deduped, so idle ticks never reach the HID
        // endpoint or the callback.
        let interval = pollInterval
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: interval)
                guard let self else { return }
                readAndDispatch(trigger: .poll)
            }
        }
    }

    /// Reads the current TIS input source and updates `lastIndex` on success.
    /// Does NOT fire `onLayoutChanged` — use `readAndDispatch` for that.
    ///
    /// Use this when a caller needs a fresh authoritative read of macOS state
    /// (typically: on HID device reconnect, to send firmware the actual
    /// current layout instead of a potentially-stale cached `lastIndex`).
    /// `lastIndex` is preserved on read failure so the caller can fall back.
    @discardableResult
    func refreshCurrentIndex() -> UInt8? {
        guard let result = readCurrent() else { return nil }
        lastIndex = result.idx
        Log.layout.debug("layout '\(result.id, privacy: .public)' → idx=\(result.idx) (refresh)")
        return result.idx
    }

    /// What caused a `readAndDispatch` call — only affects logging, so a
    /// poll-caught change (i.e. a missed/raced notification) leaves a
    /// persisted trace for post-mortems.
    enum ReadTrigger {
        case notification
        case poll
    }

    /// Reads the current input source and dispatches the resolved index when
    /// it differs from the previously cached one. Same-state notifications
    /// (Punto Switcher and similar tools fire bursts of TIS notifications
    /// even for no-op switches; see firmware-side analysis) are deduped here
    /// to avoid hammering the QMK Raw HID endpoint, which is single-buffered
    /// and can drop packets under rapid bursts.
    func readAndDispatch(trigger: ReadTrigger = .notification) {
        let previousIndex = lastIndex
        guard let result = readCurrent() else { return }
        lastIndex = result.idx
        if previousIndex == result.idx { return }
        if trigger == .poll {
            // .notice persists in the unified log (unlike .info) — this is
            // the evidence that a DNC notification was dropped or raced.
            Log.layout.notice("layout '\(result.id, privacy: .public)' → idx=\(result.idx) (reconciliation poll)")
        } else {
            Log.layout.info("layout '\(result.id, privacy: .public)' → idx=\(result.idx)")
        }
        onLayoutChanged?(result.idx)
    }

    /// Pure TIS read + resolve. Returns `nil` on any failure (TIS API
    /// returned nil, property missing, suffix not in `layouts`). Does not
    /// mutate `lastIndex` — that's the caller's job, so `refreshCurrentIndex`
    /// and `readAndDispatch` can each apply their own write/dispatch policy.
    private func readCurrent() -> (idx: UInt8, id: String)? {
        let sourceID: String? = if let currentSourceIDProvider {
            currentSourceIDProvider()
        } else {
            readSystemSourceID()
        }
        guard let id = sourceID else { return nil }

        guard let idx = LayoutResolver.resolveIndex(inputSourceID: id, layouts: layouts) else {
            let layoutList = layouts
            Log.layout
                .warning("input source '\(id, privacy: .public)' not in \(layoutList, privacy: .public) — ignored")
            return nil
        }

        return (idx, id)
    }

    /// The real Carbon read: current keyboard-layout input source ID.
    private func readSystemSourceID() -> String? {
        guard
            let unmanaged = TISCopyCurrentKeyboardLayoutInputSource(),
            let inputSource = unmanaged.takeRetainedValue() as TISInputSource?
        else {
            Log.layout.error("TISCopyCurrentKeyboardLayoutInputSource returned nil")
            return nil
        }

        guard
            let rawID = TISGetInputSourceProperty(inputSource, kTISPropertyInputSourceID)
        else {
            Log.layout.error("kTISPropertyInputSourceID returned nil")
            return nil
        }
        return Unmanaged<CFString>.fromOpaque(rawID).takeUnretainedValue() as String
    }

    /// Cancels the distributed-notification subscription and the
    /// reconciliation poll. Same rationale as `HIDLink.stop()` — Swift 6
    /// forbids touching non-Sendable fields from the (always-nonisolated)
    /// `deinit`.
    func stop() {
        pollTask?.cancel()
        pollTask = nil
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
        // between read (LayoutResolver) and write (this method).
        let filter: [CFString: Any] = [
            kTISPropertyInputSourceCategory: kTISCategoryKeyboardInputSource as Any,
        ]
        let provider = inputSourceListProvider ?? TISCreateInputSourceList
        guard
            let unmanaged = provider(filter as CFDictionary, false),
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
