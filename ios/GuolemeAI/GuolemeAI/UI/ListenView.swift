import PhotosUI
import SwiftUI

struct ListenView: View {
    @EnvironmentObject private var model: AppModel
    @State private var photoItem: PhotosPickerItem?
    @State private var showCamera = false
    @State private var cameraImage: UIImage?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                if let message = model.statusMessage {
                    Text(message)
                        .font(.footnote)
                        .foregroundStyle(.orange)
                }
                if model.settings.translateMode {
                    TranslateView()
                } else if let assist = model.currentAssist {
                    AssistCardView(
                        assist: assist,
                        streaming: model.streaming,
                        meetingMode: model.settings.meetingMode,
                        displayAsReadable: model.displayAsReadable,
                        readableLoading: model.readableLoading,
                        onClose: { model.closeCurrentCard() },
                        onReadable: { Task { await model.getReadableAnswer() } }
                    )
                } else {
                    emptyState
                }
            }
            .padding(16)
        }
        .background(AppTheme.bg.ignoresSafeArea())
        .onChange(of: photoItem) { _, item in
            guard let item else { return }
            Task {
                defer { photoItem = nil }
                if let data = try? await item.loadTransferable(type: Data.self),
                   let image = UIImage(data: data) {
                    await model.answerFromImage(image)
                } else {
                    model.statusMessage = "无法读取相册图片，请换一张再试"
                }
            }
        }
        .fullScreenCover(isPresented: $showCamera) {
            CameraPicker(image: $cameraImage)
                .ignoresSafeArea()
        }
        .onChange(of: cameraImage) { _, image in
            if let image {
                Task { await model.answerFromImage(image) }
                cameraImage = nil
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("过了么AI")
                        .font(.title2.weight(.bold))
                    Text(model.modeLabel)
                        .font(.caption)
                        .foregroundStyle(AppTheme.muted)
                    Text(model.contextStore.promptStatusLine)
                        .font(.caption2)
                        .foregroundStyle(AppTheme.success.opacity(0.9))
                }
                Spacer()
                AudioLevelView(level: model.audioLevel)
            }
            Button {
                model.toggleListening()
            } label: {
                HStack {
                    Circle()
                        .fill(model.listening ? AppTheme.success : AppTheme.muted)
                        .frame(width: 8, height: 8)
                    Text(model.listening ? "暂停监听" : "开始监听")
                        .fontWeight(.semibold)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
            }
            .buttonStyle(.borderedProminent)
            .tint(model.listening ? AppTheme.success : AppTheme.accent)
            .disabled(!model.hasApiKey && !model.settings.translateMode)

            HStack(spacing: 10) {
                PhotosPicker(selection: $photoItem, matching: .images) {
                    Label(model.imageBusy ? "识图中…" : "相册看题", systemImage: "photo")
                }
                .buttonStyle(.bordered)
                .disabled(model.imageBusy)
                Button {
                    showCamera = true
                } label: {
                    Label(model.imageBusy ? "识图中…" : "拍摄屏幕", systemImage: "camera")
                }
                .buttonStyle(.bordered)
                .disabled(model.imageBusy)
            }
            .font(.footnote)
        }
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(model.settings.meetingMode ? "会议模式：等待捕捉提问…" : "等待捕捉下一条「对方提问」…")
                .font(.headline)
            Text("把 iPhone 靠近电脑扬声器，开始监听后会在本机显示提词。不要覆盖其他 App，也不采集系统内部音频。")
                .font(.footnote)
                .foregroundStyle(AppTheme.muted)
            Text(model.contextStore.promptStatusLine)
                .font(.footnote)
                .foregroundStyle(AppTheme.success)
            VStack(alignment: .leading, spacing: 6) {
                Label("手机麦克风对准电脑外放", systemImage: "iphone.and.arrow.forward")
                Label("外放音量开大，减少环境噪音", systemImage: "speaker.wave.2")
                Label("锁屏后仍可继续听（通知栏会显示监听中）", systemImage: "moon.stars")
            }
            .font(.footnote)
            .foregroundStyle(AppTheme.muted)
            .padding(.top, 6)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AppTheme.elevated)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
    }
}

struct CameraPicker: UIViewControllerRepresentable {
    @Binding var image: UIImage?
    @Environment(\.dismiss) private var dismiss

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = UIImagePickerController.isSourceTypeAvailable(.camera) ? .camera : .photoLibrary
        picker.allowsEditing = false
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let parent: CameraPicker
        init(_ parent: CameraPicker) { self.parent = parent }
        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            parent.dismiss()
        }
        func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            parent.image = (info[.editedImage] as? UIImage) ?? (info[.originalImage] as? UIImage)
            parent.dismiss()
        }
    }
}
