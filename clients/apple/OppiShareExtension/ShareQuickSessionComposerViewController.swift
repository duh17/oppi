import OSLog
import UIKit

private let shareComposerLog = Logger(subsystem: "dev.chenda.Oppi", category: "ShareQuickSession")

private enum ShareWorkspaceLoadOutcome: Sendable {
    case success([ShareQuickSessionWorkspace])
    case failure(serverID: String, serverName: String, message: String)
}

@MainActor
final class ShareQuickSessionComposerViewController: UIViewController, UITextViewDelegate {
    private let payload: ShareQuickSessionPayload
    private let onFinish: (Bool) -> Void
    private var workspaces: [ShareQuickSessionWorkspace] = []
    private var selectedWorkspace: ShareQuickSessionWorkspace?
    private var loadTask: Task<Void, Never>?
    private var sendTask: Task<Void, Never>?

    private let workspaceButton = UIButton(type: .system)
    private let textView = UITextView()
    private let sendButton = UIButton(type: .system)
    private let cancelButton = UIButton(type: .system)
    private let statusLabel = UILabel()
    private let retryButton = UIButton(type: .system)
    private let activity = UIActivityIndicatorView(style: .medium)

    init(payload: ShareQuickSessionPayload, onFinish: @escaping (Bool) -> Void) {
        self.payload = payload
        self.onFinish = onFinish
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    deinit {
        loadTask?.cancel()
        sendTask?.cancel()
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        preferredContentSize = CGSize(width: 420, height: 430)
        buildForm()
        loadWorkspaces()
    }

    private func buildForm() {
        let title = UILabel()
        title.text = "Quick Session"
        title.font = .preferredFont(forTextStyle: .headline)
        title.adjustsFontForContentSizeCategory = true
        title.textAlignment = .center
        title.accessibilityTraits = .header

        cancelButton.setTitle("Cancel", for: .normal)
        cancelButton.addTarget(self, action: #selector(cancel), for: .touchUpInside)
        cancelButton.accessibilityIdentifier = "share.quickSession.cancel"

        sendButton.configuration = .filled()
        sendButton.configuration?.title = "Send"
        sendButton.addTarget(self, action: #selector(send), for: .touchUpInside)
        sendButton.accessibilityIdentifier = "share.quickSession.send"
        sendButton.isEnabled = false

        let header = UIView()
        for item in [cancelButton, title, sendButton] {
            item.translatesAutoresizingMaskIntoConstraints = false
            header.addSubview(item)
        }
        NSLayoutConstraint.activate([
            header.heightAnchor.constraint(equalToConstant: 48),
            cancelButton.leadingAnchor.constraint(equalTo: header.leadingAnchor),
            cancelButton.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            cancelButton.heightAnchor.constraint(greaterThanOrEqualToConstant: 44),
            sendButton.trailingAnchor.constraint(equalTo: header.trailingAnchor),
            sendButton.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            sendButton.heightAnchor.constraint(greaterThanOrEqualToConstant: 44),
            title.centerXAnchor.constraint(equalTo: header.centerXAnchor),
            title.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            title.leadingAnchor.constraint(greaterThanOrEqualTo: cancelButton.trailingAnchor, constant: 8),
            title.trailingAnchor.constraint(lessThanOrEqualTo: sendButton.leadingAnchor, constant: -8),
        ])

        workspaceButton.configuration = .tinted()
        workspaceButton.configuration?.image = UIImage(systemName: "folder")
        workspaceButton.configuration?.imagePadding = 8
        workspaceButton.configuration?.title = "Loading workspaces…"
        workspaceButton.configuration?.cornerStyle = .medium
        workspaceButton.contentHorizontalAlignment = .leading
        workspaceButton.showsMenuAsPrimaryAction = true
        workspaceButton.isEnabled = false
        workspaceButton.accessibilityIdentifier = "share.quickSession.workspace"

        textView.text = payload.text ?? ""
        textView.font = .preferredFont(forTextStyle: .body)
        textView.adjustsFontForContentSizeCategory = true
        textView.backgroundColor = .secondarySystemBackground
        textView.layer.cornerRadius = 12
        textView.layer.cornerCurve = .continuous
        textView.textContainerInset = UIEdgeInsets(top: 10, left: 8, bottom: 10, right: 8)
        textView.delegate = self
        textView.accessibilityLabel = "Shared text"
        textView.accessibilityIdentifier = "share.quickSession.text"

        statusLabel.font = .preferredFont(forTextStyle: .caption1)
        statusLabel.adjustsFontForContentSizeCategory = true
        statusLabel.textColor = .secondaryLabel
        statusLabel.numberOfLines = 2
        statusLabel.accessibilityIdentifier = "share.quickSession.status"
        activity.hidesWhenStopped = true
        retryButton.setTitle("Retry", for: .normal)
        retryButton.addTarget(self, action: #selector(retryWorkspaceLoad), for: .touchUpInside)
        retryButton.accessibilityIdentifier = "share.quickSession.workspace.retry"
        retryButton.isHidden = true
        let statusRow = UIStackView(arrangedSubviews: [activity, statusLabel, retryButton])
        statusRow.axis = .horizontal
        statusRow.spacing = 8
        statusRow.alignment = .center

        let stack = UIStackView(arrangedSubviews: [header, workspaceButton, textView])
        stack.axis = .vertical
        stack.spacing = 10
        if !payload.files.isEmpty {
            let attachmentRow = makeAttachmentRow()
            stack.addArrangedSubview(attachmentRow)
            attachmentRow.heightAnchor.constraint(equalToConstant: 38).isActive = true
        }
        stack.addArrangedSubview(statusRow)
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)

        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 4),
            stack.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -16),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: view.keyboardLayoutGuide.topAnchor, constant: -12),
            workspaceButton.heightAnchor.constraint(greaterThanOrEqualToConstant: 44),
            textView.heightAnchor.constraint(greaterThanOrEqualToConstant: payload.files.isEmpty ? 170 : 130),
            statusRow.heightAnchor.constraint(greaterThanOrEqualToConstant: 44),
            retryButton.heightAnchor.constraint(greaterThanOrEqualToConstant: 44),
        ])
        UIAccessibility.post(notification: .screenChanged, argument: title)
    }

    private func makeAttachmentRow() -> UIScrollView {
        let scroll = UIScrollView()
        scroll.showsHorizontalScrollIndicator = false
        let stack = UIStackView()
        stack.axis = .horizontal
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        scroll.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor),
            stack.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor),
            stack.heightAnchor.constraint(equalTo: scroll.frameLayoutGuide.heightAnchor),
        ])

        for (index, file) in payload.files.enumerated() {
            var configuration = UIButton.Configuration.tinted()
            configuration.title = file.name
            configuration.image = UIImage(systemName: file.mimeType.hasPrefix("image/") ? "photo" : "doc")
            configuration.imagePadding = 6
            configuration.cornerStyle = .capsule
            let pill = UIButton(configuration: configuration)
            pill.isUserInteractionEnabled = false
            pill.accessibilityIdentifier = "share.quickSession.attachment.\(index)"
            pill.accessibilityLabel = "Attachment, \(file.name)"
            stack.addArrangedSubview(pill)
        }
        return scroll
    }

    private func loadWorkspaces() {
        loadTask?.cancel()
        let servers = ShareQuickSessionCredentialStore.loadServers()
        retryButton.isHidden = true
        selectedWorkspace = nil
        workspaces = []
        workspaceButton.menu = nil
        workspaceButton.isEnabled = false
        workspaceButton.configuration?.title = "Loading workspaces…"
        updateSendEnabled()
        guard !servers.isEmpty else {
            workspaceButton.configuration?.title = "No paired server"
            statusLabel.text = "Open Oppi and pair a server before sharing."
            return
        }

        activity.startAnimating()
        statusLabel.textColor = .secondaryLabel
        statusLabel.text = "Loading workspaces…"
        loadTask = Task { [weak self] in
            let outcomes = await withTaskGroup(of: ShareWorkspaceLoadOutcome.self) { group in
                for server in servers {
                    group.addTask {
                        let sender = ShareQuickSessionSender.live(server: server)
                        do {
                            return .success(try await sender.fetchWorkspaces(server: server))
                        } catch {
                            return .failure(
                                serverID: server.id,
                                serverName: server.name,
                                message: error.localizedDescription
                            )
                        }
                    }
                }
                var result: [ShareWorkspaceLoadOutcome] = []
                for await outcome in group {
                    result.append(outcome)
                }
                return result
            }
            guard !Task.isCancelled, let self else { return }

            self.activity.stopAnimating()
            var loaded: [ShareQuickSessionWorkspace] = []
            var failures: [(serverName: String, message: String)] = []
            for outcome in outcomes {
                switch outcome {
                case .success(let serverWorkspaces):
                    loaded.append(contentsOf: serverWorkspaces)
                case .failure(let serverID, let serverName, let message):
                    failures.append((serverName, message))
                    shareComposerLog.error(
                        "Workspace load failed for server \(serverID.prefix(12), privacy: .public): \(message, privacy: .public)"
                    )
                }
            }

            self.workspaces = loaded.sorted {
                $0.server.sortOrder == $1.server.sortOrder
                    ? $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
                    : $0.server.sortOrder < $1.server.sortOrder
            }
            guard let first = self.workspaces.first else {
                self.workspaceButton.configuration?.title = "Workspaces unavailable"
                self.statusLabel.textColor = .systemRed
                self.statusLabel.text = failures.first.map {
                    "Couldn’t load \($0.serverName): \($0.message)"
                } ?? "No workspaces are available on the paired servers."
                self.retryButton.isHidden = false
                return
            }

            self.select(first)
            self.workspaceButton.isEnabled = true
            self.updateWorkspaceMenu()
            if !failures.isEmpty {
                self.statusLabel.text = "Some paired servers are unavailable."
                self.retryButton.isHidden = false
            }
        }
    }

    @objc private func retryWorkspaceLoad() {
        loadWorkspaces()
    }

    private func updateWorkspaceMenu() {
        let showsServer = Set(workspaces.map(\.server.id)).count > 1
        workspaceButton.menu = UIMenu(children: workspaces.map { workspace in
            UIAction(
                title: showsServer ? "\(workspace.name) — \(workspace.server.name)" : workspace.name,
                image: UIImage(systemName: "folder"),
                state: workspace.id == selectedWorkspace?.id && workspace.server.id == selectedWorkspace?.server.id ? .on : .off
            ) { [weak self] _ in
                Task { @MainActor in
                    self?.select(workspace)
                    self?.updateWorkspaceMenu()
                }
            }
        })
    }

    private func select(_ workspace: ShareQuickSessionWorkspace) {
        selectedWorkspace = workspace
        let showsServer = Set(workspaces.map(\.server.id)).count > 1
        workspaceButton.configuration?.title = showsServer ? "\(workspace.name) — \(workspace.server.name)" : workspace.name
        statusLabel.text = "Session starts immediately on \(workspace.server.name)."
        updateSendEnabled()
    }

    func textViewDidChange(_ textView: UITextView) {
        updateSendEnabled()
    }

    private func updateSendEnabled() {
        sendButton.isEnabled = sendTask == nil
            && selectedWorkspace != nil
            && (!textView.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !payload.files.isEmpty)
    }

    @objc private func send() {
        guard sendTask == nil,
              let selectedWorkspace,
              let inboxURL = ShareQuickSessionPayload.inboxURL else { return }
        let attachments = payload.files.map {
            ShareQuickSessionDraftAttachment(
                name: $0.name,
                mimeType: $0.mimeType,
                fileURL: inboxURL.appendingPathComponent($0.relativePath, isDirectory: false)
            )
        }
        setSending(true)
        sendTask = Task { [weak self] in
            guard let self else { return }
            do {
                let sender = ShareQuickSessionSender.live(server: selectedWorkspace.server)
                _ = try await sender.send(
                    payloadID: payload.id,
                    text: textView.text,
                    attachments: attachments,
                    workspace: selectedWorkspace
                )
                guard !Task.isCancelled else { return }
                ShareQuickSessionPayload.removePayloadFiles(id: payload.id)
                onFinish(false)
            } catch is CancellationError {
                return
            } catch {
                self.sendTask = nil
                self.setSending(false)
                self.statusLabel.textColor = .systemRed
                self.statusLabel.text = "Couldn’t start the session: \(error.localizedDescription)"
                UIAccessibility.post(notification: .announcement, argument: self.statusLabel.text)
            }
        }
    }

    private func setSending(_ sending: Bool) {
        cancelButton.isEnabled = !sending
        workspaceButton.isEnabled = !sending
        retryButton.isEnabled = !sending
        textView.isEditable = !sending
        sendButton.isEnabled = false
        sendButton.configuration?.title = sending ? "Sending…" : "Send"
        statusLabel.textColor = .secondaryLabel
        if sending {
            statusLabel.text = "Starting session and sending shared content…"
            activity.startAnimating()
        } else {
            activity.stopAnimating()
            updateSendEnabled()
        }
    }

    @objc private func cancel() {
        loadTask?.cancel()
        sendTask?.cancel()
        ShareQuickSessionPayload.removePayloadFiles(id: payload.id)
        onFinish(true)
    }
}
