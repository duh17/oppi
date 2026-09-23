import Foundation
import Testing
@testable import Oppi

@Suite("Server detail configuration")
struct ServerDetailConfigurationTests {
    @Test func dictionaryEditorLivesInServerSettingsNotAppVoiceSettings() throws {
        let appleRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let server = try String(
            contentsOf: appleRoot.appending(path: "Oppi/Features/Servers/ServerDetailView.swift"),
            encoding: .utf8
        )
        let settings = try String(
            contentsOf: appleRoot.appending(path: "Oppi/Features/Settings/SettingsView.swift"),
            encoding: .utf8
        )
        let start = try #require(server.range(of: "private var serverSettingsSections"))
        let end = try #require(server.range(of: "private var connectionStatusTitle", range: start.upperBound..<server.endIndex))
        let serverSettings = String(server[start.lowerBound..<end.lowerBound])
        #expect(serverSettings.contains("DictationDictionaryView(workspaceId: nil)"))
        #expect(serverSettings.contains("server.dictationDictionary"))
        #expect(!settings.contains("DictationDictionaryView"))
        #expect(!settings.contains("Dictation Dictionary"))
    }

    @Test func mobileOutputGuideStateDistinguishesLoadingAvailableAndFailure() {
        #expect(ServerDetailMobileOutputGuideState.resolve(configuration: nil, isLoading: true, error: nil) == .loading)
        #expect(ServerDetailMobileOutputGuideState.resolve(
            configuration: MobileOutputGuideConfiguration(enabled: true, revision: 4),
            isLoading: false,
            error: nil
        ) == .available(enabled: true, revision: 4, error: nil))
        #expect(ServerDetailMobileOutputGuideState.resolve(
            configuration: nil,
            isLoading: false,
            error: "Offline"
        ) == .failed("Offline"))
    }

    @Test func mobileOutputGuideFailureKeepsLastTrustworthyValueAndSurfacesTheError() {
        let current = MobileOutputGuideConfiguration(enabled: false, revision: 7)

        #expect(ServerDetailMobileOutputGuideState.resolve(
            configuration: current,
            isLoading: false,
            error: "Save failed"
        ) == .available(enabled: false, revision: 7, error: "Save failed"))
        #expect(ServerDetailMobileOutputGuideState.resolve(
            configuration: current,
            isLoading: true,
            error: "Refresh failed"
        ) == .available(enabled: false, revision: 7, error: "Refresh failed"))
    }
}
