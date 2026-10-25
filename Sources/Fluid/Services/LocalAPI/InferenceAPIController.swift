import Foundation

@MainActor
final class InferenceAPIController: LocalAPIRouteHandler {
    struct TranscribeJSONRequest: Decodable {
        let path: String?
        let audioBase64: String?
        let filename: String?
    }

    struct TextRequest: Decodable {
        let text: String
    }

    struct TranscribeResponse: Encodable {
        let text: String
        let confidence: Float
        let sampleCount: Int
        let provider: String
        var words: [WordBody]?
        var segments: [SegmentBody]?
    }

    struct WordBody: Encodable {
        let text: String
        let start: Double
        let end: Double
    }

    struct SegmentBody: Encodable {
        let text: String
        let start: Double
        let end: Double
    }

    struct PostprocessResponse: Encodable {
        let text: String
        let provider: String
        let model: String
    }

    func handle(_ request: LocalAPI.Request) async -> LocalAPI.Response {
        guard request.method == "POST" else {
            return LocalAPI.error("Method not allowed.", status: 405)
        }

        switch request.path {
        case "/v1/transcribe":
            return await self.transcribe(request)
        case "/v1/postprocess":
            return await self.postprocess(request)
        default:
            return LocalAPI.error("Route not found.", status: 404)
        }
    }

    private func transcribe(_ request: LocalAPI.Request) async -> LocalAPI.Response {
        do {
            if let fileURL = try self.decodeFilePath(from: request) {
                return try await self.transcribeFile(fileURL, request: request)
            }

            let temporaryFileURL = try await self.decodeUploadedAudioFile(from: request)
            do {
                let response = try await self.transcribeFile(temporaryFileURL, request: request)
                await LocalAPIAudioDecoder.removeTemporaryFile(at: temporaryFileURL)
                return response
            } catch {
                await LocalAPIAudioDecoder.removeTemporaryFile(at: temporaryFileURL)
                throw error
            }
        } catch let error as ASRActivityError {
            // POC: a client can tell "busy" (503) from "bad request" (400).
            return LocalAPI.error("busy: \(error.localizedDescription)", status: 503)
        } catch {
            return LocalAPI.error(error.localizedDescription, status: 400)
        }
    }

    private func flag(_ request: LocalAPI.Request, _ name: String) -> Bool {
        ["1", "true", "yes"].contains(request.query[name]?.lowercased() ?? "")
    }

    /// Sentence-ish segments from word timings: split at sentence-final punctuation or a pause of 0.8 s.
    private static func segments(from words: [ASRWordTiming]) -> [SegmentBody] {
        var result: [SegmentBody] = []
        var current: [ASRWordTiming] = []
        func close() {
            guard let first = current.first, let last = current.last else { return }
            result.append(SegmentBody(text: current.map(\.text).joined(separator: " "), start: first.start, end: last.end))
            current = []
        }
        for word in words {
            if let last = current.last, word.start - last.end > 0.8 { close() }
            current.append(word)
            if let ch = word.text.last, ".?!".contains(ch) { close() }
        }
        close()
        return result
    }

    private func transcribeFile(_ fileURL: URL, request: LocalAPI.Request) async throws -> LocalAPI.Response {
        let raw = self.flag(request, "raw")
        let wantWords = self.flag(request, "words") || self.flag(request, "segments")
        guard raw || wantWords else { return try await self.transcribeFile(fileURL) }
        let detailed = try await AppServices.shared.asr.transcribeDetailedForAPI(fileURL, raw: raw, wantWords: wantWords)
        return LocalAPI.json(
            TranscribeResponse(
                text: detailed.text,
                confidence: detailed.confidence,
                sampleCount: detailed.sampleCount,
                provider: SettingsStore.shared.selectedSpeechModel.displayName,
                words: self.flag(request, "words") ? detailed.words.map { WordBody(text: $0.text, start: $0.start, end: $0.end) } : nil,
                segments: self.flag(request, "segments") ? Self.segments(from: detailed.words) : nil
            )
        )
    }

