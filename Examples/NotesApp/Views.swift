// Willow Notes App - SwiftUI Views
//
// All views for the Notes application

import SwiftUI
import Willow

// MARK: - Loading View

struct LoadingView: View {
    var body: some View {
        VStack(spacing: 20) {
            ProgressView()
                .scaleEffect(1.5)
            Text("Loading Willow Notes...")
                .font(.headline)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.systemGroupedBackground))
    }
}

// MARK: - Login View

struct LoginView: View {
    @EnvironmentObject var appState: AppState
    @State private var privateKey = ""
    @State private var isNewUser = true
    @State private var isLoading = false
    @State private var showPrivateKey = false
    @State private var generatedKey: String?

    var body: some View {
        NavigationView {
            ScrollView {
                VStack(spacing: 30) {
                    // Logo
                    VStack(spacing: 10) {
                        Image(systemName: "note.text")
                            .font(.system(size: 60))
                            .foregroundColor(.blue)
                        Text("Willow Notes")
                            .font(.largeTitle)
                            .fontWeight(.bold)
                        Text("Decentralized, verified notes")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                    }
                    .padding(.top, 40)

                    // Mode Selector
                    Picker("Mode", selection: $isNewUser) {
                        Text("New User").tag(true)
                        Text("Existing User").tag(false)
                    }
                    .pickerStyle(.segmented)
                    .padding(.horizontal)

                    if isNewUser {
                        newUserView
                    } else {
                        existingUserView
                    }

                    if let error = appState.error {
                        Text(error)
                            .font(.caption)
                            .foregroundColor(.red)
                            .padding()
                    }

                    Spacer()
                }
                .padding()
            }
            .navigationBarHidden(true)
        }
    }

    private var newUserView: some View {
        VStack(spacing: 20) {
            Text("Generate a new decentralized identity (DID) to start using Willow Notes.")
                .font(.body)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)

            if let key = generatedKey {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Save your private key!")
                        .font(.headline)
                        .foregroundColor(.orange)

                    Text("You'll need this to log in again. Store it securely.")
                        .font(.caption)
                        .foregroundColor(.secondary)

                    HStack {
                        Text(key)
                            .font(.system(.caption, design: .monospaced))
                            .lineLimit(2)

                        Button(action: {
                            UIPasteboard.general.string = key
                        }) {
                            Image(systemName: "doc.on.doc")
                        }
                    }
                    .padding()
                    .background(Color(.systemGray6))
                    .cornerRadius(8)
                }
                .padding()
                .background(Color.orange.opacity(0.1))
                .cornerRadius(12)
            }

            Button(action: generateDID) {
                HStack {
                    if isLoading {
                        ProgressView()
                            .progressViewStyle(CircularProgressViewStyle(tint: .white))
                    }
                    Text(isLoading ? "Generating..." : "Generate DID & Start")
                }
                .frame(maxWidth: .infinity)
                .padding()
                .background(Color.blue)
                .foregroundColor(.white)
                .cornerRadius(10)
            }
            .disabled(isLoading)
            .padding(.horizontal)
        }
    }

    private var existingUserView: some View {
        VStack(spacing: 20) {
            Text("Enter your private key to access your notes.")
                .font(.body)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)

            HStack {
                if showPrivateKey {
                    TextField("Private Key", text: $privateKey)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(.body, design: .monospaced))
                        .autocapitalization(.none)
                        .disableAutocorrection(true)
                } else {
                    SecureField("Private Key", text: $privateKey)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(.body, design: .monospaced))
                }

                Button(action: { showPrivateKey.toggle() }) {
                    Image(systemName: showPrivateKey ? "eye.slash" : "eye")
                        .foregroundColor(.secondary)
                }
            }
            .padding(.horizontal)

            Button(action: login) {
                HStack {
                    if isLoading {
                        ProgressView()
                            .progressViewStyle(CircularProgressViewStyle(tint: .white))
                    }
                    Text(isLoading ? "Logging in..." : "Login")
                }
                .frame(maxWidth: .infinity)
                .padding()
                .background(privateKey.isEmpty ? Color.gray : Color.blue)
                .foregroundColor(.white)
                .cornerRadius(10)
            }
            .disabled(privateKey.isEmpty || isLoading)
            .padding(.horizontal)
        }
    }

    private func generateDID() {
        isLoading = true
        Task {
            do {
                let result = try await appState.generateAndRegister()
                generatedKey = result.privateKey
                await appState.checkAppRegistration()
            } catch {
                appState.error = error.localizedDescription
            }
            isLoading = false
        }
    }

    private func login() {
        isLoading = true
        Task {
            do {
                try await appState.login(with: privateKey)
                await appState.checkAppRegistration()
            } catch {
                appState.error = error.localizedDescription
            }
            isLoading = false
        }
    }
}

