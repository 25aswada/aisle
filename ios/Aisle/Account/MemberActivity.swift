import Foundation
import UIKit

/// What a shopper has done with Aisle+, kept on the phone for the member screen:
/// photo searches per day (and a few small thumbnails), follow-up questions with the
/// latest exchange, and multi-store trips. Views read the counts with @AppStorage.
enum MemberActivity {
    static let freePhotosPerDay = 1
    static let freeFollowUpsPerSearch = 1
    static let freeSearchesPerDay = 5

    static let photosKey = "aisle.member.photos"
    static let photoDaysKey = "aisle.member.photoDays"
    static let followUpsKey = "aisle.member.followUps"
    static let lastQuestionKey = "aisle.member.lastQuestion"
    static let lastAnswerKey = "aisle.member.lastAnswer"
    static let tripsKey = "aisle.member.multiStoreTrips"

    private static let keepThumbnails = 4
    private static let dayFormat: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    // MARK: - Recording

    /// A photo search that named an item.
    static func recordPhotoSearch(_ photo: Data, now: Date = .now, defaults: UserDefaults = .standard) {
        defaults.set(defaults.integer(forKey: photosKey) + 1, forKey: photosKey)
        var days = photoDays(defaults)
        let key = dayFormat.string(from: now)
        days[key, default: 0] += 1
        // Two months is plenty for a two-week chart.
        let cutoff = dayFormat.string(from: now.addingTimeInterval(-60 * 86_400))
        days = days.filter { $0.key >= cutoff }
        if let data = try? JSONEncoder().encode(days) { defaults.set(data, forKey: photoDaysKey) }
        saveThumbnail(photo, at: now)
    }

    static func recordFollowUp(question: String, answer: String, defaults: UserDefaults = .standard) {
        defaults.set(defaults.integer(forKey: followUpsKey) + 1, forKey: followUpsKey)
        defaults.set(question, forKey: lastQuestionKey)
        defaults.set(answer, forKey: lastAnswerKey)
    }

    static func recordMultiStoreTrip(defaults: UserDefaults = .standard) {
        defaults.set(defaults.integer(forKey: tripsKey) + 1, forKey: tripsKey)
    }

    // MARK: - Reading

    struct Day: Identifiable, Equatable {
        let date: Date
        let count: Int
        var id: Date { date }
        var extra: Int { max(0, count - MemberActivity.freePhotosPerDay) }
    }

    /// Photo searches per day for the last `count` days, oldest first, including empty days.
    static func recentDays(_ count: Int = 14, now: Date = .now, defaults: UserDefaults = .standard) -> [Day] {
        let days = photoDays(defaults)
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: now)
        return (0..<count).reversed().compactMap { offset in
            guard let date = calendar.date(byAdding: .day, value: -offset, to: today) else { return nil }
            return Day(date: date, count: days[dayFormat.string(from: date)] ?? 0)
        }
    }

    /// The newest photo thumbnails, newest first.
    static func thumbnails() -> [UIImage] {
        guard let folder = thumbnailFolder,
              let files = try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
        else { return [] }
        return files
            .filter { $0.pathExtension == "jpg" }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }
            .prefix(keepThumbnails)
            .compactMap { UIImage(contentsOfFile: $0.path) }
    }

    static func reset(defaults: UserDefaults = .standard) {
        for key in [photosKey, photoDaysKey, followUpsKey, lastQuestionKey, lastAnswerKey, tripsKey] {
            defaults.removeObject(forKey: key)
        }
        if let folder = thumbnailFolder { try? FileManager.default.removeItem(at: folder) }
    }

    // MARK: - Storage

    private static func photoDays(_ defaults: UserDefaults) -> [String: Int] {
        defaults.data(forKey: photoDaysKey)
            .flatMap { try? JSONDecoder().decode([String: Int].self, from: $0) } ?? [:]
    }

    private static var thumbnailFolder: URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("MemberThumbnails", isDirectory: true)
    }

    private static func saveThumbnail(_ photo: Data, at date: Date) {
        guard let folder = thumbnailFolder,
              let image = UIImage(data: photo),
              let small = image.preparingThumbnail(of: CGSize(width: 180, height: 180)),
              let jpeg = small.jpegData(compressionQuality: 0.7) else { return }
        let manager = FileManager.default
        try? manager.createDirectory(at: folder, withIntermediateDirectories: true)
        let name = String(format: "%013.0f.jpg", date.timeIntervalSince1970 * 1000)
        try? jpeg.write(to: folder.appendingPathComponent(name), options: .atomic)
        // Keep only the newest few.
        if let files = try? manager.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil) {
            let old = files.filter { $0.pathExtension == "jpg" }
                .sorted { $0.lastPathComponent > $1.lastPathComponent }
                .dropFirst(keepThumbnails)
            for file in old { try? manager.removeItem(at: file) }
        }
    }
}
