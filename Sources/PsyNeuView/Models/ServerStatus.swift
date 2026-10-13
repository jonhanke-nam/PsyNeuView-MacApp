import Foundation

enum ServerStatus: String, Sendable {
    case stopped
    case starting
    case running
    case stopping
    case error

    var displayName: String {
        switch self {
        case .stopped:  return "Stopped"
        case .starting: return "Starting"
        case .running:  return "Running"
        case .stopping: return "Stopping"
        case .error:    return "Error"
        }
    }

    var statusDot: String {
        switch self {
        case .stopped:  return "⚫"
        case .starting: return "🟡"
        case .running:  return "🟢"
        case .stopping: return "🟡"
        case .error:    return "🔴"
        }
    }
}
