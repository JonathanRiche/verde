import CryptoKit
import Foundation
import ImageIO
import SwiftUI
import UIKit

/*
 * Image attachments in transcripts. The core fetches a message's image from the host in chunks
 * (`attachment_fetch`) and exposes it in the `attachments` view; the app writes it once to a disk
 * cache in Caches/ (named by the SHA-256 of its key), shows ImageIO-downsampled thumbnails, and
 * then lets the core drop the bytes (`attachment_release`). Images just attached on this phone are
 * shown from their local bytes right away. Image bytes are never logged.
 */

// MARK: - Keys, names and states (pure)

/// "<workspace_id>|<thread_id>|<message_id>|<index>": the core's `attachments` view key.
func attachmentKey(workspaceID: String, threadID: String, messageID: String, index: Int) -> String {
    [workspaceID, threadID, messageID, String(index)].joined(separator: "|")
}

/// The row's durable message id. Rows carry their message id as `id`; when the generated models
/// add an explicit `message_id`, read it here (the one place).
/// The stored message id the daemon knows; unsaved rows fall back to the row id
/// (their images come from local bytes anyway).
func attachmentMessageID(_ row: ChatRow) -> String { row.message_id ?? row.id }

/// Cache file name: SHA-256 of the key (never the ids themselves) plus an extension from the mime.
func attachmentCacheName(key: String, mime: String) -> String {
    let digest = SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined()
    return digest + "." + attachmentFileExtension(mime)
}

func attachmentFileExtension(_ mime: String) -> String {
    switch mime.lowercased() {
    case "image/png": return "png"
    case "image/gif": return "gif"
    case "image/webp": return "webp"
    case "image/heic": return "heic"
    case "image/heif": return "heif"
    default: return "jpg"
    }
}

/// One entry of the `attachments` view.
struct AttachmentFetchState: Decodable, Equatable {
    /// `loading`, `ready`, `failed` or `unavailable`.
    var status: String
    var mime: String
    var total_bytes: Int64
    var data_base64: String?
    var error_code: String?

    private enum Keys: String, CodingKey { case status, mime, total_bytes, data_base64, error_code }
    init(status: String, mime: String = "", total_bytes: Int64 = 0, data_base64: String? = nil, error_code: String? = nil) {
        self.status = status; self.mime = mime; self.total_bytes = total_bytes; self.data_base64 = data_base64; self.error_code = error_code
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        status = try c.decodeIfPresent(String.self, forKey: .status) ?? "loading"
        mime = try c.decodeIfPresent(String.self, forKey: .mime) ?? ""
        if let number = try? c.decodeIfPresent(Int64.self, forKey: .total_bytes) { total_bytes = number }
        else { total_bytes = Int64((try? c.decodeIfPresent(String.self, forKey: .total_bytes)) ?? "") ?? 0 }
        data_base64 = try c.decodeIfPresent(String.self, forKey: .data_base64)
        error_code = try c.decodeIfPresent(String.self, forKey: .error_code)
    }
}

/// The `attachments` selector's data: a map of key → state (also accepted under `items`).
func decodeAttachmentsView(_ data: Data?) -> [String: AttachmentFetchState] {
    guard let data, case .object(let envelope)? = try? JSONDecoder().decode(JSONValue.self, from: data),
          let payload = envelope["data"] else { return [:] }
    var map = payload
    if case .object(let object) = payload, let items = object["items"], case .object = items { map = items }
    guard let encoded = try? JSONEncoder().encode(map) else { return [:] }
    return (try? JSONDecoder().decode([String: AttachmentFetchState].self, from: encoded)) ?? [:]
}

enum ThumbnailPhase: Equatable { case image, loading, unavailable }

/// What a thumbnail shows: the image once cached; "Preview unavailable" only when the host said so.
func thumbnailPhase(status: String?, cached: Bool) -> ThumbnailPhase {
    if cached { return .image }
    switch status {
    case "failed"?, "unavailable"?: return .unavailable
    default: return .loading
    }
}

/// Aspect-preserving size whose longer side is `longest` points.
func thumbnailSize(for pixels: CGSize, longest: CGFloat = 160) -> CGSize {
    guard pixels.width > 0, pixels.height > 0 else { return CGSize(width: longest, height: longest) }
    let scale = longest / max(pixels.width, pixels.height)
    return CGSize(width: max(48, (pixels.width * scale).rounded()), height: max(48, (pixels.height * scale).rounded()))
}

func isImageAttachment(_ attachment: ChatAttachment) -> Bool { attachment.mime.lowercased().hasPrefix("image/") }

