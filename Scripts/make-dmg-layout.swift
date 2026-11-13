// Writes the .DS_Store that makes Finder open the disk image as a laid-out install window: window size,
// icon view, background picture and icon positions.
//
// Usage: swift Scripts/make-dmg-layout.swift <mounted volume> <background file at its root> \
//            <window width> <window height> <icon size> <name>=<x>,<y> [<name>=<x>,<y> ...]
//
// The usual way to get this file is to script Finder and let it write one, but that needs Automation
// permission and a visible window. The file format is small and stable, so this writes it directly, with the
// same records and the same block layout as stores written for other install images:
//   .   bwsp  window bounds and which bars are hidden
//   .   icvl  icon view
//   .   icvp  icon size, text size, and the background picture as a classic alias
//   .   pBBk  the same picture as a bookmark, which newer systems read
//   .   vSrn  1
//   <item>  Iloc  where its icon sits
import Foundation

func fail(_ message: String) -> Never {
    FileHandle.standardError.write((message + "\n").data(using: .utf8)!)
    exit(1)
}

let arguments = CommandLine.arguments
guard arguments.count >= 7, let windowWidth = Int(arguments[3]), let windowHeight = Int(arguments[4]), let iconSize = Double(arguments[5]) else {
    fail("usage: make-dmg-layout.swift <volume> <background> <width> <height> <icon size> <name>=<x>,<y> ...")
}
let volumeURL = URL(fileURLWithPath: arguments[1])
let backgroundName = arguments[2]
let backgroundURL = volumeURL.appendingPathComponent(backgroundName)
var items: [(name: String, x: UInt32, y: UInt32)] = []
for argument in arguments[6...] {
    let parts = argument.split(separator: "=", maxSplits: 1)
    let point = parts.count == 2 ? parts[1].split(separator: ",") : []
    guard point.count == 2, let x = UInt32(point[0]), let y = UInt32(point[1]) else { fail("bad item: \(argument)") }
    items.append((String(parts[0]), x, y))
}

// MARK: Big-endian packing

extension Data {
    mutating func be16(_ value: UInt16) { append(contentsOf: [UInt8(value >> 8), UInt8(value & 0xFF)]) }
    mutating func be32(_ value: UInt32) { for shift in stride(from: 24, through: 0, by: -8) { append(UInt8((value >> UInt32(shift)) & 0xFF)) } }
    mutating func be64(_ value: UInt64) { for shift in stride(from: 56, through: 0, by: -8) { append(UInt8((value >> UInt64(shift)) & 0xFF)) } }
    mutating func ascii(_ string: String) { append(string.data(using: .isoLatin1)!) }
    mutating func utf16(_ string: String) { for unit in string.utf16 { be16(unit) } }
    /// A Pascal string in a fixed field: length byte, text, zero padding.
    mutating func pascal(_ string: String, field: Int) {
        let bytes = [UInt8]((string.data(using: .macOSRoman) ?? Data()).prefix(field - 1))
        append(UInt8(bytes.count))
        append(contentsOf: bytes)
        append(contentsOf: [UInt8](repeating: 0, count: field - 1 - bytes.count))
    }
    mutating func pad(to size: Int) { if count < size { append(contentsOf: [UInt8](repeating: 0, count: size - count)) } }
}

// MARK: What the file system says about the volume and the picture

func status(_ path: String) -> stat {
    var info = stat()
    guard lstat(path, &info) == 0 else { fail("cannot stat \(path)") }
    return info
}

let macEpoch: Int64 = 2_082_844_800 // seconds between 1904 and 1970
let volumeInfo = status(volumeURL.path)
let fileInfo = status(backgroundURL.path)
guard let volumeName = try? volumeURL.resourceValues(forKeys: [.volumeNameKey]).volumeName else { fail("\(volumeURL.path) is not a mounted volume") }
let volumeCreated = UInt64(Int64(volumeInfo.st_birthtimespec.tv_sec) + macEpoch)
let fileCreated = UInt64(Int64(fileInfo.st_birthtimespec.tv_sec) + macEpoch)

// MARK: The background as a classic alias record (version 2)

