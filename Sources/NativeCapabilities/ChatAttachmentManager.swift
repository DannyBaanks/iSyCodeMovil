import Foundation
#if canImport(UniformTypeIdentifiers)
import UniformTypeIdentifiers
#endif
#if canImport(UIKit)
import UIKit
#endif
#if canImport(PDFKit)
import PDFKit
#endif
#if canImport(ImageIO)
import ImageIO
#endif

public struct MultimodalCapabilityReport: Sendable, Equatable {
    public let providerID: String
    public let modelID: String
    public let supportsImages: Bool
    public let supportsExtractedDocuments: Bool
    public let supportsAudioBinary: Bool
    public let supportsVideoBinary: Bool
    public let explanation: String

    public init(
        providerID: String,
        modelID: String,
        supportsImages: Bool,
        supportsExtractedDocuments: Bool,
        supportsAudioBinary: Bool,
        supportsVideoBinary: Bool,
        explanation: String
    ) {
        self.providerID = providerID
        self.modelID = modelID
        self.supportsImages = supportsImages
        self.supportsExtractedDocuments = supportsExtractedDocuments
        self.supportsAudioBinary = supportsAudioBinary
        self.supportsVideoBinary = supportsVideoBinary
        self.explanation = explanation
    }
}

/// Real per-provider capability matrix grounded on the actual request serializers in `ModelProvider.swift`,
/// `ChatGPTCodexProvider.swift`, `GUSLocalModelProvider.swift`, and remote CLI backends.
public enum MultimodalProviderCompatibility {
    public static func evaluate(
        providerID: String?,
        modelID: String?,
        backendMode: BackendMode
    ) -> MultimodalCapabilityReport {
        if backendMode == .remote {
            return MultimodalCapabilityReport(
                providerID: "remote-cli",
                modelID: modelID ?? "remoto",
                supportsImages: false,
                supportsExtractedDocuments: true,
                supportsAudioBinary: false,
                supportsVideoBinary: false,
                explanation: "Este backend remoto en tu computadora solo recibe texto y rutas; puedes enviar documentos de texto/PDF extraído, pero no imágenes binarias directamente."
            )
        }

        let pid = (providerID ?? "scripted").lowercased()
        let mid = modelID ?? ""
        let lowerModel = mid.lowercased()

        switch pid {
        case "gus-local":
            return MultimodalCapabilityReport(
                providerID: pid,
                modelID: mid,
                supportsImages: false,
                supportsExtractedDocuments: true,
                supportsAudioBinary: false,
                supportsVideoBinary: false,
                explanation: "GUS local (Qwen/Smol en este iPhone) solo procesa texto. Para analizar fotografías usa OpenAI, Gemini, ChatGPT OAuth, OpenRouter o NVIDIA VL."
            )
        case "nvidia":
            let hasVision = RemoteModelProvider.modelSupportsImages(providerID: pid, model: mid)
            return MultimodalCapabilityReport(
                providerID: pid,
                modelID: mid,
                supportsImages: hasVision,
                supportsExtractedDocuments: true,
                supportsAudioBinary: false,
                supportsVideoBinary: false,
                explanation: hasVision
                    ? "NVIDIA NIM (\(mid)) admite imágenes por `image_url` y texto extraído de documentos."
                    : "El modelo NVIDIA actual (\(mid)) es solo texto. Elige `nvidia/nemotron-3.5-super-vl-120b-a12b` para enviar imágenes."
            )
        case "openai", "gemini", "openrouter", "chatgpt-oauth":
            return MultimodalCapabilityReport(
                providerID: pid,
                modelID: mid,
                supportsImages: true,
                supportsExtractedDocuments: true,
                supportsAudioBinary: false,
                supportsVideoBinary: false,
                explanation: "\(pid.uppercased()) admite imágenes (JPEG/PNG) y texto extraído de PDF/CSV/JSON/MD. Los clips de audio o video binarios aún no viajan por este endpoint."
            )
        case "xai":
            let hasVision = lowerModel.isEmpty || RemoteModelProvider.modelSupportsImages(providerID: pid, model: mid)
            return MultimodalCapabilityReport(
                providerID: pid,
                modelID: mid,
                supportsImages: hasVision,
                supportsExtractedDocuments: true,
                supportsAudioBinary: false,
                supportsVideoBinary: false,
                explanation: hasVision
                    ? "xAI (\(mid)) admite imágenes vía `image_url` y texto de documentos."
                    : "El modelo xAI actual (\(mid)) es solo texto."
            )
        case "scripted":
            return MultimodalCapabilityReport(
                providerID: pid,
                modelID: mid,
                supportsImages: false,
                supportsExtractedDocuments: true,
                supportsAudioBinary: false,
                supportsVideoBinary: false,
                explanation: "Modo demo sin conexión: configura un proveedor real para enviar imágenes."
            )
        default:
            return MultimodalCapabilityReport(
                providerID: pid,
                modelID: mid,
                supportsImages: false,
                supportsExtractedDocuments: true,
                supportsAudioBinary: false,
                supportsVideoBinary: false,
                explanation: "El proveedor actual solo tiene confirmado envío textual."
            )
        }
    }
}