// MARK: - Local bytes and the disk cache

/// Bytes of images attached on this phone, by draft `local_id`, so the sent row shows them at once.
final class LocalAttachmentPreviews: @unchecked Sendable {
    static let shared = LocalAttachmentPreviews()
    private let cache = NSCache<NSString, NSData>()
    init() { cache.totalCostLimit = 8 * 1024 * 1024 }
    func put(_ id: String, _ bytes: Data) { cache.setObject(bytes as NSData, forKey: id as NSString, cost: bytes.count) }
    func get(_ id: String) -> Data? { cache.object(forKey: id as NSString) as Data? }
}

func downsampledImage(_ source: CGImageSource?, maxPixel: CGFloat) -> UIImage? {
    guard let source else { return nil }
    let options: [CFString: Any] = [
        kCGImageSourceCreateThumbnailFromImageAlways: true,
        kCGImageSourceShouldCacheImmediately: true,
        kCGImageSourceCreateThumbnailWithTransform: true,
        kCGImageSourceThumbnailMaxPixelSize: max(1, maxPixel),
    ]
    guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
    return UIImage(cgImage: image)
}

func downsampledImage(url: URL, maxPixel: CGFloat) -> UIImage? {
    downsampledImage(CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary), maxPixel: maxPixel)
}

func downsampledImage(data: Data, maxPixel: CGFloat) -> UIImage? {
    downsampledImage(CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary), maxPixel: maxPixel)
}

/// Fetched images on disk (Caches/AttachmentPreviews, excluded from backup by the system) and
/// decoded thumbnails in memory.
final class AttachmentImageCache: @unchecked Sendable {
    static let shared = AttachmentImageCache()
    private let directory: URL
    private let thumbnails = NSCache<NSString, UIImage>()
    private let lock = NSLock()
    private var inFlight: Set<String> = []

    init(directory: URL? = nil) {
        let base = directory ?? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        self.directory = base.appendingPathComponent("AttachmentPreviews", isDirectory: true)
        try? FileManager.default.createDirectory(at: self.directory, withIntermediateDirectories: true)
        thumbnails.countLimit = 120
    }

    /// The cached file for `key`, whatever its extension.
    func file(for key: String) -> URL? {
        let stem = attachmentCacheName(key: key, mime: "").split(separator: ".").first.map(String.init) ?? ""
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path),
              let name = names.first(where: { $0.hasPrefix(stem + ".") }) else { return nil }
        return directory.appendingPathComponent(name)
    }

    @discardableResult
    func store(_ data: Data, key: String, mime: String) -> URL? {
        let url = directory.appendingPathComponent(attachmentCacheName(key: key, mime: mime))
        do { try data.write(to: url, options: [.atomic, .completeFileProtection]) } catch { return nil }
        return url
    }

    func thumbnail(for key: String, maxPixel: CGFloat) -> UIImage? {
        let id = "\(key)#\(Int(maxPixel))" as NSString
        if let image = thumbnails.object(forKey: id) { return image }
        guard let url = file(for: key), let image = downsampledImage(url: url, maxPixel: maxPixel) else { return nil }
        thumbnails.setObject(image, forKey: id)
        return image
    }

    /// Starts one fetch per key at a time; false when one is already running.
    func begin(_ key: String) -> Bool { lock.lock(); defer { lock.unlock() }; return inFlight.insert(key).inserted }
    func end(_ key: String) { lock.lock(); inFlight.remove(key); lock.unlock() }

    /// Drops every cached image (e.g. when a host is forgotten).
    func clear() {
        thumbnails.removeAllObjects()
        try? FileManager.default.removeItem(at: directory)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
}

// MARK: - Core intents (raw until models are regenerated)

enum AttachmentIntent {
    static func fetch(intentID: String, workspaceID: String, threadID: String, messageID: String, index: Int) -> (String, [String: JSONValue]) {
        ("attachment_fetch", ["intent_id": .string(intentID), "workspace_id": .string(workspaceID), "thread_id": .string(threadID),
                              "message_id": .string(messageID), "index": .integer(Int64(index))])
    }
    static func release(intentID: String, key: String) -> (String, [String: JSONValue]) {
        ("attachment_release", ["intent_id": .string(intentID), "key": .string(key)])
    }
}

// MARK: - Views

struct ViewerRequestImage: Identifiable {
    let url: URL
    var id: String { url.path }
}

