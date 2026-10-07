// Hold-space voice for the prompt box: the Mac's own speech engine turns speech into text.
import AVFoundation
import Foundation
import Speech

final class Voice {
    /// (text so far, is it final, error message)
    var onUpdate: ((String, Bool, String?) -> Void)?
    private let engine = AVAudioEngine()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-IN")) ?? SFSpeechRecognizer()
    private var listening = false
    private var lastText = ""

    func start() {
        guard !listening else { return }
        SFSpeechRecognizer.requestAuthorization { status in
            guard status == .authorized else {
                return self.fail("Speech is not allowed. Open System Settings, Privacy, Speech Recognition, and turn on Claude Stack.")
            }
            AVCaptureDevice.requestAccess(for: .audio) { ok in
                guard ok else {
                    return self.fail("The microphone is not allowed. Open System Settings, Privacy, Microphone, and turn on Claude Stack.")
                }
                DispatchQueue.main.async { self.begin() }
            }
        }
    }

    private func begin() {
        guard let recognizer, recognizer.isAvailable else { return fail("Speech engine is not available right now.") }
        let req = SFSpeechAudioBufferRecognitionRequest()
        req.shouldReportPartialResults = true
        if recognizer.supportsOnDeviceRecognition { req.requiresOnDeviceRecognition = true }
        request = req
        lastText = ""
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { buf, _ in req.append(buf) }
        engine.prepare()
        do { try engine.start() } catch { return fail("Could not start the microphone: \(error.localizedDescription)") }
        listening = true
        task = recognizer.recognitionTask(with: req) { [weak self] result, error in
            guard let self else { return }
            if let result {
                self.lastText = result.bestTranscription.formattedString
                let final = result.isFinal
                DispatchQueue.main.async { self.onUpdate?(self.lastText, final, nil) }
                if final { self.cleanUp() }
            } else if error != nil {
                // Ending with no speech also lands here. Report what we have as final.
                DispatchQueue.main.async { self.onUpdate?(self.lastText, true, nil) }
                self.cleanUp()
            }
        }
    }

    func stop() {
        guard listening else { return }
        engine.stop()
        engine.inputNode.removeTap(onBus: 0)
        request?.endAudio()
        listening = false
        // The final result comes through the task callback.
    }

    private func cleanUp() {
        if engine.isRunning { engine.stop(); engine.inputNode.removeTap(onBus: 0) }
        request = nil; task = nil; listening = false
    }

    private func fail(_ msg: String) {
        DispatchQueue.main.async { self.onUpdate?("", true, msg) }
    }
}
