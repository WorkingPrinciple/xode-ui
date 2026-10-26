// SPDX-License-Identifier: GPL-3.0-only
#if !XODUS_SHIPPING
import CoreML
import Vision

enum NativeCheckOCR {
    struct Unavailable: LocalizedError {
        let reason: String
        var errorDescription: String? { "OCR unavailable: \(reason)" }
    }

    static func recognize(_ image: CGImage, level: VNRequestTextRecognitionLevel = .accurate) throws -> [String] {
        try recognize { cpuOnly in
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = level
            if cpuOnly {
                for (stage, devices) in try request.supportedComputeStageDevices {
                    if let cpu = devices.first(where: { if case .cpu = $0 { return true }; return false }) {
                        request.setComputeDevice(cpu, for: stage)
                    }
                }
            }
            try VNImageRequestHandler(cgImage: image).perform([request])
            return (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }
        }
    }

    static func recognize(attempt: (Bool) throws -> [String]) throws -> [String] {
        let firstFailure: String
        do {
            let labels = try attempt(false)
            if !labels.isEmpty { return labels }
            firstFailure = "default compute returned no text"
        } catch { firstFailure = error.localizedDescription }
        do {
            let labels = try attempt(true)
            guard !labels.isEmpty else { throw Unavailable(reason: "CPU compute returned no text") }
            return labels
        } catch {
            throw Unavailable(reason: "\(firstFailure); CPU retry: \(error.localizedDescription)")
        }
    }

    static func checks(_ check: (Bool, String) -> Void) {
        var attempts: [Bool] = []
        do {
            let labels = try recognize { cpu in
                attempts.append(cpu)
                if !cpu { throw Unavailable(reason: "forced accelerator failure") }
                return ["Recovered"]
            }
            check(labels == ["Recovered"] && attempts == [false, true],
                  "OCR retries a failed accelerator exactly once on CPU")
        } catch { check(false, error.localizedDescription) }
        attempts = []
        do {
            let labels = try recognize { cpu in
                attempts.append(cpu)
                return cpu ? ["Recovered"] : []
            }
            check(labels == ["Recovered"] && attempts == [false, true],
                  "OCR retries empty recognition exactly once on CPU")
        } catch { check(false, error.localizedDescription) }
        do {
            _ = try recognize { _ in throw Unavailable(reason: "forced recognition failure") }
            check(false, "Forced OCR failure must be explicit")
        } catch {
            check(error.localizedDescription.contains("OCR unavailable:")
                  && error.localizedDescription.contains("forced recognition failure"),
                  "Forced OCR failure reports OCR unavailable and the underlying error")
        }
    }
}
#endif