// MARK: - Setup View

struct SetupView: View {
    @EnvironmentObject var appState: AppState
    @State private var isLoading = false
    @State private var statusMessage = ""

    var body: some View {
        NavigationView {
            VStack(spacing: 30) {
                Image(systemName: "externaldrive.badge.plus")
                    .font(.system(size: 60))
                    .foregroundColor(.blue)

                Text("Welcome to Willow Notes!")
                    .font(.title)
                    .fontWeight(.bold)

                Text("This appears to be your first time. Let's set up your notes storage on the Willow network.")
                    .font(.body)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)

                if !statusMessage.isEmpty {
                    Text(statusMessage)
                        .font(.subheadline)
                        .foregroundColor(.green)
                        .padding()
                        .background(Color.green.opacity(0.1))
                        .cornerRadius(8)
                }

                if let error = appState.error {
                    Text(error)
                        .font(.caption)
                        .foregroundColor(.red)
                        .padding()
                }

                VStack(alignment: .leading, spacing: 10) {
                    Text("What happens during setup:")
                        .font(.headline)

                    SetupStepRow(number: 1, text: "Register your app on the Willow network")
                    SetupStepRow(number: 2, text: "Create a secure, indexed collection for your notes")
                    SetupStepRow(number: 3, text: "Set up cryptographic proofs for data verification")
                }
                .padding()
                .background(Color(.systemGray6))
                .cornerRadius(12)
                .padding(.horizontal)

                HStack(spacing: 15) {
                    Button("Set Up Notes Storage") {
                        setup()
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(isLoading)

                    Button("Logout") {
                        appState.logout()
                    }
                    .buttonStyle(.bordered)
                }

                Spacer()
            }
            .padding()
            .navigationBarHidden(true)
        }
    }

    private func setup() {
        isLoading = true
        statusMessage = "Registering application..."

        Task {
            do {
                try await appState.setupApp()
                statusMessage = "Setup complete!"
            } catch {
                appState.error = error.localizedDescription
            }
            isLoading = false
        }
    }
}

struct SetupStepRow: View {
    let number: Int
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Text("\(number).")
                .fontWeight(.bold)
                .foregroundColor(.blue)
            Text(text)
                .foregroundColor(.secondary)
        }
    }
}

// MARK: - Main View

struct MainView: View {
    @EnvironmentObject var appState: AppState
    @State private var viewModel: NotesViewModel?
    @State private var showingNewNote = false
    @State private var selectedNote: Note?
    @State private var showingNoteDetail = false

    var body: some View {
        NavigationView {
            if let viewModel = viewModel {
                mainContent(viewModel: viewModel)
            } else {
                ProgressView("Initializing...")
                    .task {
                        viewModel = NotesViewModel(appState: appState)
                    }
            }
        }
    }

    @ViewBuilder
    private func mainContent(viewModel: NotesViewModel) -> some View {
        VStack(spacing: 0) {
            // Status bar
            StatusBar(
                balance: appState.balance,
                appBalance: appState.appBalance,
                notesCount: viewModel.notesCount
            )

            // Search and filter
            SearchFilterBar(viewModel: viewModel)

            // Notes list
            if viewModel.isLoading && viewModel.notes.isEmpty {
                Spacer()
                ProgressView("Loading notes...")
                Spacer()
            } else if viewModel.filteredNotes.isEmpty {
                Spacer()
                EmptyStateView(hasFilter: !viewModel.filter.isEmpty)
                Spacer()
            } else {
                NotesList(
                    notes: viewModel.filteredNotes,
                    onSelect: { note in
                        selectedNote = note
                        showingNoteDetail = true
                    },
                    onTogglePin: { note in
                        Task { await viewModel.togglePin(note) }
                    },
                    onDelete: { note in
                        Task { _ = await viewModel.deleteNote(note) }
                    }
                )
            }

            if let error = viewModel.error {
                Text(error)
                    .font(.caption)
                    .foregroundColor(.red)
                    .padding()
            }
        }
        .navigationTitle("Willow Notes")
        .toolbar {
            ToolbarItem(placement: .navigationBarLeading) {
                Button("Logout") {
                    appState.logout()
                }
            }
            ToolbarItem(placement: .navigationBarTrailing) {
                Button(action: { showingNewNote = true }) {
                    Image(systemName: "plus")
                }
            }
        }
        .sheet(isPresented: $showingNewNote) {
            NoteEditorView(viewModel: viewModel, note: nil)
        }
        .sheet(isPresented: $showingNoteDetail) {
            if let note = selectedNote {
                NoteDetailView(viewModel: viewModel, note: note)
            }
        }
        .refreshable {
            await viewModel.refresh()
        }
        .task {
            await viewModel.loadNotes()
        }
    }
}

