import SwiftUI
import AVFoundation
import AppKit
import UniformTypeIdentifiers
import Combine

// MARK: - Models & Enums

/// Audio file export format choices
enum AudioExportFormat: String, CaseIterable, Identifiable {
    case wav = "WAV (Uncompressed PCM)"
    case m4a = "M4A (AAC Encoded)"
    
    var id: String { self.rawValue }
    
    var utType: UTType {
        switch self {
        case .wav: return .wav
        case .m4a: return .mpeg4Audio
        }
    }
    
    var fileExtension: String {
        switch self {
        case .wav: return "wav"
        case .m4a: return "m4a"
        }
    }
}

/// Export destination selection mode
enum ExportDestinationMode: String, CaseIterable, Identifiable {
    case alwaysAsk = "Always Ask (Save Panel)"
    case customFolder = "Custom Output Folder"
    
    var id: String { self.rawValue }
}

/// Represents current status of speech synthesis
enum PlaybackState: Equatable {
    case stopped
    case playing
    case paused
    case previewing
    case exporting(progress: Double)
    
    var statusTitle: String {
        switch self {
        case .stopped: return "Ready"
        case .playing: return "Speaking..."
        case .paused: return "Paused"
        case .previewing: return "Previewing..."
        case .exporting(let p): return String(format: "Exporting... %.0f%%", p * 100)
        }
    }
    
    var statusColor: Color {
        switch self {
        case .stopped: return .secondary
        case .playing: return .green
        case .paused: return .orange
        case .previewing: return .purple
        case .exporting: return .accentColor
        }
    }
}

/// Helper model wrapping AVSpeechSynthesisVoice with locale metadata
struct VoiceItem: Identifiable, Hashable {
    let id: String
    let voice: AVSpeechSynthesisVoice
    let name: String
    let languageCode: String
    let localizedLanguage: String
    
    init(voice: AVSpeechSynthesisVoice) {
        self.id = voice.identifier
        self.voice = voice
        self.name = voice.name
        self.languageCode = voice.language
        
        let locale = Locale(identifier: voice.language)
        self.localizedLanguage = locale.localizedString(forLanguageCode: locale.language.languageCode?.identifier ?? voice.language) ?? voice.language
    }
    
    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
    
    static func == (lhs: VoiceItem, rhs: VoiceItem) -> Bool {
        lhs.id == rhs.id
    }
}

/// Rule definition for text replacements and IPA phoneme annotations
struct PronunciationRule: Identifiable, Codable, Equatable {
    var id: UUID = UUID()
    var originalWord: String
    var replacement: String
    var isIPA: Bool
    var isEnabled: Bool = true
}

// MARK: - Highlightable Text Editor (AppKit Representable)

/// Custom text editor that supports live character range highlighting during speech playback
struct HighlightableTextEditor: NSViewRepresentable {
    @Binding var text: String
    var highlightedRange: NSRange?
    
    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }
    
    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSTextView.scrollableTextView()
        guard let textView = scrollView.documentView as? NSTextView else { return scrollView }
        
        textView.delegate = context.coordinator
        textView.isRichText = false
        textView.font = NSFont.systemFont(ofSize: 14)
        textView.backgroundColor = .textBackgroundColor
        textView.drawsBackground = true
        textView.string = text
        scrollView.drawsBackground = true
        
        return scrollView
    }
    
    func updateNSView(_ nsView: NSScrollView, context: Context) {
        guard let textView = nsView.documentView as? NSTextView else { return }
        
        if textView.string != text {
            textView.string = text
        }
        
        guard let layoutManager = textView.layoutManager, let textStorage = textView.textStorage else { return }
        let fullRange = NSRange(location: 0, length: textStorage.length)
        
        // Remove previous word highlight attributes across the document
        layoutManager.removeTemporaryAttribute(.backgroundColor, forCharacterRange: fullRange)
        layoutManager.removeTemporaryAttribute(.foregroundColor, forCharacterRange: fullRange)
        
        // Apply high-visibility highlight to the word currently being spoken
        if let range = highlightedRange, range.location != NSNotFound, NSMaxRange(range) <= textStorage.length {
            layoutManager.addTemporaryAttributes([
                .backgroundColor: NSColor.systemYellow,
                .foregroundColor: NSColor.black
            ], forCharacterRange: range)
            
            textView.scrollRangeToVisible(range)
        }
    }
    
    class Coordinator: NSObject, NSTextViewDelegate {
        var parent: HighlightableTextEditor
        
        init(_ parent: HighlightableTextEditor) {
            self.parent = parent
        }
        
        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            self.parent.text = textView.string
        }
    }
}

// MARK: - Pronunciation Manager

@MainActor
final class PronunciationManager: ObservableObject {
    @Published var rules: [PronunciationRule] = [] {
        didSet {
            saveRules()
        }
    }
    
    private let storageKey = "SWSPronunciationRules"
    
    init() {
        loadRules()
    }
    
