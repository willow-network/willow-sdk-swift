// Willow Notes App - Notes View Model
//
// Manages notes data and operations

import Foundation
import Willow

@MainActor
class NotesViewModel: ObservableObject {
    @Published var notes: [Note] = []
    @Published var isLoading = false
    @Published var error: String?
    @Published var filter = NoteFilter()
    @Published var sortOption: NoteSortOption = .updated

    var appState: AppState

    init(appState: AppState) {
        self.appState = appState
    }

    // MARK: - Computed Properties

    var filteredNotes: [Note] {
        var result = notes.filter { filter.matches($0) }

        // Sort: pinned first, then by sort option
        result.sort { note1, note2 in
            // Pinned notes first
            if note1.pinned != note2.pinned {
                return note1.pinned
            }

            // Then by sort option
            switch sortOption {
            case .updated:
                return note1.updated > note2.updated
            case .created:
                return note1.created > note2.created
            case .title:
                return note1.title.localizedCaseInsensitiveCompare(note2.title) == .orderedAscending
            }
        }

        return result
    }

    var categories: [NoteCategory] {
        NoteCategory.allCases
    }

    var notesCount: Int {
        notes.count
    }

    var pinnedCount: Int {
        notes.filter { $0.pinned }.count
    }

    // MARK: - CRUD Operations

    func loadNotes() async {
        isLoading = true
        error = nil

        do {
            let client = try appState.getClient()
            let response = try await client.data.query(
                subgroveId: appState.collectionId,
                query: QueryRequest(limit: 100)
            )

            var loadedNotes: [Note] = []
            for doc in response.documents {
                if let dict = doc as? [String: Any],
                   let note = Note.fromDictionary(dict) {
                    loadedNotes.append(note)
                }
            }

            notes = loadedNotes
        } catch {
            self.error = "Failed to load notes: \(error.localizedDescription)"
        }

        isLoading = false
    }

    func createNote(_ note: Note) async -> Bool {
        isLoading = true
        error = nil

        do {
            let client = try appState.getClient()
            try await client.data.store(
                subgroveId: appState.collectionId,
                key: note.id,
                data: note.toDictionary()
            )

            notes.append(note)
            isLoading = false
            return true
        } catch {
            self.error = "Failed to create note: \(error.localizedDescription)"
            isLoading = false
            return false
        }
    }

    func updateNote(_ note: Note) async -> Bool {
        isLoading = true
        error = nil

        do {
            let client = try appState.getClient()
            try await client.data.update(
                subgroveId: appState.collectionId,
                key: note.id,
                data: note.toDictionary()
            )

            if let index = notes.firstIndex(where: { $0.id == note.id }) {
                notes[index] = note
            }

            isLoading = false
            return true
        } catch {
            self.error = "Failed to update note: \(error.localizedDescription)"
            isLoading = false
            return false
        }
    }

    func deleteNote(_ note: Note) async -> Bool {
        isLoading = true
        error = nil

        do {
            let client = try appState.getClient()
            try await client.data.delete(
                subgroveId: appState.collectionId,
                key: note.id
            )

            notes.removeAll { $0.id == note.id }
            isLoading = false
            return true
        } catch {
            self.error = "Failed to delete note: \(error.localizedDescription)"
            isLoading = false
            return false
        }
    }

    func togglePin(_ note: Note) async {
        var updatedNote = note
        updatedNote.pinned.toggle()
        updatedNote.updated = Date()

        _ = await updateNote(updatedNote)
    }

    // MARK: - Filtering

    func setCategory(_ category: NoteCategory?) {
        filter.category = category
    }

    func setSearchText(_ text: String) {
        filter.searchText = text
    }

    func clearFilters() {
        filter = NoteFilter()
    }

    // MARK: - Refresh

    func refresh() async {
        await loadNotes()
        await appState.refreshBalances()
    }
}
