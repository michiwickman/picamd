import AppKit

/// Native overlay for an `![alt](src)` image. Loads file:// images
/// synchronously (cheap) and http(s) images on a background queue.
final class ImageBlockView: BlockAttachmentView {
    private let imageView = NSImageView()
    private let captionLabel = NSTextField(labelWithString: "")
    private var loadedImageSize: NSSize?

    override func setupContent() {
        layer?.cornerRadius = 6
        layer?.backgroundColor = NSColor(white: 0.5, alpha: 0.04).cgColor

        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.imageAlignment = .alignCenter
        imageView.translatesAutoresizingMaskIntoConstraints = false
        imageView.wantsLayer = true
        imageView.layer?.cornerRadius = 4
        imageView.layer?.masksToBounds = true
        addSubview(imageView)

        captionLabel.translatesAutoresizingMaskIntoConstraints = false
        captionLabel.font = NSFont.systemFont(ofSize: 11)
        captionLabel.textColor = .secondaryLabelColor
        captionLabel.alignment = .center
        captionLabel.lineBreakMode = .byTruncatingTail
        addSubview(captionLabel)

        NSLayoutConstraint.activate([
            imageView.topAnchor.constraint(equalTo: topAnchor, constant: 4),
            imageView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            imageView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            captionLabel.topAnchor.constraint(equalTo: imageView.bottomAnchor, constant: 4),
            captionLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            captionLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            captionLabel.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -4),
        ])

        loadImage()

        // VoiceOver: expose this overlay as an image element with the alt text.
        setAccessibilityElement(true)
        setAccessibilityRole(.image)
        setAccessibilityLabel(altText)
    }

    /// Match the `![alt](src)` pattern once and cache the captured
    /// ranges, so `altText` and `sourceURL` don't both re-run the regex
    /// on every property access.
    private var imageMatch: (alt: String, src: String) {
        let payload = block.payload
        let nsPayload = payload as NSString
        let range = NSRange(location: 0, length: nsPayload.length)
        guard let m = MarkdownRegexes.inlineImage.firstMatch(in: payload, range: range),
              m.numberOfRanges >= 3 else { return ("", "") }
        return (nsPayload.substring(with: m.range(at: 1)),
                nsPayload.substring(with: m.range(at: 2)))
    }

    private var altText: String { imageMatch.alt }
    private var sourceURL: String { imageMatch.src }

    private func loadImage() {
        captionLabel.stringValue = altText
        let src = sourceURL
        guard !src.isEmpty else { return }

        let url: URL?
        if src.hasPrefix("http://") || src.hasPrefix("https://") {
            url = URL(string: src)
        } else if let docDir = documentURL?.deletingLastPathComponent() {
            url = docDir.appendingPathComponent(src)
        } else {
            url = URL(fileURLWithPath: src)
        }

        guard let url = url else {
            captionLabel.stringValue = "🖼  \(altText)  (could not resolve URL)"
            return
        }
        if url.isFileURL {
            if let img = NSImage(contentsOf: url) {
                imageView.image = img
                loadedImageSize = img.size
            } else {
                captionLabel.stringValue = "🖼  \(altText)  (file not found)"
            }
        } else {
            URLSession.shared.dataTask(with: url) { [weak self] data, _, _ in
                guard let self = self, let data = data, let img = NSImage(data: data) else { return }
                DispatchQueue.main.async { [weak self] in
                    guard let self = self else { return }
                    self.imageView.image = img
                    self.loadedImageSize = img.size
                    self.invalidateIntrinsicContentSize()
                    self.needsLayout = true
                }
            }.resume()
        }
    }

    override func desiredHeight(for width: CGFloat) -> CGFloat {
        let captionHeight: CGFloat = altText.isEmpty ? 0 : 18
        let constrainedWidth = explicitWidth.map { min($0, width - 8) } ?? (width - 8)
        if let size = loadedImageSize, size.width > 0 {
            let aspect = size.height / size.width
            let imageWidth = min(constrainedWidth, size.width)
            let imageHeight = imageWidth * aspect
            return imageHeight + captionHeight + 12
        }
        return 200 + captionHeight + 12
    }

    /// Pandoc-style `{width=400}` parsed out of the image syntax. nil
    /// when no explicit width was given.
    private var explicitWidth: CGFloat? {
        let payload = block.payload
        let nsPayload = payload as NSString
        let fullRange = NSRange(location: 0, length: nsPayload.length)
        guard let m = MarkdownRegexes.imageResizeAttribute.firstMatch(in: payload, range: fullRange),
              m.numberOfRanges >= 2 else { return nil }
        let widthString = nsPayload.substring(with: m.range(at: 1))
        return Double(widthString).map { CGFloat($0) }
    }
}
