import Foundation
import Combine
import AVFoundation
import CoreImage
import Vision
import UIKit

// MARK: - Public data types

struct ProcessingSettings: Sendable {
    /// Seconds between two OCR scans.
    var sampleInterval: Double
    /// Strength of the pixelation + blur.
    var blurStrength: Double
    var allowPartialWords: Bool
    var tolerateOCRErrors: Bool
}

/// One tracked appearance of a keyword (e.g. a name scrolling through the screen).
struct HitSummary: Identifiable, Sendable {
    let id: Int
    let keyword: String
    let start: Double
    let end: Double
    let observationCount: Int
    let minConfidence: Float
    let containsFuzzyMatch: Bool

    /// Hits that deserve a closer look in the preview.
    var isUncertain: Bool { minConfidence < 0.5 || containsFuzzyMatch || observationCount == 1 }
}

struct ProcessingResult: Sendable {
    let outputURL: URL
    let hits: [HitSummary]
    let analyzedFrames: Int
    let failedFrames: Int
    let videoDuration: Double
}

// MARK: - Internal data types

private struct KeywordHit: Sendable {
    let rect: CGRect
    let confidence: Float
    let isFuzzy: Bool
    let keyword: String
}

private struct DetectionSample: Sendable {
    let time: Double
    let hits: [KeywordHit]
}

private struct BoxObservation: Sendable {
    let time: Double
    let rect: CGRect
    let confidence: Float
    let isFuzzy: Bool
}

private struct BoxTrack: Sendable {
    let keyword: String
    var observations: [BoxObservation]
}

private enum ProcessingError: LocalizedError {
    case invalidVideo
    case noVideoTrack
    case noKeywords
    case notEnoughStorage(neededMB: Int64, availableMB: Int64)
    case cannotCreateExporter
    case exportFailed(String?)

    var errorDescription: String? {
        switch self {
        case .invalidVideo:
            return "Die Videodatei hat keine gültige Länge oder konnte nicht gelesen werden."
        case .noVideoTrack:
            return "In der Datei wurde keine Videospur gefunden."
        case .noKeywords:
            return "Bitte mindestens ein Schlagwort eingeben."
        case let .notEnoughStorage(needed, available):
            return "Nicht genug freier Speicher auf dem iPhone. Benötigt werden ca. \(needed) MB, frei sind \(available) MB. Bitte Speicher freigeben oder ein kürzeres Video wählen."
        case .cannotCreateExporter:
            return "Der Videoexport konnte nicht gestartet werden."
        case let .exportFailed(details):
            let base = "Der Videoexport ist fehlgeschlagen. Die App muss während des Exports geöffnet bleiben."
            if let details, !details.isEmpty { return base + " Details: " + details }
            return base
        }
    }
}

// MARK: - Processor

@MainActor
final class VideoProcessor: ObservableObject {
    @Published private(set) var isProcessing = false
    @Published private(set) var progress = 0.0
    @Published private(set) var status = "Bereit"
    @Published private(set) var result: ProcessingResult?
    @Published private(set) var errorMessage: String?

    private var processingTask: Task<Void, Never>?

    func reset() {
        guard !isProcessing else { return }
        progress = 0
        status = "Bereit"
        if let old = result?.outputURL { try? FileManager.default.removeItem(at: old) }
        result = nil
        errorMessage = nil
    }

    func cancel() {
        guard isProcessing else { return }
        status = "Wird abgebrochen …"
        processingTask?.cancel()
    }