func aliasRecord() -> Data {
    var record = Data()
    record.be32(0)                           // application signature
    record.be16(0)                           // record size, filled in below
    record.be16(2)                           // version
    record.be16(0)                           // kind: file
    record.pascal(volumeName, field: 28)
    record.be32(UInt32(truncatingIfNeeded: volumeCreated))
    record.ascii("H+")                       // file system
    record.be16(0)                           // disk type: fixed
    record.be32(UInt32(volumeInfo.st_ino))   // parent folder: the volume's root
    record.pascal(backgroundName, field: 64)
    record.be32(UInt32(fileInfo.st_ino))
    record.be32(UInt32(truncatingIfNeeded: fileCreated))
    record.be32(0)                           // creator code
    record.be32(0)                           // type code
    record.be16(0xFFFF)                      // levels from: not relative
    record.be16(0xFFFF)                      // levels to
    record.be32(0)                           // volume attributes
    record.be16(0)                           // file system id
    record.append(contentsOf: [UInt8](repeating: 0, count: 10))

    func tag(_ id: UInt16, _ value: Data) {
        record.be16(id)
        record.be16(UInt16(value.count))
        record.append(value)
        if value.count % 2 == 1 { record.append(0) }
    }
    func text(_ string: String) -> Data { string.data(using: .utf8)! }
    func unicode(_ string: String) -> Data {
        var data = Data()
        data.be16(UInt16(string.utf16.count))
        data.utf16(string)
        return data
    }
    func highResolution(_ seconds: UInt64) -> Data {
        var data = Data()
        data.be64(seconds << 16)
        return data
    }
    tag(0, text(volumeName))                                 // name of the parent folder
    tag(16, highResolution(volumeCreated))
    tag(17, highResolution(fileCreated))
    tag(2, text("\(volumeName):\(backgroundName)"))          // classic path
    tag(14, unicode(backgroundName))
    tag(15, unicode(volumeName))
    tag(18, text("/" + backgroundName))                      // path inside the volume
    tag(19, text(volumeURL.path))                            // where the volume mounts
    record.be16(0xFFFF)                                      // end
    record.be16(0)

    let size = UInt16(record.count)
    record[4] = UInt8(size >> 8)
    record[5] = UInt8(size & 0xFF)
    return record
}

// MARK: Records

let bookmark: Data
do {
    bookmark = try backgroundURL.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
} catch {
    fail("cannot make a bookmark for \(backgroundURL.path): \(error.localizedDescription)")
}

func binaryPlist(_ value: [String: Any]) -> Data {
    guard let data = try? PropertyListSerialization.data(fromPropertyList: value, format: .binary, options: 0) else { fail("cannot encode a property list") }
    return data
}

let windowSettings = binaryPlist([
    "ContainerShowSidebar": false,
    "PreviewPaneVisibility": false,
    "ShowPathbar": false,
    "ShowSidebar": false,
    "ShowStatusBar": false,
    "ShowTabView": false,
    "ShowToolbar": false,
    "SidebarWidth": 180,
    "WindowBounds": "{{200, 160}, {\(windowWidth), \(windowHeight)}}",
])

let iconViewSettings = binaryPlist([
    "arrangeBy": "none",
    "backgroundColorBlue": 1.0,
    "backgroundColorGreen": 1.0,
    "backgroundColorRed": 1.0,
    "backgroundImageAlias": aliasRecord(),
    "backgroundType": 2,
    "gridOffsetX": 0.0,
    "gridOffsetY": 0.0,
    "gridSpacing": 100.0,
    "iconSize": iconSize,
    "labelOnBottom": true,
    "scrollPositionX": 0.0,
    "scrollPositionY": 0.0,
    "showIconPreview": false,
    "showItemInfo": false,
    "textSize": 13.0,
    "viewOptionsVersion": 1,
])

struct Record {
    var name: String
    var id: String
    var type: String
    var payload: Data

    var encoded: Data {
        var data = Data()
        data.be32(UInt32(name.utf16.count))
        data.utf16(name)
        data.ascii(id)
        data.ascii(type)
        data.append(payload)
        return data
    }
}

func blob(_ value: Data) -> Data {
    var data = Data()
    data.be32(UInt32(value.count))
    data.append(value)
    return data
}

func long(_ value: UInt32) -> Data {
    var data = Data()
    data.be32(value)
    return data
}