/// One image in a transcript row: the thumbnail, a placeholder while it loads, or "Preview
/// unavailable"; tap opens the full-screen viewer.
struct AttachmentThumbnail: View {
    let browse: BrowseModel
    let workspaceID: String
    let threadID: String
    let messageID: String
    let index: Int
    let attachment: ChatAttachment
    var longest: CGFloat = 140
    @Environment(\.displayScale) private var displayScale
    @State private var image: UIImage?
    @State private var status: String?
    @State private var viewer: ViewerRequestImage?
    @State private var requested = false

    private var key: String { attachmentKey(workspaceID: workspaceID, threadID: threadID, messageID: messageID, index: index) }
    private var maxPixel: CGFloat { longest * displayScale }

    var body: some View {
        let phase = thumbnailPhase(status: status, cached: image != nil)
        Group {
            switch phase {
            case .image:
                if let image {
                    let size = thumbnailSize(for: CGSize(width: image.size.width * image.scale, height: image.size.height * image.scale), longest: longest)
                    Image(uiImage: image).resizable().scaledToFill()
                        .frame(width: size.width, height: size.height)
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                        .contentShape(RoundedRectangle(cornerRadius: 10))
                        .onTapGesture { if let url = AttachmentImageCache.shared.file(for: key) { viewer = ViewerRequestImage(url: url) } }
                        .accessibilityElement()
                        .accessibilityLabel("Image" + (attachment.name.isEmpty ? "" : ", " + attachment.name))
                        .accessibilityHint("Opens the image full screen.")
                        .accessibilityAddTraits(.isButton)
                        .accessibilityAction { if let url = AttachmentImageCache.shared.file(for: key) { viewer = ViewerRequestImage(url: url) } }
                }
            case .loading:
                RoundedRectangle(cornerRadius: 10).fill(VerdeTheme.alternate)
                    .frame(width: longest * 0.8, height: longest * 0.6)
                    .overlay { ProgressView() }
                    .accessibilityLabel("Image loading")
            case .unavailable:
                VStack(spacing: 4) {
                    Image(systemName: "photo").foregroundStyle(VerdeTheme.subtle)
                    Text("Preview unavailable").font(VerdeTheme.ui(11)).foregroundStyle(VerdeTheme.subtle)
                }
                .frame(width: longest * 0.8, height: longest * 0.6)
                .background(VerdeTheme.alternate, in: RoundedRectangle(cornerRadius: 10))
                .accessibilityElement(children: .combine)
            }
        }
        // Lazily: only rows on screen fetch.
        .task(id: key) { await load() }
        .onChange(of: browse.session?.store.snapshots["attachments"]) { _, data in
            guard image == nil, requested else { return }
            Task { await receive(decodeAttachmentsView(data)[key]) }
        }
        .fullScreenCover(item: $viewer) { request in AttachmentViewer(url: request.url) }
    }

    private func load() async {
        // 1. Bytes attached on this phone.
        if let bytes = LocalAttachmentPreviews.shared.get(attachment.local_id), let local = downsampledImage(data: bytes, maxPixel: maxPixel) {
            AttachmentImageCache.shared.store(bytes, key: key, mime: attachment.mime.isEmpty ? "image/jpeg" : attachment.mime)
            image = local
            return
        }
        // 2. The disk cache.
        if let cached = AttachmentImageCache.shared.thumbnail(for: key, maxPixel: maxPixel) { image = cached; return }
        // 3. Ask the core to fetch it (once per key across the app).
        guard let session = browse.session else { status = "unavailable"; return }
        requested = true
        if let existing = decodeAttachmentsView(session.store.snapshots["attachments"])[key] {
            await receive(existing)
            if image != nil || existing.status != "loading" && existing.status != "ready" { return }
        }
        guard AttachmentImageCache.shared.begin(key) else { status = "loading"; return }
        status = "loading"
        await session.start()
        guard let host = session.host else { AttachmentImageCache.shared.end(key); status = "unavailable"; return }
        let (type, fields) = AttachmentIntent.fetch(intentID: UUID().uuidString, workspaceID: workspaceID, threadID: threadID,
                                                    messageID: messageID, index: index)
        do { try await host.sendIntent(type, fields) } catch {
            AttachmentImageCache.shared.end(key)
            status = "unavailable"
        }
    }

