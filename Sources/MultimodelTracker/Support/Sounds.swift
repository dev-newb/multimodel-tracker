import Foundation
import AVFoundation
import AppKit

/// The three alert sounds, ported from I'm Burning!. Audio is shipped
/// BYTE-IDENTICAL — never trimmed, normalised or re-encoded. The 18-second
/// choir on a reset is deliberate: resets are a glorious event.
enum SoundKind: String, CaseIterable, Identifiable {
    case burn, reset, banked, limit
    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .burn:   return "Burning tokens quickly"
        case .reset:  return "Limit reset early (Codex)"
        case .banked: return "Banked reset added (Codex)"
        case .limit:  return "Usage limit reached"
        }
    }

    /// Bundled default, shipped in Contents/Resources/sounds.
    var defaultFile: (name: String, ext: String) {
        switch self {
        case .burn:   return ("burn-default", "wav")
        case .reset:  return ("reset-default", "mp3")
        case .banked: return ("banked-default", "mp3")
        case .limit:  return ("limit-default", "mp3")   // a punch into rock
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
    /// The name the user actually picked, shown instead of our copy's
    /// internal filename.
    private var originalNames: [SoundKind: String] = [:]

    private init() {
        for kind in SoundKind.allCases {
            let d = UserDefaults.standard
            let prefix = "mmt.sound.\(kind.rawValue)."
            settings[kind] = SoundSetting(
                enabled: d.object(forKey: prefix + "enabled") as? Bool ?? true,
                path: d.string(forKey: prefix + "path"),
                volume: d.object(forKey: prefix + "volume") as? Double ?? 0.85)
            originalNames[kind] = d.string(forKey: prefix + "name")
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

    /// Where custom picks are kept. The user's original file can be moved,
    /// renamed or deleted at any time; keeping our own copy means a chosen
    /// sound stays working, and the bundled defaults are always still there
    /// to revert to.
    static var soundsDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                            in: .userDomainMask)[0]
            .appendingPathComponent("MultimodelTracker/Sounds", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }

    func setPath(_ path: String?, for kind: SoundKind) {
        var stored = path
        if let path {
            // Copy in under a per-kind name, replacing any previous pick.
            let src = URL(fileURLWithPath: path)
            let dst = Self.soundsDirectory
                .appendingPathComponent("\(kind.rawValue)-custom.\(src.pathExtension)")
            try? FileManager.default.removeItem(at: dst)
            if (try? FileManager.default.copyItem(at: src, to: dst)) != nil {
                stored = dst.path
                originalNames[kind] = src.lastPathComponent
                UserDefaults.standard.set(src.lastPathComponent,
                                          forKey: "mmt.sound.\(kind.rawValue).name")
            }
        } else {
            originalNames[kind] = nil
            UserDefaults.standard.removeObject(forKey: "mmt.sound.\(kind.rawValue).name")
        }
        settings[kind]?.path = stored
        let key = "mmt.sound.\(kind.rawValue).path"
        if let stored { UserDefaults.standard.set(stored, forKey: key) }
        else { UserDefaults.standard.removeObject(forKey: key) }
    }

    func label(for kind: SoundKind) -> String {
        guard let p = settings[kind]?.path else { return kind.defaultLabel }
        return originalNames[kind] ?? URL(fileURLWithPath: p).lastPathComponent
    }

    func isCustom(_ kind: SoundKind) -> Bool { settings[kind]?.path != nil }

    private func url(for kind: SoundKind) -> URL? {
        if let p = settings[kind]?.path, FileManager.default.fileExists(atPath: p) {
            return URL(fileURLWithPath: p)
        }
        let d = kind.defaultFile
        return Bundle.main.url(forResource: d.name, withExtension: d.ext, subdirectory: "sounds")
            ?? Bundle.main.url(forResource: d.name, withExtension: d.ext)
    }

    /// How long this alert's CONFIGURED file runs — the flash animation lasts
    /// exactly this long, so a custom sound automatically retimes the flash.
    /// Read through AVAudioPlayer like playback itself, cached per path
    /// (choosing a new file changes the path, which misses the cache).
    private var durationCache: [String: TimeInterval] = [:]
    func duration(for kind: SoundKind) -> TimeInterval {
        guard let url = url(for: kind) else { return 5 }
        if let hit = durationCache[url.path] { return hit }
        let d = (try? AVAudioPlayer(contentsOf: url))?.duration ?? 5
        durationCache[url.path] = d
        return d
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
