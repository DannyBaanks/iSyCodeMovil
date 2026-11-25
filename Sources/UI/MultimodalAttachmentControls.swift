import SwiftUI
#if canImport(PhotosUI)
import PhotosUI
#endif
#if canImport(UniformTypeIdentifiers)
import UniformTypeIdentifiers
#endif
#if canImport(AVFoundation)
import AVFoundation
#endif
#if canImport(UIKit)
import UIKit
#endif

// MARK: - Reusable Native Media / File Coordinator attached via ViewModifier

@MainActor
public final class MultimodalComposerCoordinator: ObservableObject {
    @Published public var showPhotosPicker = false
    @Published public var showVideoPicker = false
    @Published public var showFileImporter = false
    @Published public var showAudioImporter = false
    @Published public var showCameraSheet = false
    @Published public var showWorkspaceSheet = false
    @Published public var showCameraPermissionAlert = false
    @Published public var cameraPermissionMessage = ""
    @Published public var isPreparingMedia = false
    @Published public var statusError: String?
    @Published public var inspectingAttachment: Attachment?

    public init() {}

    public func openCamera() {
        #if canImport(UIKit) && canImport(AVFoundation)
        guard UIImagePickerController.isSourceTypeAvailable(.camera) else {
            cameraPermissionMessage = "Este dispositivo o simulador no cuenta con cámara disponible. Puedes elegir una fotografía desde Fototeca o Archivos."
            showCameraPermissionAlert = true
            return
        }
        let status = AVCaptureDevice.authorizationStatus(for: .video)
        switch status {
        case .authorized:
            showCameraSheet = true
        case .notDetermined:
            Task {
                let granted = await AVCaptureDevice.requestAccess(for: .video)
                await MainActor.run {
                    if granted {
                        self.showCameraSheet = true
                    } else {
                        self.cameraPermissionMessage = "Permiso de cámara denegado. Puedes activarlo en Ajustes → ISyCode Móvil."
                        self.showCameraPermissionAlert = true
                    }
                }
            }
        case .denied, .restricted:
            cameraPermissionMessage = "El permiso de cámara está desactivado en Ajustes de iOS. Actívalo para tomar fotografías directamente desde iSyCode."
            showCameraPermissionAlert = true
        @unknown default:
            cameraPermissionMessage = "No se pudo verificar el permiso de la cámara."
            showCameraPermissionAlert = true
        }
        #else
        cameraPermissionMessage = "La cámara nativa solo está disponible en iOS."
        showCameraPermissionAlert = true
        #endif
    }