public struct MultimodalPreparationOutput: Sendable {
    public let parts: [ModelMessage.ContentPart]
    public let fallbackPromptNotes: [String]
    public let blockedReason: String?

    public init(parts: [ModelMessage.ContentPart], fallbackPromptNotes: [String], blockedReason: String?) {
        self.parts = parts
        self.fallbackPromptNotes = fallbackPromptNotes
        self.blockedReason = blockedReason
    }
}

/// Manages security-scoped imports, PhotosPicker data, normalized camera captures, bounded text extraction,
/// staging storage, and controlled payload preparation without loading huge binaries into RAM unnecessarily.
public actor ChatAttachmentManager {
    public static let shared = ChatAttachmentManager()

    public static let maxAttachmentsPerMessage = 8
    public static let maxAttachmentFileBytes: Int64 = 25 * 1024 * 1024
    public static let maxInlineImageBytes: Int = 4 * 1024 * 1024
    public static let maxImageDimension: CGFloat = 2048
    public static let maxExtractedTextCharacters = 40_000

    private let stagingDirectory: URL

    public init(directoryURL: URL? = nil) {
        if let directoryURL {
            self.stagingDirectory = directoryURL
        } else {
            let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
                ?? FileManager.default.temporaryDirectory
            self.stagingDirectory = support.appendingPathComponent("ISyCodeAttachments/staging", isDirectory: true)
        }
        try? FileManager.default.createDirectory(at: self.stagingDirectory, withIntermediateDirectories: true)
    }

    // MARK: - File Importer (Security-Scoped -> Private Authorized Staging)

    public func importFromFileURL(_ url: URL) async -> ChatAttachment {
        let scoped = url.startAccessingSecurityScopedResource()
        defer {
            if scoped {
                url.stopAccessingSecurityScopedResource()
            }
        }

        let id = UUID().uuidString
        let rawName = url.lastPathComponent.isEmpty ? "archivo" : url.lastPathComponent
        let resourceValues = try? url.resourceValues(forKeys: [.fileSizeKey, .contentTypeKey, .isDirectoryKey])
        if resourceValues?.isDirectory == true {
            return ChatAttachment(
                id: id,
                type: .folder,
                source: .filesImporter,
                state: .unsupported("No se pueden adjuntar carpetas completas directamente."),
                name: rawName,
                icon: "folder.badge.questionmark"
            )
        }

        let byteSize = Int64(resourceValues?.fileSize ?? 0)
        if byteSize > Self.maxAttachmentFileBytes {
            return ChatAttachment(
                id: id,
                type: .file,
                source: .filesImporter,
                state: .failed("El archivo supera el límite de 25 MB (\(ByteCountFormatter.string(fromByteCount: byteSize, countStyle: .file)))."),
                name: rawName,
                icon: "exclamationmark.triangle",
                byteCount: byteSize
            )
        }

        let stagedURL = stagingURL(id: id, originalName: rawName)
        do {
            try FileManager.default.createDirectory(at: stagingDirectory, withIntermediateDirectories: true)
            if FileManager.default.fileExists(atPath: stagedURL.path) {
                try FileManager.default.removeItem(at: stagedURL)
            }
            try FileManager.default.copyItem(at: url, to: stagedURL)
        } catch {
            return ChatAttachment(
                id: id,
                type: .file,
                source: .filesImporter,
                state: .failed("No se pudo copiar al almacenamiento privado: \(error.localizedDescription)"),
                name: rawName,
                icon: "exclamationmark.triangle"
            )
        }

        let actualSize = (try? FileManager.default.attributesOfItem(atPath: stagedURL.path)[.size] as? Int64) ?? byteSize
        let ext = stagedURL.pathExtension.lowercased()
        let mime = Self.resolveMimeType(fileExtension: ext)
        let uti = Self.resolveUTTypeIdentifier(fileExtension: ext)

        return await buildAttachmentFromStagedFile(
            id: id,
            stagedURL: stagedURL,
            name: rawName,
            source: .filesImporter,
            byteCount: actualSize,
            mimeType: mime,
            utTypeIdentifier: uti,
            fileExtension: ext
        )
    }

    // MARK: - PhotosPicker / Image Data / Camera Import

    public func importPhotosImageData(
        _ data: Data,
        suggestedFilename: String = "foto.jpg",
        fileExtension: String = "jpg",
        source: AttachmentSource = .photosLibrary
    ) async -> ChatAttachment {
        let id = UUID().uuidString
        guard data.count <= Self.maxAttachmentFileBytes else {
            return ChatAttachment(
                id: id,
                type: .image,
                source: source,
                state: .failed("La imagen supera el límite de 25 MB."),
                name: suggestedFilename,
                icon: "photo",
                byteCount: Int64(data.count)
            )
        }

        #if canImport(UIKit)
        if let prepared = Self.normalizeImageDataIfNeeded(data, preferredExt: fileExtension) {
            let ext = prepared.ext
            let cleanName = Self.replaceExtension(of: suggestedFilename, with: ext)
            let stagedURL = stagingURL(id: id, originalName: cleanName)
            do {
                try FileManager.default.createDirectory(at: stagingDirectory, withIntermediateDirectories: true)
                try prepared.data.write(to: stagedURL, options: .atomic)
                return ChatAttachment(
                    id: id,
                    type: .image,
                    source: source,
                    state: .ready,
                    name: cleanName,
                    path: stagedURL.path,
                    icon: source == .camera ? "camera.fill" : "photo.fill",
                    mimeType: prepared.mimeType,
                    utTypeIdentifier: ext == "png" ? "public.png" : "public.jpeg",
                    byteCount: Int64(prepared.data.count),
                    pixelWidth: prepared.width,
                    pixelHeight: prepared.height
                )
            } catch {
                return ChatAttachment(
                    id: id,
                    type: .image,
                    source: source,
                    state: .failed("Error al guardar imagen: \(error.localizedDescription)"),
                    name: cleanName,
                    icon: "photo"
                )
            }
        }
        #endif

        // Fallback when UIKit/image decode unavailable (keeps original bytes up to limit)
        let stagedURL = stagingURL(id: id, originalName: suggestedFilename)
        do {
            try FileManager.default.createDirectory(at: stagingDirectory, withIntermediateDirectories: true)
            try data.write(to: stagedURL, options: .atomic)
            let mime = Self.resolveMimeType(fileExtension: fileExtension)
            return ChatAttachment(
                id: id,
                type: .image,
                source: source,
                state: .ready,
                name: suggestedFilename,
                path: stagedURL.path,
                icon: "photo.fill",
                mimeType: mime,
                byteCount: Int64(data.count)
            )
        } catch {
            return ChatAttachment(
                id: id,
                type: .image,
                source: source,
                state: .failed("Error guardando archivo multimedia: \(error.localizedDescription)"),
                name: suggestedFilename,
                icon: "photo"
            )
        }
    }

    public func importPhotosVideoFile(from tempURL: URL, suggestedFilename: String = "video.mp4") async -> ChatAttachment {
        let id = UUID().uuidString
        let size = (try? FileManager.default.attributesOfItem(atPath: tempURL.path)[.size] as? Int64) ?? 0
        guard size <= Self.maxAttachmentFileBytes else {
            return ChatAttachment(
                id: id,
                type: .video,
                source: .photosLibrary,
                state: .failed("El video supera el límite de 25 MB."),
                name: suggestedFilename,
                icon: "video.slash",
                byteCount: size
            )
        }
        let stagedURL = stagingURL(id: id, originalName: suggestedFilename)
        do {
            try FileManager.default.createDirectory(at: stagingDirectory, withIntermediateDirectories: true)
            if FileManager.default.fileExists(atPath: stagedURL.path) {
                try FileManager.default.removeItem(at: stagedURL)
            }
            try FileManager.default.copyItem(at: tempURL, to: stagedURL)
        } catch {
            return ChatAttachment(
                id: id,
                type: .video,
                source: .photosLibrary,
                state: .failed("No se pudo guardar el video: \(error.localizedDescription)"),
                name: suggestedFilename,
                icon: "video"
            )
        }
        let ext = stagedURL.pathExtension.lowercased()
        let mime = Self.resolveMimeType(fileExtension: ext)
        return ChatAttachment(
            id: id,
            type: .video,
            source: .photosLibrary,
            state: .unsupported("Clip guardado localmente, pero los endpoints actuales de ISyCode no envían video binario directamente."),
            name: suggestedFilename,
            path: stagedURL.path,
            icon: "video.fill",
            mimeType: mime,
            byteCount: size,
            warningMessage: "Los proveedores configurados actualmente no aceptan video binario en chat; extrae capturas clave para analizarlas."
        )
    }

    #if canImport(UIKit)
    public func importCameraUIImage(_ image: UIImage) async -> ChatAttachment {
        guard let normalized = Self.renderOrientedJPEG(image, maxDimension: Self.maxImageDimension, quality: 0.86) else {
            return ChatAttachment(
                type: .image,
                source: .camera,
                state: .failed("No se pudo codificar la fotografía capturada."),
                name: "camara.jpg",
                icon: "camera"
            )
        }
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let name = "foto-\(stamp.prefix(19)).jpg"
        return await importPhotosImageData(normalized.data, suggestedFilename: name, fileExtension: "jpg", source: .camera)
    }
    #endif

    // MARK: - Multimodal Payload Preparation

    public func prepareForSend(
        attachments: [ChatAttachment],
        providerID: String?,
        modelID: String?,
        backendMode: BackendMode
    ) async -> MultimodalPreparationOutput {
        let compat = MultimodalProviderCompatibility.evaluate(
            providerID: providerID,
            modelID: modelID,
            backendMode: backendMode
        )

        var parts: [ModelMessage.ContentPart] = []
        var promptNotes: [String] = []
        var incompatibleReasons: [String] = []

        for attachment in attachments {
            switch attachment.type {
            case .image:
                guard compat.supportsImages else {
                    incompatibleReasons.append("'\(attachment.name)': \(compat.explanation)")
                    continue
                }
                guard let path = attachment.path,
                      let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
                      data.count <= Self.maxInlineImageBytes else {
                    incompatibleReasons.append("'\(attachment.name)': el archivo de imagen no está listo o excede 4 MB inline.")
                    continue
                }
                let mime = attachment.mimeType ?? "image/jpeg"
                parts.append(.image(base64: data.base64EncodedString(), mimeType: mime, filename: attachment.name))
                promptNotes.append("[Imagen adjunta: \(attachment.name)]")

            case .file:
                if let extracted = attachment.extractedText, !extracted.isEmpty {
                    parts.append(.document(filename: attachment.name, mimeType: attachment.mimeType, text: extracted))
                    promptNotes.append("[Documento adjunto: \(attachment.name)]")
                } else if let path = attachment.path, backendMode == .remote {
                    promptNotes.append("@\(path)")
                } else {
                    incompatibleReasons.append(
                        "'\(attachment.name)': no se pudo extraer texto legible para enviar al modelo (\(attachment.warningMessage ?? "formato binario"))."
                    )
                }

            case .video, .audio:
                incompatibleReasons.append(
                    "'\(attachment.name)': el proveedor activo no admite \(attachment.type == .video ? "video" : "audio binario") directo en el endpoint de chat."
                )

            case .folder, .context:
                if let path = attachment.path, !path.isEmpty {
                    promptNotes.append("@\(path)")
                } else {
                    promptNotes.append("@\(attachment.name)")
                }
            }
        }

        return MultimodalPreparationOutput(
            parts: parts,
            fallbackPromptNotes: promptNotes,
            blockedReason: incompatibleReasons.isEmpty ? nil : incompatibleReasons.joined(separator: "\n")
        )
    }

    public func removeStagedFile(for attachment: ChatAttachment) {
        guard let path = attachment.path,
              path.hasPrefix(stagingDirectory.path) else { return }
        try? FileManager.default.removeItem(atPath: path)
    }

    public func cleanupStagedFiles(olderThanAge seconds: TimeInterval = 48 * 3600) {
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: stagingDirectory,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return }
        let cutoff = Date().addingTimeInterval(-seconds)
        for url in urls {
            let mod = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            if mod < cutoff {
                try? FileManager.default.removeItem(at: url)
            }
        }
    }

    // MARK: - Private Staging & Extraction Helpers

    private func stagingURL(id: String, originalName: String) -> URL {
        let clean = originalName
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "..", with: "_")
        return stagingDirectory.appendingPathComponent("\(id.prefix(8))_\(clean)")
    }

    private func buildAttachmentFromStagedFile(
        id: String,
        stagedURL: URL,
        name: String,
        source: AttachmentSource,
        byteCount: Int64,
        mimeType: String,
        utTypeIdentifier: String,
        fileExtension: String
    ) async -> ChatAttachment {
        let imageExtensions: Set<String> = ["jpg", "jpeg", "png", "heic", "heif", "webp", "gif"]
        let audioExtensions: Set<String> = ["m4a", "mp3", "wav", "aac", "caf"]
        let videoExtensions: Set<String> = ["mp4", "mov", "m4v"]

        if imageExtensions.contains(fileExtension) {
            if let data = try? Data(contentsOf: stagedURL) {
                #if canImport(UIKit)
                if let normalized = Self.normalizeImageDataIfNeeded(data, preferredExt: fileExtension) {
                    try? normalized.data.write(to: stagedURL, options: .atomic)
                    return ChatAttachment(
                        id: id,
                        type: .image,
                        source: source,
                        state: .ready,
                        name: name,
                        path: stagedURL.path,
                        icon: "photo.fill",
                        mimeType: normalized.mimeType,
                        utTypeIdentifier: utTypeIdentifier,
                        byteCount: Int64(normalized.data.count),
                        pixelWidth: normalized.width,
                        pixelHeight: normalized.height
                    )
                }
                #endif
            }
            return ChatAttachment(
                id: id,
                type: .image,
                source: source,
                state: .ready,
                name: name,
                path: stagedURL.path,
                icon: "photo.fill",
                mimeType: mimeType,
                utTypeIdentifier: utTypeIdentifier,
                byteCount: byteCount
            )
        }

        if audioExtensions.contains(fileExtension) {
            return ChatAttachment(
                id: id,
                type: .audio,
                source: .audioPicker,
                state: .unsupported("Los endpoints de chat actuales no aceptan audio binario; usa el micrófono para transcribir audio hablado."),
                name: name,
                path: stagedURL.path,
                icon: "waveform",
                mimeType: mimeType,
                utTypeIdentifier: utTypeIdentifier,
                byteCount: byteCount,
                warningMessage: "Usa el dictado nativo o convierte el audio a texto antes de enviarlo."
            )
        }

        if videoExtensions.contains(fileExtension) {
            return ChatAttachment(
                id: id,
                type: .video,
                source: source,
                state: .unsupported("Clip guardado localmente, pero el endpoint de chat actual no admite video binario."),
                name: name,
                path: stagedURL.path,
                icon: "video.fill",
                mimeType: mimeType,
                utTypeIdentifier: utTypeIdentifier,
                byteCount: byteCount,
                warningMessage: "Los proveedores activos requieren texto o imágenes fijas."
            )
        }

        if fileExtension == "pdf" {
            let extraction = Self.extractPDFText(from: stagedURL, maxCharacters: Self.maxExtractedTextCharacters)
            if let text = extraction.text, !text.isEmpty {
                return ChatAttachment(
                    id: id,
                    type: .file,
                    source: source,
                    state: .ready,
                    name: name,
                    path: stagedURL.path,
                    icon: "doc.richtext.fill",
                    mimeType: mimeType,
                    utTypeIdentifier: utTypeIdentifier,
                    byteCount: byteCount,
                    extractedText: text,
                    warningMessage: extraction.warning
                )
            } else {
                return ChatAttachment(
                    id: id,
                    type: .file,
                    source: source,
                    state: .unsupported(extraction.warning ?? "El PDF parece escaneado y no contiene texto seleccionable."),
                    name: name,
                    path: stagedURL.path,
                    icon: "doc.richtext",
                    mimeType: mimeType,
                    utTypeIdentifier: utTypeIdentifier,
                    byteCount: byteCount,
                    warningMessage: extraction.warning ?? "Sin capa de texto en PDF; toma una fotografía para visión."
                )
            }
        }

        // Plain-text / structured text formats (TXT, MD, JSON, CSV, Swift, Zig, Py, TS, XML, YAML, Log)
        if let text = Self.extractUTF8Text(from: stagedURL, maxCharacters: Self.maxExtractedTextCharacters) {
            let iconName: String
            switch fileExtension {
            case "csv": iconName = "tablecells"
            case "json": iconName = "curlybraces"
            case "md", "markdown": iconName = "doc.plaintext.fill"
            default: iconName = "doc.text.fill"
            }
            return ChatAttachment(
                id: id,
                type: .file,
                source: source,
                state: .ready,
                name: name,
                path: stagedURL.path,
                icon: iconName,
                mimeType: mimeType,
                utTypeIdentifier: utTypeIdentifier,
                byteCount: byteCount,
                extractedText: text.content,
                warningMessage: text.truncated ? "Archivo truncado a \(Self.maxExtractedTextCharacters) caracteres." : nil
            )
        }

        return ChatAttachment(
            id: id,
            type: .file,
            source: source,
            state: .unsupported("Formato binario no soportado directamente en chat (\(fileExtension.isEmpty ? "bin" : fileExtension))."),
            name: name,
            path: stagedURL.path,
            icon: "doc.badge.gearshape",
            mimeType: mimeType,
            utTypeIdentifier: utTypeIdentifier,
            byteCount: byteCount,
            warningMessage: "Solo se puede leer texto de PDF, TXT, MD, JSON, CSV o código fuente."
        )
    }

    public static func extractPDFText(from url: URL, maxCharacters: Int) -> (text: String?, warning: String?) {
        #if canImport(PDFKit)
        guard let doc = PDFDocument(url: url) else {
            return (nil, "No se pudo abrir el documento PDF.")
        }
        var chunks: [String] = []
        var total = 0
        var truncated = false
        for pageIndex in 0..<doc.pageCount {
            guard let page = doc.page(at: pageIndex), let pageText = page.string?.trimmingCharacters(in: .whitespacesAndNewlines), !pageText.isEmpty else {
                continue
            }
            let block = "--- Página \(pageIndex + 1) ---\n\(pageText)"
            if total + block.count > maxCharacters {
                let remaining = max(0, maxCharacters - total)
                if remaining > 0 {
                    chunks.append(String(block.prefix(remaining)))
                }
                truncated = true
                break
            }
            chunks.append(block)
            total += block.count + 2
        }
        if chunks.isEmpty {
            return (nil, "El PDF tiene \(doc.pageCount) página(s) pero no contiene texto extraíble (posiblemente es un escaneo).")
        }
        let warn = truncated ? "PDF truncado a \(maxCharacters) caracteres (\(doc.pageCount) páginas en total)." : nil
        return (chunks.joined(separator: "\n\n"), warn)
        #else
        return (nil, "PDFKit no disponible en este host.")
        #endif
    }

    public static func extractUTF8Text(from url: URL, maxCharacters: Int) -> (content: String, truncated: Bool)? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        // Read bounded slice (4x max characters UTF-8 bytes) so huge files never fill RAM
        let maxBytes = maxCharacters * 4 + 1024
        guard let slice = try? handle.read(upToCount: maxBytes), !slice.isEmpty else {
            return ("", false)
        }
        // Reject raw binary NUL bytes
        if slice.prefix(2048).contains(0) {
            return nil
        }
        guard let text = String(data: slice, encoding: .utf8) ?? String(data: slice, encoding: .isoLatin1) else {
            return nil
        }
        if text.count > maxCharacters {
            return (String(text.prefix(maxCharacters)), true)
        }
        return (text, false)
    }

    #if canImport(UIKit)
    private struct EncodedImage {
        let data: Data
        let mimeType: String
        let ext: String
        let width: Int
        let height: Int
    }

    private static func normalizeImageDataIfNeeded(_ rawData: Data, preferredExt: String) -> EncodedImage? {
        guard let uiImage = UIImage(data: rawData) else { return nil }
        let extLower = preferredExt.lowercased()
        let pixelW = Int(uiImage.size.width * uiImage.scale)
        let pixelH = Int(uiImage.size.height * uiImage.scale)
        let isTooLarge = rawData.count > maxInlineImageBytes
            || CGFloat(max(pixelW, pixelH)) > maxImageDimension
        let needsOrientationOrHEICConversion = uiImage.imageOrientation != .up || extLower == "heic" || extLower == "heif"

        // Preserve original PNG/JPEG untouched when orientation is .up and within inline size limits
        if !isTooLarge && !needsOrientationOrHEICConversion && (extLower == "png" || extLower == "jpg" || extLower == "jpeg") {
            return EncodedImage(
                data: rawData,
                mimeType: extLower == "png" ? "image/png" : "image/jpeg",
                ext: extLower == "png" ? "png" : "jpg",
                width: max(pixelW, 1),
                height: max(pixelH, 1)
            )
        }

        if extLower == "png" && !isTooLarge && !needsOrientationOrHEICConversion, let png = uiImage.pngData(), png.count <= maxInlineImageBytes {
            return EncodedImage(data: png, mimeType: "image/png", ext: "png", width: max(pixelW, 1), height: max(pixelH, 1))
        }

        guard let jpeg = renderOrientedJPEG(uiImage, maxDimension: maxImageDimension, quality: 0.85) else {
            return nil
        }
        return EncodedImage(data: jpeg.data, mimeType: "image/jpeg", ext: "jpg", width: jpeg.width, height: jpeg.height)
    }

    private static func renderOrientedJPEG(_ image: UIImage, maxDimension: CGFloat, quality: CGFloat) -> (data: Data, width: Int, height: Int)? {
        let w = image.size.width
        let h = image.size.height
        guard w > 0, h > 0 else { return nil }
        let scaleFactor = min(1.0, maxDimension / max(w, h))
        let targetSize = CGSize(width: max(1, floor(w * scaleFactor)), height: max(1, floor(h * scaleFactor)))
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1.0
        format.opaque = true
        let renderer = UIGraphicsImageRenderer(size: targetSize, format: format)
        let rendered = renderer.image { _ in
            image.draw(in: CGRect(origin: .zero, size: targetSize))
        }
        var currentQuality = quality
        while currentQuality >= 0.35 {
            if let data = rendered.jpegData(compressionQuality: currentQuality), data.count <= maxInlineImageBytes {
                return (data, Int(targetSize.width), Int(targetSize.height))
            }
            currentQuality -= 0.15
        }
        guard let fallback = rendered.jpegData(compressionQuality: 0.35) else { return nil }
        return (fallback, Int(targetSize.width), Int(targetSize.height))
    }
    #endif

    private static func replaceExtension(of filename: String, with newExt: String) -> String {
        let base = URL(fileURLWithPath: filename).deletingPathExtension().lastPathComponent
        return "\(base.isEmpty ? "imagen" : base).\(newExt)"
    }

    private static func resolveMimeType(fileExtension ext: String) -> String {
        #if canImport(UniformTypeIdentifiers)
        if let ut = UTType(filenameExtension: ext), let mime = ut.preferredMIMEType {
            return mime
        }
        #endif
        switch ext {
        case "jpg", "jpeg": return "image/jpeg"
        case "png": return "image/png"
        case "heic": return "image/heic"
        case "pdf": return "application/pdf"
        case "csv": return "text/csv"
        case "json": return "application/json"
        case "md", "markdown": return "text/markdown"
        case "txt": return "text/plain"
        case "mp4": return "video/mp4"
        case "mov": return "video/quicktime"
        case "m4a": return "audio/mp4"
        default: return "application/octet-stream"
        }
    }

    private static func resolveUTTypeIdentifier(fileExtension ext: String) -> String {
        #if canImport(UniformTypeIdentifiers)
        if let ut = UTType(filenameExtension: ext) {
            return ut.identifier
        }
        #endif
        return "public.data"
    }
}
