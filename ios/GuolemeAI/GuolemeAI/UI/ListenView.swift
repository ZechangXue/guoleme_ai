import PhotosUI
import SwiftUI

struct ListenView: View {
    @EnvironmentObject private var model: AppModel
    @State private var photoItem: PhotosPickerItem?
    @State private var showCamera = false
    @State private var cameraImage: UIImage?
    @State private var showMeetingPrep = false
    @State private var showQuickEn = false

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
                    MeetingLiveSection(meeting: model.meeting, profile: model.meetingProfile, showPrep: $showMeetingPrep, showQuickEn: $showQuickEn)
                    TranslateView()
                    MeetingTranscriptView(meeting: model.meeting)
                } else if model.settings.meetingMode {
                    MeetingLiveSection(meeting: model.meeting, profile: model.meetingProfile, showPrep: $showMeetingPrep, showQuickEn: $showQuickEn)
                    MeetingTranscriptView(meeting: model.meeting)
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
                    model.statusMessage = model.t(.albumFail)
                }
            }
        }
        .sheet(isPresented: $showMeetingPrep) {
            MeetingPrepSheet(meeting: model.meeting, profile: model.meetingProfile)
                .environmentObject(model)
        }
        .sheet(isPresented: $showQuickEn) {
            QuickEnSheet(meeting: model.meeting)
                .environmentObject(model)
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
                    Text(model.t(.appName))
                        .font(.title2.weight(.bold))
                    Text(model.modeLabel)
                        .font(.caption)
                        .foregroundStyle(AppTheme.muted)
                    Text(model.contextStore.promptStatusLine(language: model.settings.uiLanguage))
                        .font(.caption2)
                        .foregroundStyle(AppTheme.success.opacity(0.9))
                }
                Spacer()
                AudioLevelView(level: model.audioLevel, label: model.t(.audioLevel))
            }
            Button {
                model.toggleListening()
            } label: {
                HStack {
                    Circle()
                        .fill(model.listening ? AppTheme.success : AppTheme.muted)
                        .frame(width: 8, height: 8)
                    Text(model.listening ? model.t(.pauseListening) : model.t(.startListening))
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
                    Label(model.imageBusy ? model.t(.recognizing) : model.t(.albumQA), systemImage: "photo")
                }
                .buttonStyle(.bordered)
                .disabled(model.imageBusy)
                Button {
                    showCamera = true
                } label: {
                    Label(model.imageBusy ? model.t(.recognizing) : model.t(.captureScreen), systemImage: "camera")
                }
                .buttonStyle(.bordered)
                .disabled(model.imageBusy)
            }
            .font(.footnote)
        }
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(model.settings.meetingMode ? model.t(.waitMeetingQuestion) : model.t(.waitQuestion))
                .font(.headline)
            Text(model.t(.emptyHint))
                .font(.footnote)
                .foregroundStyle(AppTheme.muted)
            Text(model.contextStore.promptStatusLine(language: model.settings.uiLanguage))
                .font(.footnote)
                .foregroundStyle(AppTheme.success)
            VStack(alignment: .leading, spacing: 6) {
                Label(model.t(.tipMic), systemImage: "iphone.and.arrow.forward")
                Label(model.t(.tipVolume), systemImage: "speaker.wave.2")
                Label(model.t(.tipLock), systemImage: "moon.stars")
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
