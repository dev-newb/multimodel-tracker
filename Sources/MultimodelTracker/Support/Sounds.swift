import Foundation
import AVFoundation
import AppKit

/// The three alert sounds, ported from I'm Burning!. Audio is shipped
/// BYTE-IDENTICAL — never trimmed, normalised or re-encoded. The 18-second
/// choir on a reset is deliberate: resets are a glorious event.
enum SoundKind: String, CaseIterable, Identifiable {
    case burn, reset, banked
    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .burn:   return "Burning tokens quickly"
        case .reset:  return "Limit reset early"
        case .banked: return "Banked reset added"
        }
    }

    /// Bundled default, shipped in Contents/Resources/sounds.
    var defaultFile: (name: String, ext: String) {
        switch self {
        case .burn:   return ("burn-default", "wav")
        case .reset:  return ("reset-default", "mp3")
        case .banked: return ("banked-default", "mp3")
        }
    }

    var defaultLabel: String { "\(defaultFile.name).\(defaultFile.ext)" }
}

struct SoundSetting {
    var enabled = true
    /// nil means the bundled default.
    var path: String?
    var volume: Double = 0.85
}

/// Plays the alerts and remembers each one's settings.
@MainActor
final class Sounds: ObservableObject {
    static let shared = Sounds()

    @Published private(set) var settings: [SoundKind: SoundSetting] = [:]
    /// One live player per kind. A re-trigger stops the previous instance of
    /// that same sound first, so overlapping events retrigger cleanly instead
    /// of layering on top of each other.
    private var players: [SoundKind: AVAudioPlayer] = [:]

    private init() {
        for kind in SoundKind.allCases {
            let d = UserDefaults.standard
            let prefix = "mmt.sound.\(kind.rawValue)."
            settings[kind] = SoundSetting(
                enabled: d.object(forKey: prefix + "enabled") as? Bool ?? true,
                path: d.string(forKey: prefix + "path"),
                volume: d.object(forKey: prefix + "volume") as? Double ?? 0.85)
        }
    }

    func setEnabled(_ on: Bool, for kind: SoundKind) {
        settings[kind]?.enabled = on
        UserDefaults.standard.set(on, forKey: "mmt.sound.\(kind.rawValue).enabled")
    }

    func setVolume(_ v: Double, for kind: SoundKind) {
        settings[kind]?.volume = v
        UserDefaults.standard.set(v, forKey: "mmt.sound.\(kind.rawValue).volume")
        players[kind]?.volume = Float(v)
    }

    func setPath(_ path: String?, for kind: SoundKind) {
        settings[kind]?.path = path
        let key = "mmt.sound.\(kind.rawValue).path"
        if let path { UserDefaults.standard.set(path, forKey: key) }
        else { UserDefaults.standard.removeObject(forKey: key) }
    }

    func label(for kind: SoundKind) -> String {
        guard let p = settings[kind]?.path else { return kind.defaultLabel }
        return URL(fileURLWithPath: p).lastPathComponent
    }

    private func url(for kind: SoundKind) -> URL? {
        if let p = settings[kind]?.path, FileManager.default.fileExists(atPath: p) {
            return URL(fileURLWithPath: p)
        }
        let d = kind.defaultFile
        return Bundle.main.url(forResource: d.name, withExtension: d.ext, subdirectory: "sounds")
            ?? Bundle.main.url(forResource: d.name, withExtension: d.ext)
    }

    /// `force` ignores the enabled flag, for the Test buttons.
    func play(_ kind: SoundKind, force: Bool = false) {
        guard force || settings[kind]?.enabled == true else { return }
        guard let url = url(for: kind) else { return }
        players[kind]?.stop()
        guard let player = try? AVAudioPlayer(contentsOf: url) else { return }
        player.volume = Float(settings[kind]?.volume ?? 0.85)
        player.prepareToPlay()
        player.play()
        players[kind] = player
    }
}
