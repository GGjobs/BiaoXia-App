import SwiftData
import SwiftUI

@main
struct BiaoXiaApp: App {
    private let modelContainer: ModelContainer = {
        do {
            return try ModelContainer(for: FillTaskRecord.self)
        } catch {
            fatalError("无法初始化表匣数据库：\(error.localizedDescription)")
        }
    }()

    var body: some Scene {
        WindowGroup {
            RootView()
        }
        .modelContainer(modelContainer)
    }
}