// MARK: - Status Bar

struct StatusBar: View {
    let balance: Double
    let appBalance: Double
    let notesCount: Int

    var body: some View {
        HStack {
            Label("\(Int(balance)) WILL", systemImage: "wallet.pass")
            Spacer()
            Label("\(Int(appBalance)) App", systemImage: "app.badge")
            Spacer()
            Label("\(notesCount) Notes", systemImage: "note.text")
        }
        .font(.caption)
        .foregroundColor(.secondary)
        .padding(.horizontal)
        .padding(.vertical, 8)
        .background(Color(.systemGray6))
    }
}

// MARK: - Search Filter Bar

struct SearchFilterBar: View {
    @ObservedObject var viewModel: NotesViewModel
    @State private var searchText = ""

    var body: some View {
        VStack(spacing: 10) {
            // Search
            HStack {
                Image(systemName: "magnifyingglass")
                    .foregroundColor(.secondary)
                TextField("Search notes...", text: $searchText)
                    .onChange(of: searchText) { newValue in
                        viewModel.setSearchText(newValue)
                    }
                if !searchText.isEmpty {
                    Button(action: {
                        searchText = ""
                        viewModel.setSearchText("")
                    }) {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundColor(.secondary)
                    }
                }
            }
            .padding(10)
            .background(Color(.systemGray6))
            .cornerRadius(10)
            .padding(.horizontal)

            // Category filter
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    CategoryChip(
                        title: "All",
                        isSelected: viewModel.filter.category == nil,
                        action: { viewModel.setCategory(nil) }
                    )

                    ForEach(NoteCategory.allCases, id: \.self) { category in
                        CategoryChip(
                            title: category.displayName,
                            icon: category.icon,
                            isSelected: viewModel.filter.category == category,
                            action: { viewModel.setCategory(category) }
                        )
                    }
                }
                .padding(.horizontal)
            }
        }
        .padding(.vertical, 10)
    }
}

struct CategoryChip: View {
    let title: String
    var icon: String? = nil
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                if let icon = icon {
                    Image(systemName: icon)
                        .font(.caption)
                }
                Text(title)
                    .font(.subheadline)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(isSelected ? Color.blue : Color(.systemGray5))
            .foregroundColor(isSelected ? .white : .primary)
            .cornerRadius(20)
        }
    }
}

// MARK: - Empty State

struct EmptyStateView: View {
    let hasFilter: Bool

    var body: some View {
        VStack(spacing: 15) {
            Image(systemName: hasFilter ? "magnifyingglass" : "note.text")
                .font(.system(size: 50))
                .foregroundColor(.secondary)

            Text(hasFilter ? "No notes match your search" : "No notes yet")
                .font(.headline)
                .foregroundColor(.secondary)

            Text(hasFilter ? "Try a different search term" : "Tap + to create your first note")
                .font(.subheadline)
                .foregroundColor(.secondary)
        }
    }
}

// MARK: - Notes List

struct NotesList: View {
    let notes: [Note]
    let onSelect: (Note) -> Void
    let onTogglePin: (Note) -> Void
    let onDelete: (Note) -> Void

    var body: some View {
        List {
            ForEach(notes) { note in
                NoteRow(note: note)
                    .contentShape(Rectangle())
                    .onTapGesture { onSelect(note) }
                    .swipeActions(edge: .leading) {
                        Button(action: { onTogglePin(note) }) {
                            Label(note.pinned ? "Unpin" : "Pin", systemImage: "pin")
                        }
                        .tint(.orange)
                    }
                    .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                        Button(role: .destructive, action: { onDelete(note) }) {
                            Label("Delete", systemImage: "trash")
                        }
                    }
            }
        }
        .listStyle(.plain)
    }
}

struct NoteRow: View {
    let note: Note

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                if note.pinned {
                    Image(systemName: "pin.fill")
                        .font(.caption)
                        .foregroundColor(.orange)
                }
                Text(note.title)
                    .font(.headline)
                    .lineLimit(1)
                Spacer()
            }

            if !note.content.isEmpty {
                Text(note.content)
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .lineLimit(2)
            }

            HStack {
                Label(note.category.displayName, systemImage: note.category.icon)
                    .font(.caption)
                    .foregroundColor(.secondary)

                Spacer()

                ForEach(note.tags.prefix(2), id: \.self) { tag in
                    Text(tag)
                        .font(.caption2)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.blue.opacity(0.1))
                        .foregroundColor(.blue)
                        .cornerRadius(4)
                }

                if note.tags.count > 2 {
                    Text("+\(note.tags.count - 2)")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
            }
        }
        .padding(.vertical, 4)
    }
}

// MARK: - Note Detail View

