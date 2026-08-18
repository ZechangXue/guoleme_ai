import SwiftUI
import UniformTypeIdentifiers

struct ContextView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var context: ContextStore
    @State private var importerType: ContextDocType = .resume
    @State private var showImporter = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text(model.t(.libraryHelp))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } header: {
                    Text(model.t(.libraryHelpTitle))
                }
                Section {
                    TextField(model.t(.pasteResume), text: $context.pasteResume, axis: .vertical)
                        .lineLimit(4...10)
                    TextField(model.t(.pasteJD), text: $context.pasteJD, axis: .vertical)
                        .lineLimit(4...10)
                    TextField(model.t(.pasteNotes), text: $context.pasteNotes, axis: .vertical)
                        .lineLimit(3...8)
                    Button(model.t(.savePaste)) {
                        context.savePasteFields()
                    }
                } header: {
                    Text(model.t(.pasteSection))
                }
                Section {
                    Picker(model.t(.typeLabel), selection: $importerType) {
                        ForEach(ContextDocType.allCases) { type in
                            Text(type.displayName(for: model.settings.uiLanguage)).tag(type)
                        }
                    }
                    Button(model.t(.pickFile)) { showImporter = true }
                } header: {
                    Text(model.t(.importSection))
                }
                Section {
                    if context.files.isEmpty {
                        Text(model.t(.libraryEmpty)).foregroundStyle(.secondary)
                    } else {
                        ForEach(context.files) { file in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(file.fileName)
                                Text("\(file.docType.displayName(for: model.settings.uiLanguage)) · \(model.t(.charsUnit, file.rawText.count))")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .onDelete { indexSet in
                            for i in indexSet {
                                context.remove(id: context.files[i].id)
                            }
                        }
                    }
                    if !context.files.isEmpty {
                        Button(model.t(.clearLibrary), role: .destructive) {
                            context.clear()
                        }
                    }
                } header: {
                    Text(model.t(.libraryCount, context.files.count))
                }
            }
            .scrollContentBackground(.hidden)
            .background(AppTheme.bg)
            .navigationTitle(model.t(.libraryTitle))
            .fileImporter(isPresented: $showImporter, allowedContentTypes: DocumentImporter.allowedTypes) { result in
                switch result {
                case .success(let url):
                    importFile(url)
                case .failure(let error):
                    model.statusMessage = error.localizedDescription
                }
            }
        }
    }

    private func importFile(_ url: URL) {
        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }
        do {
            let text = try DocumentImporter.text(from: url)
            model.contextStore.addFile(name: url.lastPathComponent, docType: importerType, text: text)
        } catch {
            model.statusMessage = error.localizedDescription
        }
    }
}