    func addRule(original: String, replacement: String, isIPA: Bool) {
        let trimmedOriginal = original.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedReplacement = replacement.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedOriginal.isEmpty && !trimmedReplacement.isEmpty else { return }
        
        let newRule = PronunciationRule(originalWord: trimmedOriginal, replacement: trimmedReplacement, isIPA: isIPA)
        rules.append(newRule)
    }
    
    func removeRule(at offsets: IndexSet) {
        rules.remove(atOffsets: offsets)
    }
    
    func deleteRule(_ rule: PronunciationRule) {
        rules.removeAll(where: { $0.id == rule.id })
    }
    
    func toggleRule(_ rule: PronunciationRule) {
        if let idx = rules.firstIndex(where: { $0.id == rule.id }) {
            rules[idx].isEnabled.toggle()
        }
    }
    
    /// Processes text string applying enabled pronunciation rules
    func processUtteranceText(_ input: String) -> NSAttributedString {
        let activeRules = rules.filter { $0.isEnabled }
        guard !activeRules.isEmpty else {
            return NSAttributedString(string: input)
        }
        
        var currentText = input
        // Apply non-IPA plain text substitutions first
        for rule in activeRules where !rule.isIPA {
            let pattern = "\\b\(NSRegularExpression.escapedPattern(for: rule.originalWord))\\b"
            if let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) {
                let range = NSRange(location: 0, length: currentText.utf16.count)
                currentText = regex.stringByReplacingMatches(in: currentText, options: [], range: range, withTemplate: rule.replacement)
            }
        }
        
        let attributed = NSMutableAttributedString(string: currentText)
        
        // Apply IPA annotations to matched ranges
        for rule in activeRules where rule.isIPA {
            let pattern = "\\b\(NSRegularExpression.escapedPattern(for: rule.originalWord))\\b"
            if let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) {
                let matches = regex.matches(in: currentText, options: [], range: NSRange(location: 0, length: currentText.utf16.count))
                for match in matches {
                    let ipaKey = NSAttributedString.Key("AVSpeechSynthesisIPAPhonemeAttribute")
                    attributed.addAttribute(ipaKey, value: rule.replacement, range: match.range)
                }
            }
        }
        
        return attributed
    }
    
    private func loadRules() {
        if let data = UserDefaults.standard.data(forKey: storageKey),
           let decoded = try? JSONDecoder().decode([PronunciationRule].self, from: data) {
            self.rules = decoded
        }
    }
    
    private func saveRules() {
        if let encoded = try? JSONEncoder().encode(rules) {
            UserDefaults.standard.set(encoded, forKey: storageKey)
        }
    }
}

// MARK: - Voice Manager

@MainActor
final class VoiceManager: ObservableObject {
    @Published var availableVoices: [VoiceItem] = []
    @Published var englishOnly: Bool = true {
        didSet {
            UserDefaults.standard.set(englishOnly, forKey: "FilterEnglishVoicesOnly")
        }
    }
    @Published var favoriteVoiceIDs: Set<String> = [] {
        didSet {
            saveFavorites()
        }
    }
    @Published var selectedVoiceID: String = "" {
        didSet {
            UserDefaults.standard.set(selectedVoiceID, forKey: "SelectedVoiceID")
        }
    }
    @Published var searchQuery: String = ""
    
    private let favoritesKey = "FavoriteVoiceIDs"
    private var cancellables = Set<AnyCancellable>()
    
    init() {
        if UserDefaults.standard.object(forKey: "FilterEnglishVoicesOnly") != nil {
            self.englishOnly = UserDefaults.standard.bool(forKey: "FilterEnglishVoicesOnly")
        } else {
            self.englishOnly = true
        }
        loadFavorites()
        refreshVoices()
        restoreSelectedVoice()
        setupVoiceChangeObserver()
    }
    
    /// Fetches all system voices installed on macOS
    func refreshVoices() {
        let systemVoices = AVSpeechSynthesisVoice.speechVoices()
        let items = systemVoices.map { VoiceItem(voice: $0) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        
        self.availableVoices = items
        
        // Fallback gracefully if selected voice is unavailable/removed
        if !items.contains(where: { $0.id == selectedVoiceID }) {
            if let defaultVoice = AVSpeechSynthesisVoice(language: Locale.current.identifier) ?? systemVoices.first {
                selectedVoiceID = defaultVoice.identifier
            }
        }
    }
    
    func toggleFavorite(voiceID: String) {
        if favoriteVoiceIDs.contains(voiceID) {
            favoriteVoiceIDs.remove(voiceID)
        } else {
            favoriteVoiceIDs.insert(voiceID)
        }
    }
    
    func isFavorite(voiceID: String) -> Bool {
        favoriteVoiceIDs.contains(voiceID)
    }
    
    var selectedVoiceItem: VoiceItem? {
        availableVoices.first(where: { $0.id == selectedVoiceID })
    }
    
    /// Returns filtered voices partitioned into Favorites and Non-Favorites
    var filteredVoices: (favorites: [VoiceItem], others: [VoiceItem]) {
        let query = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        
        let filtered = availableVoices.filter { item in
            if englishOnly {
                let lang = item.languageCode.lowercased()
                if !lang.hasPrefix("en") { return false }
            }
            if query.isEmpty { return true }
            return item.name.lowercased().contains(query) ||
                   item.localizedLanguage.lowercased().contains(query) ||
                   item.languageCode.lowercased().contains(query)
        }
        
        let favs = filtered.filter { favoriteVoiceIDs.contains($0.id) }
        let others = filtered.filter { !favoriteVoiceIDs.contains($0.id) }
        
        return (favs, others)
    }
    
    private func setupVoiceChangeObserver() {
        if #available(macOS 14.0, *) {
            NotificationCenter.default.publisher(for: AVSpeechSynthesizer.availableVoicesDidChangeNotification)
                .receive(on: DispatchQueue.main)
                .sink { [weak self] _ in
                    self?.refreshVoices()
                }
                .store(in: &cancellables)
        }
    }
    
