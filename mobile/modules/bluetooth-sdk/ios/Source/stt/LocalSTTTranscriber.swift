import Foundation

protocol LocalSTTTranscriber: AnyObject, Sendable {
    var runtimeId: String { get }
    var canInitializeSelectedModelInProcess: Bool { get }
    var hasActiveRecognizer: Bool { get }
    @discardableResult func initialize() -> Bool
    func acceptAudio(pcm16le: Data)
    func shutdown()
}