    #if canImport(PhotosUI) && canImport(UIKit)
    public func handlePHPickerResults(_ results: [PHPickerResult], isVideo: Bool, into attachments: Binding<[Attachment]>) {
        guard !results.isEmpty else { return }
        let remaining = max(0, ChatAttachmentManager.maxAttachmentsPerMessage - attachments.wrappedValue.count)
        guard remaining > 0 else {
            statusError = "Límite de \(ChatAttachmentManager.maxAttachmentsPerMessage) adjuntos por mensaje alcanzado."
            return
        }
        let slice = Array(results.prefix(remaining))
        isPreparingMedia = true
        statusError = nil

        var placeholders: [(id: String, provider: NSItemProvider, index: Int)] = []
        for (index, result) in slice.enumerated() {
            let placeholderID = UUID().uuidString
            let placeholder = Attachment(
                id: placeholderID,
                type: isVideo ? .video : .image,
                source: .photosLibrary,
                state: .preparing,
                name: isVideo ? "Video \(index + 1)…" : "Foto \(index + 1)…",
                icon: isVideo ? "video" : "photo"
            )
            attachments.wrappedValue.append(placeholder)
            placeholders.append((id: placeholderID, provider: result.itemProvider, index: index))
        }

        Task {
            for entry in placeholders {
                let copyResult = await Self.copyProviderFile(provider: entry.provider, isVideo: isVideo, index: entry.index)
                let built: Attachment
                switch copyResult {
                case .success(let info):
                    defer { try? FileManager.default.removeItem(at: info.tempURL) }
                    if isVideo {
                        built = await ChatAttachmentManager.shared.importPhotosVideoFile(from: info.tempURL, suggestedFilename: info.name)
                    } else if let data = try? Data(contentsOf: info.tempURL) {
                        built = await ChatAttachmentManager.shared.importPhotosImageData(
                            data,
                            suggestedFilename: info.name,
                            fileExtension: info.ext,
                            source: .photosLibrary
                        )
                    } else {
                        built = Attachment(
                            id: entry.id,
                            type: .image,
                            source: .photosLibrary,
                            state: .failed("No se pudo leer la imagen seleccionada."),
                            name: info.name,
                            icon: "photo"
                        )
                    }
                case .failure(let err):
                    built = Attachment(
                        id: entry.id,
                        type: isVideo ? .video : .image,
                        source: .photosLibrary,
                        state: .failed(err.localizedDescription),
                        name: isVideo ? "Video \(entry.index + 1)" : "Foto \(entry.index + 1)",
                        icon: isVideo ? "video" : "photo"
                    )
                }

                let finalAttachment = Attachment(
                    id: entry.id,
                    type: built.type,
                    source: built.source,
                    state: built.state,
                    name: built.name,
                    path: built.path,
                    icon: built.icon,
                    mimeType: built.mimeType,
                    utTypeIdentifier: built.utTypeIdentifier,
                    byteCount: built.byteCount,
                    pixelWidth: built.pixelWidth,
                    pixelHeight: built.pixelHeight,
                    extractedText: built.extractedText,
                    warningMessage: built.warningMessage
                )
                if let idx = attachments.wrappedValue.firstIndex(where: { $0.id == entry.id }) {
                    attachments.wrappedValue[idx] = finalAttachment
                }
            }
            isPreparingMedia = false
            OCHaptics.light()
        }
    }

    private nonisolated static func copyProviderFile(
        provider: NSItemProvider,
        isVideo: Bool,
        index: Int
    ) async -> Result<(tempURL: URL, ext: String, name: String), Error> {
        let preferredUTType: UTType = isVideo ? .movie : .image
        let typeIdentifier = provider.registeredTypeIdentifiers.first(where: {
            UTType($0)?.conforms(to: preferredUTType) == true
        }) ?? preferredUTType.identifier

        return await withCheckedContinuation { continuation in
            provider.loadFileRepresentation(forTypeIdentifier: typeIdentifier) { url, error in
                if let error {
                    continuation.resume(returning: .failure(error))
                    return
                }
                guard let url else {
                    continuation.resume(returning: .failure(NSError(
                        domain: "MultimodalPicker",
                        code: 1,
                        userInfo: [NSLocalizedDescriptionKey: "El selector no entregó la URL del archivo."]
                    )))
                    return
                }
                let ext = url.pathExtension.isEmpty ? (isVideo ? "mp4" : "jpg") : url.pathExtension
                let tempCopy = FileManager.default.temporaryDirectory
                    .appendingPathComponent("phpick-\(UUID().uuidString).\(ext)")
                let suggestedName = url.lastPathComponent.isEmpty ? "media-\(index + 1).\(ext)" : url.lastPathComponent
                do {
                    if FileManager.default.fileExists(atPath: tempCopy.path) {
                        try FileManager.default.removeItem(at: tempCopy)
                    }
                    try FileManager.default.copyItem(at: url, to: tempCopy)
                    continuation.resume(returning: .success((tempCopy, ext, suggestedName)))
                } catch {
                    continuation.resume(returning: .failure(error))
                }
            }
        }
    }
    #endif