    private func loadFavorites() {
        if let array = UserDefaults.standard.stringArray(forKey: favoritesKey) {
            favoriteVoiceIDs = Set(array)
        }
    }
    
    private func saveFavorites() {
        UserDefaults.standard.set(Array(favoriteVoiceIDs), forKey: favoritesKey)
    }
    
    private func restoreSelectedVoice() {
        if let savedID = UserDefaults.standard.string(forKey: "SelectedVoiceID"), !savedID.isEmpty {
            self.selectedVoiceID = savedID
        }
    }
}

// MARK: - Speech & Audio Export Engine

final class SpeechEngine: NSObject, ObservableObject, AVSpeechSynthesizerDelegate {
    @Published var playbackState: PlaybackState = .stopped
    @Published var highlightedRange: NSRange? = nil
    @Published var errorMessage: String? = nil
    
    private let synthesizer = AVSpeechSynthesizer()
    private var exportSynthesizer: AVSpeechSynthesizer?
    private var isPreviewingActive = false
    
    override init() {
        super.init()
        synthesizer.delegate = self
    }
    
    // MARK: - Speech Engine Helpers
    
    /// Ensures speech rate stays strictly within AVFoundation bounds
    static func clampRate(_ rate: Float) -> Float {
        max(AVSpeechUtteranceMinimumSpeechRate, min(AVSpeechUtteranceMaximumSpeechRate, rate))
    }
    
    /// Ensures pitch multiplier stays strictly within valid AVFoundation bounds (0.5...2.0)
    static func clampPitch(_ pitch: Float) -> Float {
        max(0.5, min(2.0, pitch))
    }
    
    // MARK: - Real-time Playback
    
    func speak(
        attributedText: NSAttributedString,
        voice: AVSpeechSynthesisVoice?,
        rate: Float,
        pitch: Float,
        volume: Float
    ) {
        guard !attributedText.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        
        stop()
        isPreviewingActive = false
        
        let utterance = AVSpeechUtterance(attributedString: attributedText)
        utterance.voice = voice
        utterance.rate = SpeechEngine.clampRate(rate)
        utterance.pitchMultiplier = SpeechEngine.clampPitch(pitch)
        utterance.volume = max(0.0, min(1.0, volume))
        
        synthesizer.speak(utterance)
    }
    
    /// Dedicated non-destructive voice preview playback
    func previewVoice(voiceItem: VoiceItem?, rate: Float, pitch: Float) {
        guard let item = voiceItem else { return }
        stop()
        
        isPreviewingActive = true
        let sampleText = "Hello, this is \(item.name)."
        let utterance = AVSpeechUtterance(string: sampleText)
        utterance.voice = item.voice
        utterance.rate = SpeechEngine.clampRate(rate)
        utterance.pitchMultiplier = SpeechEngine.clampPitch(pitch)
        utterance.volume = 1.0
        
        synthesizer.speak(utterance)
    }
    
    func pause() {
        if synthesizer.isSpeaking && !synthesizer.isPaused {
            synthesizer.pauseSpeaking(at: .immediate)
        }
    }
    
    func resume() {
        if synthesizer.isPaused {
            synthesizer.continueSpeaking()
        }
    }
    
    func stop() {
        if synthesizer.isSpeaking || synthesizer.isPaused {
            synthesizer.stopSpeaking(at: .immediate)
        }
        DispatchQueue.main.async {
            self.playbackState = .stopped
            self.highlightedRange = nil
            self.isPreviewingActive = false
        }
    }
    
