import Cocoa
import Vision

func check(_ valid: Bool, _ message: String) {
  if !valid { fputs("FAIL: \(message)\n", stderr); exit(1) }
}

let args = CommandLine.arguments
check(args.count == 4, "expected PCM, cue metadata and output paths")
let pcm = try Data(contentsOf: URL(fileURLWithPath: args[1]))
let speech = try NakuSubtitleTools.voiceActivity(pcm)
check(speech.count == pcm.count / 640, "20ms VAD clock")
check(speech.contains(1) && speech.contains(0), "speech and silence both detected")
let silence = try NakuSubtitleTools.voiceActivity(Data(repeating: 0, count: 640 * 300))
check(!silence.contains(1), "silence is never dialogue")
func picture(_ text: String) -> Data {
  let image = NSImage(size: NSSize(width: 1280, height: 720))
  image.lockFocus()
  NSColor.black.setFill(); NSRect(x: 0, y: 0, width: 1280, height: 720).fill()
  let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 44), .foregroundColor: NSColor.white]
  (text as NSString).draw(at: NSPoint(x: 310, y: 65), withAttributes: attrs)
  image.unlockFocus()
  let bitmap = NSBitmapImageRep(data: image.tiffRepresentation!)!
  return bitmap.representation(using: .png, properties: [:])!
}
check(try NakuSubtitleTools.hasChineseCaption(picture("这是自写的中文字幕")), "Chinese picture subtitles detected")
check(try !NakuSubtitleTools.hasChineseCaption(picture("")), "blank image has no subtitles")
var metadata = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: args[2]))) as! [String: Any]
metadata["speech"] = [UInt8](speech)
try JSONSerialization.data(withJSONObject: metadata).write(to: URL(fileURLWithPath: args[3]))
print("Native WebRTC VAD and Vision OCR passed; \(speech.count) frames, \(speech.filter { $0 == 1 }.count) voiced")
