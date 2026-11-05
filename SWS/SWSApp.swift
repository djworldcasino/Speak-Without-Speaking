import SwiftUI
import AVFoundation
import AppKit
import UniformTypeIdentifiers

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

/// Represents current status of speech synthesis
enum PlaybackState: Equatable {
    case stopped
    case playing
    case paused
    case exporting(progress: Double)
    
    var statusTitle: String {
        switch self {
        case .stopped: return "Ready"
        case .playing: return "Speaking..."
        case .paused: return "Paused"
        case .exporting(let p): return String(format: "Exporting... %.0f%%", p * 100)
        }
    }
    
    var statusColor: Color {
        switch self {
        case .stopped: return .secondary
        case .playing: return .green
        case .paused: return .orange
        case .exporting: return .accentColor
        }
    }
}

/// Helper model wrapping AVSpeechSynthesisVoice with locale meta data
struct VoiceItem: Identifiable, Hashable {
    let id: String
    let voice: AVSpeechSynthesisVoice
    let name: String
    let languageCode: String
    let localizedLanguage: String
    let qualityName: String
    
    init(voice: AVSpeechSynthesisVoice) {
        self.id = voice.identifier
        self.voice = voice
        self.name = voice.name
        self.languageCode = voice.language
        
        let locale = Locale(identifier: voice.language)
        self.localizedLanguage = locale.localizedString(forLanguageCode: locale.language.languageCode?.identifier ?? voice.language) ?? voice.language
        
        switch voice.quality {
        case .enhanced:
            self.qualityName = "Enhanced"
        case .premium:
            self.qualityName = "Premium"
        default:
            self.qualityName = "Standard"
        }
    }
    
    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
    
    static func == (lhs: VoiceItem, rhs: VoiceItem) -> Bool {
        lhs.id == rhs.id
    }
}

// MARK: - Voice Manager

@MainActor
final class VoiceManager: ObservableObject {
    @Published var availableVoices: [VoiceItem] = []
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
    
    init() {
        loadFavorites()
        refreshVoices()
        restoreSelectedVoice()
    }
    
    /// Fetches all system voices installed on macOS
    func refreshVoices() {
        let systemVoices = AVSpeechSynthesisVoice.speechVoices()
        let items = systemVoices.map { VoiceItem(voice: $0) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        
        self.availableVoices = items
        
        // Ensure selected voice exists, otherwise fallback to default system voice
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
            if query.isEmpty { return true }
            return item.name.lowercased().contains(query) ||
                   item.localizedLanguage.lowercased().contains(query) ||
                   item.languageCode.lowercased().contains(query)
        }
        
        let favs = filtered.filter { favoriteVoiceIDs.contains($0.id) }
        let others = filtered.filter { !favoriteVoiceIDs.contains($0.id) }
        
        return (favs, others)
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
    
    override init() {
        super.init()
        synthesizer.delegate = self
    }
    
    // MARK: - Real-time Playback
    
    func speak(text: String, voice: AVSpeechSynthesisVoice?, rate: Float, pitch: Float, volume: Float) {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        
        if synthesizer.isSpeaking {
            synthesizer.stopSpeaking(at: .immediate)
        }
        
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = voice
        utterance.rate = rate
        utterance.pitchMultiplier = pitch
        utterance.volume = volume
        
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
        }
    }
    