    public func handleFileImporterResult(_ result: Result<[URL], Error>, into attachments: Binding<[Attachment]>) {
        switch result {
        case .failure(let error):
            statusError = "No se pudieron importar los archivos: \(error.localizedDescription)"
        case .success(let urls):
            guard !urls.isEmpty else { return }
            let remaining = max(0, ChatAttachmentManager.maxAttachmentsPerMessage - attachments.wrappedValue.count)
            guard remaining > 0 else {
                statusError = "Límite de \(ChatAttachmentManager.maxAttachmentsPerMessage) adjuntos por mensaje alcanzado."
                return
            }
            isPreparingMedia = true
            statusError = nil
            Task {
                for url in urls.prefix(remaining) {
                    let built = await ChatAttachmentManager.shared.importFromFileURL(url)
                    attachments.wrappedValue.append(built)
                }
                isPreparingMedia = false
                OCHaptics.light()
            }
        }
    }
}

// MARK: - iOS 16+ PHPicker Representable (no full photo library permission needed)

#if canImport(PhotosUI) && canImport(UIKit)
private struct PHPickerSheetRepresentable: UIViewControllerRepresentable {
    let filter: PHPickerFilter
    let selectionLimit: Int
    let onFinish: ([PHPickerResult]) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onFinish: onFinish)
    }

    func makeUIViewController(context: Context) -> PHPickerViewController {
        var config = PHPickerConfiguration()
        config.filter = filter
        config.selectionLimit = max(1, selectionLimit)
        config.preferredAssetRepresentationMode = .current
        let picker = PHPickerViewController(configuration: config)
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: PHPickerViewController, context: Context) {}

    final class Coordinator: NSObject, PHPickerViewControllerDelegate {
        let onFinish: ([PHPickerResult]) -> Void

        init(onFinish: @escaping ([PHPickerResult]) -> Void) {
            self.onFinish = onFinish
        }

        func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
            onFinish(results)
        }
    }
}
#endif

// MARK: - Unified "+" Native Attachment Button

public struct ComposerPlusMenuButton: View {
    @ObservedObject var coordinator: MultimodalComposerCoordinator
    var includesWorkspaceFiles: Bool = true
    var includesLearnActions: Bool = true

    public init(
        coordinator: MultimodalComposerCoordinator,
        includesWorkspaceFiles: Bool = true,
        includesLearnActions: Bool = true
    ) {
        self.coordinator = coordinator
        self.includesWorkspaceFiles = includesWorkspaceFiles
        self.includesLearnActions = includesLearnActions
    }

    public var body: some View {
        Menu {
            Section("Medios y cámara") {
                Button {
                    OCHaptics.light()
                    coordinator.showPhotosPicker = true
                } label: {
                    Label("Fototeca (fotos)", systemImage: "photo.on.rectangle.angled")
                }

                Button {
                    OCHaptics.light()
                    coordinator.showVideoPicker = true
                } label: {
                    Label("Videos de Fototeca", systemImage: "video")
                }

                Button {
                    OCHaptics.light()
                    coordinator.openCamera()
                } label: {
                    Label("Tomar fotografía (Cámara)", systemImage: "camera")
                }
            }

            Section("Documentos y audio") {
                Button {
                    OCHaptics.light()
                    coordinator.showFileImporter = true
                } label: {
                    Label("Explorar Archivos (PDF, CSV, JSON, MD…)", systemImage: "folder")
                }

                Button {
                    OCHaptics.light()
                    coordinator.showAudioImporter = true
                } label: {
                    Label("Adjuntar audio existente", systemImage: "waveform")
                }

                if includesWorkspaceFiles {
                    Button {
                        OCHaptics.light()
                        coordinator.showWorkspaceSheet = true
                    } label: {
                        Label("Archivos del proyecto / contexto", systemImage: "doc.text.magnifyingglass")
                    }
                }
            }

            if includesLearnActions {
                Section("Automatización y Llavero") {
                    Button {
                        OCHaptics.medium()
                        NotificationCenter.default.post(name: .openLearnActionSheet, object: nil)
                    } label: {
                        Label("Aprender acción (WDA polling)", systemImage: "record.circle")
                    }

                    Button {
                        OCHaptics.light()
                        NotificationCenter.default.post(name: .openSecretVaultSheet, object: nil)
                    } label: {
                        Label("Llavero de contraseñas", systemImage: "key.fill")
                    }
                }
            }
        } label: {
            ZStack {
                Circle()
                    .fill(OCColor.bgLayer1)
                    .frame(width: 36, height: 36)
                    .overlay(Circle().stroke(OCColor.borderMuted, lineWidth: 1))
                Image(systemName: "plus")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(OCColor.iconPrimary)
            }
            .frame(width: 44, height: 44)
            .contentShape(Rectangle())
        }
        .accessibilityLabel("Agregar adjunto, foto, cámara, archivo o acción")
        .accessibilityIdentifier("composer-plus-button")
        .fixedSize(horizontal: true, vertical: false)
    }
}