    // MARK: - AVSpeechSynthesizerDelegate
    
    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didStart utterance: AVSpeechUtterance) {
        DispatchQueue.main.async {
            self.playbackState = self.isPreviewingActive ? .previewing : .playing
        }
    }
    
    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didPause utterance: AVSpeechUtterance) {
        DispatchQueue.main.async {
            self.playbackState = .paused
        }
    }
    
    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didContinue utterance: AVSpeechUtterance) {
        DispatchQueue.main.async {
            self.playbackState = self.isPreviewingActive ? .previewing : .playing
        }
    }
    
    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        DispatchQueue.main.async {
            self.playbackState = .stopped
            self.highlightedRange = nil
            self.isPreviewingActive = false
        }
    }
    
    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        DispatchQueue.main.async {
            self.playbackState = .stopped
            self.highlightedRange = nil
            self.isPreviewingActive = false
        }
    }
    
    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, willSpeakRangeOfSpeechString characterRange: NSRange, utterance: AVSpeechUtterance) {
        if !isPreviewingActive {
            DispatchQueue.main.async {
                self.highlightedRange = characterRange
            }
        }
    }
    
    // MARK: - Audio Buffer File Export (Crash-free Two-Pass Rendering)
    
    func exportToFile(
        attributedText: NSAttributedString,
        voice: AVSpeechSynthesisVoice?,
        rate: Float,
        pitch: Float,
        volume: Float,
        format: AudioExportFormat,
        outputURL: URL,
        completion: @escaping (Result<URL, Error>) -> Void
    ) {
        guard !attributedText.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            completion(.failure(NSError(domain: "SWS", code: 400, userInfo: [NSLocalizedDescriptionKey: "Text buffer is empty."])))
            return
        }
        
        stop()
        
        let utterance = AVSpeechUtterance(attributedString: attributedText)
        utterance.voice = voice
        utterance.rate = SpeechEngine.clampRate(rate)
        utterance.pitchMultiplier = SpeechEngine.clampPitch(pitch)
        utterance.volume = max(0.0, min(1.0, volume))
        
        let exportSynth = AVSpeechSynthesizer()
        self.exportSynthesizer = exportSynth
        
        DispatchQueue.main.async {
            self.playbackState = .exporting(progress: 0.0)
        }
        
        // Render PCM buffer to temporary WAV file to prevent format assertion crashes
        let tempWavURL = FileManager.default.temporaryDirectory.appendingPathComponent("SWS_Temp_\(UUID().uuidString).wav")
        var audioFile: AVAudioFile? = nil
        var isCompleted = false
        let estimatedTotalLength = Float(attributedText.string.count)
        var charactersProcessed: Float = 0
        
        let cleanupAndFinish: (Result<URL, Error>) -> Void = { result in
            guard !isCompleted else { return }
            isCompleted = true
            try? FileManager.default.removeItem(at: tempWavURL)
            DispatchQueue.main.async {
                self.playbackState = .stopped
                self.exportSynthesizer = nil
                completion(result)
            }
        }
        
        exportSynth.write(utterance) { [weak self] (buffer: AVAudioBuffer) in
            guard let self = self else { return }
            guard let pcmBuffer = buffer as? AVAudioPCMBuffer else { return }
            
            // Frame length 0 indicates completion of synthesis stream
            if pcmBuffer.frameLength == 0 {
                audioFile = nil // Close file handle
                
                if format == .wav {
                    do {
                        if FileManager.default.fileExists(atPath: outputURL.path) {
                            try FileManager.default.removeItem(at: outputURL)
                        }
                        try FileManager.default.moveItem(at: tempWavURL, to: outputURL)
                        cleanupAndFinish(.success(outputURL))
                    } catch {
                        cleanupAndFinish(.failure(error))
                    }
                } else {
                    // Convert WAV to AAC M4A via AVAssetExportSession
                    let asset = AVAsset(url: tempWavURL)
                    guard let exportSession = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetAppleM4A) else {
                        cleanupAndFinish(.failure(NSError(domain: "SWS", code: 500, userInfo: [NSLocalizedDescriptionKey: "Could not create M4A export session."])))
                        return
                    }
                    
                    if FileManager.default.fileExists(atPath: outputURL.path) {
                        try? FileManager.default.removeItem(at: outputURL)
                    }
                    
                    exportSession.outputURL = outputURL
                    exportSession.outputFileType = .m4a
                    
                    exportSession.exportAsynchronously {
                        if exportSession.status == .completed {
                            cleanupAndFinish(.success(outputURL))
                        } else {
                            let err = exportSession.error ?? NSError(domain: "SWS", code: 500, userInfo: [NSLocalizedDescriptionKey: "M4A audio conversion failed."])
                            cleanupAndFinish(.failure(err))
                        }
                    }
                }
                return
            }
            
            do {
                if audioFile == nil {
                    // Always write PCM using the buffer's native format
                    audioFile = try AVAudioFile(
                        forWriting: tempWavURL,
                        settings: pcmBuffer.format.settings,
                        commonFormat: pcmBuffer.format.commonFormat,
                        interleaved: pcmBuffer.format.isInterleaved
                    )
                }
                
                try audioFile?.write(from: pcmBuffer)
                
                charactersProcessed += Float(pcmBuffer.frameLength) / Float(pcmBuffer.format.sampleRate) * 12.0
                let rawProgress = min(Double(charactersProcessed / max(estimatedTotalLength, 1.0)), 0.99)
                
                DispatchQueue.main.async {
                    self.playbackState = .exporting(progress: rawProgress)
                }
            } catch {
                cleanupAndFinish(.failure(error))
            }
        }
    }
}