    // MARK: - AVSpeechSynthesizerDelegate
    
    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didStart utterance: AVSpeechUtterance) {
        DispatchQueue.main.async {
            self.playbackState = .playing
        }
    }
    
    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didPause utterance: AVSpeechUtterance) {
        DispatchQueue.main.async {
            self.playbackState = .paused
        }
    }
    
    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didContinue utterance: AVSpeechUtterance) {
        DispatchQueue.main.async {
            self.playbackState = .playing
        }
    }
    
    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        DispatchQueue.main.async {
            self.playbackState = .stopped
            self.highlightedRange = nil
        }
    }
    
    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        DispatchQueue.main.async {
            self.playbackState = .stopped
            self.highlightedRange = nil
        }
    }
    
    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, willSpeakRangeOfSpeechString characterRange: NSRange, utterance: AVSpeechUtterance) {
        DispatchQueue.main.async {
            self.highlightedRange = characterRange
        }
    }
    
    // MARK: - Audio Buffer File Export
    
    func exportToFile(
        text: String,
        voice: AVSpeechSynthesisVoice?,
        rate: Float,
        pitch: Float,
        volume: Float,
        format: AudioExportFormat,
        outputURL: URL,
        completion: @escaping (Result<URL, Error>) -> Void
    ) {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            completion(.failure(NSError(domain: "SWS", code: 400, userInfo: [NSLocalizedDescriptionKey: "Text buffer is empty."])))
            return
        }
        
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = voice
        utterance.rate = rate
        utterance.pitchMultiplier = pitch
        utterance.volume = volume
        
        // Retain dedicated synthesizer instance for export session
        let exportSynth = AVSpeechSynthesizer()
        self.exportSynthesizer = exportSynth
        
        DispatchQueue.main.async {
            self.playbackState = .exporting(progress: 0.0)
        }
        
        var audioFile: AVAudioFile? = nil
        let estimatedTotalLength = Float(text.count)
        var charactersProcessed: Float = 0
        
        exportSynth.write(utterance) { [weak self] (buffer: AVAudioBuffer) in
            guard let self = self else { return }
            guard let pcmBuffer = buffer as? AVAudioPCMBuffer else { return }
            
            // Frame length 0 indicates completion of synthesis stream
            if pcmBuffer.frameLength == 0 {
                DispatchQueue.main.async {
                    self.playbackState = .stopped
                    self.exportSynthesizer = nil
                    completion(.success(outputURL))
                }
                return
            }
            
            do {
                if audioFile == nil {
                    // Create AVAudioFile on first valid buffer arrival
                    let fileSettings: [String: Any]
                    
                    if format == .m4a {
                        fileSettings = [
                            AVFormatIDKey: kAudioFormatMPEG4AAC,
                            AVSampleRateKey: pcmBuffer.format.sampleRate,
                            AVNumberOfChannelsKey: pcmBuffer.format.channelCount,
                            AVEncoderBitRateKey: 128000
                        ]
                    } else {
                        // Standard PCM WAV
                        fileSettings = pcmBuffer.format.settings
                    }
                    
                    audioFile = try AVAudioFile(
                        forWriting: outputURL,
                        settings: fileSettings,
                        commonFormat: pcmBuffer.format.commonFormat,
                        interleaved: pcmBuffer.format.isInterleaved
                    )
                }
                
                try audioFile?.write(from: pcmBuffer)
                
                // Track progress estimation
                charactersProcessed += Float(pcmBuffer.frameLength) / Float(pcmBuffer.format.sampleRate) * 12.0
                let rawProgress = min(Double(charactersProcessed / max(estimatedTotalLength, 1.0)), 0.99)
                
                DispatchQueue.main.async {
                    self.playbackState = .exporting(progress: rawProgress)
                }
            } catch {
                DispatchQueue.main.async {
                    self.playbackState = .stopped
                    self.exportSynthesizer = nil
                    completion(.failure(error))
                }
            }
        }
    }
}

// MARK: - Main SwiftUI View

struct ContentView: View {
    @StateObject private var voiceManager = VoiceManager()
    @StateObject private var speechEngine = SpeechEngine()
    
    // User preferences & speech text state
    @AppStorage("EnteredSpeechText") private var text: String = "The King's Pact binds them. They cannot show themselves or speak to us. One, create ways to see without seeing. Two, create ways to speak without speaking. Three, create ways to know without knowing."
    @AppStorage("SpeechRate") private var speechRate: Double = Double(AVSpeechUtteranceDefaultSpeechRate)
    @AppStorage("SpeechPitch") private var speechPitch: Double = 1.0
    @AppStorage("SpeechVolume") private var speechVolume: Double = 1.0
    @AppStorage("ExportFormat") private var exportFormatRaw: String = AudioExportFormat.wav.rawValue
    
    @State private var showingExportAlert = false
    @State private var alertTitle = ""
    @State private var alertMessage = ""
    @State private var lastExportedURL: URL? = nil
    