// MARK: - ViewModifier Wiring Pickers, Camera, Workspace Sheet & Errors

public struct MultimodalComposerAttachmentsModifier: ViewModifier {
    @ObservedObject var coordinator: MultimodalComposerCoordinator
    @Binding var attachments: [Attachment]
    var workspaceSheetContent: (() -> AnyView)?

    public init(
        coordinator: MultimodalComposerCoordinator,
        attachments: Binding<[Attachment]>,
        workspaceSheetContent: (() -> AnyView)? = nil
    ) {
        self.coordinator = coordinator
        self._attachments = attachments
        self.workspaceSheetContent = workspaceSheetContent
    }

    public func body(content: Content) -> some View {
        content
            #if canImport(PhotosUI) && canImport(UIKit)
            .sheet(isPresented: $coordinator.showPhotosPicker) {
                PHPickerSheetRepresentable(
                    filter: .images,
                    selectionLimit: max(1, ChatAttachmentManager.maxAttachmentsPerMessage - attachments.count)
                ) { results in
                    coordinator.showPhotosPicker = false
                    coordinator.handlePHPickerResults(results, isVideo: false, into: $attachments)
                }
            }
            .sheet(isPresented: $coordinator.showVideoPicker) {
                PHPickerSheetRepresentable(
                    filter: .videos,
                    selectionLimit: 2
                ) { results in
                    coordinator.showVideoPicker = false
                    coordinator.handlePHPickerResults(results, isVideo: true, into: $attachments)
                }
            }
            #endif
            .fileImporter(
                isPresented: $coordinator.showFileImporter,
                allowedContentTypes: Self.documentContentTypes,
                allowsMultipleSelection: true
            ) { result in
                coordinator.handleFileImporterResult(result, into: $attachments)
            }
            .fileImporter(
                isPresented: $coordinator.showAudioImporter,
                allowedContentTypes: [.audio],
                allowsMultipleSelection: false
            ) { result in
                coordinator.handleFileImporterResult(result, into: $attachments)
            }
            .fullScreenCover(isPresented: $coordinator.showCameraSheet) {
                CameraCaptureSheet(
                    onCaptured: { image in
                        coordinator.showCameraSheet = false
                        #if canImport(UIKit)
                        coordinator.isPreparingMedia = true
                        Task {
                            let built = await ChatAttachmentManager.shared.importCameraUIImage(image)
                            await MainActor.run {
                                attachments.append(built)
                                coordinator.isPreparingMedia = false
                                OCHaptics.success()
                            }
                        }
                        #endif
                    },
                    onCancel: {
                        coordinator.showCameraSheet = false
                    }
                )
                .ignoresSafeArea()
            }
            .sheet(item: $coordinator.inspectingAttachment) { item in
                AttachmentInspectionModal(attachment: item) {
                    attachments.removeAll { $0.id == item.id }
                    Task { await ChatAttachmentManager.shared.removeStagedFile(for: item) }
                    coordinator.inspectingAttachment = nil
                }
            }
            .sheet(isPresented: $coordinator.showWorkspaceSheet) {
                if let workspaceSheetContent {
                    workspaceSheetContent()
                }
            }
            .alert("Cámara", isPresented: $coordinator.showCameraPermissionAlert) {
                #if canImport(UIKit)
                if let settingsURL = URL(string: UIApplication.openSettingsURLString) {
                    Button("Abrir Ajustes") { UIApplication.shared.open(settingsURL) }
                }
                #endif
                Button("Entendido", role: .cancel) {}
            } message: {
                Text(coordinator.cameraPermissionMessage)
            }
    }