var records = [
    Record(name: ".", id: "bwsp", type: "blob", payload: blob(windowSettings)),
    Record(name: ".", id: "icvl", type: "type", payload: "icnv".data(using: .ascii)!),
    Record(name: ".", id: "icvp", type: "blob", payload: blob(iconViewSettings)),
    Record(name: ".", id: "pBBk", type: "blob", payload: blob(bookmark)),
    Record(name: ".", id: "vSrn", type: "long", payload: long(1)),
]
for item in items {
    var location = Data()
    location.be32(item.x)
    location.be32(item.y)
    location.append(contentsOf: [0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0x00, 0x00])
    records.append(Record(name: item.name, id: "Iloc", type: "blob", payload: blob(location)))
}
// The store is a B-tree ordered by name, then by record id. Everything here fits in one leaf.
records.sort { ($0.name.lowercased(), $0.id) < ($1.name.lowercased(), $1.id) }

// MARK: The store: a buddy-allocated file with three blocks

// Offsets are counted from byte 4 of the file. Blocks are powers of two, and an address is offset | log2(size).
let infoOffset = 2048, infoSize = 2048        // block 0: the allocator's own tables
let headerOffset = 32, headerSize = 32        // block 1: the tree's header
let nodeOffset = 8192, nodeSize = 8192        // block 2: the one leaf node
let spaceSize = nodeOffset + nodeSize

var node = Data()
node.be32(0)                                  // no child pointer: a leaf
node.be32(UInt32(records.count))
for record in records { node.append(record.encoded) }
guard node.count <= nodeSize else { fail("the layout records do not fit in one node (\(node.count) bytes)") }
node.pad(to: nodeSize)

var tree = Data()
tree.be32(2)                                  // root node is block 2
tree.be32(0)                                  // tree height
tree.be32(UInt32(records.count))
tree.be32(1)                                  // nodes
tree.be32(0x1000)                             // page size
tree.pad(to: headerSize)

func address(_ offset: Int, _ size: Int) -> UInt32 { UInt32(offset) | UInt32(size.trailingZeroBitCount) }

var info = Data()
info.be32(3)                                  // blocks
info.be32(0)
let addresses = [address(infoOffset, infoSize), address(headerOffset, headerSize), address(nodeOffset, nodeSize)]
for slot in 0..<256 { info.be32(slot < addresses.count ? addresses[slot] : 0) }
info.be32(1)                                  // one named tree
info.append(4)
info.ascii("DSDB")
info.be32(1)
// Free lists, one per power of two: every buddy that is not the file header or one of the three blocks.
let used: [(Int, Int)] = [(0, 32), (headerOffset, headerSize), (infoOffset, infoSize), (nodeOffset, nodeSize)]
for power in 0..<32 {
    let width = 1 << power
    // A block of this width at this offset is free when nothing used lies inside it and its buddy below is
    // not also free (otherwise the two would have merged into one larger block).
    var free: [UInt32] = []
    if power >= 5, power < 31 {
        let offset = width
        let overlaps = used.contains { $0.0 < offset + width && offset < $0.0 + $0.1 }
        let lowerHalfUsed = used.contains { $0.0 < width }
        if !overlaps && lowerHalfUsed { free.append(UInt32(offset)) }
    }
    info.be32(UInt32(free.count))
    for offset in free { info.be32(offset) }
}
guard info.count <= infoSize else { fail("allocator tables too large") }
info.pad(to: infoSize)

var space = Data(count: spaceSize)
func place(_ block: Data, at offset: Int) { space.replaceSubrange(offset..<offset + block.count, with: block) }
var fileHeader = Data()
fileHeader.ascii("Bud1")
fileHeader.be32(UInt32(infoOffset))
fileHeader.be32(UInt32(infoSize))
fileHeader.be32(UInt32(infoOffset))
fileHeader.append(contentsOf: [0x00, 0x00, 0x10, 0x0C, 0x00, 0x00, 0x00, 0x87, 0x00, 0x00, 0x20, 0x0B, 0x00, 0x00, 0x00, 0x00])
place(fileHeader, at: 0)
place(tree, at: headerOffset)
place(info, at: infoOffset)
place(node, at: nodeOffset)

var file = Data()
file.be32(1)
file.append(space)
let destination = volumeURL.appendingPathComponent(".DS_Store")
do {
    try file.write(to: destination)
} catch {
    fail("cannot write \(destination.path): \(error.localizedDescription)")
}
print("wrote \(destination.path): \(records.count) records, \(file.count) bytes")
