@preconcurrency import AVFoundation
import Foundation
import Observation
@preconcurrency import Speech

/// Press-and-hold dictation for the capture sheet. Recognition runs on device when the phone supports it,
/// so the audio never leaves the device; permissions are asked the first time the mic is pressed.
@MainActor
@Observable
final class VoiceRecognizer {
    enum State: Equatable {
        case idle
        case listening
        case denied(String)
        case unavailable
    }

    private(set) var state: State = .idle
    private(set) var transcript = ""

    @ObservationIgnored private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "zh-CN"))
    @ObservationIgnored private let engine = AVAudioEngine()
    @ObservationIgnored private var request: SFSpeechAudioBufferRecognitionRequest?
    @ObservationIgnored private var task: SFSpeechRecognitionTask?

    var isListening: Bool { state == .listening }

    func start() async {
        guard state != .listening else { return }
        guard let recognizer, recognizer.isAvailable else {
            state = .unavailable
            return
        }
        guard await Self.authorize() else {
            state = .denied("需要在系统设置里允许麦克风和语音识别")
            return
        }
        transcript = ""
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.record, mode: .measurement, options: .duckOthers)
            try session.setActive(true, options: .notifyOthersOnDeactivation)

            let request = SFSpeechAudioBufferRecognitionRequest()
            request.shouldReportPartialResults = true
            if recognizer.supportsOnDeviceRecognition { request.requiresOnDeviceRecognition = true }
            self.request = request

            let input = engine.inputNode
            input.installTap(onBus: 0, bufferSize: 1024, format: input.outputFormat(forBus: 0)) { buffer, _ in
                request.append(buffer)
            }
            engine.prepare()
            try engine.start()
            state = .listening
            task = recognizer.recognitionTask(with: request) { [weak self] result, error in
                let text = result?.bestTranscription.formattedString
                let isFinal = result?.isFinal ?? false
                Task { @MainActor in
                    guard let self else { return }
                    if let text { self.transcript = text }
                    if error != nil || isFinal { self.finish() }
                }
            }
        } catch {
            finish()
            state = .unavailable
        }
    }

    /// Stop listening; the transcript so far stays
    func stop() {
        request?.endAudio()
        finish()
    }

    private func finish() {
        if engine.isRunning {
            engine.stop()
            engine.inputNode.removeTap(onBus: 0)
        }
        task?.cancel()
        task = nil
        request = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        if state == .listening { state = .idle }
    }

    private static func authorize() async -> Bool {
        let speech = await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0 == .authorized) }
        }
        guard speech else { return false }
        return await AVAudioApplication.requestRecordPermission()
    }
}
