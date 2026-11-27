import UIKit
import Vision
import VisionKit

/// Apple's on-device text recogniser, made dependable on this phone.
///
/// Kubera runs outside the sandbox as a platform app (TrollStore). There the recogniser's usual setup can fail or come
/// back empty, so several setups are tried in turn: the accurate recogniser on the Neural Engine, then on the CPU, older
/// revisions, the fast recogniser, and last Live Text (VisionKit). The first setup that reads any text is kept for the
/// rest of the session. Each failure is written to the diagnostic log once.
enum TextReader {
    struct Setup: CustomStringConvertible {
        var revision: Int
        var accurate: Bool
        var cpuOnly: Bool
        var description: String { "rev\(revision) \(accurate ? "accurate" : "fast")\(cpuOnly ? " cpu" : "")" }
    }

    static let setups: [Setup] = {
        let revisions = VNRecognizeTextRequest.supportedRevisions.sorted(by: >)
        var s: [Setup] = []
        for r in revisions {
            s.append(Setup(revision: r, accurate: true, cpuOnly: false))
            s.append(Setup(revision: r, accurate: true, cpuOnly: true))
        }
        for r in revisions { s.append(Setup(revision: r, accurate: false, cpuOnly: true)) }
        return s
    }()

    enum Outcome {
        case lines([OCRLine])
        case empty
        case failed(String)
    }

    private static let lock = NSLock()
    private static var chosen: Int?            // index of the setup that has read text this session
    private static var liveTextOnly = false    // no Vision setup reads anything here; Live Text does
    private static var logged = Set<String>()

    private static func once(_ key: String, _ message: @autoclosure () -> String) {
        lock.lock(); let fresh = logged.insert(key).inserted; lock.unlock()
        if fresh { Diag.log(message()) }
    }

    private static func ms(since t: Date) -> Int { Int(Date().timeIntervalSince(t) * 1000) }

    /// Lines of text in the picture, top first. Empty when nothing could be read.
    static func lines(in cg: CGImage) async -> [OCRLine] {
        lock.lock(); let skipVision = liveTextOnly; lock.unlock()
        if !skipVision {
            let found: [OCRLine]? = await withCheckedContinuation { cont in
                DispatchQueue.global(qos: .userInitiated).async { cont.resume(returning: visionLines(cg)) }
            }
            if let found { return found }
        }
        let lt = await liveText(cg)
        if !lt.isEmpty && !skipVision {
            lock.lock(); liveTextOnly = true; lock.unlock()
            Diag.log("text reader: using Live Text (\(lt.count) lines)")
        }
        return lt
    }

    /// nil when no setup read anything, so Live Text should have a go.
    private static func visionLines(_ cg: CGImage) -> [OCRLine]? {
        lock.lock(); let start = chosen; lock.unlock()
        if let i = start {
            switch run(setups[i], on: cg) {
            case .lines(let l): return l
            case .empty: return []   // this setup works, so the picture has no text
            case .failed(let why): once("fail\(i)", "text reader \(setups[i]) failed: \(why)")
            }
        }
        for (i, s) in setups.enumerated() where i != start {
            let t0 = Date()
            switch run(s, on: cg) {
            case .lines(let l):
                lock.lock(); chosen = i; lock.unlock()
                once("use\(i)", "text reader: using \(s) (\(l.count) lines, \(ms(since: t0)) ms)")
                return l
            case .empty:
                once("empty\(i)", "text reader \(s): no text (\(ms(since: t0)) ms)")
            case .failed(let why):
                once("fail\(i)", "text reader \(s) failed: \(why) (\(ms(since: t0)) ms)")
            }
        }
        return nil
    }

    static func run(_ setup: Setup, on cg: CGImage) -> Outcome {
        let req = VNRecognizeTextRequest()
        req.revision = setup.revision
        req.recognitionLevel = setup.accurate ? .accurate : .fast
        req.usesLanguageCorrection = false
        // Small enough for phone UI text, which is about 1/60 of a screenshot's height.
        req.minimumTextHeight = 1.0 / 96
        if setup.cpuOnly { req.usesCPUOnly = true }
        let handler = VNImageRequestHandler(cgImage: cg, orientation: .up, options: [:])
        do {
            try handler.perform([req])
        } catch {
            let e = error as NSError
            return .failed("\(e.domain) \(e.code) \(e.localizedDescription)")
        }
        let observations = req.results ?? []
        let pixels = observations.isEmpty ? nil : PixelSampler(cg)
        var out: [OCRLine] = []
        for o in observations {
            guard let top = o.topCandidates(1).first else { continue }
            let b = o.boundingBox // origin bottom-left, normalised
            var line = OCRLine(text: top.string, x: Double(b.minX), y: Double(1 - b.maxY), w: Double(b.width), h: Double(b.height))
            line.tint = pixels?.tint(in: b) ?? 0
            out.append(line)
        }
        return out.isEmpty ? .empty : .lines(out)
    }

    /// Live Text reads the picture in a system service. It gives the text in reading order without positions or
    /// colours, so lines are spaced evenly down the page and signs come only from "+" / "-".
    @MainActor
    static func liveText(_ cg: CGImage) async -> [OCRLine] {
        guard ImageAnalyzer.isSupported else { once("lt-unsupported", "Live Text is not supported here"); return [] }
        do {
            let analysis = try await ImageAnalyzer().analyze(cg, orientation: .up, configuration: ImageAnalyzer.Configuration([.text]))
            let rows = analysis.transcript.components(separatedBy: .newlines)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
            let n = Double(max(rows.count, 1))
            return rows.enumerated().map { i, t in OCRLine(text: t, x: 0.05, y: Double(i) / n, w: 0.9, h: 0.8 / n) }
        } catch {
            let e = error as NSError
            once("lt-fail", "Live Text failed: \(e.domain) \(e.code) \(e.localizedDescription)")
            return []
        }
    }

    /// Every setup on one picture, for the diagnostic log.
    static func probe(_ cg: CGImage) async -> [String] {
        var out = ["picture \(cg.width)x\(cg.height) bpc=\(cg.bitsPerComponent) bpp=\(cg.bitsPerPixel) alpha=\(cg.alphaInfo.rawValue) space=\(cg.colorSpace?.name.map { $0 as String } ?? "-")",
                   "revisions \(Array(VNRecognizeTextRequest.supportedRevisions))"]
        for s in setups {
            let t0 = Date()
            let r: Outcome = await withCheckedContinuation { cont in
                DispatchQueue.global(qos: .userInitiated).async { cont.resume(returning: run(s, on: cg)) }
            }
            switch r {
            case .lines(let l): out.append("\(s): \(l.count) lines in \(ms(since: t0)) ms, first \"\(l.first?.text ?? "")\"")
            case .empty: out.append("\(s): no text in \(ms(since: t0)) ms")
            case .failed(let why): out.append("\(s): failed in \(ms(since: t0)) ms: \(why)")
            }
        }
        let t0 = Date()
        let lt = await liveText(cg)
        out.append("Live Text: \(lt.count) lines in \(ms(since: t0)) ms, first \"\(lt.first?.text ?? "")\"")
        return out
    }
}
