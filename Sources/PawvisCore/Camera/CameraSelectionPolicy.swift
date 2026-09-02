import Foundation

/// Which camera feeds the capture session. Pure, like `LaunchAtLoginPolicy`
/// and `FirstRunPolicy`: the app enumerates the cameras macOS can see and
/// this decides, so the rule is unit-tested and lives in one place.
///
/// The rules:
///   - **An explicit pick wins.** Settings → General and the menu bar store
///     an `AVCaptureDevice.uniqueID`; while that camera is present, it is
///     the camera, whatever else is around.
///   - **Automatic is the built-in camera.** It faces the user by
///     construction. An iPhone macOS offers as a Continuity Camera, a USB
///     webcam, a virtual camera: all of them are picker entries, never
///     adopted unasked. Pawvis does not switch cameras on its own, because
///     a hand tracker that changes its own viewpoint goes blind, or keeps
///     pointing from a camera the user is not in front of.
///   - **A pick that walked away is Automatic until it returns.** Unplug
///     the chosen camera and tracking rides the built-in one instead of a
///     dead input; the app re-adopts the pick the moment it reconnects.
///   - **Something beats nothing.** No built-in camera (a Mac mini, a Mac
///     Studio) means the first camera at all, so an external-only setup
///     still works out of the box.
public enum CameraSelectionPolicy {
    /// What a camera is, as far as choosing one goes.
    public enum Kind: Equatable, Sendable {
        /// The camera built into the Mac or its display.
        case builtIn
        /// An iPhone (or iPad) that macOS offers as a Continuity Camera.
        /// Only reported once the app opts in with
        /// `NSCameraUseContinuityCameraDeviceType`; without that key macOS
        /// files the phone under `.other`. The rule treats it exactly like
        /// `.other`; the kind exists so diagnostics can say what a device
        /// is.
        case continuity
        /// Anything else: a USB webcam, a capture card, a virtual camera.
        case other
    }

    public struct Candidate: Equatable, Sendable {
        public var id: String
        public var kind: Kind

        public init(id: String, kind: Kind) {
            self.id = id
            self.kind = kind
        }
    }

    /// The camera to run on, or nil when there is none at all.
    ///
    /// - Parameters:
    ///   - pick: the persisted explicit choice (`general.cameraDeviceID`);
    ///     nil is Automatic.
    ///   - available: every camera macOS can see right now, in discovery
    ///     order.
    public static func choose(pick: String?, available: [Candidate]) -> String? {
        if let pick, available.contains(where: { $0.id == pick }) {
            return pick
        }
        return (available.first(where: { $0.kind == .builtIn }) ?? available.first)?.id
    }

    /// Whether `choose` is currently on the built-in-camera rule rather
    /// than an explicit pick: no pick, or a pick that is not present.
    public static func isAutomatic(pick: String?, available: [Candidate]) -> Bool {
        guard let pick else { return true }
        return !available.contains(where: { $0.id == pick })
    }

    /// What the camera picker should be showing. Both pickers (Settings →
    /// General and the menu bar) render from this, so they can never
    /// disagree about the state of the same setting.
    ///
    /// The third case is the one this type exists for. Unplug a picked
    /// camera and the *session* falls back within milliseconds, but the
    /// stored pick still names the device that left — so a picker that only
    /// knows ids either shows a raw UUID or, worse, matches no entry at all
    /// and renders blank, which reads as "broken" rather than "waiting".
    /// Naming the absent camera and saying what is running instead is the
    /// honest report, and it is one click back to Automatic from there.
    public enum PickPresentation: Equatable, Sendable {
        /// No pick: the built-in-camera rule is in effect.
        case automatic
        /// The picked camera is present and feeding the session.
        case connected(id: String)
        /// A pick that is not currently connected. Tracking is riding the
        /// automatic choice; the pick is re-adopted the moment it returns.
        case awaitingReturn(id: String, name: String?)
    }

    /// - Parameters:
    ///   - pick: the persisted `general.cameraDeviceID`.
    ///   - pickName: the persisted `general.cameraDeviceName`, the pick's
    ///     display name as it read when chosen. Absent for picks stored by
    ///     builds before that field existed.
    ///   - availableIDs: the uniqueIDs of every camera macOS can see right
    ///     now. Ids, not `Candidate`s: presence is the only thing this
    ///     decides on, and asking callers for kinds they would have to
    ///     invent invites a wrong answer the day it starts mattering.
    public static func presentation(
        pick: String?,
        pickName: String?,
        availableIDs: [String]
    ) -> PickPresentation {
        guard let pick else { return .automatic }
        if availableIDs.contains(pick) { return .connected(id: pick) }
        // An empty remembered name is no name: the caller falls back to
        // generic copy rather than rendering "  (not connected)".
        let name = (pickName?.isEmpty ?? true) ? nil : pickName
        return .awaitingReturn(id: pick, name: name)
    }
}
