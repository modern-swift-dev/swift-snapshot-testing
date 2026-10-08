#if os(macOS)
    import Cocoa
    import XCTest

    @MainActor public extension Diffing where Value == NSImage {
        /// A pixel-diffing strategy for NSImage's which requires a 100% match.
        static let image = Diffing.image()

        /// A pixel-diffing strategy for NSImage that allows customizing how precise the matching must be.
        ///
        /// - Parameters:
        ///   - options: The image comparison options.
        /// - Returns: A new diffing strategy.
        static func image(options: ImageSnapshotOptions = .init()) -> Diffing {
            .init(
                toData: { requirePNGData($0) },
                fromDataOptional: { NSImage(data: $0) },
                diffV2: { old, new in
                    // NB: Encode the new image at most once; comparison and failure artifacts share it.
                    var cachedNewPNGData: Data?
                    func newPNGData() -> Data? {
                        if cachedNewPNGData == nil {
                            cachedNewPNGData = NSImagePNGRepresentation(new)
                        }
                        return cachedNewPNGData
                    }
                    guard let message = compare(
                        old, new,
                        newPNGData: newPNGData,
                        precision: options.precision,
                        perceptualPrecision: options.perceptualPrecision
                    ) else {
                        return nil
                    }
                    let difference = SnapshotTesting.diff(old, new)
                    let oldAttachment = DiffAttachment.data(
                        requirePNGData(old),
                        name: "reference.png"
                    )
                    let newAttachment = DiffAttachment.data(
                        newPNGData() ?? requirePNGData(new),
                        name: "failure.png"
                    )
                    let differenceAttachment = DiffAttachment.data(
                        requirePNGData(difference),
                        name: "difference.png"
                    )
                    return (
                        message,
                        [oldAttachment, newAttachment, differenceAttachment]
                    )
                }
            )
        }

        @available(*, deprecated, message: "Use image(options:) instead") static func image(precision: Float = 1, perceptualPrecision: Float = 1) -> Diffing {
            .image(options: .init(precision: precision, perceptualPrecision: perceptualPrecision))
        }
    }

    @MainActor public extension Snapshotting where Value == NSImage, Format == NSImage {
        /// A snapshot strategy for comparing images based on pixel equality.
        static var image: Snapshotting {
            .image()
        }

        /// A snapshot strategy for comparing images based on pixel equality.
        ///
        /// - Parameters:
        ///   - options: The image comparison options.
        ///   - isOpaque: Whether to composite transparency onto white and omit the alpha channel.
        static func image(
            options: ImageSnapshotOptions = .init(),
            isOpaque: Bool = false
        ) -> Snapshotting {
            .init(
                pathExtension: "png",
                diffing: .image(options: options),
                snapshot: { image in
                    let pixelSize = CGSize(width: image.size.width * 2, height: image.size.height * 2)
                    let snapshot: NSImage =
                        if let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil),
                        CGFloat(cgImage.width) >= pixelSize.width,
                        CGFloat(cgImage.height) >= pixelSize.height {
                            image
                        } else {
                            snapshotImage(size: image.size) {
                                image.draw(in: NSRect(origin: .zero, size: image.size))
                            }
                        }
                    return isOpaque ? opaqueImage(snapshot) : snapshot
                }
            )
        }

        @available(*, deprecated, message: "Use image(options:isOpaque:) instead") static func image(
            precision: Float = 1,
            perceptualPrecision: Float = 1,
            isOpaque: Bool = false
        ) -> Snapshotting {
            .image(
                options: .init(precision: precision, perceptualPrecision: perceptualPrecision),
                isOpaque: isOpaque
            )
        }
    }

    @MainActor private func opaqueImage(_ image: NSImage) -> NSImage {
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            preconditionFailure("Could not create an opaque image.")
        }
        let colorSpace = cgImage.colorSpace.flatMap { $0.model == .rgb ? $0 : nil }
            ?? CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGBitmapInfo(
            rawValue: (cgImage.bitmapInfo.rawValue & ~CGBitmapInfo.alphaInfoMask.rawValue)
                | CGImageAlphaInfo.noneSkipLast.rawValue
        )
        guard let context = CGContext(
            data: nil,
            width: cgImage.width,
            height: cgImage.height,
            bitsPerComponent: cgImage.bitsPerComponent,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: bitmapInfo.rawValue
        ) else {
            preconditionFailure("Could not create an opaque image context.")
        }
        context.setFillColor(red: 1, green: 1, blue: 1, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: cgImage.width, height: cgImage.height))
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: cgImage.width, height: cgImage.height))
        guard let opaqueCGImage = context.makeImage() else {
            preconditionFailure("Could not create an opaque image.")
        }
        return NSImage(cgImage: opaqueCGImage, size: image.size)
    }

    private func NSImagePNGRepresentation(_ image: NSImage) -> Data? {
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            return nil
        }
        let rep = NSBitmapImageRep(cgImage: cgImage)
        rep.size = image.size
        return rep.representation(using: .png, properties: [:])
    }

    private func requirePNGData(_ image: NSImage) -> Data {
        guard let data = NSImagePNGRepresentation(image) else {
            fatalError("Could not encode image as PNG.")
        }
        return data
    }

    private func compare(
        _ old: NSImage,
        _ new: NSImage,
        newPNGData: () -> Data?,
        precision: Float,
        perceptualPrecision: Float
    ) -> String? {
        guard let oldCgImage = old.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            return "Reference image could not be loaded."
        }
        guard let newCgImage = new.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            return "Newly-taken snapshot could not be loaded."
        }
        guard newCgImage.width != 0, newCgImage.height != 0 else {
            return "Newly-taken snapshot is empty."
        }
        guard oldCgImage.width == newCgImage.width, oldCgImage.height == newCgImage.height else {
            return "Newly-taken snapshot@\(new.size) does not match reference@\(old.size)."
        }
        guard let oldContext = context(for: oldCgImage), let oldData = oldContext.data else {
            return "Reference image's data could not be loaded."
        }
        guard let newContext = context(for: newCgImage), let newData = newContext.data else {
            return "Newly-taken snapshot's data could not be loaded."
        }
        let byteCount = oldContext.height * oldContext.bytesPerRow
        if memcmp(oldData, newData, byteCount) == 0 {
            return nil
        }
        guard let pngData = newPNGData(),
              let newerCgImage = NSImage(data: pngData)?.cgImage(
                  forProposedRect: nil, context: nil, hints: nil
              ),
              let newerContext = context(for: newerCgImage),
              let newerData = newerContext.data else {
            return "Newly-taken snapshot's data could not be loaded."
        }
        if memcmp(oldData, newerData, byteCount) == 0 {
            return nil
        }
        if precision >= 1, perceptualPrecision >= 1 {
            return "Newly-taken snapshot does not match reference."
        }
        if perceptualPrecision < 1 {
            guard let normalizedOldImage = oldContext.makeImage(),
                  let normalizedNewImage = newerContext.makeImage() else {
                return "Image data could not be normalized."
            }
            return perceptuallyCompare(
                CIImage(cgImage: normalizedOldImage),
                CIImage(cgImage: normalizedNewImage),
                pixelPrecision: precision,
                perceptualPrecision: perceptualPrecision
            )
        } else {
            let oldBytes = oldData.assumingMemoryBound(to: UInt8.self)
            let newBytes = newerData.assumingMemoryBound(to: UInt8.self)
            let byteCountThreshold = Int((1 - precision) * Float(byteCount))
            var differentByteCount = 0
            // NB: We are purposely using a verbose 'while' loop instead of a 'for in' loop.  When the
            //     compiler doesn't have optimizations enabled, like in test targets, a `while` loop is
            //     significantly faster than a `for` loop for iterating through the elements of a memory
            //     buffer. Details can be found in [SR-6983](https://github.com/apple/swift/issues/49531)
            var index = 0
            while index < byteCount {
                defer { index += 1 }
                if oldBytes[index] != newBytes[index] {
                    differentByteCount += 1
                }
            }
            if differentByteCount > byteCountThreshold {
                let actualPrecision = 1 - Float(differentByteCount) / Float(byteCount)
                return "Actual image precision \(actualPrecision) is less than required \(precision)"
            }
        }
        return nil
    }

    private func context(for cgImage: CGImage) -> CGContext? {
        guard let space = CGColorSpace(name: CGColorSpace.sRGB) ?? cgImage.colorSpace,
              let context = CGContext(
                  data: nil,
                  width: cgImage.width,
                  height: cgImage.height,
                  bitsPerComponent: 8,
                  bytesPerRow: cgImage.width * 4,
                  space: space,
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ) else {
            return nil
        }

        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: cgImage.width, height: cgImage.height))
        return context
    }

    private func diff(_ old: NSImage, _ new: NSImage) -> NSImage {
        guard let oldCgImage = old.cgImage(forProposedRect: nil, context: nil, hints: nil),
              let newCgImage = new.cgImage(forProposedRect: nil, context: nil, hints: nil),
              let differenceFilter = CIFilter(name: "CIDifferenceBlendMode") else {
            fatalError("Could not create image difference.")
        }
        let oldCiImage = CIImage(cgImage: oldCgImage)
        let newCiImage = CIImage(cgImage: newCgImage)
        differenceFilter.setValue(oldCiImage, forKey: kCIInputImageKey)
        differenceFilter.setValue(newCiImage, forKey: kCIInputBackgroundImageKey)
        let maxSize = CGSize(
            width: max(old.size.width, new.size.width),
            height: max(old.size.height, new.size.height)
        )
        guard let outputImage = differenceFilter.outputImage else {
            fatalError("Could not create image difference.")
        }
        let rep = NSCIImageRep(ciImage: outputImage)
        let difference = NSImage(size: maxSize)
        difference.addRepresentation(rep)
        return difference
    }
#endif