    private static var documentContentTypes: [UTType] {
        var types: [UTType] = [.pdf, .plainText, .json, .commaSeparatedText, .image, .text, .sourceCode]
        if let md = UTType(filenameExtension: "md") {
            types.append(md)
        }
        types.append(.data)
        return types
    }
}

public extension View {
    func multimodalComposerSupport(
        coordinator: MultimodalComposerCoordinator,
        attachments: Binding<[Attachment]>,
        workspaceSheet: (() -> AnyView)? = nil
    ) -> some View {
        modifier(MultimodalComposerAttachmentsModifier(
            coordinator: coordinator,
            attachments: attachments,
            workspaceSheetContent: workspaceSheet
        ))
    }
}

// MARK: - Rich Attachment Preview Bar (Thumbnails + Status + Compatibility)

public struct RichAttachmentsBar: View {
    let attachments: [Attachment]
    let capabilityReport: MultimodalCapabilityReport
    let onInspect: (Attachment) -> Void
    let onRemove: (Attachment) -> Void

    public init(
        attachments: [Attachment],
        capabilityReport: MultimodalCapabilityReport,
        onInspect: @escaping (Attachment) -> Void,
        onRemove: @escaping (Attachment) -> Void
    ) {
        self.attachments = attachments
        self.capabilityReport = capabilityReport
        self.onInspect = onInspect
        self.onRemove = onRemove
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: OCSpacing.sm) {
                    ForEach(attachments) { item in
                        attachmentCard(item)
                    }
                }
                .padding(.vertical, 2)
            }

            if let incompatibilityBanner {
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 11.5))
                        .foregroundColor(OCColor.warning)
                    Text(incompatibilityBanner)
                        .font(.system(size: 11.5))
                        .foregroundColor(OCColor.warning)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(OCColor.warning.opacity(0.10))
                .clipShape(OCRoundedRect(OCRadius.r8))
            }
        }
    }

    private var incompatibilityBanner: String? {
        // A hint, not a block: the photo is sent anyway and the model says if it can't see it.
        if attachments.contains(where: { $0.type == .image }) {
            if !capabilityReport.canCarryImages {
                return "Este motor no recibe imágenes: el modelo te dirá que no puede verla."
            }
            if !capabilityReport.supportsImages {
                return "Puede que este modelo no vea imágenes. Se envía igual; si no puede, te lo dirá."
            }
        }
        if let unsupported = attachments.first(where: {
            if case .unsupported = $0.state { return true }
            return false
        }) {
            return unsupported.warningMessage ?? unsupported.state.badgeLabel
        }
        return nil
    }

    private func attachmentCard(_ item: Attachment) -> some View {
        HStack(spacing: 8) {
            Button {
                onInspect(item)
            } label: {
                HStack(spacing: 8) {
                    thumbnailView(item)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.name)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundColor(OCColor.textPrimary)
                            .lineLimit(1)
                        HStack(spacing: 4) {
                            if let size = item.formattedByteSize {
                                Text(size)
                                    .font(.system(size: 10.5))
                                    .foregroundColor(OCColor.textFaint)
                            }
                            Text(item.state.badgeLabel)
                                .font(.system(size: 10.5, weight: .medium))
                                .foregroundColor(stateColor(item))
                        }
                    }
                }
            }
            .buttonStyle(.plain)

            Button {
                OCHaptics.light()
                onRemove(item)
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 15))
                    .foregroundColor(OCColor.textFaint)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Quitar adjunto \(item.name)")
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(OCColor.bgLayer1)
        .clipShape(OCRoundedRect(OCRadius.r10))
        .overlay(
            OCRoundedRect(OCRadius.r10)
                .stroke(stateColor(item).opacity(0.35), lineWidth: 1)
        )
    }

    @ViewBuilder
    private func thumbnailView(_ item: Attachment) -> some View {
        if case .preparing = item.state {
            ProgressView()
                .frame(width: 34, height: 34)
        } else {
            #if canImport(UIKit)
            if item.type == .image, let path = item.path, let uiImage = UIImage(contentsOfFile: path) {
                Image(uiImage: uiImage)
                    .resizable()
                    .scaledToFill()
                    .frame(width: 34, height: 34)
                    .clipShape(RoundedRectangle(cornerRadius: OCRadius.r8))
            } else {
                fallbackIconBox(item)
            }
            #else
            fallbackIconBox(item)
            #endif
        }
    }

    private func fallbackIconBox(_ item: Attachment) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: OCRadius.r8)
                .fill(OCColor.bgBase)
                .frame(width: 34, height: 34)
            Image(systemName: item.icon)
                .font(.system(size: 15, weight: .semibold))
                .foregroundColor(stateColor(item))
        }
    }

    private func stateColor(_ item: Attachment) -> Color {
        switch item.state {
        case .ready, .sent: return OCColor.success
        case .preparing, .selected, .uploading: return OCColor.info
        case .unsupported: return OCColor.warning
        case .failed, .cancelled: return OCColor.danger
        }
    }
}

