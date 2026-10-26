// SPDX-License-Identifier: GPL-3.0-only
#if !XODUS_SHIPPING
import CoreML
import AppKit
import Vision

enum NativeCheckOCR {
    struct Unavailable: LocalizedError {
        let reason: String
        var errorDescription: String? { "OCR unavailable: \(reason)" }
    }

    static func recognize(_ image: CGImage, level: VNRequestTextRecognitionLevel = .accurate) throws -> [String] {
        try observations(image, level: level).compactMap { $0.topCandidates(1).first?.string }
    }

    static func observations(_ image: CGImage, level: VNRequestTextRecognitionLevel = .accurate,
                             minimumTextHeight: Float = 0) throws -> [VNRecognizedTextObservation] {
        try recognize { attempt in
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = level
            request.minimumTextHeight = minimumTextHeight
            if attempt > 0 {
                for (stage, devices) in try request.supportedComputeStageDevices {
                    if let cpu = devices.first(where: { if case .cpu = $0 { return true }; return false }) {
                        request.setComputeDevice(cpu, for: stage)
                    }
                }
            }
            if attempt == 2 {
                guard let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else {
                    throw Unavailable(reason: "PNG encoding failed")
                }
                try VNImageRequestHandler(data: png).perform([request])
            } else {
                try VNImageRequestHandler(cgImage: image).perform([request])
            }
            return request.results ?? []
        }
    }

    static func recognize<Value>(pause: () -> Void = { Thread.sleep(forTimeInterval: 0.5) },
                                 attempt: (Int) throws -> [Value]) throws -> [Value] {
        var failures: [String] = []
        for index in 0..<3 {
            if index > 0 { pause() }
            do {
                let labels = try attempt(index)
                if !labels.isEmpty { return labels }
                failures.append("attempt \(index + 1) returned no text")
            } catch { failures.append("attempt \(index + 1): \(error.localizedDescription)") }
        }
        throw Unavailable(reason: failures.joined(separator: "; "))
    }

    static func checks(_ check: (Bool, String) -> Void) {
        var attempts: [Int] = []
        do {
            let labels = try recognize(pause: {}) { index in
                attempts.append(index)
                if index == 0 { throw Unavailable(reason: "forced accelerator failure") }
                return ["Recovered"]
            }
            check(labels == ["Recovered"] && attempts == [0, 1],
                  "OCR retries a failed accelerator exactly once on CPU")
        } catch { check(false, error.localizedDescription) }
        attempts = []
        do {
            let labels = try recognize(pause: {}) { index in
                attempts.append(index)
                return index > 0 ? ["Recovered"] : []
            }
            check(labels == ["Recovered"] && attempts == [0, 1],
                  "OCR retries empty recognition exactly once on CPU")
        } catch { check(false, error.localizedDescription) }
        do {
            let _: [String] = try recognize(pause: {}) { _ in throw Unavailable(reason: "forced recognition failure") }
            check(false, "Forced OCR failure must be explicit")
        } catch {
            check(error.localizedDescription.contains("OCR unavailable:")
                  && error.localizedDescription.contains("forced recognition failure"),
                  "Forced OCR failure reports OCR unavailable and the underlying error")
        }
        attempts = []
        var pauses = 0
        do {
            let labels = try recognize(pause: { pauses += 1 }) { index in
                attempts.append(index)
                if index < 2 { throw Unavailable(reason: "forced image reader failure") }
                return ["PNG recovery"]
            }
            check(labels == ["PNG recovery"] && attempts == [0, 1, 2] && pauses == 2,
                  "OCR backs off before CPU and PNG retries and stops after recovery")
        } catch { check(false, error.localizedDescription) }
    }
}
#endif
