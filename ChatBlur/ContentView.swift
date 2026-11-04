import SwiftUI
import PhotosUI
import AVKit
import Photos
import UniformTypeIdentifiers

private enum MediaKind: Equatable {
    case video
    case photo
}

private struct SelectedMedia {
    let url: URL
    let kind: MediaKind
}

struct ContentView: View {
    @StateObject private var processor = VideoProcessor()
    @State private var photoSelection: PhotosPickerItem?
    @State private var selectedMedia: SelectedMedia?
    @State private var keywordText = ""
    @State private var sampleInterval = 0.12
    @State private var blurRadius = 18.0
    @State private var allowPartialWords = false
    @State private var tolerateOCRErrors = true
    @State private var isFileImporterPresented = false
    @State private var isImporting = false
    @State private var importError: String?
    @State private var player: AVPlayer?
    @State private var hasReviewedResult = false
    @State private var saveMessage: String?
    @State private var isSaving = false

    private struct ScanOption: Identifiable {
        let title: String
        let seconds: Double
        var id: Double { seconds }
    }

    private let scanOptions: [ScanOption] = [
        ScanOption(title: "Sehr genau · am langsamsten", seconds: 0.08),
        ScanOption(title: "Ausgewogen (empfohlen)", seconds: 0.12),
        ScanOption(title: "Schneller", seconds: 0.20),
        ScanOption(title: "Entwurf · kann Treffer verpassen", seconds: 0.33)
    ]

