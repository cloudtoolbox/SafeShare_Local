import AppKit
import Foundation
import PDFKit
import Vision

final class PDFRedactionEngine {
    func burnInRedactions(
        sourcePDFURL: URL,
        pageMaps: [DocumentPageTextMap],
        entities: [RedactionEntity],
        includeFaceDetection: Bool,
        outputURL: URL
    ) throws {
        guard let source = PDFDocument(url: sourcePDFURL) else {
            throw NSError(domain: "PDFRedactionEngine", code: 1, userInfo: [NSLocalizedDescriptionKey: "Cannot open source PDF"])
        }

        let accepted = entities.filter { $0.decision != .keep }
        let rectsByPage = buildPageRects(pageMaps: pageMaps, entities: accepted, source: source)

        let output = PDFDocument()
        for pageIndex in 0..<source.pageCount {
            guard let page = source.page(at: pageIndex) else { continue }
            let mediaBounds = page.bounds(for: .mediaBox)

            let image = NSImage(size: mediaBounds.size)
            image.lockFocusFlipped(false)
            guard let cg = NSGraphicsContext.current?.cgContext else {
                image.unlockFocus()
                continue
            }

            cg.setFillColor(NSColor.white.cgColor)
            cg.fill(CGRect(origin: .zero, size: mediaBounds.size))

            cg.saveGState()
            page.draw(with: .mediaBox, to: cg)
            cg.restoreGState()

            var allRects = rectsByPage[pageIndex] ?? []
            if includeFaceDetection {
                allRects.append(contentsOf: detectFaceRects(on: page, mediaBounds: mediaBounds))
            }
            allRects.append(contentsOf: detectAuthorizingProviderRects(on: page, mediaBounds: mediaBounds))

            cg.setFillColor(NSColor.black.cgColor)
            for rect in mergeNearbyRects(allRects) {
                let normalized = clampRect(rect, pageBounds: mediaBounds)
                if normalized.width > 0 && normalized.height > 0 {
                    cg.fill(normalized)
                }
            }

            image.unlockFocus()
            if let redactedPage = PDFPage(image: image) {
                output.insert(redactedPage, at: output.pageCount)
            }
        }

        guard output.write(to: outputURL) else {
            throw NSError(domain: "PDFRedactionEngine", code: 2, userInfo: [NSLocalizedDescriptionKey: "Failed to write redacted PDF"])
        }
    }

    private func buildPageRects(pageMaps: [DocumentPageTextMap], entities: [RedactionEntity], source: PDFDocument) -> [Int: [CGRect]] {
        var result: [Int: [CGRect]] = [:]
        guard !pageMaps.isEmpty else { return result }

        for entity in entities {
            for pageMap in pageMaps {
                let pageStart = pageMap.globalStartOffset
                let pageEnd = pageMap.globalEndOffset
                let overlapStart = max(entity.startOffset, pageStart)
                let overlapEnd = min(entity.endOffset, pageEnd)
                guard overlapEnd > overlapStart else { continue }

                let localStart = overlapStart - pageStart
                let localEnd = overlapEnd - pageStart
                guard let page = source.page(at: pageMap.pageIndex) else { continue }

                var rects = spanRects(page: page, pageText: pageMap.pageText, start: localStart, end: localEnd)
                if rects.isEmpty {
                    rects = fallbackRectsByValue(page: page, pageText: pageMap.pageText, value: entity.rawValue)
                }
                if !rects.isEmpty {
                    result[pageMap.pageIndex, default: []].append(contentsOf: rects)
                }
            }
        }

        for key in result.keys {
            result[key] = mergeNearbyRects(result[key] ?? [])
        }

        return result
    }

    private func spanRects(page: PDFPage, pageText: String, start: Int, end: Int) -> [CGRect] {
        guard start >= 0, end > start else { return [] }
        guard start < pageText.count else { return [] }

        let clampedEnd = min(end, pageText.count)
        guard let startIndex = pageText.index(pageText.startIndex, offsetBy: start, limitedBy: pageText.endIndex),
              let endIndex = pageText.index(pageText.startIndex, offsetBy: clampedEnd, limitedBy: pageText.endIndex)
        else { return [] }

        let nsRange = NSRange(startIndex..<endIndex, in: pageText)
        guard nsRange.length > 0 else { return [] }

        if let selection = page.selection(for: nsRange) {
            let lineSelections = selection.selectionsByLine()
            let rects = lineSelections.compactMap { line -> CGRect? in
                let rect = line.bounds(for: page).insetBy(dx: -1.5, dy: -1.5)
                return (rect.isNull || rect.isEmpty) ? nil : rect
            }
            if !rects.isEmpty {
                return mergeNearbyRects(rects)
            }
        }

        var rawRects: [CGRect] = []
        for idx in nsRange.location..<(nsRange.location + nsRange.length) {
            let rect = page.characterBounds(at: idx)
            if rect.isNull || rect.isEmpty { continue }
            let expanded = rect.insetBy(dx: -1.5, dy: -1.5)
            rawRects.append(expanded)
        }

        return mergeNearbyRects(rawRects)
    }