    /// Caches ready bytes, shows them, and lets the core drop its copy.
    private func receive(_ state: AttachmentFetchState?) async {
        guard let state, image == nil else { return }
        status = state.status
        if state.status == "failed" || state.status == "unavailable" { AttachmentImageCache.shared.end(key); return }
        guard state.status == "ready", let base64 = state.data_base64, let data = Data(base64Encoded: base64) else { return }
        let key = self.key, mime = state.mime, maxPixel = self.maxPixel
        let decoded = await Task.detached(priority: .userInitiated) { () -> UIImage? in
            AttachmentImageCache.shared.store(data, key: key, mime: mime)
            return AttachmentImageCache.shared.thumbnail(for: key, maxPixel: maxPixel)
        }.value
        AttachmentImageCache.shared.end(key)
        if let decoded { image = decoded } else { status = "failed" }
        if let host = browse.session?.host {
            let (type, fields) = AttachmentIntent.release(intentID: UUID().uuidString, key: key)
            try? await host.sendIntent(type, fields)
        }
    }
}

/// A row's attachments: image thumbnails (aspect-preserving, 96–160pt) and names for other files.
struct AttachmentStrip: View {
    let browse: BrowseModel
    let workspaceID: String
    let threadID: String
    let row: ChatRow
    var longest: CGFloat = 140
    var alignment: HorizontalAlignment = .leading

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(alignment: .top, spacing: 6) {
                ForEach(Array(row.attachments.enumerated()), id: \.offset) { index, attachment in
                    if isImageAttachment(attachment) {
                        AttachmentThumbnail(browse: browse, workspaceID: workspaceID, threadID: threadID,
                                            messageID: attachmentMessageID(row), index: attachment.index.map { Int($0) } ?? index, attachment: attachment, longest: longest)
                    } else {
                        Text(attachment.name.split(separator: "/").last.map(String.init) ?? attachment.name)
                            .font(VerdeTheme.ui(12)).lineLimit(1).padding(.horizontal, 8).padding(.vertical, 4)
                            .background(VerdeTheme.alternate, in: Capsule())
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: Alignment(horizontal: alignment, vertical: .center))
    }
}

/// Full-screen image: pinch to zoom, double-tap to reset, drag down to dismiss, share the file.
struct AttachmentViewer: View {
    let url: URL
    @Environment(\.dismiss) private var dismiss
    @Environment(\.displayScale) private var displayScale
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var image: UIImage?
    @State private var scale: CGFloat = 1
    @State private var committedScale: CGFloat = 1
    @State private var offset: CGSize = .zero
    @State private var committedOffset: CGSize = .zero

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                Color.black.opacity(scale <= 1 ? max(0.4, 1 - Double(abs(offset.height)) / 400) : 1).ignoresSafeArea()
                if let image {
                    Image(uiImage: image).resizable().scaledToFit()
                        .scaleEffect(scale)
                        .offset(offset)
                        .gesture(MagnifyGesture()
                            .onChanged { value in scale = min(6, max(1, committedScale * value.magnification)) }
                            .onEnded { _ in committedScale = scale; if scale <= 1 { reset() } })
                        .simultaneousGesture(DragGesture()
                            .onChanged { value in
                                offset = CGSize(width: committedOffset.width + value.translation.width,
                                                height: committedOffset.height + value.translation.height)
                            }
                            .onEnded { value in
                                if scale <= 1 {
                                    if abs(value.translation.height) > 120 { dismiss() } else { reset() }
                                } else {
                                    committedOffset = offset
                                }
                            })
                        .onTapGesture(count: 2) { reset() }
                        .accessibilityLabel("Image")
                        .accessibilityAddTraits(.isImage)
                } else {
                    ProgressView().tint(.white)
                }
            }
            .task {
                let maxPixel = max(geometry.size.width, geometry.size.height) * displayScale * 2
                image = await Task.detached(priority: .userInitiated) { downsampledImage(url: url, maxPixel: maxPixel) }.value
            }
        }
        .overlay(alignment: .top) {
            HStack {
                Button { dismiss() } label: {
                    Image(systemName: "xmark").font(.system(size: 16, weight: .semibold)).foregroundStyle(.white)
                        .frame(width: 44, height: 44).background(.black.opacity(0.4), in: Circle())
                }
                .accessibilityLabel("Close")
                Spacer()
                ShareLink(item: url) {
                    Image(systemName: "square.and.arrow.up").font(.system(size: 16, weight: .semibold)).foregroundStyle(.white)
                        .frame(width: 44, height: 44).background(.black.opacity(0.4), in: Circle())
                }
                .accessibilityLabel("Share image")
            }
            .padding(.horizontal, 12)
        }
        .statusBarHidden()
    }

    private func reset() {
        withAnimation(reduceMotion ? nil : .spring(response: 0.3)) {
            scale = 1; committedScale = 1; offset = .zero; committedOffset = .zero
        }
    }
}
