// Willow Notes App - Models
//
// Data models for the Notes application

import Foundation

// MARK: - Note Model

struct Note: Identifiable, Codable, Equatable {
    let id: String
    var title: String
    var content: String
    var category: NoteCategory
    var tags: [String]
    var created: Date
    var updated: Date
    var pinned: Bool

    init(
        id: String = UUID().uuidString,
        title: String,
        content: String = "",
        category: NoteCategory = .personal,
        tags: [String] = [],
        created: Date = Date(),
        updated: Date = Date(),
        pinned: Bool = false
    ) {
        self.id = id
        self.title = title
        self.content = content
        self.category = category
        self.tags = tags
        self.created = created
        self.updated = updated
        self.pinned = pinned
    }

    // Convert to dictionary for storage
    func toDictionary() -> [String: Any] {
        return [
            "id": id,
            "title": title,
            "content": content,
            "category": category.rawValue,
            "tags": tags,
            "created": created.timeIntervalSince1970 * 1000,
            "updated": updated.timeIntervalSince1970 * 1000,
            "pinned": pinned
        ]
    }

    // Create from dictionary
    static func fromDictionary(_ dict: [String: Any]) -> Note? {
        guard let id = dict["id"] as? String,
              let title = dict["title"] as? String else {
            return nil
        }

        let content = dict["content"] as? String ?? ""
        let categoryRaw = dict["category"] as? String ?? "personal"
        let category = NoteCategory(rawValue: categoryRaw) ?? .personal
        let tags = dict["tags"] as? [String] ?? []
        let createdMs = dict["created"] as? Double ?? Date().timeIntervalSince1970 * 1000
        let updatedMs = dict["updated"] as? Double ?? Date().timeIntervalSince1970 * 1000
        let pinned = dict["pinned"] as? Bool ?? false

        return Note(
            id: id,
            title: title,
            content: content,
            category: category,
            tags: tags,
            created: Date(timeIntervalSince1970: createdMs / 1000),
            updated: Date(timeIntervalSince1970: updatedMs / 1000),
            pinned: pinned
        )
    }
}

// MARK: - Note Category

enum NoteCategory: String, CaseIterable, Codable {
    case personal
    case work
    case ideas
    case archive

    var displayName: String {
        rawValue.capitalized
    }

    var icon: String {
        switch self {
        case .personal: return "person.fill"
        case .work: return "briefcase.fill"
        case .ideas: return "lightbulb.fill"
        case .archive: return "archivebox.fill"
        }
    }

    var color: String {
        switch self {
        case .personal: return "blue"
        case .work: return "orange"
        case .ideas: return "yellow"
        case .archive: return "gray"
        }
    }
}

// MARK: - Filter Options

struct NoteFilter {
    var category: NoteCategory?
    var searchText: String = ""

    var isEmpty: Bool {
        category == nil && searchText.isEmpty
    }

    func matches(_ note: Note) -> Bool {
        // Category filter
        if let category = category, note.category != category {
            return false
        }

        // Search filter
        if !searchText.isEmpty {
            let searchLower = searchText.lowercased()
            let titleMatch = note.title.lowercased().contains(searchLower)
            let contentMatch = note.content.lowercased().contains(searchLower)
            let tagMatch = note.tags.contains { $0.lowercased().contains(searchLower) }

            if !titleMatch && !contentMatch && !tagMatch {
                return false
            }
        }

        return true
    }
}

// MARK: - Sort Options

enum NoteSortOption: String, CaseIterable {
    case updated
    case created
    case title

    var displayName: String {
        switch self {
        case .updated: return "Last Updated"
        case .created: return "Date Created"
        case .title: return "Title"
        }
    }
}

// MARK: - Editor State

struct NoteEditorState {
    var note: Note?
    var isNew: Bool
    var title: String = ""
    var content: String = ""
    var category: NoteCategory = .personal
    var tagsText: String = ""

    init(note: Note? = nil) {
        self.note = note
        self.isNew = note == nil

        if let note = note {
            self.title = note.title
            self.content = note.content
            self.category = note.category
            self.tagsText = note.tags.joined(separator: ", ")
        }
    }

    var tags: [String] {
        tagsText
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    var isValid: Bool {
        !title.trimmingCharacters(in: .whitespaces).isEmpty
    }

    func toNote() -> Note {
        if let existingNote = note {
            return Note(
                id: existingNote.id,
                title: title.trimmingCharacters(in: .whitespaces),
                content: content,
                category: category,
                tags: tags,
                created: existingNote.created,
                updated: Date(),
                pinned: existingNote.pinned
            )
        } else {
            return Note(
                title: title.trimmingCharacters(in: .whitespaces),
                content: content,
                category: category,
                tags: tags
            )
        }
    }
}