    private func transcribeFile(_ fileURL: URL) async throws -> LocalAPI.Response {
        let apiResult = try await AppServices.shared.asr.transcribeFileForAPI(fileURL)
        return LocalAPI.json(
            TranscribeResponse(
                text: apiResult.result.text,
                confidence: apiResult.result.confidence,
                sampleCount: apiResult.sampleCount,
                provider: SettingsStore.shared.selectedSpeechModel.displayName
            )
        )
    }

    private func decodeFilePath(from request: LocalAPI.Request) throws -> URL? {
        guard self.isJSON(request) else { return nil }
        let payload: TranscribeJSONRequest
        do {
            payload = try LocalAPI.decoder.decode(TranscribeJSONRequest.self, from: request.body)
        } catch {
            throw NSError(domain: "InferenceAPIController", code: -3, userInfo: [NSLocalizedDescriptionKey: "Invalid JSON audio payload."])
        }

        guard let path = payload.path, !path.isEmpty else { return nil }
        return URL(fileURLWithPath: path)
    }

    private func postprocess(_ request: LocalAPI.Request) async -> LocalAPI.Response {
        do {
            let text = try self.decodeText(from: request)
            let result = try await DictationPostProcessingService.shared.process(text)
            return LocalAPI.json(
                PostprocessResponse(
                    text: result.text,
                    provider: result.providerID,
                    model: result.model
                )
            )
        } catch {
            return LocalAPI.error(error.localizedDescription, status: 400)
        }
    }

    private func decodeUploadedAudioFile(from request: LocalAPI.Request) async throws -> URL {
        let data: Data
        let suggestedExtension: String
        if self.isJSON(request) {
            let payload: TranscribeJSONRequest
            do {
                payload = try LocalAPI.decoder.decode(TranscribeJSONRequest.self, from: request.body)
            } catch {
                throw NSError(domain: "InferenceAPIController", code: -3, userInfo: [NSLocalizedDescriptionKey: "Invalid JSON audio payload."])
            }

            if let audioBase64 = payload.audioBase64,
               let decodedData = Data(base64Encoded: audioBase64)
            {
                data = decodedData
                suggestedExtension = payload.filename.flatMap { URL(fileURLWithPath: $0).pathExtension } ?? "wav"
            } else {
                throw NSError(domain: "InferenceAPIController", code: -1, userInfo: [NSLocalizedDescriptionKey: "Missing audio path or audioBase64."])
            }
        } else {
            guard !request.body.isEmpty else {
                throw NSError(domain: "InferenceAPIController", code: -1, userInfo: [NSLocalizedDescriptionKey: "Missing audio body."])
            }

            data = request.body
            let filename = request.headers["x-filename"] ?? "audio.wav"
            suggestedExtension = URL(fileURLWithPath: filename).pathExtension
        }

        return try await LocalAPIAudioDecoder.temporaryFile(
            fromAudioData: data,
            suggestedExtension: suggestedExtension
        )
    }

    private func decodeText(from request: LocalAPI.Request) throws -> String {
        if self.isJSON(request) {
            let payload: TextRequest
            do {
                payload = try LocalAPI.decoder.decode(TextRequest.self, from: request.body)
            } catch {
                throw NSError(domain: "InferenceAPIController", code: -4, userInfo: [NSLocalizedDescriptionKey: "Invalid JSON text payload."])
            }
            return payload.text
        }

        guard let text = String(data: request.body, encoding: .utf8) else {
            throw NSError(domain: "InferenceAPIController", code: -2, userInfo: [NSLocalizedDescriptionKey: "Text body must be UTF-8."])
        }
        return text
    }

    private func isJSON(_ request: LocalAPI.Request) -> Bool {
        request.headers["content-type"]?.lowercased().contains("application/json") == true
    }
}
