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
                Section("使用说明") {
                    Text("面试模式会用简历 / JD / 笔记来针对性作答。组会模式优先用「会议 / 项目文档」；如果还没传项目文档，会回退使用已入库的简历和笔记，避免空泛回答。资料只存在本机。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                Section("纯文本粘贴") {
                    TextField("简历 / CV", text: $context.pasteResume, axis: .vertical)
                        .lineLimit(4...10)
                    TextField("职位描述 / JD", text: $context.pasteJD, axis: .vertical)
                        .lineLimit(4...10)
                    TextField("笔记", text: $context.pasteNotes, axis: .vertical)
                        .lineLimit(3...8)
                    Button("保存粘贴内容到资料库") {
                        context.savePasteFields()
                    }
                }
                Section("导入文件（PDF / TXT / DOCX）") {
                    Picker("类型", selection: $importerType) {
                        ForEach(ContextDocType.allCases) { type in
                            Text(type.displayName).tag(type)
                        }
                    }
                    Button("从文件 App 选择") { showImporter = true }
                }
                Section("已入库 (\(context.files.count))") {
                    if context.files.isEmpty {
                        Text("还没有文档").foregroundStyle(.secondary)
                    } else {
                        ForEach(context.files) { file in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(file.fileName)
                                Text("\(file.docType.displayName) · \(file.rawText.count) 字")
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
                        Button("清空资料库", role: .destructive) {
                            context.clear()
                        }
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(AppTheme.bg)
            .navigationTitle("资料库")
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
