import Foundation

@main
struct Benchmark {
  static func main() throws {
    let entries = (0..<100_000).map { i -> MediaEntry in
      let j = (i * 7919) % 100_000
      return MediaEntry(path: "/collection/Game \(j / 1000)/assets/Scene \(j / 100)/photo \(j).webp", size: Int64(j), modified: Double(j), isVideo: false)
    }
    func measure(_ action: () -> [MediaEntry]) -> Double {
      let start = ProcessInfo.processInfo.systemUptime
      let result = action()
      precondition(result.count == entries.count)
      return ProcessInfo.processInfo.systemUptime - start
    }
    let old = measure {
      entries.sorted { a, b in
        let af = (a.path as NSString).deletingLastPathComponent
        let bf = (b.path as NSString).deletingLastPathComponent
        if af != bf { return af.localizedStandardCompare(bf) == .orderedAscending }
        let c = (a.path as NSString).lastPathComponent.localizedStandardCompare((b.path as NSString).lastPathComponent)
        if c != .orderedSame { return c == .orderedAscending }
        return a.path.localizedStandardCompare(b.path) == .orderedAscending
      }
    }
    let updated = measure { SortOrder.name.sorted(entries, grouped: true) }
    let t = ProcessInfo.processInfo.systemUptime
    precondition(Scanner.sameContents(entries, entries.reversed()))
    let unchanged = ProcessInfo.processInfo.systemUptime - t
    var grid = GridLayout()
    grid.rebuild(entries: entries, width: 1900, tile: 90, grouped: false)
    let start = ProcessInfo.processInfo.systemUptime
    var checksum = 0
    for i in 0..<10_000 { checksum += grid.visible(offset: Double(i), height: 1000).count }
    let visible = (ProcessInfo.processInfo.systemUptime - start) * 1_000_000 / 10_000
    let data: [String: Any] = ["entries": entries.count, "legacyGroupedNameSeconds": old, "naturalGroupedNameSeconds": updated, "unchangedComparisonSeconds": unchanged, "visibleMicrosecondsMean": visible, "checksum": checksum]
    print(String(data: try JSONSerialization.data(withJSONObject: data, options: [.prettyPrinted, .sortedKeys]), encoding: .utf8)!)
  }
}
