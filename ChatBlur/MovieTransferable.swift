import Foundation
import CoreTransferable
import UniformTypeIdentifiers

/// Transfers movie files without loading the full video into RAM.
struct MovieTransferable: Transferable {
    let url: URL

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(contentType: .movie) { movie in
            SentTransferredFile(movie.url)
        } importing: { received in
            let destination = FileManager.default.temporaryDirectory
                .appendingPathComponent("ChatBlur-import-\(UUID().uuidString)-\(received.file.lastPathComponent)")
            try FileManager.default.copyItem(at: received.file, to: destination)
            return MovieTransferable(url: destination)
        }
    }
}
