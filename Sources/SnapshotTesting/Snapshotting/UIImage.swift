#if os(iOS) || os(tvOS) || os(watchOS)
    #if canImport(CoreImage)
        import CoreImage
    #endif
    import UIKit

    public extension UIImage {
        /// How image orientation affects snapshot comparison.
        enum OrientationComparison: Sendable {
            /// Compare backing pixels and ignore orientation metadata.
            case ignored
            /// Independently render each image upright before comparing its visible pixels.
            case rendered
        }
    }

    @MainActor public extension Diffing where Value == UIImage {
        /// A pixel-diffing strategy for UIImage's which requires a 100% match.
        static let image = Diffing.image(options: .init())

        #if os(watchOS)
            /// A pixel-diffing strategy for `UIImage` that allows customizing how precise matching must be.
            ///
            /// - Parameters:
            ///   - options: The image comparison options.
            ///   - scale: The scale used when loading the reference image from disk. Defaults to `1`.
            static func image(options: ImageSnapshotOptions = .init(), scale: CGFloat? = nil) -> Diffing {
                imageDiffing(
                    precision: options.precision,
                    perceptualPrecision: 1,
                    scale: scale,
                    orientationComparison: .ignored
                )
            }

            @available(*, deprecated, message: "Use image(options:scale:) instead")
            @_disfavoredOverload static func image(precision: Float = 1, scale: CGFloat? = nil) -> Diffing {
                .image(options: .init(precision: precision), scale: scale)
            }
        #else
            /// A pixel-diffing strategy for UIImage that allows customizing how precise the matching must be.
            ///
            /// - Parameters:
            ///   - options: The image comparison options.
            ///   - scale: Scale to use when loading the reference image from disk. If `nil` or the
            ///     `UITraitCollection`s default value of `0.0`, the screens scale is used.
            ///   - orientationComparison: How image orientation affects comparison.
            /// - Returns: A new diffing strategy.
            static func image(
                options: ImageSnapshotOptions = .init(),
                scale: CGFloat? = nil,
                orientationComparison: UIImage.OrientationComparison = .ignored
            ) -> Diffing {
                imageDiffing(
                    precision: options.precision,
                    perceptualPrecision: options.perceptualPrecision,
                    scale: scale,
                    orientationComparison: orientationComparison
                )
            }

            @available(*, deprecated, message: "Use image(options:scale:orientationComparison:) instead") static func image(
                precision: Float = 1,
                perceptualPrecision: Float = 1,
                scale: CGFloat? = nil,
                orientationComparison: UIImage.OrientationComparison = .ignored
            ) -> Diffing {
                .image(
                    options: .init(precision: precision, perceptualPrecision: perceptualPrecision),
                    scale: scale,
                    orientationComparison: orientationComparison
                )
            }
        #endif

        private static func imageDiffing(
            precision: Float,
            perceptualPrecision: Float,
            scale: CGFloat?,
            orientationComparison: UIImage.OrientationComparison
        ) -> Diffing {
            let imageScale: CGFloat = if let scale, scale != 0.0 {
                scale
            } else {
                #if os(watchOS)
                    1
                #else
                    UIScreen.main.scale
                #endif
            }
            let toData: @MainActor @Sendable (UIImage) -> Data = {
                var image = $0
                #if !os(watchOS)
                    if case .rendered = orientationComparison {
                        image = renderedUp(image)
                    }
                #endif
                guard let data = image.pngData() ?? emptyImage().pngData() else {
                    fatalError("Could not encode image as PNG.")
                }
                return data
            }
            return .init(
                toData: toData,
                fromDataOptional: { UIImage(data: $0, scale: imageScale) },
                diffV2: { old, new in
                    var old = old
                    var new = new.size == .zero ? emptyImage() : new
                    switch orientationComparison {
                        case .ignored:
                            old = old.cgImage.map {
                                UIImage(cgImage: $0, scale: old.scale, orientation: new.imageOrientation)
                            } ?? old
                        case .rendered:
                            #if !os(watchOS)
                                old = renderedUp(old)
                                new = renderedUp(new)
                            #endif
                    }
                    guard let message = compare(
                        old, new, precision: precision, perceptualPrecision: perceptualPrecision
                    ) else {
                        return nil
                    }
                    let difference = SnapshotTesting.diff(old, new)
                    let referenceAttachment = DiffAttachment.data(toData(old), name: "reference.png")
                    let failureAttachment = DiffAttachment.data(toData(new), name: "failure.png")
                    let differenceAttachment = DiffAttachment.data(toData(difference), name: "difference.png")
                    return (
                        message,
                        [referenceAttachment, failureAttachment, differenceAttachment]
                    )
                }
            )
        }

        /// Used when the image size has no width or no height to generated the default empty image
        private static func emptyImage() -> UIImage {
            #if os(watchOS)
                let colorSpace = CGColorSpaceCreateDeviceRGB()
                guard let context = CGContext(
                    data: nil,
                    width: 1,
                    height: 1,
                    bitsPerComponent: 8,
                    bytesPerRow: 4,
                    space: colorSpace,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                ), let image = context.makeImage() else {
                    preconditionFailure("Could not create an empty image placeholder.")
                }
                return UIImage(cgImage: image)
            #else
                let label = UILabel(frame: CGRect(x: 0, y: 0, width: 400, height: 80))
                label.backgroundColor = .red
                label.text =
                    "Error: No image could be generated for this view as its size was zero. Please set an explicit size in the test."
                label.textAlignment = .center
                label.numberOfLines = 3
                return label.asImage()
            #endif
        }
    }

    @MainActor public extension Snapshotting where Value == UIImage, Format == UIImage {
        /// A snapshot strategy for comparing images based on pixel equality.
        static var image: Snapshotting {
            .image(options: .init())
        }

        #if os(watchOS)
            /// A snapshot strategy for comparing images based on pixel equality.
            ///
            /// - Parameters:
            ///   - options: The image comparison options.
            ///   - scale: The scale of the reference image stored on disk. Defaults to `1`.
            ///   - isOpaque: Whether to composite transparency onto white and omit the alpha channel.
            static func image(
                options: ImageSnapshotOptions = .init(),
                scale: CGFloat? = nil,
                isOpaque: Bool = false
            ) -> Snapshotting {
                .init(
                    pathExtension: "png",
                    diffing: .image(options: options, scale: scale),
                    snapshot: { isOpaque ? opaqueImage($0) : $0 }
                )
            }

            @available(*, deprecated, message: "Use image(options:scale:isOpaque:) instead")
            @_disfavoredOverload static func image(
                precision: Float = 1,
                scale: CGFloat? = nil,
                isOpaque: Bool = false
            ) -> Snapshotting {
                .image(options: .init(precision: precision), scale: scale, isOpaque: isOpaque)
            }
        #else
            /// A snapshot strategy for comparing images based on pixel equality.
            ///
            /// - Parameters:
            ///   - options: The image comparison options.
            ///   - scale: The scale of the reference image stored on disk.
            ///   - isOpaque: Whether to composite transparency onto white and omit the alpha channel.
            ///   - orientationComparison: How image orientation affects comparison.
            static func image(
                options: ImageSnapshotOptions = .init(),
                scale: CGFloat? = nil,
                isOpaque: Bool = false,
                orientationComparison: UIImage.OrientationComparison = .ignored
            ) -> Snapshotting {
                .init(
                    pathExtension: "png",
                    diffing: .image(
                        options: options,
                        scale: scale,
                        orientationComparison: orientationComparison
                    ),
                    snapshot: { isOpaque ? opaqueImage($0) : $0 }
                )
            }

            @available(*, deprecated, message: "Use image(options:scale:isOpaque:orientationComparison:) instead") static func image(
                precision: Float = 1,
                perceptualPrecision: Float = 1,
                scale: CGFloat? = nil,
                isOpaque: Bool = false,
                orientationComparison: UIImage.OrientationComparison = .ignored
            ) -> Snapshotting {
                .image(
                    options: .init(precision: precision, perceptualPrecision: perceptualPrecision),
                    scale: scale,
                    isOpaque: isOpaque,
                    orientationComparison: orientationComparison
                )
            }
        #endif
    }

    #if !os(watchOS)
        @MainActor private func renderedUp(_ image: UIImage) -> UIImage {
            guard image.imageOrientation != .up else {
                return image
            }
            let format = UIGraphicsImageRendererFormat()
            format.scale = image.scale
            format.preferredRange = .standard
            return UIGraphicsImageRenderer(size: image.size, format: format).image { _ in
                image.draw(in: CGRect(origin: .zero, size: image.size))
            }
        }
    #endif

    @MainActor private func opaqueImage(_ image: UIImage) -> UIImage {
        let cgImage: CGImage?
        #if canImport(CoreImage)
            cgImage = image.cgImage ?? image.ciImage.flatMap {
                CIContext().createCGImage($0, from: $0.extent)
            }
        #else
            cgImage = image.cgImage
        #endif
        guard let cgImage else {
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
        return UIImage(cgImage: opaqueCGImage, scale: image.scale, orientation: image.imageOrientation)
    }

    // remap snapshot & reference to same colorspace
    private let imageContextColorSpace = CGColorSpace(name: CGColorSpace.sRGB)
    private let imageContextBitsPerComponent = 8
    private let imageContextBytesPerPixel = 4

    private func compare(_ old: UIImage, _ new: UIImage, precision: Float, perceptualPrecision: Float)
        -> String? {
        guard let oldCgImage = old.cgImage else {
            return "Reference image could not be loaded."
        }
        guard let newCgImage = new.cgImage else {
            return "Newly-taken snapshot could not be loaded."
        }
        guard newCgImage.width != 0, newCgImage.height != 0 else {
            return "Newly-taken snapshot is empty."
        }
        guard oldCgImage.width == newCgImage.width, oldCgImage.height == newCgImage.height else {
            return "Newly-taken snapshot@\(new.size) does not match reference@\(old.size)."
        }
        let pixelCount = oldCgImage.width * oldCgImage.height
        let byteCount = imageContextBytesPerPixel * pixelCount
        guard let oldContext = context(for: oldCgImage),
              let oldData = oldContext.data else {
            return "Reference image's data could not be loaded."
        }
        if let newContext = context(for: newCgImage), let newData = newContext.data {
            if memcmp(oldData, newData, byteCount) == 0 {
                return nil
            }
        }
        guard let pngData = new.pngData(),
              let newerCgImage = UIImage(data: pngData)?.cgImage,
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
        #if !os(watchOS)
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
            }
        #endif
        let oldBytes = oldData.assumingMemoryBound(to: UInt8.self)
        let newerBytes = newerData.assumingMemoryBound(to: UInt8.self)
        let byteCountThreshold = Int((1 - precision) * Float(byteCount))
        var differentByteCount = 0
        // NB: We are purposely using a verbose 'while' loop over raw pointers instead of a 'for in'
        //     loop over arrays. When the compiler doesn't have optimizations enabled, like in test
        //     targets, this is significantly faster for iterating through the elements of a memory
        //     buffer. Details can be found in [SR-6983](https://github.com/apple/swift/issues/49531)
        var index = 0
        withExtendedLifetime((oldContext, newerContext)) {
            while index < byteCount {
                defer { index += 1 }
                if oldBytes[index] != newerBytes[index] {
                    differentByteCount += 1
                }
            }
        }
        if differentByteCount > byteCountThreshold {
            let actualPrecision = 1 - Float(differentByteCount) / Float(byteCount)
            return "Actual image precision \(actualPrecision) is less than required \(precision)"
        }
        return nil
    }

    private func context(for cgImage: CGImage) -> CGContext? {
        let bytesPerRow = cgImage.width * imageContextBytesPerPixel
        guard let colorSpace = imageContextColorSpace,
              let context = CGContext(
                  data: nil,
                  width: cgImage.width,
                  height: cgImage.height,
                  bitsPerComponent: imageContextBitsPerComponent,
                  bytesPerRow: bytesPerRow,
                  space: colorSpace,
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ) else {
            return nil
        }

        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: cgImage.width, height: cgImage.height))
        return context
    }

    private func diff(_ old: UIImage, _ new: UIImage) -> UIImage {
        #if os(watchOS)
            // ponytail: Size mismatches attach the failure image; add a Core Graphics compositor if needed.
            normalizedComponentDiff(old, new) ?? new
        #else
            normalizedComponentDiff(old, new)
                ?? blendModeDiff(old, new)
        #endif
    }

    #if !os(watchOS)
        private func blendModeDiff(_ old: UIImage, _ new: UIImage) -> UIImage {
            let width = max(old.size.width, new.size.width)
            let height = max(old.size.height, new.size.height)
            let scale = max(old.scale, new.scale)
            UIGraphicsBeginImageContextWithOptions(CGSize(width: width, height: height), true, scale)
            new.draw(at: .zero)
            old.draw(at: .zero, blendMode: .difference, alpha: 1)
            guard let differenceImage = UIGraphicsGetImageFromCurrentImageContext() else {
                fatalError("Could not create image difference.")
            }
            UIGraphicsEndImageContext()
            return differenceImage
        }
    #endif

    private func normalizedComponentDiff(_ old: UIImage, _ new: UIImage) -> UIImage? {
        guard let oldCgImage = old.cgImage,
              let pngData = new.pngData(),
              let newCgImage = UIImage(data: pngData)?.cgImage,
              oldCgImage.width == newCgImage.width,
              oldCgImage.height == newCgImage.height else {
            return nil
        }

        guard let outputColorSpace = CGColorSpace(name: CGColorSpace.linearGray),
              let outputFormat = vImage_CGImageFormat(
                  bitsPerComponent: imageContextBitsPerComponent,
                  bitsPerPixel: imageContextBitsPerComponent,
                  colorSpace: outputColorSpace,
                  bitmapInfo: .init()
              ) else {
            return nil
        }

        let width = oldCgImage.width
        let height = oldCgImage.height
        let pixelCount = width * height
        let scale = old.scale

        guard let oldContext = context(for: oldCgImage),
              let oldData = oldContext.data,
              let newContext = context(for: newCgImage),
              let newData = newContext.data else {
            return nil
        }
        let oldBytes = oldData.assumingMemoryBound(to: UInt8.self)
        let newBytes = newData.assumingMemoryBound(to: UInt8.self)
        var diffBytes = [UInt8](repeating: 0, count: pixelCount)
        withExtendedLifetime((oldContext, newContext)) {
            diffBytes.withUnsafeMutableBufferPointer { diffBuffer in
                guard let diffPixels = diffBuffer.baseAddress else {
                    return
                }

                var index = 0
                while index < pixelCount {
                    defer { index += 1 }
                    let pixelOffset = index * imageContextBytesPerPixel

                    let rOld = Int16(oldBytes[pixelOffset])
                    let gOld = Int16(oldBytes[pixelOffset + 1])
                    let bOld = Int16(oldBytes[pixelOffset + 2])
                    let aOld = Int16(oldBytes[pixelOffset + 3])

                    let rNew = Int16(newBytes[pixelOffset])
                    let gNew = Int16(newBytes[pixelOffset + 1])
                    let bNew = Int16(newBytes[pixelOffset + 2])
                    let aNew = Int16(newBytes[pixelOffset + 3])

                    let rDiff = abs(rOld - rNew)
                    let gDiff = abs(gOld - gNew)
                    let bDiff = abs(bOld - bNew)
                    let aDiff = abs(aOld - aNew)

                    let maxDiff = max(rDiff, gDiff, bDiff, aDiff)
                    diffPixels[index] = UInt8(maxDiff)
                }
            }
        }

        let outputCgImage: CGImage? = diffBytes.withUnsafeMutableBytes { diffPtr in
            var diffBuffer = vImage_Buffer(
                data: diffPtr.baseAddress,
                height: vImagePixelCount(height),
                width: vImagePixelCount(width),
                rowBytes: width
            )

            do {
                var normalizedBuffer = try vImage_Buffer(
                    width: width,
                    height: height,
                    bitsPerPixel: UInt32(imageContextBitsPerComponent)
                )
                defer { normalizedBuffer.free() }

                let error = vImageContrastStretch_Planar8(
                    &diffBuffer,
                    &normalizedBuffer,
                    vImage_Flags(kvImageNoFlags)
                )

                let buffer = error == kvImageNoError ? normalizedBuffer : diffBuffer

                return try buffer.createCGImage(format: outputFormat)
            } catch {
                return nil
            }
        }

        guard let outputCgImage else {
            return nil
        }

        return UIImage(cgImage: outputCgImage, scale: scale, orientation: new.imageOrientation)
    }
