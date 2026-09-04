import AppKit
import CMedia
import Metal

if CommandLine.arguments.contains("--probe-video"),
  let index = CommandLine.arguments.firstIndex(of: "--probe-video"),
  CommandLine.arguments.count > index + 1
{
  var error = [CChar](repeating: 0, count: 256)
  guard let decoder = mz_open(CommandLine.arguments[index + 1], 1, 1, &error, 256) else {
    fputs(String(cString: error) + "\n", stderr)
    exit(1)
  }
  var frame = MZFrame()
  var video = 0
  var audio = 0
  var hardware = 0
  var seconds = 0.0
  let start = ProcessInfo.processInfo.systemUptime
  while video < 120 && mz_next(decoder, &frame) == 1 {
    if frame.kind == 1 {
      video += 1
      hardware += frame.hardware != 0 ? 1 : 0
      seconds = frame.seconds
    } else {
      audio += Int(frame.samples)
    }
  }
  let duration = mz_duration(decoder)
  let seek = mz_seek(decoder, 0) == 1
  mz_close(decoder)
  let info: [String: Any] = [
    "videoFrames": video, "hardwareFrames": hardware, "audioSamples": audio, "lastPTS": seconds,
    "duration": duration, "seekToStart": seek,
    "decodeSeconds": ProcessInfo.processInfo.systemUptime - start,
  ]
  print(
    String(
      data: try! JSONSerialization.data(
        withJSONObject: info, options: [.prettyPrinted, .sortedKeys]), encoding: .utf8)!)
  exit(video > 0 ? 0 : 1)
}
if let index = CommandLine.arguments.firstIndex(of: "--diagnose"),
  CommandLine.arguments.count > index + 1
{
  let root = URL(fileURLWithPath: CommandLine.arguments[index + 1])
  let start = ProcessInfo.processInfo.systemUptime
  var entries: [MediaEntry] = []
  let result = Scanner.scan(root: root, cancellation: Cancellation()) {
    entries.append(contentsOf: $0)
  }
  let scanSeconds = ProcessInfo.processInfo.systemUptime - start
  var groups: [String: Int] = [:]
  for entry in entries {
    groups[(entry.path as NSString).pathExtension.lowercased(), default: 0] += 1
  }
  var measurements: [[String: Any]] = []
  if let device = MTLCreateSystemDefaultDevice() {
    for ext in ["jpg", "png", "webp", "avif", "gif"] {
      if let e = entries.first(where: { ($0.path as NSString).pathExtension.lowercased() == ext }) {
        autoreleasepool {
          let t = ProcessInfo.processInfo.systemUptime
          let image = ImageDecoder.image(path: e.path, limit: 512).flatMap {
            ImageDecoder.prepare($0.0, animated: $0.1, device: device)
          }
          measurements.append([
            "format": ext, "prepared": image != nil,
            "milliseconds": (ProcessInfo.processInfo.systemUptime - t) * 1000,
            "bytes": image?.cost ?? 0,
          ])
        }
      }
    }
  }
  let info: [String: Any] = [
    "entries": result.count, "errors": result.errors, "scanSeconds": scanSeconds, "formats": groups,
    "singleFileTextureProbes": measurements,
  ]
  print(
    String(
      data: try! JSONSerialization.data(
        withJSONObject: info, options: [.prettyPrinted, .sortedKeys]), encoding: .utf8)!)
  exit(0)
}
let app = NSApplication.shared
let controller = AppController()
app.setActivationPolicy(.regular)
app.delegate = controller
app.run()
