import Foundation
import SwiftData

enum MessageRole: String, Codable {
    case user
    case assistant
    case system
}

@Model
final class Message {
    var id: UUID
    var role: MessageRole
    var content: String
    var timestamp: Date
    var conversation: Conversation?

    // Generation stats (assistant messages only)
    var generationSeconds: Double?
    var tokenCount: Int?
    var memoryBytesUsed: Int?

    // Thinking (models with native <think> support)
    var thinkingContent: String?
    var thinkingSeconds: Double?

    var tokensPerSecond: Double? {
        guard let tokens = tokenCount, let seconds = generationSeconds, seconds > 0 else { return nil }
        return Double(tokens) / seconds
    }

    init(role: MessageRole, content: String) {
        self.id = UUID()
        self.role = role
        self.content = content
        self.timestamp = .now
    }
}
