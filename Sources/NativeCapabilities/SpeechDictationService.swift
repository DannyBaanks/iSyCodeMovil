import Foundation
#if canImport(AVFoundation)
import AVFoundation
#endif
#if canImport(Speech)
import Speech
#endif

public enum SpeechDictationLocale: String, CaseIterable, Identifiable, Sendable {
    case esMX = "es-MX"
    case esES = "es-ES"
    case enUS = "en-US"

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .esMX: return "Español (México)"
        case .esES: return "Español (España)"
        case .enUS: return "English (US)"
        }
    }

    public var shortTag: String {
        switch self {
        case .esMX: return "ES-MX"
        case .esES: return "ES"
        case .enUS: return "EN"
        }
    }
}

public enum SpeechRecognitionAvailability: Equatable, Sendable {
    case onDevice(locale: String)
    case requiresNetwork(locale: String)
    case unavailable(reason: String)

    public var badgeText: String {
        switch self {
        case .onDevice: return "En este iPhone"
        case .requiresNetwork: return "Usa Apple Speech (red)"
        case .unavailable: return "No disponible"
        }
    }
}

public enum SpeechDictationState: Equatable, Sendable {
    case idle
    case requestingPermissions
    case recording(elapsedSeconds: Int, level: Float)
    case transcribing
    case error(String)

    public var isRecording: Bool {
        if case .recording = self { return true }
        return false
    }

    public var isTranscribing: Bool {
        if case .transcribing = self { return true }
        return false
    }
}

/// Pure text insertion utility preserving existing composer text cleanly.
public enum SpeechTextMerger {
    public static func merge(existing: String, transcript: String) -> String {
        let cleanTranscript = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanTranscript.isEmpty else { return existing }
        if existing.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return cleanTranscript
        }
        if let last = existing.last, last.isWhitespace || last.isNewline {
            return existing + cleanTranscript
        }
        return existing + " " + cleanTranscript
    }
}

/// Asynchronous native record -> stop -> transcribe dictation controller using AVFoundation + Speech.
/// Never auto-sends transcribed text, preserves existing drafts, and cleans up temporary recordings.
@MainActor
public final class SpeechDictationService: ObservableObject {
    public static let shared = SpeechDictationService()

    @Published public private(set) var state: SpeechDictationState = .idle
    @Published public var selectedLocale: SpeechDictationLocale = .esMX {
        didSet { UserDefaults.standard.set(selectedLocale.rawValue, forKey: "isycode.dictation.locale") }
    }
    /// When true (default), allows Apple's Speech service over network only if on-device recognition is unavailable
    /// for the chosen locale, and clearly labels that mode in the UI.
    @Published public var allowNetworkFallback: Bool = true {
        didSet { UserDefaults.standard.set(allowNetworkFallback, forKey: "isycode.dictation.networkFallback") }
    }

    #if canImport(AVFoundation)
    private var recorder: AVAudioRecorder?
    #endif
    private var tempAudioURL: URL?
    private var meterTimer: Timer?
    private var recordingStart: Date?
    private var interruptionObserver: NSObjectProtocol?
    private var routeObserver: NSObjectProtocol?
    private var captureID = UUID()
    private var transcriptionTask: Task<Void, Never>?
    private var activeCompletion: (@MainActor (String) -> Void)?

    public init() {
        if let saved = UserDefaults.standard.string(forKey: "isycode.dictation.locale"),
           let loc = SpeechDictationLocale(rawValue: saved) {
            self.selectedLocale = loc
        }
        if UserDefaults.standard.object(forKey: "isycode.dictation.networkFallback") != nil {
            self.allowNetworkFallback = UserDefaults.standard.bool(forKey: "isycode.dictation.networkFallback")
        }
    }