    func start(inputURL: URL, keywords: [String], settings: ProcessingSettings) {
        guard !isProcessing else { return }
        let matcher = KeywordMatcher(
            keywords: keywords,
            allowPartialWords: settings.allowPartialWords,
            tolerateOCRErrors: settings.tolerateOCRErrors
        )
        guard !matcher.isEmpty else {
            errorMessage = ProcessingError.noKeywords.errorDescription
            return
        }

        reset()
        isProcessing = true
        status = "Video wird vorbereitet …"
        // The XR must not lock during a long analysis, otherwise the export is interrupted.
        UIApplication.shared.isIdleTimerDisabled = true

        processingTask = Task.detached(priority: .userInitiated) { [weak self] in
            do {
                let output = try await Self.processVideo(
                    inputURL: inputURL,
                    matcher: matcher,
                    settings: settings,
                    update: { newProgress, newStatus in
                        Task { @MainActor [weak self] in
                            guard let self, self.isProcessing else { return }
                            self.progress = newProgress
                            self.status = newStatus
                        }
                    }
                )
                await MainActor.run {
                    guard let self else { return }
                    self.result = output
                    self.progress = 1
                    self.status = "Fertig. Bitte das Ergebnis vollständig ansehen, bevor du es teilst."
                    self.finishProcessing()
                }
            } catch {
                let cancelled = error is CancellationError || Task.isCancelled
                let message = Self.friendlyMessage(for: error)
                await MainActor.run {
                    guard let self else { return }
                    if cancelled {
                        self.status = "Abgebrochen"
                        self.progress = 0
                    } else {
                        self.errorMessage = message
                        self.status = "Verarbeitung fehlgeschlagen"
                    }
                    self.finishProcessing()
                }
            }
        }
    }

    private func finishProcessing() {
        isProcessing = false
        processingTask = nil
        UIApplication.shared.isIdleTimerDisabled = false
    }

    nonisolated private static func friendlyMessage(for error: Error) -> String {
        let nsError = error as NSError
        if nsError.domain == AVFoundationErrorDomain && nsError.code == AVError.diskFull.rawValue {
            return "Der Speicher des iPhones ist voll. Bitte Speicher freigeben und erneut versuchen."
        }
        if nsError.domain == NSCocoaErrorDomain && nsError.code == NSFileWriteOutOfSpaceError {
            return "Der Speicher des iPhones ist voll. Bitte Speicher freigeben und erneut versuchen."
        }
        return error.localizedDescription
    }

    // MARK: Temporary files

