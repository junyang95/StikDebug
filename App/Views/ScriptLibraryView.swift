import SwiftUI
import UniformTypeIdentifiers

struct ScriptLibraryView: View {
    @ObservedObject var library: ScriptLibrary
    @State private var searchText = ""
    @State private var showImporter = false
    @State private var showCreate = false
    @State private var newName = ""
    @State private var editingScript: LauncherScript?
    @State private var deletingScript: LauncherScript?
    @State private var operationError: String?

    private var matchingScripts: [LauncherScript] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        return library.items.filter { query.isEmpty || $0.name.localizedStandardContains(query) }
    }

    var body: some View {
        List {
            Section {
                Picker(selection: Binding(get: { library.defaultScriptID }, set: { library.setDefault($0) })) {
                    ForEach(library.items) { script in Text(script.name).tag(script.id) }
                } label: {
                    Text("scripts.default", tableName: "Library")
                }
            } footer: {
                Text("scripts.default_hint", tableName: "Library")
            }

            if let error = library.errorMessage {
                Section {
                    LauncherMessage(message: error, isError: true)
                    Button { library.reload() } label: { Text("library.retry", tableName: "Library") }
                }
            }

            if matchingScripts.isEmpty {
                Section {
                    Text("scripts.no_results", tableName: "Library")
                        .foregroundStyle(.secondary)
                }
            } else {
                Section {
                    ForEach(matchingScripts.filter(\.isBundled)) { script in
                        scriptRow(script)
                    }
                } header: {
                    Text("scripts.bundled", tableName: "Library")
                } footer: {
                    Text("scripts.bundled_hint", tableName: "Library")
                }
                Section {
                    let custom = matchingScripts.filter { !$0.isBundled }
                    if custom.isEmpty && searchText.isEmpty {
                        Text("scripts.custom_empty", tableName: "Library")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    ForEach(custom) { script in
                        scriptRow(script)
                            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                Button(role: .destructive) { deletingScript = script } label: {
                                    Text("library.delete", tableName: "Library")
                                }
                            }
                    }
                } header: {
                    Text("scripts.custom", tableName: "Library")
                } footer: {
                    Text("scripts.custom_hint", tableName: "Library")
                }
            }
        }
        .navigationTitle(Text("scripts.title", tableName: "Library"))
        .searchable(text: $searchText, prompt: Text("scripts.search", tableName: "Library"))
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button { newName = ""; showCreate = true } label: {
                    Label { Text("scripts.new", tableName: "Library") } icon: { Image(systemName: "doc.badge.plus") }
                }
                Button { showImporter = true } label: {
                    Label { Text("scripts.import", tableName: "Library") } icon: { Image(systemName: "square.and.arrow.down") }
                }
            }
        }
        .sheet(item: $editingScript) { script in
            ScriptEditorSheet(library: library, script: script)
        }
        .alert(Text("scripts.new", tableName: "Library"), isPresented: $showCreate) {
            TextField(String(localized: "scripts.filename", table: "Library"), text: $newName)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            Button {
                do { editingScript = try library.create(name: newName) }
                catch { operationError = error.localizedDescription }
            } label: { Text("library.create", tableName: "Library") }
            Button(role: .cancel) {} label: { Text("library.cancel", tableName: "Library") }
        }
        .confirmationDialog(Text("scripts.delete_title", tableName: "Library"), isPresented: Binding(
            get: { deletingScript != nil }, set: { if !$0 { deletingScript = nil } }
        ), titleVisibility: .visible) {
            Button(role: .destructive) {
                guard let script = deletingScript else { return }
                do { try library.delete(script) }
                catch { operationError = error.localizedDescription }
                deletingScript = nil
            } label: { Text("library.delete", tableName: "Library") }
            Button(role: .cancel) { deletingScript = nil } label: { Text("library.cancel", tableName: "Library") }
        } message: {
            Text("scripts.delete_message \(deletingScript?.name ?? "")", tableName: "Library")
        }
        .fileImporter(isPresented: $showImporter, allowedContentTypes: [UTType(filenameExtension: "js") ?? .sourceCode]) { result in
            do { editingScript = try library.importScript(from: result.get()) }
            catch { operationError = error.localizedDescription }
        }
        .alert(Text("library.failed", tableName: "Library"), isPresented: Binding(
            get: { operationError != nil }, set: { if !$0 { operationError = nil } }
        )) {
            Button { operationError = nil } label: { Text("library.ok", tableName: "Library") }
        } message: { Text(operationError ?? "") }
    }

    private func scriptRow(_ script: LauncherScript) -> some View {
        Button { editingScript = script } label: {
            HStack(spacing: 12) {
                Image(systemName: script.isBundled ? "doc.text" : "doc.badge.gearshape")
                    .foregroundStyle(Color.accentColor)
                VStack(alignment: .leading, spacing: 4) {
                    Text(script.name).foregroundStyle(.primary)
                    if library.defaultScriptID == script.id {
                        Text("scripts.default_badge", tableName: "Library")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 8)
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityHint(Text(script.isBundled ? "scripts.view_hint" : "scripts.edit_hint", tableName: "Library"))
    }
}

private struct ScriptEditorSheet: View {
    @ObservedObject var library: ScriptLibrary
    let script: LauncherScript
    @Environment(\.dismiss) private var dismiss
    @State private var source = ""
    @State private var savedSource = ""
    @State private var hasLoaded = false
    @State private var operationError: String?
    @State private var showDiscard = false

    private var isDirty: Bool { hasLoaded && !script.isBundled && source != savedSource }

    var body: some View {
        NavigationStack {
            Group {
                if script.isBundled {
                    ScrollView([.vertical, .horizontal]) {
                        Text(verbatim: source)
                            .font(.system(.footnote, design: .monospaced))
                            .textSelection(.enabled)
                            .padding()
                            .frame(maxWidth: .infinity, alignment: .topLeading)
                    }
                } else {
                    TextEditor(text: $source)
                        .font(.system(.footnote, design: .monospaced))
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .padding(.horizontal, 8)
                        .disabled(!hasLoaded)
                        .accessibilityLabel(Text("scripts.editor", tableName: "Library"))
                }
            }
            .safeAreaInset(edge: .bottom) {
                Text(script.isBundled ? "scripts.read_only_hint" : "scripts.editor_hint", tableName: "Library")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
                    .background(.regularMaterial)
            }
            .navigationTitle(script.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button {
                        if isDirty { showDiscard = true } else { dismiss() }
                    } label: {
                        Text(script.isBundled ? "library.done" : "library.cancel", tableName: "Library")
                    }
                }
                if !script.isBundled {
                    ToolbarItem(placement: .confirmationAction) {
                        Button {
                            do {
                                try library.save(script, content: source)
                                savedSource = source
                                dismiss()
                            } catch { operationError = error.localizedDescription }
                        } label: { Text("library.save", tableName: "Library") }
                        .disabled(!isDirty)
                    }
                }
            }
            .task {
                guard !hasLoaded else { return }
                do {
                    source = try library.content(of: script)
                    savedSource = source
                    hasLoaded = true
                } catch { operationError = error.localizedDescription }
            }
            .alert(Text("library.failed", tableName: "Library"), isPresented: Binding(
                get: { operationError != nil }, set: { if !$0 { operationError = nil } }
            )) {
                Button { operationError = nil } label: { Text("library.ok", tableName: "Library") }
            } message: { Text(operationError ?? "") }
            .confirmationDialog(Text("scripts.discard_title", tableName: "Library"), isPresented: $showDiscard, titleVisibility: .visible) {
                Button(role: .destructive) { dismiss() } label: { Text("scripts.discard", tableName: "Library") }
                Button(role: .cancel) {} label: { Text("scripts.keep_editing", tableName: "Library") }
            }
        }
        .interactiveDismissDisabled(isDirty)
    }
}