    private var keywords: [String] {
        keywordText
            .components(separatedBy: CharacterSet(charactersIn: ",;\n"))
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    header
                    mediaPickerSection
                    keywordSection
                    settingsSection
                    processSection
                    if processor.result != nil || processor.imageResult != nil { reviewSection }
                    privacyNote
                    footer
                }
                .padding(20)
                .frame(maxWidth: 620)
                .frame(maxWidth: .infinity)
            }
            .background(Color(uiColor: .systemGroupedBackground))
            .navigationTitle("Protect your Chat")
            .navigationBarTitleDisplayMode(.inline)
            .scrollDismissesKeyboard(.interactively)
            .fileImporter(
                isPresented: $isFileImporterPresented,
                allowedContentTypes: [.movie, .mpeg4Movie, .quickTimeMovie, .image],
                allowsMultipleSelection: false,
                onCompletion: handleFileImport
            )
            .onChange(of: photoSelection) { newItem in
                guard let newItem else { return }
                Task { await importPhotoPickerItem(newItem) }
            }
            .onChange(of: processor.result?.outputURL) { url in
                player?.pause()
                player = url.map { AVPlayer(url: $0) }
                hasReviewedResult = false
                saveMessage = nil
            }
            .onChange(of: processor.imageResult?.outputURL) { _ in
                hasReviewedResult = false
                saveMessage = nil
            }
            .alert("Import fehlgeschlagen", isPresented: Binding(
                get: { importError != nil },
                set: { if !$0 { importError = nil } }
            )) {
                Button("OK", role: .cancel) { importError = nil }
            } message: {
                Text(importError ?? "Unbekannter Fehler.")
            }
        }
        .tint(.teal)
    }

    // MARK: Sections

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Image(systemName: "eye.slash.circle.fill")
                    .font(.system(size: 34))
                    .foregroundStyle(.teal)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Bildschirmaufnahmen anonymisieren")
                        .font(.title3.bold())
                    Text("Schlagwörter automatisch erkennen und verwischen")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
            Text("Für WhatsApp-Chats und andere Bildschirmvideos – auch wenn der Inhalt scrollt. Fotos von Chats funktionieren genauso.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .padding(.top, 2)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background, in: RoundedRectangle(cornerRadius: 18))
    }

    private var mediaPickerSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionTitle("1", "Video oder Foto auswählen")

            if let selectedMedia {
                HStack(spacing: 12) {
                    Image(systemName: selectedMedia.kind == .photo ? "photo.fill" : "film.fill")
                        .font(.title2)
                        .foregroundStyle(.teal)
                        .frame(width: 42, height: 42)
                        .background(.teal.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
                    VStack(alignment: .leading, spacing: 3) {
                        Text(displayName(for: selectedMedia.url))
                            .font(.subheadline.weight(.semibold))
                            .lineLimit(2)
                        Text("Kopie bereit zur Analyse – das Original bleibt unverändert")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                    Button {
                        removeSelectedMedia()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                            .font(.title3)
                    }
                    .accessibilityLabel("Datei entfernen")
                    .disabled(processor.isProcessing)
                }
                .padding(12)
                .background(.background, in: RoundedRectangle(cornerRadius: 12))
            }

            PhotosPicker(selection: $photoSelection, matching: .any(of: [.videos, .images]), photoLibrary: .shared()) {
                Label("Aus Fotos wählen", systemImage: "photo.on.rectangle.angled")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .disabled(isImporting || processor.isProcessing)

            Button {
                isFileImporterPresented = true
            } label: {
                Label("Aus Dateien wählen", systemImage: "folder")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .disabled(isImporting || processor.isProcessing)

            if isImporting {
                ProgressView("Datei wird vorbereitet …")
                    .font(.caption)
            }
        }
    }

    private var keywordSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionTitle("2", "Schlagwörter festlegen")
            Text("Ein Begriff pro Zeile oder mehrere durch Kommas trennen – z. B. Namen, Telefonnummern, Adressen, Steuer-ID, IBAN oder Kundennummern. Leerzeichen in Nummern spielen keine Rolle.")
                .font(.footnote)
                .foregroundStyle(.secondary)
            TextEditor(text: $keywordText)
                .frame(minHeight: 94)
                .padding(8)
                .scrollContentBackground(.hidden)
                .background(.background, in: RoundedRectangle(cornerRadius: 12))
                .overlay {
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(Color(uiColor: .separator).opacity(0.45), lineWidth: 1)
                }
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .disabled(processor.isProcessing)
                .accessibilityLabel("Schlagwortliste")
            if !keywords.isEmpty {
                Text("\(keywords.count) Suchbegriff(e): \(keywords.joined(separator: " · "))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
            }
        }
    }

    private var settingsSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            sectionTitle("3", "Verarbeitung einstellen")

            if selectedMedia?.kind != .photo {
                VStack(alignment: .leading, spacing: 7) {
                    Text("Scan-Häufigkeit")
                        .font(.subheadline.weight(.semibold))
                    Picker("Scan-Häufigkeit", selection: $sampleInterval) {
                        ForEach(scanOptions) { option in
                            Text(option.title).tag(option.seconds)
                        }
                    }
                    .pickerStyle(.menu)
                    .disabled(processor.isProcessing)
                    Text("Wie oft das Video nach Text durchsucht wird. Häufiger = sicherer bei schnellem Scrollen, aber langsamer. Gilt nur für Videos.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Toggle(isOn: $tolerateOCRErrors) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Lesefehler tolerieren").font(.subheadline.weight(.semibold))
                    Text("Findet z. B. „Danlel“ für „Daniel“. Solche Treffer werden als unsicher markiert.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .disabled(processor.isProcessing)

            Toggle(isOn: $allowPartialWords) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Auch Wortteile finden").font(.subheadline.weight(.semibold))
                    Text("Aus: nur ganze Wörter („Anna“ ≠ „Annalena“). An: auch innerhalb längerer Wörter.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .disabled(processor.isProcessing)

            VStack(alignment: .leading, spacing: 7) {
                HStack {
                    Text("Stärke der Unkenntlichmachung")
                        .font(.subheadline.weight(.semibold))
                    Spacer()
                    Text("\(Int(blurRadius))")
                        .font(.subheadline.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                Slider(value: $blurRadius, in: 8...30, step: 2)
                    .disabled(processor.isProcessing)
            }
        }
    }

    private var processSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionTitle("4", "Anonymisieren & exportieren")

            if processor.isProcessing {
                Button(role: .destructive) {
                    processor.cancel()
                } label: {
                    Label("Abbrechen", systemImage: "stop.circle")
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 4)
                }
                .buttonStyle(.bordered)
            } else {
                Button {
                    startProcessing()
                } label: {
                    Label(
                        selectedMedia?.kind == .photo ? "Blur anwenden und Foto erstellen" : "Blur anwenden und Video erstellen",
                        systemImage: "wand.and.stars"
                    )
                    .fontWeight(.semibold)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 4)
                }
                .buttonStyle(.borderedProminent)
                .disabled(selectedMedia == nil || keywords.isEmpty || isImporting)
            }

            if processor.isProcessing || processor.result != nil || processor.imageResult != nil || processor.status == "Abgebrochen" {
                VStack(alignment: .leading, spacing: 8) {
                    ProgressView(value: processor.progress)
                    Text(processor.status)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    if processor.isProcessing {
                        Text("Bitte die App geöffnet lassen, bis der Export fertig ist.")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(12)
                .background(.background, in: RoundedRectangle(cornerRadius: 12))
            }

            if let error = processor.errorMessage {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    @ViewBuilder
    private var reviewSection: some View {
        if let result = processor.result {
            VStack(alignment: .leading, spacing: 12) {
                sectionTitle("5", "Ergebnis prüfen & teilen")

                if let player {
                    VideoPlayer(player: player)
                        .frame(height: 420)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                }

                hitList(result)

                Toggle(isOn: $hasReviewedResult) {
                    Text("Ich habe das ganze Video angesehen. Automatische Erkennung kann Stellen übersehen.")
                        .font(.footnote)
                }

                shareButton(url: result.outputURL)
                saveToPhotosButton(url: result.outputURL)
                saveMessageView
            }
        } else if let result = processor.imageResult {
            VStack(alignment: .leading, spacing: 12) {
                sectionTitle("5", "Ergebnis prüfen & teilen")

                if let image = UIImage(contentsOfFile: result.outputURL.path) {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFit()
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                }

                imageHitList(result)

                Toggle(isOn: $hasReviewedResult) {
                    Text("Ich habe das ganze Bild angesehen. Automatische Erkennung kann Stellen übersehen.")
                        .font(.footnote)
                }

                shareButton(url: result.outputURL)
                saveToPhotosButton(url: result.outputURL)
                saveMessageView
            }
        }
    }

    @ViewBuilder
    private func shareButton(url: URL) -> some View {
        if url.pathExtension.lowercased() == "jpg" {
            ShareLink(item: url, preview: SharePreview("ChatBlur-Foto")) {
                Label("Teilen / in Dateien sichern", systemImage: "square.and.arrow.up")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .disabled(!hasReviewedResult)
        } else {
            ShareLink(item: MovieTransferable(url: url), preview: SharePreview("ChatBlur-Video")) {
                Label("Teilen / in Dateien sichern", systemImage: "square.and.arrow.up")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .disabled(!hasReviewedResult)
        }
    }

    private func saveToPhotosButton(url: URL) -> some View {
        Button {
            Task { await saveToPhotos(url) }
        } label: {
            Label(isSaving ? "Wird gesichert …" : "In Fotos sichern", systemImage: "photo.badge.plus")
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.bordered)
        .disabled(!hasReviewedResult || isSaving)
    }

    @ViewBuilder
    private var saveMessageView: some View {
        if let saveMessage {
            Text(saveMessage)
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    private func hitList(_ result: ProcessingResult) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            let uncertainCount = result.hits.filter(\.isUncertain).count
            Text("\(result.hits.count) Fundstelle(n) · \(uncertainCount) unsicher")
                .font(.subheadline.weight(.semibold))

            if result.hits.isEmpty {
                Label("Kein Schlagwort gefunden. Prüfe die Schreibweise oder wähle eine höhere Scan-Häufigkeit.", systemImage: "exclamationmark.triangle")
                    .font(.footnote)
                    .foregroundStyle(.orange)
            }
            if result.failedFrames > 0 {
                Label("\(result.failedFrames) von \(result.analyzedFrames) Analysebildern konnten nicht gelesen werden – dort besonders genau prüfen.", systemImage: "exclamationmark.triangle")
                    .font(.footnote)
                    .foregroundStyle(.orange)
            }

            ForEach(result.hits) { hit in
                Button {
                    player?.pause()
                    player?.seek(
                        to: CMTime(seconds: max(0, hit.start - 0.2), preferredTimescale: 600),
                        toleranceBefore: .zero,
                        toleranceAfter: .zero
                    )
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: hit.isUncertain ? "questionmark.circle.fill" : "checkmark.circle.fill")
                            .foregroundStyle(hit.isUncertain ? .orange : .teal)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("\(formatTime(hit.start)) – \(formatTime(hit.end))")
                                .font(.subheadline.monospacedDigit())
                            Text(hitDescription(hit))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 0)
                        Image(systemName: "play.circle")
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 6)
                    .padding(.horizontal, 10)
                    .background(.background, in: RoundedRectangle(cornerRadius: 10))
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func imageHitList(_ result: ImageResult) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            let uncertainCount = result.hits.filter(\.isUncertain).count
            Text("\(result.hits.count) Fundstelle(n) · \(uncertainCount) unsicher")
                .font(.subheadline.weight(.semibold))

            if result.hits.isEmpty {
                Label("Kein Schlagwort gefunden. Prüfe die Schreibweise und das Bild genau.", systemImage: "exclamationmark.triangle")
                    .font(.footnote)
                    .foregroundStyle(.orange)
            }

            ForEach(result.hits) { hit in
                HStack(spacing: 10) {
                    Image(systemName: hit.isUncertain ? "questionmark.circle.fill" : "checkmark.circle.fill")
                        .foregroundStyle(hit.isUncertain ? .orange : .teal)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("„\(hit.keyword)“")
                            .font(.subheadline)
                        Text(imageHitDescription(hit))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.vertical, 6)
                .padding(.horizontal, 10)
                .background(.background, in: RoundedRectangle(cornerRadius: 10))
            }
        }
    }

    private var privacyNote: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "lock.iphone")
                .foregroundStyle(.teal)
            VStack(alignment: .leading, spacing: 4) {
                Text("Lokal auf dem iPhone – keine Garantie auf Vollständigkeit")
                    .font(.subheadline.weight(.semibold))
                Text("Die Analyse läuft komplett auf dem Gerät, nichts wird hochgeladen. Verwischt wird die ganze erkannte Textzeile. Texterkennung kann Stellen übersehen – besonders bei sehr schnellem Scrollen, kleiner Schrift oder kurzen Einblendungen. Das Original wird nie verändert. Fotos werden ohne Standort- und Aufnahmedaten exportiert.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.teal.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
    }

    private var footer: some View {
        VStack(spacing: 6) {
            Text("Brockworks – Protect your Chat")
                .font(.caption.weight(.semibold))
            Link("Datenschutz & Anleitung", destination: URL(string: "https://brockworks.de/protect-your-chat-dsgvo/")!)
                .font(.caption)
        }
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity)
        .padding(.top, 4)
    }

    // MARK: Helpers

    private func sectionTitle(_ number: String, _ title: String) -> some View {
        HStack(spacing: 10) {
            Text(number)
                .font(.caption.bold())
                .foregroundStyle(.white)
                .frame(width: 25, height: 25)
                .background(Color.teal, in: Circle())
            Text(title).font(.headline)
        }
    }

    private func startProcessing() {
        guard let selectedMedia else { return }
        player?.pause()
        player = nil
        let settings = ProcessingSettings(
            sampleInterval: sampleInterval,
            blurStrength: blurRadius,
            allowPartialWords: allowPartialWords,
            tolerateOCRErrors: tolerateOCRErrors
        )
        switch selectedMedia.kind {
        case .video:
            processor.start(inputURL: selectedMedia.url, keywords: keywords, settings: settings)
        case .photo:
            processor.startImage(inputURL: selectedMedia.url, keywords: keywords, settings: settings)
        }
    }

    private func hitDescription(_ hit: HitSummary) -> String {
        var parts = ["„\(hit.keyword)“", "\(hit.observationCount)× erkannt"]
        if hit.containsFuzzyMatch { parts.append("ähnliche Schreibweise") }
        if hit.minConfidence < 0.5 { parts.append("niedrige OCR-Sicherheit") }
        if hit.observationCount == 1 { parts.append("nur kurz sichtbar") }
        return parts.joined(separator: " · ")
    }

    private func imageHitDescription(_ hit: ImageHitSummary) -> String {
        var parts: [String] = []
        if hit.isFuzzy { parts.append("ähnliche Schreibweise") }
        if hit.confidence < 0.5 { parts.append("niedrige OCR-Sicherheit") }
        if parts.isEmpty { parts.append("eindeutig erkannt") }
        return parts.joined(separator: " · ")
    }

    private func formatTime(_ seconds: Double) -> String {
        let tenths = Int((max(0, seconds) * 10).rounded())
        let minutes = tenths / 600
        let secs = (tenths % 600) / 10
        let fraction = tenths % 10
        return String(format: "%d:%02d,%d", minutes, secs, fraction)
    }

    private func displayName(for url: URL) -> String {
        let name = url.lastPathComponent
        // Imported copies are named "ChatBlur-import-<UUID>-<original name>".
        if name.hasPrefix("ChatBlur-import-") {
            let rest = name.dropFirst("ChatBlur-import-".count)
            if rest.count > 37 { return String(rest.dropFirst(37)) }
        }
        return name
    }

    private func removeSelectedMedia() {
        if let url = selectedMedia?.url { try? FileManager.default.removeItem(at: url) }
        selectedMedia = nil
        photoSelection = nil
        player?.pause()
        player = nil
        processor.reset()
    }

    private func setSelectedMedia(_ media: SelectedMedia) {
        if let old = selectedMedia?.url, old != media.url { try? FileManager.default.removeItem(at: old) }
        selectedMedia = media
        player?.pause()
        player = nil
        processor.reset()
    }

    @MainActor
    private func saveToPhotos(_ url: URL) async {
        isSaving = true
        defer { isSaving = false }
        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard status == .authorized || status == .limited else {
            saveMessage = "Kein Zugriff auf Fotos. Bitte in Einstellungen › ChatBlur › Fotos erlauben oder „Teilen“ verwenden."
            return
        }
        let isImage = url.pathExtension.lowercased() == "jpg"
        do {
            try await PHPhotoLibrary.shared().performChanges {
                if isImage {
                    _ = PHAssetChangeRequest.creationRequestForAssetFromImage(atFileURL: url)
                } else {
                    _ = PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: url)
                }
            }
            saveMessage = isImage
                ? "Als neues Foto in Fotos gesichert. Das Original ist unverändert."
                : "Als neues Video in Fotos gesichert. Das Original ist unverändert."
        } catch {
            saveMessage = "Sichern fehlgeschlagen: \(error.localizedDescription)"
        }
    }

    @MainActor
    private func importPhotoPickerItem(_ item: PhotosPickerItem) async {
        isImporting = true
        defer { isImporting = false }
        do {
            let imageType = item.supportedContentTypes.first { $0.conforms(to: .image) }
            if let imageType {
                guard let data = try await item.loadTransferable(type: Data.self) else {
                    throw ImportProblem.noFileDelivered
                }
                let ext = imageType.preferredFilenameExtension ?? "img"
                let destination = FileManager.default.temporaryDirectory
                    .appendingPathComponent("ChatBlur-import-\(UUID().uuidString)-Foto.\(ext)")
                try data.write(to: destination, options: .atomic)
                setSelectedMedia(SelectedMedia(url: destination, kind: .photo))
            } else {
                guard let movie = try await item.loadTransferable(type: MovieTransferable.self) else {
                    throw ImportProblem.noFileDelivered
                }
                setSelectedMedia(SelectedMedia(url: movie.url, kind: .video))
            }
        } catch {
            importError = "Die Datei konnte nicht aus Fotos geladen werden. Bitte versuche es über „Aus Dateien wählen“. Details: \(error.localizedDescription)"
        }
    }

    private func handleFileImport(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            guard let pickedURL = urls.first else { return }
            do {
                let hasAccess = pickedURL.startAccessingSecurityScopedResource()
                defer { if hasAccess { pickedURL.stopAccessingSecurityScopedResource() } }
                let isImage = (try? pickedURL.resourceValues(forKeys: [.contentTypeKey]).contentType)?
                    .conforms(to: .image) ?? false
                let destination = FileManager.default.temporaryDirectory
                    .appendingPathComponent("ChatBlur-import-\(UUID().uuidString)-\(pickedURL.lastPathComponent)")
                try FileManager.default.copyItem(at: pickedURL, to: destination)
                setSelectedMedia(SelectedMedia(url: destination, kind: isImage ? .photo : .video))
            } catch {
                importError = "Die Datei konnte nicht kopiert werden: \(error.localizedDescription)"
            }
        case .failure(let error):
            importError = error.localizedDescription
        }
    }

    private enum ImportProblem: LocalizedError {
        case noFileDelivered
        var errorDescription: String? { "Es wurde keine Datei geliefert." }
    }
}