// MARK: - Settings View

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var voiceManager: VoiceManager
    @ObservedObject var pronunciationManager: PronunciationManager
    
    @AppStorage("ExportFormat") private var exportFormatRaw: String = AudioExportFormat.wav.rawValue
    @AppStorage("ExportDestinationMode") private var exportDestModeRaw: String = ExportDestinationMode.alwaysAsk.rawValue
    @AppStorage("CustomExportFolderPath") private var customFolderPath: String = ""
    
    // Pronunciation rule entry state
    @State private var newOriginalWord: String = ""
    @State private var newReplacement: String = ""
    @State private var newIsIPA: Bool = false
    
    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("SWS Settings")
                    .font(.headline)
                Spacer()
                Button("Done") {
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
            .padding()
            .background(Color(NSColor.windowBackgroundColor))
            
            Divider()
            
            TabView {
                // MARK: Tab 1 - General & Voices
                Form {
                    Section(header: Text("Voice Preferences").font(.headline)) {
                        Toggle("Filter Non-English Voices", isOn: $voiceManager.englishOnly)
                            .help("When enabled, only English language voices will appear in the voice selector.")
                    }
                    
                    Section(header: Text("Export Configuration").font(.headline)) {
                        Picker("Default Audio Format:", selection: $exportFormatRaw) {
                            ForEach(AudioExportFormat.allCases) { fmt in
                                Text(fmt.rawValue).tag(fmt.rawValue)
                            }
                        }
                        .pickerStyle(.radioGroup)
                        
                        Divider()
                            .padding(.vertical, 4)
                        
                        Picker("Export Destination:", selection: $exportDestModeRaw) {
                            ForEach(ExportDestinationMode.allCases) { mode in
                                Text(mode.rawValue).tag(mode.rawValue)
                            }
                        }
                        .pickerStyle(.radioGroup)
                        
                        if exportDestModeRaw == ExportDestinationMode.customFolder.rawValue {
                            HStack {
                                Text(customFolderPath.isEmpty ? "No folder selected" : customFolderPath)
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                
                                Spacer()
                                
                                Button("Choose Folder...") {
                                    selectCustomFolder()
                                }
                            }
                            .padding(.top, 4)
                        }
                    }
                }
                .padding()
                .tabItem {
                    Label("General", systemImage: "gearshape")
                }
                
                // MARK: Tab 2 - Pronunciation Dictionary
                VStack(alignment: .leading, spacing: 12) {
                    Text("Pronunciation Replacements")
                        .font(.headline)
                    Text("Substitute words or apply IPA phonemes before synthesizing speech.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    
                    // Input Row
                    HStack(spacing: 8) {
                        TextField("Original Word", text: $newOriginalWord)
                            .textFieldStyle(.roundedBorder)
                        
                        TextField("Replacement / IPA", text: $newReplacement)
                            .textFieldStyle(.roundedBorder)
                        
                        Toggle("IPA", isOn: $newIsIPA)
                            .help("Treat replacement string as International Phonetic Alphabet (IPA)")
                        
                        Button("Add Rule") {
                            pronunciationManager.addRule(original: newOriginalWord, replacement: newReplacement, isIPA: newIsIPA)
                            newOriginalWord = ""
                            newReplacement = ""
                        }
                        .disabled(newOriginalWord.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || newReplacement.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                    
                    Divider()
                    
                    // Rules List
                    List {
                        if pronunciationManager.rules.isEmpty {
                            Text("No pronunciation rules added yet.")
                                .foregroundColor(.secondary)
                                .font(.caption)
                        } else {
                            ForEach(pronunciationManager.rules) { rule in
                                HStack {
                                    Toggle("", isOn: Binding(
                                        get: { rule.isEnabled },
                                        set: { _ in pronunciationManager.toggleRule(rule) }
                                    ))
                                    .labelsHidden()
                                    
                                    Text(rule.originalWord)
                                        .fontWeight(.semibold)
                                    Image(systemName: "arrow.right")
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                    Text(rule.replacement)
                                        .foregroundColor(rule.isIPA ? .purple : .primary)
                                    
                                    if rule.isIPA {
                                        Text("IPA")
                                            .font(.caption2)
                                            .padding(.horizontal, 4)
                                            .padding(.vertical, 2)
                                            .background(Color.purple.opacity(0.15))
                                            .foregroundColor(.purple)
                                            .cornerRadius(4)
                                    }
                                    
                                    Spacer()
                                    
                                    Button(action: { pronunciationManager.deleteRule(rule) }) {
                                        Image(systemName: "trash")
                                            .foregroundColor(.red)
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                        }
                    }
                    .listStyle(.inset)
                }
                .padding()
                .tabItem {
                    Label("Pronunciation", systemImage: "character.book.closed")
                }
            }
            .frame(width: 520, height: 380)
        }
    }
    
    private func selectCustomFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Select Export Folder"
        
        let handler = { (response: NSApplication.ModalResponse) in
            if response == .OK, let url = panel.url {
                self.customFolderPath = url.path
                if let bookmark = try? url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil) {
                    UserDefaults.standard.set(bookmark, forKey: "CustomExportFolderBookmark")
                }
            }
        }
        
        if let window = NSApp.keyWindow ?? NSApp.windows.first {
            panel.beginSheetModal(for: window, completionHandler: handler)
        } else {
            panel.begin(completionHandler: handler)
        }
    }
}

// MARK: - Main SwiftUI View

struct ContentView: View {
    @StateObject private var voiceManager = VoiceManager()
    @StateObject private var speechEngine = SpeechEngine()
    @StateObject private var pronunciationManager = PronunciationManager()
    
    // Default passage always shown on app launch
    @State private var text: String = "The King's Pact binds them. They cannot show themselves or speak to us. One, create ways to see without seeing. Two, create ways to speak without speaking. Three, create ways to know without knowing."
    
    @AppStorage("SpeechRate") private var speechRate: Double = Double(AVSpeechUtteranceDefaultSpeechRate)
    @AppStorage("SpeechPitch") private var speechPitch: Double = 1.0
    @AppStorage("SpeechVolume") private var speechVolume: Double = 1.0
    
    @AppStorage("ExportFormat") private var exportFormatRaw: String = AudioExportFormat.wav.rawValue
    @AppStorage("ExportDestinationMode") private var exportDestModeRaw: String = ExportDestinationMode.alwaysAsk.rawValue
    @AppStorage("CustomExportFolderPath") private var customFolderPath: String = ""
    
    @State private var showingSettings = false
    @State private var showingExportAlert = false
    @State private var alertTitle = ""
    @State private var alertMessage = ""
    @State private var lastExportedURL: URL? = nil
    
    var currentFormat: AudioExportFormat {
        AudioExportFormat(rawValue: exportFormatRaw) ?? .wav
    }
    
    var currentDestMode: ExportDestinationMode {
        ExportDestinationMode(rawValue: exportDestModeRaw) ?? .alwaysAsk
    }
    
    var characterCount: Int { text.count }
    var wordCount: Int {
        text.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }.count
    }
    var lineCount: Int {
        text.components(separatedBy: .newlines).count
    }
    
    var body: some View {
        VStack(spacing: 0) {
            // MARK: Top Control Header
            topControlHeader
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .background(Color(NSColor.windowBackgroundColor))
            
            Divider()
            
            // MARK: Parameter Controls Bar
            parameterControlsBar
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background(Color(NSColor.controlBackgroundColor).opacity(0.5))
            
            Divider()
            
            // MARK: Text Editor Area (With Live Word Highlighting)
            ZStack(alignment: .topLeading) {
                HighlightableTextEditor(text: $text, highlightedRange: speechEngine.highlightedRange)
                
                if text.isEmpty {
                    Text("Type or paste text here to synthesize speech...")
                        .foregroundColor(.secondary)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 20)
                        .allowsHitTesting(false)
                }
            }
            
            Divider()
            
            // MARK: Bottom Status & Playback Toolbar
            bottomStatusBar
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(Color(NSColor.windowBackgroundColor))
        }
        .frame(minWidth: 760, minHeight: 520)
        .sheet(isPresented: $showingSettings) {
            SettingsView(voiceManager: voiceManager, pronunciationManager: pronunciationManager)
        }
        .alert(isPresented: $showingExportAlert) {
            Alert(
                title: Text(alertTitle),
                message: Text(alertMessage),
                primaryButton: .default(Text("Show in Finder"), action: {
                    if let url = lastExportedURL {
                        NSWorkspace.shared.activateFileViewerSelecting([url])
                    }
                }),
                secondaryButton: .cancel(Text("OK"))
            )
        }
        .onAppear {
            voiceManager.refreshVoices()
        }
    }
    
    // MARK: - UI Subviews
    
    private var topControlHeader: some View {
        HStack(spacing: 12) {
            // Voice Picker Menu
            VStack(alignment: .leading, spacing: 4) {
                Text("SYSTEM VOICE")
                    .font(.caption2)
                    .fontWeight(.bold)
                    .foregroundColor(.secondary)
                
                HStack(spacing: 8) {
                    Picker("", selection: $voiceManager.selectedVoiceID) {
                        let partitioned = voiceManager.filteredVoices
                        
                        if !partitioned.favorites.isEmpty {
                            Section(header: Text("★ Favorites")) {
                                ForEach(partitioned.favorites) { item in
                                    voiceRow(item)
                                        .tag(item.id)
                                }
                            }
                        }
                        
                        Section(header: Text("Voices (\(partitioned.others.count + partitioned.favorites.count))")) {
                            ForEach(partitioned.others) { item in
                                voiceRow(item)
                                    .tag(item.id)
                            }
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .frame(maxWidth: 260)
                    
                    // Favorite Toggle Button
                    if let selected = voiceManager.selectedVoiceItem {
                        Button(action: {
                            voiceManager.toggleFavorite(voiceID: selected.id)
                        }) {
                            Image(systemName: voiceManager.isFavorite(voiceID: selected.id) ? "star.fill" : "star")
                                .foregroundColor(voiceManager.isFavorite(voiceID: selected.id) ? .yellow : .gray)
                        }
                        .buttonStyle(.plain)
                        .help("Toggle Favorite")
                    }
                    
                    // Dedicated Voice Preview Button
                    Button(action: previewCurrentVoice) {
                        Image(systemName: speechEngine.playbackState == .previewing ? "stop.fill" : "speaker.wave.2")
                            .foregroundColor(.accentColor)
                    }
                    .buttonStyle(.borderless)
                    .help("Preview Voice Sample")
                }
            }
            
            // Search Bar
            VStack(alignment: .leading, spacing: 4) {
                Text("SEARCH")
                    .font(.caption2)
                    .fontWeight(.bold)
                    .foregroundColor(.secondary)
                
                HStack {
                    Image(systemName: "magnifyingglass")
                        .foregroundColor(.secondary)
                    TextField("Search voices...", text: $voiceManager.searchQuery)
                        .textFieldStyle(.plain)
                    if !voiceManager.searchQuery.isEmpty {
                        Button(action: { voiceManager.searchQuery = "" }) {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundColor(.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 4)
                .background(Color(NSColor.controlBackgroundColor))
                .cornerRadius(6)
                .frame(maxWidth: 180)
            }
            
            Spacer()
            
            // Top Right Utility Actions
            HStack(spacing: 8) {
                Button(action: { showingSettings = true }) {
                    Label("Settings", systemImage: "gearshape.fill")
                }
                .buttonStyle(.borderless)
                
                Button(action: { text = "" }) {
                    Label("Clear", systemImage: "trash")
                }
                .buttonStyle(.borderless)
                .disabled(text.isEmpty)
            }
        }
    }
    
    private var parameterControlsBar: some View {
        HStack(spacing: 16) {
            // Speed Slider (Strict AVFoundation Bounds)
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text("Speed:")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Text(String(format: "%.2fx", speechRate / Double(AVSpeechUtteranceDefaultSpeechRate)))
                        .font(.caption)
                        .monospacedDigit()
                }
                Slider(
                    value: $speechRate,
                    in: Double(AVSpeechUtteranceMinimumSpeechRate)...Double(AVSpeechUtteranceMaximumSpeechRate)
                )
                .frame(width: 130)
            }
            
            // Pitch Slider (Strict AVFoundation Bounds: 0.5...2.0)
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text("Pitch:")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Text(String(format: "%.1f", speechPitch))
                        .font(.caption)
                        .monospacedDigit()
                }
                Slider(value: $speechPitch, in: 0.5...2.0)
                    .frame(width: 120)
            }
            
            // Volume Slider
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text("Volume:")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Text(String(format: "%.0f%%", speechVolume * 100))
                        .font(.caption)
                        .monospacedDigit()
                }
                Slider(value: $speechVolume, in: 0.0...1.0)
                    .frame(width: 120)
            }
            
            Button("Reset") {
                speechRate = Double(AVSpeechUtteranceDefaultSpeechRate)
                speechPitch = 1.0
                speechVolume = 1.0
            }
            .font(.caption)
            .buttonStyle(.borderless)
            
            Spacer()
            
            // Character & Word Counter
            HStack(spacing: 8) {
                Text("\(characterCount) chars")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Text("\(wordCount) words")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Text("\(lineCount) lines")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
    }
    
    private var bottomStatusBar: some View {
        HStack(spacing: 16) {
            // Playback State Badge
            HStack(spacing: 6) {
                Circle()
                    .fill(speechEngine.playbackState.statusColor)
                    .frame(width: 8, height: 8)
                
                Text(speechEngine.playbackState.statusTitle)
                    .font(.callout)
                    .fontWeight(.medium)
            }
            .frame(width: 150, alignment: .leading)
            
            Spacer()
            
            // Transport Controls (Play / Pause / Stop)
            HStack(spacing: 10) {
                if speechEngine.playbackState == .playing {
                    Button(action: { speechEngine.pause() }) {
                        Label("Pause", systemImage: "pause.fill")
                            .frame(minWidth: 80)
                    }
                    .keyboardShortcut("p", modifiers: [.command])
                } else if speechEngine.playbackState == .paused {
                    Button(action: { speechEngine.resume() }) {
                        Label("Resume", systemImage: "play.fill")
                            .frame(minWidth: 80)
                    }
                    .keyboardShortcut("p", modifiers: [.command])
                } else {
                    Button(action: speakCurrentText) {
                        Label("Play Speech", systemImage: "play.fill")
                            .frame(minWidth: 100)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .keyboardShortcut(.space, modifiers: [])
                }
                
                Button(action: { speechEngine.stop() }) {
                    Label("Stop", systemImage: "stop.fill")
                }
                .disabled(speechEngine.playbackState == .stopped)
                .keyboardShortcut(".", modifiers: [.command])
            }
            
            Spacer()
            
            // Export Button
            Button(action: exportAudioFile) {
                Label("Export Audio...", systemImage: "square.and.arrow.up")
            }
            .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || speechEngine.playbackState != .stopped)
        }
    }
    
    private func voiceRow(_ item: VoiceItem) -> some View {
        Text("\(item.name) (\(item.localizedLanguage))")
    }
    
    // MARK: - Actions
    
    private func speakCurrentText() {
        let voice = voiceManager.selectedVoiceItem?.voice
        let processedText = pronunciationManager.processUtteranceText(text)
        speechEngine.speak(
            attributedText: processedText,
            voice: voice,
            rate: Float(speechRate),
            pitch: Float(speechPitch),
            volume: Float(speechVolume)
        )
    }
    
    private func previewCurrentVoice() {
        if speechEngine.playbackState == .previewing {
            speechEngine.stop()
        } else {
            speechEngine.previewVoice(
                voiceItem: voiceManager.selectedVoiceItem,
                rate: Float(speechRate),
                pitch: Float(speechPitch)
            )
        }
    }
    
    /// Resolves security-scoped bookmark for custom export folder
    private func getCustomFolderURL() -> (url: URL, cleanup: () -> Void)? {
        if let bookmarkData = UserDefaults.standard.data(forKey: "CustomExportFolderBookmark") {
            var isStale = false
            if let resolvedURL = try? URL(resolvingBookmarkData: bookmarkData, options: .withSecurityScope, relativeTo: nil, bookmarkDataIsStale: &isStale) {
                if resolvedURL.startAccessingSecurityScopedResource() {
                    return (resolvedURL, { resolvedURL.stopAccessingSecurityScopedResource() })
                }
            }
        }
        let folderPath = customFolderPath.trimmingCharacters(in: .whitespacesAndNewlines)
        if !folderPath.isEmpty {
            let url = URL(fileURLWithPath: folderPath)
            return (url, {})
        }
        return nil
    }
    
    private func exportAudioFile() {
        if currentDestMode == .customFolder {
            guard let folderInfo = getCustomFolderURL(), FileManager.default.fileExists(atPath: folderInfo.url.path) else {
                alertTitle = "Folder Access Error"
                alertMessage = "Custom export folder access denied or invalid. Please re-select the folder in Settings -> Choose Folder."
                showingExportAlert = true
                return
            }
            
            let filename = "SWS_Export_\(formattedTimestamp()).\(currentFormat.fileExtension)"
            let targetURL = folderInfo.url.appendingPathComponent(filename)
            
            performExport(to: targetURL) {
                folderInfo.cleanup()
            }
        } else {
            // Save Panel attached to app window
            let panel = NSSavePanel()
            panel.allowedContentTypes = [currentFormat.utType]
            panel.canCreateDirectories = true
            panel.isExtensionHidden = false
            panel.title = "Export Speech Audio"
            panel.nameFieldStringValue = "SpeechOutput.\(currentFormat.fileExtension)"
            
            let handler = { (response: NSApplication.ModalResponse) in
                guard response == .OK, let targetURL = panel.url else { return }
                self.performExport(to: targetURL)
            }
            
            if let window = NSApp.keyWindow ?? NSApp.windows.first {
                panel.beginSheetModal(for: window, completionHandler: handler)
            } else {
                panel.begin(completionHandler: handler)
            }
        }
    }
    
    private func performExport(to targetURL: URL, completionCleanup: (() -> Void)? = nil) {
        let voice = voiceManager.selectedVoiceItem?.voice
        let processedText = pronunciationManager.processUtteranceText(text)
        
        speechEngine.exportToFile(
            attributedText: processedText,
            voice: voice,
            rate: Float(speechRate),
            pitch: Float(speechPitch),
            volume: Float(speechVolume),
            format: currentFormat,
            outputURL: targetURL
        ) { result in
            completionCleanup?()
            switch result {
            case .success(let savedURL):
                self.lastExportedURL = savedURL
                self.alertTitle = "Export Complete"
                self.alertMessage = "Audio successfully written to:\n\(savedURL.lastPathComponent)"
                self.showingExportAlert = true
            case .failure(let error):
                self.alertTitle = "Export Failed"
                self.alertMessage = error.localizedDescription
                self.showingExportAlert = true
            }
        }
    }
    
    private func formattedTimestamp() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd_HHmmss"
        return formatter.string(from: Date())
    }
}

// MARK: - Main Application Entry Point

@main
struct SWSApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
                .navigationTitle("SWS")
        }
        .windowStyle(.titleBar)
        .windowToolbarStyle(.unified)
    }
}
