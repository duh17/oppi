import Foundation

@MainActor
protocol DictationTransport: AnyObject {
    func sendDictation(_ message: ClientMessage) async throws
    func sendDictationAudio(_ data: Data) async throws
    func closeDictationTransport()
}