// MARK: - Attachment Inspection Sheet

public struct AttachmentInspectionModal: View {
    @Environment(\.dismiss) private var dismiss
    let attachment: Attachment
    let onRemove: () -> Void

    public var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: OCSpacing.lg) {
                    #if canImport(UIKit)
                    if attachment.type == .image, let path = attachment.path, let uiImage = UIImage(contentsOfFile: path) {
                        Image(uiImage: uiImage)
                            .resizable()
                            .scaledToFit()
                            .frame(maxWidth: .infinity)
                            .clipShape(OCRoundedRect(OCRadius.r12))
                    }
                    #endif

                    VStack(alignment: .leading, spacing: 8) {
                        LabeledContent("Nombre", value: attachment.name)
                        LabeledContent("Origen", value: attachment.source.displayName)
                        LabeledContent("Estado", value: attachment.state.badgeLabel)
                        if let mime = attachment.mimeType {
                            LabeledContent("Tipo", value: mime)
                        }
                        if let size = attachment.formattedByteSize {
                            LabeledContent("Tamaño", value: size)
                        }
                        if let w = attachment.pixelWidth, let h = attachment.pixelHeight {
                            LabeledContent("Dimensiones", value: "\(w) × \(h) px")
                        }
                    }
                    .padding(OCSpacing.md)
                    .ocCard(radius: OCRadius.r12)

                    if let warn = attachment.warningMessage {
                        OCUnifiedStateCard(kind: .error, title: "Nota de compatibilidad", message: warn)
                    }

                    if let text = attachment.extractedText, !text.isEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("CONTENIDO EXTRAÍDO PARA EL MODELO")
                                .font(OCTypography.sectionLabel)
                                .foregroundColor(OCColor.textFaint)
                            Text(String(text.prefix(4000)))
                                .font(.system(size: 12, design: .monospaced))
                                .foregroundColor(OCColor.textSecondary)
                                .textSelection(.enabled)
                        }
                        .padding(OCSpacing.md)
                        .ocCard(radius: OCRadius.r12)
                    }

                    Button(role: .destructive) {
                        onRemove()
                        dismiss()
                    } label: {
                        Label("Quitar de este mensaje", systemImage: "trash")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                }
                .padding(OCSpacing.contentMargin)
            }
            .background(OCColor.bgDeep.ignoresSafeArea())
            .navigationTitle("Detalle de adjunto")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Listo") { dismiss() }
                }
            }
        }
    }
}

