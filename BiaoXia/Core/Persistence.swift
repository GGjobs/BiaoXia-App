import Foundation
import SwiftData

@Model
final class FillTaskRecord {
    @Attribute(.unique) var id: UUID
    var title: String
    var statusRawValue: String
    var createdAt: Date
    var updatedAt: Date
    var taskDirectoryName: String
    var progress: Double
    var exportRelativePath: String?
    var lastError: String?

    init(snapshot: FillTaskSnapshot) {
        id = snapshot.id
        title = snapshot.title
        statusRawValue = snapshot.status.rawValue
        createdAt = snapshot.createdAt
        updatedAt = snapshot.updatedAt
        taskDirectoryName = snapshot.id.uuidString.lowercased()
        progress = 0
        exportRelativePath = snapshot.exportRelativePath
        lastError = snapshot.lastError
    }

    var status: FillTaskStatus {
        get { FillTaskStatus(rawValue: statusRawValue) ?? .failed }
        set { statusRawValue = newValue.rawValue }
    }

    func update(from snapshot: FillTaskSnapshot) {
        title = snapshot.title
        status = snapshot.status
        updatedAt = snapshot.updatedAt
        exportRelativePath = snapshot.exportRelativePath
        lastError = snapshot.lastError
        if snapshot.recognitionTotalPages > 0 {
            progress = Double(snapshot.recognitionCompletedPages) / Double(snapshot.recognitionTotalPages)
        }
    }
}
