import AVFoundation
import Observation

enum AudioRecorderError: LocalizedError {
    case couldNotStart

    var errorDescription: String? {
        String(localized: "Could not start recording.")
    }
}

/// Records one segment at a time: AAC in m4a, mono, 16 kHz, ~32 kbit/s (~15 MB per hour).
/// Keeps running on a locked screen thanks to the `audio` background mode.
@MainActor
@Observable
final class AudioRecorder {
    enum State: Equatable {
        case idle
        case recording
        case paused
    }

    private(set) var state: State = .idle
    private(set) var elapsed: TimeInterval = 0
    /// Normalized input level, 0...1.
    private(set) var level: Float = 0
    /// A call or Siri paused the recording; the UI offers to continue.
    private(set) var wasInterrupted = false

    @ObservationIgnored private var recorder: AVAudioRecorder?
    @ObservationIgnored private var meterTask: Task<Void, Never>?
    @ObservationIgnored private var observers: [NSObjectProtocol] = []

    private var settings: [String: Any] {
        [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 16_000,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: 32_000,
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue,
        ]
    }

    func requestPermission() async -> Bool {
        await AVAudioApplication.requestRecordPermission()
    }

    func start(url: URL) throws {
        guard state == .idle else { return }
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker, .allowBluetoothHFP])
        try session.setActive(true)

        let recorder = try AVAudioRecorder(url: url, settings: settings)
        recorder.isMeteringEnabled = true
        guard recorder.record() else {
            try? session.setActive(false, options: .notifyOthersOnDeactivation)
            throw AudioRecorderError.couldNotStart
        }
        self.recorder = recorder
        elapsed = 0
        wasInterrupted = false
        state = .recording
        observeSession()
        startMetering()
    }

    func pause() {
        guard state == .recording else { return }
        recorder?.pause()
        state = .paused
        level = 0
    }

    func resume() {
        guard state == .paused, let recorder else { return }
        try? AVAudioSession.sharedInstance().setActive(true)
        if recorder.record() {
            state = .recording
            wasInterrupted = false
        }
    }

    /// Finishes the file and returns the recorded duration.
    @discardableResult
    func stop() -> TimeInterval {
        guard let recorder else { return 0 }
        let duration = max(recorder.currentTime, elapsed)
        recorder.stop()
        self.recorder = nil
        meterTask?.cancel()
        meterTask = nil
        for observer in observers {
            NotificationCenter.default.removeObserver(observer)
        }
        observers = []
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        state = .idle
        level = 0
        wasInterrupted = false
        return duration
    }

    private func startMetering() {
        meterTask?.cancel()
        meterTask = Task { [weak self] in
            while !Task.isCancelled {
                self?.updateMeter()
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
    }

    private func updateMeter() {
        guard let recorder, state == .recording else { return }
        recorder.updateMeters()
        elapsed = recorder.currentTime
        let decibels = recorder.averagePower(forChannel: 0)
        level = max(0, min(1, (decibels + 50) / 50))
    }

    private func observeSession() {
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { @Sendable [weak self] note in
            let rawType = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
            MainActor.assumeIsolated {
                self?.handleInterruption(rawType: rawType)
            }
        })
        observers.append(center.addObserver(forName: AVAudioSession.mediaServicesWereResetNotification, object: nil, queue: .main) { @Sendable [weak self] _ in
            MainActor.assumeIsolated {
                self?.handleInterruption(rawType: AVAudioSession.InterruptionType.began.rawValue)
            }
        })
    }

    /// The system has already paused the recorder when an interruption begins.
    /// We never resume on our own: the user decides whether to continue.
    private func handleInterruption(rawType: UInt?) {
        guard rawType == AVAudioSession.InterruptionType.began.rawValue, state == .recording else { return }
        if let recorder {
            elapsed = recorder.currentTime
            recorder.pause()
        }
        state = .paused
        level = 0
        wasInterrupted = true
    }
}
