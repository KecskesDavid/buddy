import Foundation

nonisolated enum VoiceError: LocalizedError {
    case micDenied
    case noMicrophone
    case unavailable
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .micDenied:
            return "Buddy can't hear you. Allow Buddy in System Settings → Privacy & Security → Microphone, then hold fn⌃ again."
        case .noMicrophone:
            return "No microphone found. Connect one, or tap fn⌃ to circle without talking."
        case .unavailable:
            return "Speech recognition isn't available on this Mac. Tap fn⌃ to circle without talking."
        case .failed(let details):
            return "Buddy couldn't listen: \(details)"
        }
    }
}