#endif

#if os(iOS) || os(tvOS) || os(watchOS) || os(macOS)
    import Accelerate.vImage
#endif

#if os(iOS) || os(tvOS) || os(macOS)
    import CoreImage.CIKernel
    import MetalPerformanceShaders

    // Setting the working color space and output color space to NSNull disables color management. This is appropriate when the output
    // of the operations is computational instead of an image intended to be displayed.
    // NB: Creating a context is expensive, so share one. Core Image contexts are safe to share across threads.
    private let perceptualComparisonContext = CIContext(
        options: [.workingColorSpace: NSNull(), .outputColorSpace: NSNull()]
    )

    @available(iOS 10.0, tvOS 10.0, macOS 10.13, *) func perceptuallyCompare(
        _ old: CIImage, _ new: CIImage, pixelPrecision: Float, perceptualPrecision: Float
    ) -> String? {
        // Calculate the deltaE values. Each pixel is a value between 0-100.
        // 0 means no difference, 100 means completely opposite.
        let deltaOutputImage = old.applyingLabDeltaE(new)
        let context = perceptualComparisonContext
        let deltaThreshold = (1 - perceptualPrecision) * 100
        let actualPixelPrecision: Float
        var maximumDeltaE: Float = 0

        // Metal is supported by all iOS/tvOS devices (2013 models or later) and Macs (2012 models or later).
        // Older devices do not support iOS/tvOS 13 and macOS 10.15 which are the minimum versions of swift-snapshot-testing.
        // However, some virtualized hardware do not have GPUs and therefore do not support Metal.
        // In this case, macOS falls back to a CPU-based OpenGL ES renderer that silently fails when a Metal command is issued.
        // We need to check for Metal device support and fallback to CPU based vImage buffer iteration.
        if ThresholdImageProcessorKernel.isSupported {
            // Fast path - Metal processing
            guard let thresholdOutputImage = try? deltaOutputImage.applyingThreshold(deltaThreshold),
                  let averagePixel = thresholdOutputImage.applyingAreaAverage().renderSingleValue(in: context) else {
                return "Newly-taken snapshot's data could not be processed."
            }
            actualPixelPrecision = 1 - averagePixel
            if actualPixelPrecision < pixelPrecision {
                maximumDeltaE = deltaOutputImage.applyingAreaMaximum().renderSingleValue(in: context) ?? 0
            }
        } else {
            // Slow path - CPU based vImage buffer iteration
            guard let buffer = deltaOutputImage.render(in: context) else {
                return "Newly-taken snapshot could not be processed."
            }
            defer { buffer.free() }
            var failingPixelCount = 0
            // rowBytes must be a multiple of 8, so vImage_Buffer pads the end of each row with bytes to meet the multiple of 0 requirement.
            // We must do 2D iteration of the vImage_Buffer in order to avoid loading the padding garbage bytes at the end of each row.
            //
            // NB: We are purposely using a verbose 'while' loop instead of a 'for in' loop.  When the
            //     compiler doesn't have optimizations enabled, like in test targets, a `while` loop is
            //     significantly faster than a `for` loop for iterating through the elements of a memory
            //     buffer. Details can be found in [SR-6983](https://github.com/apple/swift/issues/49531)
            let componentStride = MemoryLayout<Float>.stride
            var line = 0
            while line < buffer.height {
                defer { line += 1 }
                let lineOffset = buffer.rowBytes * line
                var column = 0
                while column < buffer.width {
                    defer { column += 1 }
                    let byteOffset = lineOffset + column * componentStride
                    let deltaE = buffer.data.load(fromByteOffset: byteOffset, as: Float.self)
                    if deltaE > deltaThreshold {
                        failingPixelCount += 1
                        if deltaE > maximumDeltaE {
                            maximumDeltaE = deltaE
                        }
                    }
                }
            }
            let failingPixelPercent =
                Float(failingPixelCount)
                    / Float(deltaOutputImage.extent.width * deltaOutputImage.extent.height)
            actualPixelPrecision = 1 - failingPixelPercent
        }

        guard actualPixelPrecision < pixelPrecision else {
            return nil
        }
        // The actual perceptual precision is the perceptual precision of the pixel with the highest DeltaE.
        // DeltaE is in a 0-100 scale, so we need to divide by 100 to transform it to a percentage.
        let minimumPerceptualPrecision = 1 - min(maximumDeltaE / 100, 1)
        return """
        The percentage of pixels that match \(actualPixelPrecision) is less than required \(pixelPrecision)
        The lowest perceptual color precision \(minimumPerceptualPrecision) is less than required \(perceptualPrecision)
        """
    }

    extension CIImage {
        func applyingLabDeltaE(_ other: CIImage) -> CIImage {
            applyingFilter("CILabDeltaE", parameters: ["inputImage2": other])
        }

        func applyingThreshold(_ threshold: Float) throws -> CIImage {
            try ThresholdImageProcessorKernel.apply(
                withExtent: extent,
                inputs: [self],
                arguments: [ThresholdImageProcessorKernel.inputThresholdKey: threshold]
            )
        }

        func applyingAreaAverage() -> CIImage {
            applyingFilter("CIAreaAverage", parameters: [kCIInputExtentKey: extent])
        }

        func applyingAreaMaximum() -> CIImage {
            applyingFilter("CIAreaMaximum", parameters: [kCIInputExtentKey: extent])
        }

        func renderSingleValue(in context: CIContext) -> Float? {
            guard let buffer = render(in: context) else {
                return nil
            }
            defer { buffer.free() }
            return buffer.data.load(fromByteOffset: 0, as: Float.self)
        }

        func render(in context: CIContext, format: CIFormat = CIFormat.Rh) -> vImage_Buffer? {
            // Some hardware configurations (virtualized CPU renderers) do not support 32-bit float output formats,
            // so use a compatible 16-bit float format and convert the output value to 32-bit floats.
            guard var buffer16 = try? vImage_Buffer(
                width: Int(extent.width), height: Int(extent.height), bitsPerPixel: 16
            ) else {
                return nil
            }
            defer { buffer16.free() }
            context.render(
                self,
                toBitmap: buffer16.data,
                rowBytes: buffer16.rowBytes,
                bounds: extent,
                format: format,
                colorSpace: nil
            )
            guard var buffer32 = try? vImage_Buffer(
                width: Int(buffer16.width), height: Int(buffer16.height), bitsPerPixel: 32
            ),
                vImageConvert_Planar16FtoPlanarF(&buffer16, &buffer32, 0) == kvImageNoError else {
                return nil
            }
            return buffer32
        }
    }

    /// Copied from https://developer.apple.com/documentation/coreimage/ciimageprocessorkernel
    @available(iOS 10.0, tvOS 10.0, macOS 10.13, *) final class ThresholdImageProcessorKernel: CIImageProcessorKernel {
        static let inputThresholdKey = "thresholdValue"
        static let device = MTLCreateSystemDefaultDevice()

        static var isSupported: Bool {
            guard let device else {
                return false
            }
            return MPSSupportsMTLDevice(device)
        }

        override static func process(
            with inputs: [CIImageProcessorInput]?, arguments: [String: Any]?,
            output: CIImageProcessorOutput
        ) throws {
            guard let device,
                  let commandBuffer = output.metalCommandBuffer,
                  let input = inputs?.first,
                  let sourceTexture = input.metalTexture,
                  let destinationTexture = output.metalTexture,
                  let thresholdValue = arguments?[inputThresholdKey] as? Float else {
                return
            }

            let threshold = MPSImageThresholdBinary(
                device: device,
                thresholdValue: thresholdValue,
                maximumValue: 1.0,
                linearGrayColorTransform: nil
            )

            threshold.encode(
                commandBuffer: commandBuffer,
                sourceTexture: sourceTexture,
                destinationTexture: destinationTexture
            )
        }
    }
#endif