// MARK: - Native Camera Sheet (UIImagePickerController — NOT WDA)

public struct CameraCaptureSheet: View {
    #if canImport(UIKit)
    let onCaptured: (UIImage) -> Void
    #else
    let onCaptured: () -> Void
    #endif
    let onCancel: () -> Void

    #if canImport(UIKit)
    public init(onCaptured: @escaping (UIImage) -> Void, onCancel: @escaping () -> Void) {
        self.onCaptured = onCaptured
        self.onCancel = onCancel
    }

    public var body: some View {
        UIKitCameraPickerRepresentable(onCaptured: onCaptured, onCancel: onCancel)
    }
    #else
    public init(onCaptured: @escaping () -> Void, onCancel: @escaping () -> Void) {
        self.onCaptured = onCaptured
        self.onCancel = onCancel
    }

    public var body: some View {
        Text("Cámara no disponible en este host.")
    }
    #endif
}

#if canImport(UIKit)
private struct UIKitCameraPickerRepresentable: UIViewControllerRepresentable {
    let onCaptured: (UIImage) -> Void
    let onCancel: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onCaptured: onCaptured, onCancel: onCancel)
    }

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.allowsEditing = false
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}

    final class Coordinator: NSObject, UINavigationControllerDelegate, UIImagePickerControllerDelegate {
        let onCaptured: (UIImage) -> Void
        let onCancel: () -> Void

        init(onCaptured: @escaping (UIImage) -> Void, onCancel: @escaping () -> Void) {
            self.onCaptured = onCaptured
            self.onCancel = onCancel
        }

        func imagePickerController(
            _ picker: UIImagePickerController,
            didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]
        ) {
            if let img = info[.originalImage] as? UIImage {
                onCaptured(img)
            } else {
                onCancel()
            }
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            onCancel()
        }
    }
}
#endif

// MARK: - Asynchronous Speech-to-Text Dictation Button & Live Status Bar

public struct DictationMicrophoneButton: View {
    @ObservedObject private var speech = SpeechDictationService.shared
    @Binding var targetText: String
    var onFocusRequested: (() -> Void)?

    public init(targetText: Binding<String>, onFocusRequested: (() -> Void)? = nil) {
        self._targetText = targetText
        self.onFocusRequested = onFocusRequested
    }

    public var body: some View {
        Menu {
            Button {
                OCHaptics.medium()
                startOrStop()
            } label: {
                Label(
                    speech.state.isRecording ? "Detener y transcribir" : "Dictar mensaje (\(speech.selectedLocale.shortTag))",
                    systemImage: speech.state.isRecording ? "stop.circle.fill" : "mic.fill"
                )
            }
            .disabled(speech.state.isTranscribing)

            Section("Idioma · \(speech.currentAvailability().badgeText)") {
                ForEach(SpeechDictationLocale.allCases) { loc in
                    Button {
                        speech.selectedLocale = loc
                    } label: {
                        HStack {
                            Text(loc.displayName)
                            if speech.selectedLocale == loc {
                                Image(systemName: "checkmark")
                            }
                        }
                    }
                }
                Toggle("Permitir Apple Speech en red si falta idioma offline", isOn: $speech.allowNetworkFallback)
            }
        } label: {
            ZStack {
                Circle()
                    .fill(speech.state.isRecording ? OCColor.danger.opacity(0.18) : OCColor.bgLayer1)
                    .frame(width: 34, height: 34)
                Image(systemName: speech.state.isRecording ? "waveform.circle.fill" : "mic.fill")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(speech.state.isRecording ? OCColor.danger : OCColor.iconPrimary)
            }
            .frame(width: 44, height: 44)
            .contentShape(Rectangle())
        } primaryAction: {
            OCHaptics.medium()
            startOrStop()
        }
        .accessibilityLabel(speech.state.isRecording ? "Detener dictado y transcribir" : "Dictar con micrófono")
        .accessibilityIdentifier("composer-mic-button")
        .fixedSize(horizontal: true, vertical: false)
    }