    public func currentAvailability() -> SpeechRecognitionAvailability {
        #if canImport(Speech)
        guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: selectedLocale.rawValue)) else {
            return .unavailable(reason: "Idioma \(selectedLocale.displayName) no soportado por Speech.")
        }
        if recognizer.supportsOnDeviceRecognition {
            return .onDevice(locale: selectedLocale.rawValue)
        }
        if recognizer.isAvailable {
            return .requiresNetwork(locale: selectedLocale.rawValue)
        }
        return .unavailable(reason: "El servicio de reconocimiento de voz de Apple no está disponible en este momento.")
        #else
        return .unavailable(reason: "Framework Speech no disponible en este host.")
        #endif
    }

    // MARK: - Actions

    public func startRecording(onTranscript: @escaping @MainActor (String) -> Void) async {
        guard state == .idle || { if case .error = state { return true }; return false }() else { return }
        let requestID = UUID()
        captureID = requestID
        activeCompletion = onTranscript
        state = .requestingPermissions

        let perms = await requestPermissionsIfNeeded()
        guard captureID == requestID else { return }
        guard perms.granted else {
            state = .error(perms.message ?? "Faltan permisos de micrófono o reconocimiento de voz.")
            return
        }

        let availability = currentAvailability()
        switch availability {
        case .unavailable(let reason):
            state = .error(reason)
            return
        case .requiresNetwork where !allowNetworkFallback:
            state = .error("Este iPhone requiere conexión a Apple Speech para '\(selectedLocale.displayName)'. Activa 'Permitir reconocimiento en red' o descarga el idioma en Ajustes.")
            return
        case .onDevice, .requiresNetwork:
            break
        }

        #if canImport(AVFoundation)
        let audioURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("isycode-dictation-\(UUID().uuidString).m4a")
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playAndRecord, mode: .measurement, options: [.defaultToSpeaker, .allowBluetooth])
            try session.setActive(true, options: .notifyOthersOnDeactivation)

            let settings: [String: Any] = [
                AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
                AVSampleRateKey: 16_000,
                AVNumberOfChannelsKey: 1,
                AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue
            ]
            let newRecorder = try AVAudioRecorder(url: audioURL, settings: settings)
            newRecorder.isMeteringEnabled = true
            guard newRecorder.prepareToRecord(), newRecorder.record() else {
                deactivateAudioSession()
                state = .error("No se pudo iniciar la grabación de audio.")
                return
            }

            self.recorder = newRecorder
            self.tempAudioURL = audioURL
            self.recordingStart = Date()
            registerAudioObservers()
            startMeterTimer()
            state = .recording(elapsedSeconds: 0, level: 0)
        } catch {
            deactivateAudioSession()
            try? FileManager.default.removeItem(at: audioURL)
            state = .error("Error al abrir el micrófono: \(error.localizedDescription)")
        }
        #else
        state = .error("AVFoundation no disponible en este entorno.")
        #endif
    }

    public func stopAndTranscribe() {
        guard state.isRecording else { return }
        stopCaptureHardware()

        guard let audioURL = tempAudioURL else {
            state = .error("No se encontró el audio grabado.")
            return
        }

        state = .transcribing
        let requestID = captureID
        let completion = activeCompletion
        let localeID = selectedLocale.rawValue
        let networkAllowed = allowNetworkFallback

        transcriptionTask = Task { [weak self] in
            guard let self else { return }
            defer {
                self.cleanupAudioFile(audioURL)
                if self.captureID == requestID {
                    self.tempAudioURL = nil
                    self.activeCompletion = nil
                }
            }
            do {
                let text = try await Self.transcribeAudioFile(
                    at: audioURL,
                    localeIdentifier: localeID,
                    allowNetworkFallback: networkAllowed
                )
                guard self.captureID == requestID, !Task.isCancelled else { return }
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmed.isEmpty {
                    self.state = .error("No se detectó voz entendible en la grabación.")
                } else {
                    self.state = .idle
                    completion?(trimmed)
                }
            } catch is CancellationError {
                guard self.captureID == requestID else { return }
                self.state = .idle
            } catch {
                guard self.captureID == requestID else { return }
                self.state = .error(error.localizedDescription)
            }
        }
    }

    public func cancel() {
        captureID = UUID()
        transcriptionTask?.cancel()
        transcriptionTask = nil
        stopCaptureHardware()
        if let audioURL = tempAudioURL {
            cleanupAudioFile(audioURL)
            tempAudioURL = nil
        }
        activeCompletion = nil
        state = .idle
    }

    public func clearError() {
        if case .error = state {
            state = .idle
        }
    }

    // MARK: - Internals

    private func requestPermissionsIfNeeded() async -> (granted: Bool, message: String?) {
        #if canImport(AVFoundation) && canImport(Speech)
        let micGranted = await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
            AVAudioSession.sharedInstance().requestRecordPermission { ok in
                cont.resume(returning: ok)
            }
        }
        guard micGranted else {
            return (false, "Permiso de micrófono denegado. Puedes activarlo en Ajustes → ISyCode Móvil.")
        }

        let speechStatus = await withCheckedContinuation { (cont: CheckedContinuation<SFSpeechRecognizerAuthorizationStatus, Never>) in
            SFSpeechRecognizer.requestAuthorization { status in
                cont.resume(returning: status)
            }
        }
        switch speechStatus {
        case .authorized:
            return (true, nil)
        case .denied:
            return (false, "Permiso de Reconocimiento de voz denegado en Ajustes de iOS.")
        case .restricted:
            return (false, "El reconocimiento de voz está restringido en este dispositivo.")
        case .notDetermined:
            return (false, "El permiso de voz no quedó confirmado.")
        @unknown default:
            return (false, "Estado de autorización de voz desconocido.")
        }
        #else
        return (false, "Micrófono y Speech no están disponibles en este host.")
        #endif
    }

    private func startMeterTimer() {
        meterTimer?.invalidate()
        meterTimer = Timer.scheduledTimer(withTimeInterval: 0.12, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.state.isRecording else { return }
                #if canImport(AVFoundation)
                self.recorder?.updateMeters()
                let db = self.recorder?.averagePower(forChannel: 0) ?? -60
                let normalized = max(0, min(1, (db + 52) / 52))
                #else
                let normalized: Float = 0
                #endif
                let elapsed = Int(Date().timeIntervalSince(self.recordingStart ?? Date()))
                self.state = .recording(elapsedSeconds: elapsed, level: normalized)
            }
        }
    }

    private func stopCaptureHardware() {
        meterTimer?.invalidate()
        meterTimer = nil
        unregisterAudioObservers()
        #if canImport(AVFoundation)
        recorder?.stop()
        recorder = nil
        #endif
        deactivateAudioSession()
    }

    private func deactivateAudioSession() {
        #if canImport(AVFoundation)
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        #endif
    }

    private func registerAudioObservers() {
        #if canImport(AVFoundation)
        unregisterAudioObservers()
        interruptionObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                  AVAudioSession.InterruptionType(rawValue: raw) == .began else { return }
            Task { @MainActor [weak self] in
                self?.stopAndTranscribe()
            }
        }
        routeObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard let raw = note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt,
                  AVAudioSession.RouteChangeReason(rawValue: raw) == .oldDeviceUnavailable else { return }
            Task { @MainActor [weak self] in
                self?.stopAndTranscribe()
            }
        }
        #endif
    }

    private func unregisterAudioObservers() {
        if let interruptionObserver {
            NotificationCenter.default.removeObserver(interruptionObserver)
            self.interruptionObserver = nil
        }
        if let routeObserver {
            NotificationCenter.default.removeObserver(routeObserver)
            self.routeObserver = nil
        }
    }

    private func cleanupAudioFile(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }

    private static func transcribeAudioFile(
        at url: URL,
        localeIdentifier: String,
        allowNetworkFallback: Bool
    ) async throws -> String {
        #if canImport(Speech)
        guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: localeIdentifier)) else {
            throw NSError(domain: "SpeechDictation", code: 1, userInfo: [NSLocalizedDescriptionKey: "No se pudo inicializar el reconocedor para \(localeIdentifier)."])
        }
        guard recognizer.isAvailable else {
            throw NSError(domain: "SpeechDictation", code: 2, userInfo: [NSLocalizedDescriptionKey: "El reconocedor de voz no está disponible en este momento."])
        }
        if !recognizer.supportsOnDeviceRecognition && !allowNetworkFallback {
            throw NSError(domain: "SpeechDictation", code: 3, userInfo: [NSLocalizedDescriptionKey: "Falta soporte sin red para \(localeIdentifier) y desactivaste el envío a Apple Speech."])
        }

        let request = SFSpeechURLRecognitionRequest(url: url)
        request.shouldReportPartialResults = false
        request.requiresOnDeviceRecognition = recognizer.supportsOnDeviceRecognition

        let box = OneShotTranscriptionBox()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let task = recognizer.recognitionTask(with: request) { result, error in
                    if let error {
                        box.finish(with: .failure(error), continuation: continuation)
                        return
                    }
                    if let result, result.isFinal {
                        box.finish(with: .success(result.bestTranscription.formattedString), continuation: continuation)
                    }
                }
                box.storeTask(task)
            }
        } onCancel: {
            box.cancelTask()
        }
        #else
        throw NSError(domain: "SpeechDictation", code: 99, userInfo: [NSLocalizedDescriptionKey: "Speech framework no disponible en este host."])
        #endif
    }
}

#if canImport(Speech)
private final class OneShotTranscriptionBox: @unchecked Sendable {
    private let lock = NSLock()
    private var completed = false
    private var task: SFSpeechRecognitionTask?

    func storeTask(_ t: SFSpeechRecognitionTask) {
        lock.lock()
        task = t
        let alreadyCompleted = completed
        lock.unlock()
        if alreadyCompleted { t.cancel() }
    }

    func cancelTask() {
        lock.lock()
        let t = task
        completed = true
        lock.unlock()
        t?.cancel()
    }

    func finish(with result: Result<String, Error>, continuation: CheckedContinuation<String, Error>) {
        lock.lock()
        guard !completed else {
            lock.unlock()
            return
        }
        completed = true
        lock.unlock()
        switch result {
        case .success(let value): continuation.resume(returning: value)
        case .failure(let error): continuation.resume(throwing: error)
        }
    }
}
#endif