    var currentFormat: AudioExportFormat {
        AudioExportFormat(rawValue: exportFormatRaw) ?? .wav
    }
    
    var characterCount: Int { text.count }
    var wordCount: Int {
        text.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }.count
    }
    
    var body: some View {
        VStack(spacing: 0) {
            // MARK: Top Control Bar / Voice Selector
            topControlHeader
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .background(Color(NSColor.windowBackgroundColor))
            
            Divider()
            
            // MARK: Parameters Adjustment Strip
            parameterControlsBar
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background(Color(NSColor.controlBackgroundColor).opacity(0.5))
            
            Divider()
            
            // MARK: Text Editor Area
            ZStack(alignment: .topLeading) {
                TextEditor(text: $text)
                    .font(.system(.body, design: .default))
                    .padding(12)
                    .scrollContentBackground(.hidden)
                    .background(Color(NSColor.textBackgroundColor))
                
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
        .frame(minWidth: 720, minHeight: 480)
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
                        
                        Section(header: Text("All Voices")) {
                            ForEach(partitioned.others) { item in
                                voiceRow(item)
                                    .tag(item.id)
                            }
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .frame(maxWidth: 300)
                    
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
                    
                    // Voice Quality Badge
                    if let selected = voiceManager.selectedVoiceItem {
                        Text(selected.qualityName)
                            .font(.caption2)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.accentColor.opacity(0.15))
                            .foregroundColor(.accentColor)
                            .cornerRadius(4)
                    }
                }
            }
            
            Spacer()
            
            // Quick Sample Actions
            HStack(spacing: 8) {
                Button(action: loadSampleText) {
                    Label("Sample Text", systemImage: "doc.text")
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
        HStack(spacing: 24) {
            // Speed Slider
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text("Speed:")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Text(String(format: "%.2fx", speechRate / Double(AVSpeechUtteranceDefaultSpeechRate)))
                        .font(.caption)
                        .monospacedDigit()
                }
                Slider(value: $speechRate, in: Double(AVSpeechUtteranceMinimumSpeechRate)...Double(AVSpeechUtteranceMaximumSpeechRate))
                    .frame(width: 140)
            }
            
            // Pitch Slider
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
            HStack(spacing: 12) {
                Text("\(characterCount) chars")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Text("\(wordCount) words")
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
            .frame(width: 140, alignment: .leading)
            
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
            
            // Export Controls
            HStack(spacing: 8) {
                Picker("", selection: $exportFormatRaw) {
                    ForEach(AudioExportFormat.allCases) { fmt in
                        Text(fmt.fileExtension.uppercased()).tag(fmt.rawValue)
                    }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .frame(width: 90)
                
                Button(action: exportAudioFile) {
                    Label("Export Audio...", systemImage: "square.and.arrow.up")
                }
                .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || speechEngine.playbackState != .stopped)
            }
        }
    }
    
    private func voiceRow(_ item: VoiceItem) -> some View {
        Text("\(item.name) (\(item.localizedLanguage))")
    }
    
    // MARK: - Actions
    
    private func speakCurrentText() {
        let voice = voiceManager.selectedVoiceItem?.voice
        speechEngine.speak(
            text: text,
            voice: voice,
            rate: Float(speechRate),
            pitch: Float(speechPitch),
            volume: Float(speechVolume)
        )
    }
    
    private func exportAudioFile() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [currentFormat.utType]
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        panel.title = "Export Speech Audio"
        panel.nameFieldStringValue = "SpeechOutput.\(currentFormat.fileExtension)"
        
        panel.begin { response in
            guard response == .OK, let targetURL = panel.url else { return }
            
            let voice = voiceManager.selectedVoiceItem?.voice
            speechEngine.exportToFile(
                text: text,
                voice: voice,
                rate: Float(speechRate),
                pitch: Float(speechPitch),
                volume: Float(speechVolume),
                format: currentFormat,
                outputURL: targetURL
            ) { result in
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
    }
    
    private func loadSampleText() {
        text = "Apple's AVFoundation provides high-quality speech synthesis directly on macOS. With SWS, you can adjust pitch, velocity, and output formats while creating local audio files instantly."
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