    private func startOrStop() {
        if speech.state.isRecording {
            speech.stopAndTranscribe()
            return
        }
        guard !speech.state.isTranscribing else { return }
        Task {
            await speech.startRecording { transcript in
                targetText = SpeechTextMerger.merge(existing: targetText, transcript: transcript)
                OCHaptics.success()
                onFocusRequested?()
            }
        }
    }
}

public struct DictationLiveStatusBar: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ObservedObject private var speech = SpeechDictationService.shared

    public init() {}

    public var body: some View {
        switch speech.state {
        case .idle:
            EmptyView()
        case .requestingPermissions:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Solicitando permiso de micrófono y voz…")
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundColor(OCColor.textSecondary)
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(OCColor.bgLayer1)
            .clipShape(OCRoundedRect(OCRadius.r10))

        case .recording(let elapsed, let level):
            VStack(alignment: .leading, spacing: OCSpacing.xs) {
                HStack {
                    Image(systemName: "mic.fill")
                        .foregroundColor(OCColor.danger)
                        .accessibilityHidden(true)
                    Text("Grabando · \(speech.selectedLocale.shortTag)")
                        .font(.subheadline.weight(.semibold))
                    Spacer()
                    Text(formatElapsed(elapsed)).font(.footnote.monospacedDigit())
                }
                if !reduceMotion {
                    ProgressView(value: Double(level), total: 1)
                        .tint(OCColor.danger)
                        .accessibilityHidden(true)
                }
                HStack {
                    Button("Cancelar") { speech.cancel() }
                        .frame(minHeight: 44)
                    Spacer()
                    Button {
                        OCHaptics.light()
                        speech.stopAndTranscribe()
                    } label: {
                        Label("Transcribir", systemImage: "stop.fill")
                            .frame(minHeight: 44)
                    }
                }
                .font(.subheadline.weight(.medium))
            }
            .padding(.horizontal, OCSpacing.md)
            .padding(.top, OCSpacing.sm)
            .background(OCColor.bgLayer1)
            .clipShape(OCRoundedRect(OCRadius.r12))

        case .transcribing:
            HStack(spacing: 10) {
                ProgressView().controlSize(.small)
                Text("Transcribiendo dictado (\(speech.selectedLocale.shortTag))…")
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundColor(OCColor.textPrimary)
                Spacer()
                Button("Cancelar") {
                    speech.cancel()
                }
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(OCColor.textSecondary)
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(OCColor.bgLayer1)
            .clipShape(OCRoundedRect(OCRadius.r12))

        case .error(let reason):
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "mic.slash.fill")
                    .font(.system(size: 13))
                    .foregroundColor(OCColor.warning)
                Text(reason)
                    .font(.system(size: 12))
                    .foregroundColor(OCColor.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer()
                #if canImport(UIKit)
                if reason.localizedCaseInsensitiveContains("Ajustes"),
                   let url = URL(string: UIApplication.openSettingsURLString) {
                    Button("Ajustes") { UIApplication.shared.open(url) }
                        .font(.system(size: 12, weight: .semibold))
                }
                #endif
                Button {
                    speech.clearError()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundColor(OCColor.textFaint)
                        .frame(width: 44, height: 44)
                }
                .accessibilityLabel("Cerrar aviso de dictado")
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(OCColor.warning.opacity(0.10))
            .clipShape(OCRoundedRect(OCRadius.r10))
        }
    }

    private func formatElapsed(_ seconds: Int) -> String {
        let mins = seconds / 60
        let secs = seconds % 60
        return String(format: "%02d:%02d", mins, secs)
    }
}

public extension Notification.Name {
    static let openLearnActionSheet = Notification.Name("isycode.openLearnActionSheet")
    static let openSecretVaultSheet = Notification.Name("isycode.openSecretVaultSheet")
}
