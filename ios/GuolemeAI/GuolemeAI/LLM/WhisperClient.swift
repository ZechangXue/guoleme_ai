import Foundation

enum WhisperClient {
    static func transcribe(pcm: Data, sampleRate: Int, apiKey: String) async throws -> (text: String, language: String?) {
        let wav = pcm16ToWav(pcm, sampleRate: sampleRate)
        let boundary = "Boundary-\(UUID().uuidString)"
        var body = Data()
        func append(_ string: String) { body.append(Data(string.utf8)) }

        append("--\(boundary)\r\n")
        append("Content-Disposition: form-data; name=\"model\"\r\n\r\nwhisper-1\r\n")
        append("--\(boundary)\r\n")
        append("Content-Disposition: form-data; name=\"response_format\"\r\n\r\nverbose_json\r\n")
        append("--\(boundary)\r\n")
        append("Content-Disposition: form-data; name=\"file\"; filename=\"segment.wav\"\r\n")
        append("Content-Type: audio/wav\r\n\r\n")
        body.append(wav)
        append("\r\n--\(boundary)--\r\n")

        var request = URLRequest(url: URL(string: "https://api.openai.com/v1/audio/transcriptions")!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.httpBody = body

        let (data, response) = try await URLSession.shared.data(for: request)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(code) else {
            throw LLMError.http(code, String(data: data, encoding: .utf8) ?? "")
        }
        let obj = (try JSONSerialization.jsonObject(with: data)) as? [String: Any]
        let text = (obj?["text"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let language = obj?["language"] as? String
        return (text, language)
    }

    static func pcm16ToWav(_ pcm: Data, sampleRate: Int) -> Data {
        var header = Data(count: 44)
        let dataSize = UInt32(pcm.count)
        header.replaceSubrange(0..<4, with: Data("RIFF".utf8))
        header.replaceSubrange(4..<8, with: withUnsafeBytes(of: UInt32(36 + dataSize).littleEndian) { Data($0) })
        header.replaceSubrange(8..<12, with: Data("WAVE".utf8))
        header.replaceSubrange(12..<16, with: Data("fmt ".utf8))
        header.replaceSubrange(16..<20, with: withUnsafeBytes(of: UInt32(16).littleEndian) { Data($0) })
        header.replaceSubrange(20..<22, with: withUnsafeBytes(of: UInt16(1).littleEndian) { Data($0) })
        header.replaceSubrange(22..<24, with: withUnsafeBytes(of: UInt16(1).littleEndian) { Data($0) })
        header.replaceSubrange(24..<28, with: withUnsafeBytes(of: UInt32(sampleRate).littleEndian) { Data($0) })
        let byteRate = UInt32(sampleRate * 2)
        header.replaceSubrange(28..<32, with: withUnsafeBytes(of: byteRate.littleEndian) { Data($0) })
        header.replaceSubrange(32..<34, with: withUnsafeBytes(of: UInt16(2).littleEndian) { Data($0) })
        header.replaceSubrange(34..<36, with: withUnsafeBytes(of: UInt16(16).littleEndian) { Data($0) })
        header.replaceSubrange(36..<40, with: Data("data".utf8))
        header.replaceSubrange(40..<44, with: withUnsafeBytes(of: dataSize.littleEndian) { Data($0) })
        return header + pcm
    }
}
