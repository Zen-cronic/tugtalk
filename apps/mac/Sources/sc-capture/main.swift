// sc-capture: run the companion's on-device pipeline on an image file, with no Screen Recording
// permission. Prints the exact JSON body the companion would send.
//
//   sc-capture --image Fixtures/meeting-prep.png --dry-run
//   sc-capture --image Fixtures/meeting-prep.png --show-ocr --dry-run      (also prints the raw OCR to stderr)
//   sc-capture --image f.png --post --base-url http://127.0.0.1:4319 --token-file /path/local-token.txt [--goal-id ID]
//
// --post only talks to a server on this machine (127.0.0.1 or localhost), for local testing.
import CoreGraphics
import Foundation
import ScreenContextCore

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(2)
}

var options: [String: String] = [:]
var flags: Set<String> = []
var arguments = CommandLine.arguments.dropFirst().makeIterator()
while let argument = arguments.next() {
    switch argument {
    case "--dry-run", "--post", "--show-ocr": flags.insert(argument)
    case "--image", "--app-name", "--goal-id", "--purpose", "--language", "--base-url", "--token-file":
        guard let value = arguments.next() else { fail("Missing value for \(argument)") }
        options[argument] = value
    default: fail("Unknown argument \(argument). See the header of Sources/sc-capture/main.swift.")
    }
}
guard let imagePath = options["--image"] else { fail("Usage: sc-capture --image file.png [--dry-run | --post ...]") }
guard let purpose = ScreenContextPayload.Purpose(rawValue: options["--purpose"] ?? "meeting_prep") else { fail("Unknown --purpose") }

let image: CGImage
do { image = try ImageLoading.cgImage(at: URL(fileURLWithPath: imagePath)) } catch { fail("Cannot read \(imagePath)") }
let ocr: String
do { ocr = try VisionTextReader().read(image) } catch { fail("OCR failed: \(error.localizedDescription)") }
if flags.contains("--show-ocr") { FileHandle.standardError.write(Data(("--- OCR (stays on this Mac) ---\n" + ocr + "\n---\n").utf8)) }
let redacted = Redactor().redact(ocr)
guard let payload = ScreenContextPayload.make(redacted: redacted, appName: options["--app-name"] ?? "TextEdit", goalID: options["--goal-id"],
                                              purpose: purpose, language: options["--language"] ?? "en") else { fail("No text found in the image.") }
let body = try payload.encoded()

if !flags.contains("--post") {
    let pretty = try JSONSerialization.data(withJSONObject: try JSONSerialization.jsonObject(with: body), options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
    print(String(decoding: pretty, as: UTF8.self))
    FileHandle.standardError.write(Data("\(body.count) bytes, \(payload.text.count) characters, redactions \(redacted.total)\n".utf8))
    exit(0)
}

guard let base = options["--base-url"].flatMap(URL.init(string:)), let host = base.host, ["127.0.0.1", "localhost", "::1"].contains(host) else {
    fail("--post needs --base-url pointing at this machine (127.0.0.1 or localhost).")
}
guard let tokenFile = options["--token-file"],
      let token = try? String(contentsOfFile: tokenFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines), !token.isEmpty else {
    fail("--post needs --token-file with a local test token.")
}
let api = CoachAPI(baseURL: base, token: token)
let key = CoachAPI.newIdempotencyKey(prefix: "sc-capture")
do {
    let receipt = try await api.postScreenContext(payload, idempotencyKey: key)
    print("receipt \(receipt.receipt_id) record \(receipt.record.id) v\(receipt.record_version) replayed \(receipt.replayed)")
    print("summary: \(receipt.record.analysis.summary)")
    print("next step: \(receipt.record.analysis.next_step)")
} catch {
    fail("POST failed: \(error.localizedDescription)")
}
