import PawvisCore

/// A synthetic open hand in camera space, for the eyes-on demo feeds
/// (`PAWVIS_PRACTICE_DEMO`, `PAWVIS_THEREMIN_DEMO`): a screenshot machine
/// with no hand in front of it still shows the real coaching and playing
/// states. The pose is `SelfTest`'s open hand — four fingers up from the
/// knuckles, thumb out to the side — which passes the strict open-hand
/// check and reads as open to every feature the app computes.
enum DemoHand {
    /// An open right hand with its wrist at `wrist`; `scale` is the
    /// wrist-to-knuckle distance in normalized camera units.
    static func open(wrist: Vec2, scale: Double = 0.16) -> Hand {
        var joints: [HandJoint: Vec2] = [.wrist: wrist]
        let fingers: [(Finger, Vec2, Vec2)] = [
            (.index, Vec2(-0.25, -0.95), Vec2(0.06, -0.998)),
            (.middle, Vec2(0, -1.0), Vec2(0, -1)),
            (.ring, Vec2(0.22, -0.95), Vec2(-0.03, -1)),
            (.little, Vec2(0.42, -0.85), Vec2(-0.10, -0.995)),
        ]
        for (finger, mcpOffset, direction) in fingers {
            let mcp = wrist + mcpOffset * scale
            joints[finger.mcp] = mcp
            joints[finger.pip] = mcp + direction * (0.45 * scale)
            joints[finger.dip] = mcp + direction * (0.70 * scale)
            joints[finger.tip] = mcp + direction * (0.95 * scale)
        }
        let thumbTip = wrist + Vec2(-0.95, -0.70) * scale
        joints[.thumbCMC] = wrist + Vec2(-0.35, -0.25) * scale
        joints[.thumbMP] = wrist.lerp(to: thumbTip, t: 0.45)
        joints[.thumbIP] = wrist.lerp(to: thumbTip, t: 0.72)
        joints[.thumbTip] = thumbTip
        return Hand(chirality: .right, confidence: 1, joints: joints)
    }

    /// Where the open hand's palm centre lands for a wrist at `wrist`
    /// (`HandFeatures.palmCenter`: the mean of the wrist and the four
    /// knuckles), so a demo can place a hand by where its palm should be.
    static func wrist(forPalm palm: Vec2, scale: Double = 0.16) -> Vec2 {
        // Knuckle offsets sum to (0.39, −3.75) over five points (the wrist
        // contributes zero).
        palm - Vec2(0.39 / 5, -3.75 / 5) * scale
    }
}
