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
    /// Whether the listed notes were checked against a proof, and if not, why.
    @Published var listVerified = false
    @Published var verificationNote: String?

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

    // MARK: - Create and List

    func loadNotes() async {
        isLoading = true
        error = nil

        do {
            let client = try appState.getClient()
            let request = QueryRequest(limit: 100)
            let response: QueryResponse
            do {
                // Checked against a GroveDB proof of the whole notes tree and
                // the light client's header; throws when it can't be checked.
                response = try await client.data.query(subgroveId: appState.collectionId, query: request)
                listVerified = true
                verificationNote = nil
            } catch let error as WillowError where error.type == .notVerifiable {
                // The SDK can't check this query's answer, though nothing
                // shows it is wrong: list without a proof, labeled as such.
                // Any other failure (a proof that doesn't check out, a stale
                // answer, a network error) is shown as an error instead.
                response = try await client.data.queryUnverified(subgroveId: appState.collectionId, query: request)
                listVerified = false
                verificationNote = "Not verified: \(error.message)"
            }

            var loadedNotes: [Note] = []
            for result in response.results {
                let dict = result.data.mapValues { $0.value }
                if let note = Note.fromDictionary(dict) {
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

    // A note is written once. Editing, pinning, or deleting one would be an
    // UpdateData or DeleteData transaction, which the SDK doesn't build, so
    // the app offers none of them.

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
