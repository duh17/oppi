import Foundation

extension ServerConnection {
    /// The Godot pane's player link for `project` on this server: pinned and routed as
    /// the connection's other sockets, its access renewed as theirs is
    /// (`StreamAuthRenewer`, `auth_renew`).
    func makeGodotPlayerLink(project: String) -> GodotPlayerLink? {
        #if DEBUG
        if let scripted = Self._godotPlayerLinkForTesting { return scripted(project) }
        #endif
        guard let selection = endpointSelection, let credentials,
              let url = GodotPlayerLink.url(baseURL: selection.baseURL, project: project) else { return nil }
        let access = streamAccess(role: "godot_link")
        return GodotPlayerLink(
            url: url,
            token: access.token,
            renewer: access.renewer,
            tlsCertFingerprint: credentials.normalizedTLSCertFingerprint,
            tlsServerName: selection.tlsServerName,
            tailnetRoute: route.configuredTailnetRoute
        )
    }

    #if DEBUG
    /// A preview's scripted link: a preview connection has no server socket.
    @MainActor static var _godotPlayerLinkForTesting: ((_ project: String) -> GodotPlayerLink?)?
    #endif
}
