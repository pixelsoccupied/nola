import SwiftData
import SwiftUI

struct ContentView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(MLXService.self) private var mlxService
    @Environment(ModelManager.self) private var modelManager
    @Query(sort: \Conversation.updatedAt, order: .reverse) private var conversations: [Conversation]

    @State private var selectedConversation: Conversation?
    @State private var chatViewModel = ChatViewModel()

    var body: some View {
        NavigationSplitView {
            List(selection: $selectedConversation) {
                ForEach(groupedConversations, id: \.title) { group in
                    Section(group.title) {
                        ForEach(group.conversations) { conversation in
                            NavigationLink(value: conversation) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(conversation.title)
                                        .lineLimit(1)
                                    if let model = conversation.modelDisplayName {
                                        Text(model)
                                            .font(.caption2)
                                            .foregroundStyle(.tertiary)
                                            .lineLimit(1)
                                    }
                                }
                            }
                            .contextMenu {
                                Button("Delete", role: .destructive) {
                                    deleteConversation(conversation)
                                }
                            }
                        }
                    }
                }
            }
            .listStyle(.sidebar)
            .navigationTitle("Chats")
            .safeAreaPadding(.top, 12)
            .navigationSplitViewColumnWidth(min: 200, ideal: 240)
        } detail: {
            if let conversation = selectedConversation {
                ChatView(
                    conversation: conversation,
                    chatViewModel: chatViewModel
                )
                .backgroundExtensionEffect()
            } else {
                Text("Start a new chat")
                    .foregroundStyle(.secondary)
                    .backgroundExtensionEffect()
            }
        }
        .navigationSplitViewStyle(.prominentDetail)
        .toolbar {
            ToolbarItem(placement: .automatic) {
                Button(action: newChat) {
                    Label("New Chat", systemImage: "plus")
                        .labelStyle(.iconOnly)
                }
                .help("New Chat (⌘N)")
            }
            ToolbarItem(placement: .automatic) {
                BrainModelButton()
            }
        }
        .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
        .onChange(of: selectedConversation) {
            chatViewModel.stopGenerating()
            chatViewModel.dismissError()
        }
        .onReceive(NotificationCenter.default.publisher(for: .newChat)) { _ in
            newChat()
        }
        .task {
            await modelManager.scanDownloadedModels()
            // Clean up empty conversations from previous sessions
            for conversation in conversations where conversation.messages.isEmpty {
                modelContext.delete(conversation)
            }
            try? modelContext.save()
            // Always start fresh
            newChat()
        }
    }

    private func newChat() {
        let conversation = Conversation()
        modelContext.insert(conversation)
        try? modelContext.save()
        selectedConversation = conversation
    }

    private func deleteConversation(_ conversation: Conversation) {
        if selectedConversation == conversation {
            selectedConversation = nil
        }
        modelContext.delete(conversation)
        try? modelContext.save()
    }

    private func deleteConversations(at offsets: IndexSet) {
        for index in offsets {
            deleteConversation(conversations[index])
        }
    }

    // MARK: - Date grouping

    private struct ConversationGroup {
        let title: String
        let conversations: [Conversation]
    }

    private var groupedConversations: [ConversationGroup] {
        let calendar = Calendar.current
        let now = Date.now

        var today: [Conversation] = []
        var yesterday: [Conversation] = []
        var thisWeek: [Conversation] = []
        var older: [Conversation] = []

        for conversation in conversations {
            let date = conversation.updatedAt
            if calendar.isDateInToday(date) {
                today.append(conversation)
            } else if calendar.isDateInYesterday(date) {
                yesterday.append(conversation)
            } else if let weekAgo = calendar.date(byAdding: .day, value: -7, to: now),
                      date > weekAgo {
                thisWeek.append(conversation)
            } else {
                older.append(conversation)
            }
        }

        var groups: [ConversationGroup] = []
        if !today.isEmpty { groups.append(ConversationGroup(title: "Today", conversations: today)) }
        if !yesterday.isEmpty { groups.append(ConversationGroup(title: "Yesterday", conversations: yesterday)) }
        if !thisWeek.isEmpty { groups.append(ConversationGroup(title: "This Week", conversations: thisWeek)) }
        if !older.isEmpty { groups.append(ConversationGroup(title: "Older", conversations: older)) }
        return groups
    }
}