    nonisolated static var exportsDirectory: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("ChatBlurExports", isDirectory: true)
    }

    /// Removes imported copies and old exports from the app's temporary folder.
    /// The user's original video in Photos/Files is never touched.
    nonisolated static func cleanupTemporaryFiles(keeping keep: [URL] = []) {
        let fm = FileManager.default
        let keepPaths = Set(keep.map { $0.standardizedFileURL.path })
        let tmp = fm.temporaryDirectory
        if let items = try? fm.contentsOfDirectory(at: tmp, includingPropertiesForKeys: nil) {
            for item in items where item.lastPathComponent.hasPrefix("ChatBlur-import-") {
                if !keepPaths.contains(item.standardizedFileURL.path) { try? fm.removeItem(at: item) }
            }
        }
        if let items = try? fm.contentsOfDirectory(at: exportsDirectory, includingPropertiesForKeys: nil) {
            for item in items where !keepPaths.contains(item.standardizedFileURL.path) {
                try? fm.removeItem(at: item)
            }
        }
    }

    // MARK: Pipeline

    nonisolated private static func processVideo(
        inputURL: URL,
        matcher: KeywordMatcher,
        settings: ProcessingSettings,
        update: @escaping @Sendable (Double, String) -> Void
    ) async throws -> ProcessingResult {
        let asset = AVURLAsset(url: inputURL)
        let duration = try await asset.load(.duration).seconds
        guard duration.isFinite, duration > 0 else { throw ProcessingError.invalidVideo }
        let videoTracks = try await asset.loadTracks(withMediaType: .video)
        guard !videoTracks.isEmpty else { throw ProcessingError.noVideoTrack }

        try checkFreeStorage(for: inputURL)

        // 1. OCR on regularly spaced frames ------------------------------------------------
        update(0.02, "Videolänge wird geprüft …")
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        // iPhone XR screen recordings are 828 × 1792 – keep native resolution so small chat text stays readable.
        generator.maximumSize = CGSize(width: 1920, height: 1920)
        let tolerance = CMTime(seconds: 0.03, preferredTimescale: 600)
        generator.requestedTimeToleranceBefore = tolerance
        generator.requestedTimeToleranceAfter = tolerance

        let languages = supportedLanguages()
        let step = max(0.06, settings.sampleInterval)
        let sampleCount = max(1, Int(ceil(duration / step)))
        var samples: [DetectionSample] = []
        samples.reserveCapacity(min(sampleCount, 50_000))
        var failedFrames = 0
        let startDate = Date()

        for index in 0..<sampleCount {
            try Task.checkCancellation()
            let seconds = min(Double(index) * step, max(0, duration - 0.02))
            let time = CMTime(seconds: seconds, preferredTimescale: 600)

            var hits: [KeywordHit] = []
            do {
                let frame = try await generator.image(at: time)
                hits = try autoreleasepool {
                    try detectHits(in: frame.image, matcher: matcher, languages: languages)
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                // One undecodable frame must not stop the whole video; it is reported to the user instead.
                failedFrames += 1
            }
            samples.append(DetectionSample(time: seconds, hits: hits))

            if index % 3 == 0 || index == sampleCount - 1 {
                let done = index + 1
                let fraction = Double(done) / Double(sampleCount)
                var text = "Text wird erkannt: Bild \(done) von \(sampleCount)"
                if done >= 6 {
                    let elapsed = Date().timeIntervalSince(startDate)
                    let remaining = elapsed / Double(done) * Double(sampleCount - done)
                    text += " · noch ca. \(formatDuration(remaining)) bis zum Export"
                }
                update(0.03 + 0.62 * fraction, text)
            }
        }

        // 2. Link detections over time ----------------------------------------------------
        let tracks = buildTracks(from: samples, maxGap: max(0.4, step * 3.2))
        let summaries = summarize(tracks)
        update(0.66, "\(summaries.count) Treffer gefunden · Video wird gerendert …")
        try Task.checkCancellation()

        // 3. Render blur and export with original audio -----------------------------------
        let exportsDir = exportsDirectory
        try FileManager.default.createDirectory(at: exportsDir, withIntermediateDirectories: true)
        let outputURL = exportsDir.appendingPathComponent("ChatBlur-\(Int(Date().timeIntervalSince1970)).mp4")
        try? FileManager.default.removeItem(at: outputURL)

        // Masks reach a little beyond the first/last detection because the text is usually
        // already visible shortly before OCR sees it. Extra blur is the safer error.
        let lead = step + 0.06
        let strength = max(4.0, settings.blurStrength)
        let composition = AVVideoComposition(asset: asset, applyingCIFiltersWithHandler: { request in
            let extent = request.sourceImage.extent
            let rectangles = Self.activeRectangles(in: tracks, at: request.compositionTime.seconds, lead: lead)
            if rectangles.isEmpty {
                request.finish(with: request.sourceImage, context: nil)
                return
            }

            let source = request.sourceImage.clampedToExtent()
            let obscured = source
                .applyingFilter("CIPixellate", parameters: [
                    kCIInputScaleKey: strength * 0.9,
                    kCIInputCenterKey: CIVector(x: 0, y: 0)
                ])
                .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: strength * 0.6])

            var output = request.sourceImage
            for normalizedRect in rectangles {
                let pixelRect = CGRect(
                    x: extent.minX + normalizedRect.minX * extent.width,
                    y: extent.minY + normalizedRect.minY * extent.height,
                    width: normalizedRect.width * extent.width,
                    height: normalizedRect.height * extent.height
                )
                let padded = pixelRect.insetBy(
                    dx: -max(8, pixelRect.width * 0.05),
                    dy: -max(6, pixelRect.height * 0.30)
                ).intersection(extent)
                guard !padded.isNull, !padded.isEmpty else { continue }
                output = obscured.cropped(to: padded).composited(over: output)
            }
            request.finish(with: output.cropped(to: extent), context: nil)
        })

        guard let exporter = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetHighestQuality) else {
            throw ProcessingError.cannotCreateExporter
        }
        exporter.videoComposition = composition
        exporter.outputURL = outputURL
        exporter.outputFileType = .mp4
        exporter.shouldOptimizeForNetworkUse = true

        update(0.68, "Video wird gerendert, Ton wird übernommen …")
        let progressTask = Task.detached {
            while !Task.isCancelled {
                let value = Double(exporter.progress)
                update(0.68 + value * 0.31, "Video wird exportiert … \(Int(value * 100)) %")
                switch exporter.status {
                case .completed, .failed, .cancelled:
                    return
                default:
                    try? await Task.sleep(nanoseconds: 400_000_000)
                }
            }
        }

        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                exporter.exportAsynchronously {
                    continuation.resume()
                }
            }
        } onCancel: {
            exporter.cancelExport()
        }
        progressTask.cancel()

        if Task.isCancelled || exporter.status == .cancelled {
            try? FileManager.default.removeItem(at: outputURL)
            throw CancellationError()
        }
        guard exporter.status == .completed else {
            try? FileManager.default.removeItem(at: outputURL)
            if let error = exporter.error { throw ProcessingError.exportFailed(friendlyMessage(for: error)) }
            throw ProcessingError.exportFailed(nil)
        }

        update(0.99, "Export abgeschlossen …")
        return ProcessingResult(
            outputURL: outputURL,
            hits: summaries,
            analyzedFrames: sampleCount,
            failedFrames: failedFrames,
            videoDuration: duration
        )
    }

    nonisolated private static func checkFreeStorage(for inputURL: URL) throws {
        let inputSize = Int64((try? inputURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        let values = try? FileManager.default.temporaryDirectory
            .resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        guard let available = values?.volumeAvailableCapacityForImportantUsage else { return }
        // Export at highest quality can be larger than the input; keep a safety margin.
        let needed = inputSize * 2 + 150_000_000
        if available < needed {
            throw ProcessingError.notEnoughStorage(neededMB: needed / 1_000_000, availableMB: available / 1_000_000)
        }
    }

    nonisolated private static func formatDuration(_ seconds: Double) -> String {
        let total = max(0, Int(seconds.rounded()))
        if total < 60 { return "\(total) s" }
        return "\(total / 60) min \(total % 60) s"
    }

    // MARK: OCR

    nonisolated private static func supportedLanguages() -> [String] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        let supported = (try? request.supportedRecognitionLanguages()) ?? []
        return ["de-DE", "en-US"].filter { supported.contains($0) }
    }

    nonisolated private static func detectHits(in image: CGImage, matcher: KeywordMatcher, languages: [String]) throws -> [KeywordHit] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = false
        request.minimumTextHeight = 0.004
        if !languages.isEmpty { request.recognitionLanguages = languages }
        let handler = VNImageRequestHandler(cgImage: image, orientation: .up, options: [:])
        try handler.perform([request])

        var hits: [KeywordHit] = []
        for observation in request.results ?? [] {
            // Look beyond the best candidate: OCR often has the right reading in 2nd/3rd place.
            for candidate in observation.topCandidates(3) {
                if let match = matcher.match(candidate.string) {
                    hits.append(KeywordHit(
                        rect: observation.boundingBox.clampedToUnitSquare(),
                        confidence: candidate.confidence,
                        isFuzzy: match.isFuzzy,
                        keyword: match.keyword
                    ))
                    break
                }
            }
        }
        return hits
    }

    // MARK: Tracking

    /// Links detections of consecutive OCR frames into tracks. Instead of a fixed screen
    /// position, each track predicts where its text should be (using the scroll speed of
    /// its last two detections) and picks the closest new detection of the same keyword.
    nonisolated private static func buildTracks(from samples: [DetectionSample], maxGap: Double) -> [BoxTrack] {
        var tracks: [BoxTrack] = []

        for sample in samples {
            var usedTracks = Set<Int>()
            let orderedHits = sample.hits.sorted { $0.rect.midY > $1.rect.midY }

            for hit in orderedHits {
                var bestIndex: Int?
                var bestScore = CGFloat.greatestFiniteMagnitude

                for index in tracks.indices where !usedTracks.contains(index) && tracks[index].keyword == hit.keyword {
                    guard let last = tracks[index].observations.last else { continue }
                    let gap = sample.time - last.time
                    guard gap > 0, gap <= maxGap else { continue }

                    let predicted = predictedRect(for: tracks[index].observations, at: sample.time)
                    let dx = abs(predicted.midX - hit.rect.midX)
                    let dy = abs(predicted.midY - hit.rect.midY)
                    guard dx < 0.15, dy < 0.30 else { continue }
                    let score = dy + 2 * dx
                    if score < bestScore {
                        bestScore = score
                        bestIndex = index
                    }
                }

                let observation = BoxObservation(time: sample.time, rect: hit.rect, confidence: hit.confidence, isFuzzy: hit.isFuzzy)
                if let bestIndex {
                    tracks[bestIndex].observations.append(observation)
                    usedTracks.insert(bestIndex)
                } else {
                    tracks.append(BoxTrack(keyword: hit.keyword, observations: [observation]))
                    usedTracks.insert(tracks.count - 1)
                }
            }
        }
        return tracks
    }

    nonisolated private static func summarize(_ tracks: [BoxTrack]) -> [HitSummary] {
        let sorted = tracks.sorted { ($0.observations.first?.time ?? 0) < ($1.observations.first?.time ?? 0) }
        return sorted.enumerated().compactMap { pair -> HitSummary? in
            let index = pair.offset
            let track = pair.element
            guard let first = track.observations.first, let last = track.observations.last else { return nil }
            return HitSummary(
                id: index,
                keyword: track.keyword,
                start: first.time,
                end: last.time,
                observationCount: track.observations.count,
                minConfidence: track.observations.map(\.confidence).min() ?? 0,
                containsFuzzyMatch: track.observations.contains { $0.isFuzzy }
            )
        }
    }

    /// Normalised scroll velocity (units per second) between two observations, clamped to sane values.
    nonisolated private static func velocity(_ a: BoxObservation, _ b: BoxObservation) -> CGVector {
        let dt = b.time - a.time
        guard dt > 0.0001 else { return .zero }
        let limit: CGFloat = 4.0
        let vx = max(-limit, min(limit, (b.rect.midX - a.rect.midX) / CGFloat(dt)))
        let vy = max(-limit, min(limit, (b.rect.midY - a.rect.midY) / CGFloat(dt)))
        return CGVector(dx: vx, dy: vy)
    }

    nonisolated private static func predictedRect(for observations: [BoxObservation], at time: Double) -> CGRect {
        guard let last = observations.last else { return .zero }
        guard observations.count >= 2 else { return last.rect }
        let v = velocity(observations[observations.count - 2], last)
        let dt = CGFloat(time - last.time)
        return last.rect.offsetBy(dx: v.dx * dt, dy: v.dy * dt)
    }

    /// Rectangles (normalised, origin bottom-left) that must be obscured at `time`.
    nonisolated private static func activeRectangles(in tracks: [BoxTrack], at time: Double, lead: Double) -> [CGRect] {
        var results: [CGRect] = []
        for track in tracks {
            let obs = track.observations
            guard let first = obs.first, let last = obs.last else { continue }
            guard time >= first.time - lead, time <= last.time + lead else { continue }

            if obs.count == 1 {
                // Unknown motion: cover a taller area around the single detection.
                results.append(first.rect.insetBy(dx: 0, dy: -first.rect.height * 0.8))
                continue
            }
            if time <= first.time {
                let v = velocity(obs[0], obs[1])
                let dt = CGFloat(time - first.time)
                results.append(first.rect.offsetBy(dx: v.dx * dt, dy: v.dy * dt))
                continue
            }
            if time >= last.time {
                let v = velocity(obs[obs.count - 2], last)
                let dt = CGFloat(time - last.time)
                results.append(last.rect.offsetBy(dx: v.dx * dt, dy: v.dy * dt))
                continue
            }

            // Binary search for the two observations around `time`.
            var low = 0
            var high = obs.count - 1
            while high - low > 1 {
                let mid = (low + high) / 2
                if obs[mid].time <= time { low = mid } else { high = mid }
            }
            let a = obs[low]
            let b = obs[high]
            let span = max(0.0001, b.time - a.time)
            let fraction = CGFloat(min(1, max(0, (time - a.time) / span)))
            var rect = interpolate(a.rect, b.rect, fraction: fraction)
            // While scrolling fast, widen the mask a little in scroll direction.
            let motion = abs(b.rect.midY - a.rect.midY)
            if motion > 0.01 { rect = rect.insetBy(dx: 0, dy: -motion * 0.25) }
            results.append(rect)
        }
        return results
    }

    nonisolated private static func interpolate(_ a: CGRect, _ b: CGRect, fraction f: CGFloat) -> CGRect {
        CGRect(
            x: a.origin.x + (b.origin.x - a.origin.x) * f,
            y: a.origin.y + (b.origin.y - a.origin.y) * f,
            width: a.width + (b.width - a.width) * f,
            height: a.height + (b.height - a.height) * f
        )
    }
}

private extension CGRect {
    /// Keeps Vision's normalised bounding box within the unit square.
    func clampedToUnitSquare() -> CGRect {
        let minX = Swift.max(0, Swift.min(1, origin.x))
        let minY = Swift.max(0, Swift.min(1, origin.y))
        let maxX = Swift.max(minX, Swift.min(1, origin.x + size.width))
        let maxY = Swift.max(minY, Swift.min(1, origin.y + size.height))
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }
}