struct NoteDetailView: View {
    @Environment(\.dismiss) var dismiss
    @ObservedObject var viewModel: NotesViewModel
    let note: Note
    @State private var showingEditor = false
    @State private var showingDeleteAlert = false

    var body: some View {
        NavigationView {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    // Header
                    HStack {
                        VStack(alignment: .leading, spacing: 5) {
                            Text(note.title)
                                .font(.largeTitle)
                                .fontWeight(.bold)

                            HStack {
                                Label(note.category.displayName, systemImage: note.category.icon)
                                if note.pinned {
                                    Label("Pinned", systemImage: "pin.fill")
                                        .foregroundColor(.orange)
                                }
                            }
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                        }
                        Spacer()
                    }

                    // Tags
                    if !note.tags.isEmpty {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack {
                                ForEach(note.tags, id: \.self) { tag in
                                    Text(tag)
                                        .font(.caption)
                                        .padding(.horizontal, 10)
                                        .padding(.vertical, 5)
                                        .background(Color.blue.opacity(0.1))
                                        .foregroundColor(.blue)
                                        .cornerRadius(15)
                                }
                            }
                        }
                    }

                    Divider()

                    // Content
                    Text(note.content.isEmpty ? "No content" : note.content)
                        .font(.body)
                        .foregroundColor(note.content.isEmpty ? .secondary : .primary)

                    Spacer()

                    // Metadata
                    VStack(alignment: .leading, spacing: 5) {
                        Text("Created: \(note.created.formatted())")
                        Text("Updated: \(note.updated.formatted())")
                        Text("ID: \(note.id)")
                            .font(.caption2)
                    }
                    .font(.caption)
                    .foregroundColor(.secondary)
                }
                .padding()
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Close") { dismiss() }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Menu {
                        Button(action: { showingEditor = true }) {
                            Label("Edit", systemImage: "pencil")
                        }
                        Button(action: {
                            Task { await viewModel.togglePin(note) }
                            dismiss()
                        }) {
                            Label(note.pinned ? "Unpin" : "Pin", systemImage: "pin")
                        }
                        Divider()
                        Button(role: .destructive, action: { showingDeleteAlert = true }) {
                            Label("Delete", systemImage: "trash")
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                }
            }
            .sheet(isPresented: $showingEditor) {
                NoteEditorView(viewModel: viewModel, note: note)
            }
            .alert("Delete Note?", isPresented: $showingDeleteAlert) {
                Button("Cancel", role: .cancel) { }
                Button("Delete", role: .destructive) {
                    Task {
                        _ = await viewModel.deleteNote(note)
                        dismiss()
                    }
                }
            } message: {
                Text("This action cannot be undone.")
            }
        }
    }
}

// MARK: - Note Editor View

struct NoteEditorView: View {
    @Environment(\.dismiss) var dismiss
    @ObservedObject var viewModel: NotesViewModel
    let note: Note?

    @State private var editorState: NoteEditorState
    @State private var isSaving = false

    init(viewModel: NotesViewModel, note: Note?) {
        self.viewModel = viewModel
        self.note = note
        _editorState = State(initialValue: NoteEditorState(note: note))
    }

    var body: some View {
        NavigationView {
            Form {
                Section("Title") {
                    TextField("Note title", text: $editorState.title)
                }

                Section("Content") {
                    TextEditor(text: $editorState.content)
                        .frame(minHeight: 200)
                }

                Section("Category") {
                    Picker("Category", selection: $editorState.category) {
                        ForEach(NoteCategory.allCases, id: \.self) { category in
                            Label(category.displayName, systemImage: category.icon)
                                .tag(category)
                        }
                    }
                    .pickerStyle(.menu)
                }

                Section("Tags") {
                    TextField("Tags (comma-separated)", text: $editorState.tagsText)
                        .autocapitalization(.none)
                }
            }
            .navigationTitle(editorState.isNew ? "New Note" : "Edit Note")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button(action: save) {
                        if isSaving {
                            ProgressView()
                        } else {
                            Text("Save")
                        }
                    }
                    .disabled(!editorState.isValid || isSaving)
                }
            }
        }
    }

    private func save() {
        isSaving = true
        let noteToSave = editorState.toNote()

        Task {
            let success: Bool
            if editorState.isNew {
                success = await viewModel.createNote(noteToSave)
            } else {
                success = await viewModel.updateNote(noteToSave)
            }

            if success {
                dismiss()
            }
            isSaving = false
        }
    }
}

// MARK: - Preview Providers

#if DEBUG
struct LoginView_Previews: PreviewProvider {
    static var previews: some View {
        LoginView()
            .environmentObject(AppState())
    }
}

struct SetupView_Previews: PreviewProvider {
    static var previews: some View {
        SetupView()
            .environmentObject(AppState())
    }
}
#endif