    private func fallbackRectsByValue(page: PDFPage, pageText: String, value: String) -> [CGRect] {
        let needle = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return [] }

        if let range = pageText.range(of: needle, options: [.caseInsensitive]) {
            let nsRange = NSRange(range, in: pageText)
            if let selection = page.selection(for: nsRange) {
                let rects = selection.selectionsByLine().compactMap { line -> CGRect? in
                    let rect = line.bounds(for: page).insetBy(dx: -1.5, dy: -1.5)
                    return (rect.isNull || rect.isEmpty) ? nil : rect
                }
                if !rects.isEmpty {
                    return mergeNearbyRects(rects)
                }
            }
        }
        return []
    }

    private func mergeNearbyRects(_ rects: [CGRect]) -> [CGRect] {
        guard !rects.isEmpty else { return [] }
        let sorted = rects.sorted {
            if abs($0.midY - $1.midY) < 3 {
                return $0.minX < $1.minX
            }
            return $0.midY > $1.midY
        }

        var merged: [CGRect] = []
        for rect in sorted {
            if var last = merged.last,
               abs(last.midY - rect.midY) < 4,
               rect.minX <= last.maxX + 6 {
                last = last.union(rect)
                merged[merged.count - 1] = last
            } else {
                merged.append(rect)
            }
        }
        return merged
    }

    private func clampRect(_ rect: CGRect, pageBounds: CGRect) -> CGRect {
        let x = max(pageBounds.minX, min(rect.minX, pageBounds.maxX))
        let y = max(pageBounds.minY, min(rect.minY, pageBounds.maxY))
        let maxX = max(pageBounds.minX, min(rect.maxX, pageBounds.maxX))
        let maxY = max(pageBounds.minY, min(rect.maxY, pageBounds.maxY))
        return CGRect(x: x, y: y, width: max(0, maxX - x), height: max(0, maxY - y))
    }

    private func detectFaceRects(on page: PDFPage, mediaBounds: CGRect) -> [CGRect] {
        let renderScale = faceDetectionScale(for: mediaBounds)
        let pixelSize = CGSize(width: mediaBounds.width * renderScale, height: mediaBounds.height * renderScale)

        var rects: [CGRect] = []

        if let thumbnail = page.thumbnail(of: pixelSize, for: .mediaBox).cgImage(forProposedRect: nil, context: nil, hints: nil) {
            rects.append(contentsOf: detectFaceRects(in: thumbnail, mediaBounds: mediaBounds))
        }

        if let renderedPage = renderPageForVision(page: page, pixelSize: pixelSize) {
            if rects.isEmpty {
                rects.append(contentsOf: detectFaceRects(in: renderedPage, mediaBounds: mediaBounds))
            }
            rects.append(contentsOf: detectAvatarLikeRects(in: renderedPage, mediaBounds: mediaBounds))
        }

        return mergeNearbyRects(rects)
    }

    private func detectAuthorizingProviderRects(on page: PDFPage, mediaBounds: CGRect) -> [CGRect] {
        let renderScale = faceDetectionScale(for: mediaBounds)
        let pixelSize = CGSize(width: mediaBounds.width * renderScale, height: mediaBounds.height * renderScale)

        if let renderedPage = renderPageForVision(page: page, pixelSize: pixelSize) {
            return detectAuthorizingProviderRects(in: renderedPage, mediaBounds: mediaBounds)
        }
        if let thumbnail = page.thumbnail(of: pixelSize, for: .mediaBox).cgImage(forProposedRect: nil, context: nil, hints: nil) {
            return detectAuthorizingProviderRects(in: thumbnail, mediaBounds: mediaBounds)
        }
        return []
    }

    private func detectAuthorizingProviderRects(in image: CGImage, mediaBounds: CGRect) -> [CGRect] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true

        let handler = VNImageRequestHandler(cgImage: image, orientation: .up, options: [:])
        do {
            try handler.perform([request])
        } catch {
            return []
        }

        return (request.results ?? []).compactMap { observation in
            guard let text = observation.topCandidates(1).first?.string,
                  let labelRange = text.range(
                    of: #"authorizing\s+provider\s*:"#,
                    options: [.regularExpression, .caseInsensitive]
                  )
            else {
                return nil
            }

            let name = text[labelRange.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
            guard name.split(whereSeparator: \.isWhitespace).count >= 2 else { return nil }

            let totalCount = max(1, text.count)
            let redactionStart = text.distance(from: text.startIndex, to: labelRange.upperBound)
            let startRatio = min(0.95, max(0, CGFloat(redactionStart) / CGFloat(totalCount)))

            let box = observation.boundingBox
            let lineX = box.minX * mediaBounds.width
            let lineY = box.minY * mediaBounds.height
            let lineW = box.width * mediaBounds.width
            let lineH = box.height * mediaBounds.height
            let x = lineX + lineW * startRatio - 4
            return CGRect(x: x, y: lineY - 2, width: lineX + lineW - x + 4, height: lineH + 4)
        }
    }

    private func detectFaceRects(in image: CGImage, mediaBounds: CGRect) -> [CGRect] {
        let request = VNDetectFaceRectanglesRequest()
        request.revision = VNDetectFaceRectanglesRequestRevision3
        let handler = VNImageRequestHandler(cgImage: image, orientation: .up, options: [:])
        do {
            try handler.perform([request])
        } catch {
            return []
        }

        guard let results = request.results, !results.isEmpty else { return [] }

        return results.compactMap { face in
            let box = face.boundingBox
            let x = box.minX * mediaBounds.width
            let y = box.minY * mediaBounds.height
            let w = box.width * mediaBounds.width
            let h = box.height * mediaBounds.height

            let padding = max(10, min(w, h) * 0.35)
            let expanded = CGRect(x: x, y: y, width: w, height: h).insetBy(dx: -padding, dy: -padding)
            return expanded
        }
    }

    private func faceDetectionScale(for mediaBounds: CGRect) -> CGFloat {
        let longestSide = max(mediaBounds.width, mediaBounds.height)
        guard longestSide > 0 else { return 3 }
        return max(3, min(6, 2200 / longestSide))
    }

    private func renderPageForVision(page: PDFPage, pixelSize: CGSize) -> CGImage? {
        let width = max(1, Int(pixelSize.width.rounded(.up)))
        let height = max(1, Int(pixelSize.height.rounded(.up)))
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return nil
        }

        context.setFillColor(NSColor.white.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.scaleBy(x: pixelSize.width / page.bounds(for: .mediaBox).width, y: pixelSize.height / page.bounds(for: .mediaBox).height)
        page.draw(with: .mediaBox, to: context)
        return context.makeImage()
    }

    private func detectAvatarLikeRects(in image: CGImage, mediaBounds: CGRect) -> [CGRect] {
        let width = image.width
        let height = image.height
        guard width > 0, height > 0 else { return [] }

        let bytesPerPixel = 4
        let bytesPerRow = width * bytesPerPixel
        var pixels = [UInt8](repeating: 0, count: height * bytesPerRow)
        guard let context = CGContext(
            data: &pixels,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return []
        }

        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))

        let step = max(1, Int((max(mediaBounds.width, mediaBounds.height) / 900).rounded(.up)))
        let gridWidth = max(1, width / step)
        let gridHeight = max(1, height / step)
        var mask = [Bool](repeating: false, count: gridWidth * gridHeight)

        for gy in 0..<gridHeight {
            for gx in 0..<gridWidth {
                let px = min(width - 1, gx * step)
                let py = min(height - 1, gy * step)
                let offset = py * bytesPerRow + px * bytesPerPixel
                let r = CGFloat(pixels[offset]) / 255.0
                let g = CGFloat(pixels[offset + 1]) / 255.0
                let b = CGFloat(pixels[offset + 2]) / 255.0
                let maxChannel = max(r, g, b)
                let minChannel = min(r, g, b)
                let saturation = maxChannel == 0 ? 0 : (maxChannel - minChannel) / maxChannel
                let brightness = maxChannel

                if saturation > 0.05 && brightness > 0.16 && brightness < 0.98 {
                    mask[gy * gridWidth + gx] = true
                }
            }
        }

        mask = dilate(mask: mask, width: gridWidth, height: gridHeight, radius: max(2, Int((4 / step))))

        var visited = [Bool](repeating: false, count: mask.count)
        var rects: [CGRect] = []

        for start in mask.indices where mask[start] && !visited[start] {
            var stack = [start]
            visited[start] = true
            var count = 0
            var minX = gridWidth
            var maxX = 0
            var minY = gridHeight
            var maxY = 0

            while let current = stack.popLast() {
                count += 1
                let x = current % gridWidth
                let y = current / gridWidth
                minX = min(minX, x)
                maxX = max(maxX, x)
                minY = min(minY, y)
                maxY = max(maxY, y)

                let neighbors = [
                    (x - 1, y), (x + 1, y), (x, y - 1), (x, y + 1)
                ]
                for (nx, ny) in neighbors where nx >= 0 && nx < gridWidth && ny >= 0 && ny < gridHeight {
                    let next = ny * gridWidth + nx
                    guard mask[next], !visited[next] else { continue }
                    visited[next] = true
                    stack.append(next)
                }
            }

            let pixelMinX = CGFloat(minX * step)
            let pixelMaxX = CGFloat(min(width, (maxX + 1) * step))
            let pixelMinY = CGFloat(minY * step)
            let pixelMaxY = CGFloat(min(height, (maxY + 1) * step))
            let pdfWidth = (pixelMaxX - pixelMinX) / CGFloat(width) * mediaBounds.width
            let pdfHeight = (pixelMaxY - pixelMinY) / CGFloat(height) * mediaBounds.height
            let aspect = pdfWidth / max(1, pdfHeight)
            let fillRatio = CGFloat(count * step * step) / max(1, (pixelMaxX - pixelMinX) * (pixelMaxY - pixelMinY))

            guard pdfWidth >= 8,
                  pdfHeight >= 8,
                  pdfWidth <= 110,
                  pdfHeight <= 110,
                  aspect >= 0.55,
                  aspect <= 1.8,
                  fillRatio >= 0.04 else {
                continue
            }

            let pdfX = pixelMinX / CGFloat(width) * mediaBounds.width
            let pdfY = mediaBounds.height - (pixelMaxY / CGFloat(height) * mediaBounds.height)
            let padding = max(4, min(pdfWidth, pdfHeight) * 0.18)
            rects.append(CGRect(x: pdfX, y: pdfY, width: pdfWidth, height: pdfHeight).insetBy(dx: -padding, dy: -padding))
        }

        return avatarRectsByMergingFragments(rects)
    }

    private func dilate(mask: [Bool], width: Int, height: Int, radius: Int) -> [Bool] {
        guard radius > 0 else { return mask }
        var output = mask
        for y in 0..<height {
            for x in 0..<width where mask[y * width + x] {
                for dy in -radius...radius {
                    for dx in -radius...radius {
                        guard dx * dx + dy * dy <= radius * radius else { continue }
                        let nx = x + dx
                        let ny = y + dy
                        guard nx >= 0, nx < width, ny >= 0, ny < height else { continue }
                        output[ny * width + nx] = true
                    }
                }
            }
        }
        return output
    }

    private func avatarRectsByMergingFragments(_ rects: [CGRect]) -> [CGRect] {
        guard !rects.isEmpty else { return [] }
        let sorted = rects.sorted { $0.minX < $1.minX }
        var merged: [CGRect] = []

        for rect in sorted {
            var candidate = rect
            var consumedIndices: [Int] = []
            for (idx, existing) in merged.enumerated() {
                let expanded = existing.insetBy(dx: -14, dy: -14)
                if expanded.intersects(candidate) {
                    candidate = existing.union(candidate)
                    consumedIndices.append(idx)
                }
            }

            for idx in consumedIndices.reversed() {
                merged.remove(at: idx)
            }
            merged.append(candidate)
        }

        return merged.compactMap { rect in
            let aspect = rect.width / max(1, rect.height)
            guard rect.width >= 14,
                  rect.height >= 14,
                  rect.width <= 120,
                  rect.height <= 120,
                  aspect >= 0.45,
                  aspect <= 2.0 else {
                return nil
            }
            let padding = max(5, min(rect.width, rect.height) * 0.12)
            return rect.insetBy(dx: -padding, dy: -padding)
        }
    }
}
