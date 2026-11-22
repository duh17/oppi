import UIKit

// The empty chat's greeting: the Agent this session launched with, by the name
// and description the Agents list shows, and the two moments it comes and goes.

extension ChatViewController {
    /// The chat's half of the empty timeline. A session launched without an
    /// Agent keeps the plain Pi hero: no greeting, and the hero leaves as it
    /// always did.
    var emptyChatHost: ChatEmptyChatHost? {
        guard assistantIdentityPresentation != .globalAvatar else { return nil }
        return ChatEmptyChatHost(
            greeting: model.agentGreeting,
            titleIconFrame: { [weak self] in self?.barItems.titleControl.iconFrameInWindow() },
            onShown: { [weak self] in self?.loadAgentGreetingIfNeeded() },
            onLeft: { [weak self] in self?.clearAgentGreeting() }
        )
    }

    /// The empty chat names its Agent in the composer ("Message Owl").
    var greetingComposerPlaceholder: String? {
        guard activeComposerAskRequest == nil else { return nil }
        return model.agentGreeting.map { "Message \($0.name)" }
    }

    /// Reads this session's Agent name and description from the server's Agents,
    /// the list Quick Session's Agent picker reads. Called while the timeline is
    /// empty, so a chat with rows never asks; a failed read leaves the greeting
    /// with its circle and no name, and the chat works as it did.
    func loadAgentGreetingIfNeeded() {
        guard model.agentGreeting == nil, model.agentGreetingTask == nil,
              let agentId = session?.launch?.agentId, !agentId.isEmpty,
              connection.offers(.agents), let api = apiClient
        else { return }
        model.agentGreetingTask = Task { [weak self] in
            let agents = try? await api.listAgents()
            guard let self else { return }
            self.model.agentGreetingTask = nil
            guard !Task.isCancelled,
                  let summary = agents?.first(where: { $0.id == agentId })
            else { return }
            let name = summary.name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else { return }
            self.model.agentGreeting = ChatAgentGreeting(
                name: name,
                description: summary.description?.trimmingCharacters(in: .whitespacesAndNewlines)
            )
            self.setNeedsUpdateProperties()
        }
    }

    /// The empty timeline is gone: the composer says "Message…" again, and a read
    /// still out is dropped with the greeting.
    func clearAgentGreeting() {
        model.agentGreetingTask?.cancel()
        model.agentGreetingTask = nil
        guard model.agentGreeting != nil else { return }
        model.agentGreeting = nil
        setNeedsUpdateProperties()
    }
}
