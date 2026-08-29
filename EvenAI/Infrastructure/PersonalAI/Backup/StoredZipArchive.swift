import Foundation

/// A minimal, dependency-free ZIP writer using the **STORE** method (no
/// compression). Personal AI exports are small (KB–low MB of text/JSON), so
/// compression buys little and a stored archive keeps the writer tiny and
/// auditable. Produces a standard `.zip` that Finder / Files / any unzip tool
/// opens.
enum StoredZipArchive {

    struct Entry {
        var path: String     // forward-slash relative path inside the zip
        var data: Data
        var modified: Date
    }

    static func archive(_ entries: [Entry]) -> Data {
        var output = Data()
        var central = Data()
        var offset: UInt32 = 0

        for entry in entries {
            let nameBytes = Array(entry.path.utf8)
            let crc = crc32(entry.data)
            let size = UInt32(entry.data.count)
            let (dosTime, dosDate) = dosDateTime(entry.modified)

            // Local file header
            var local = Data()
            local.append(le32(0x04034b50))   // signature
            local.append(le16(20))           // version needed
            local.append(le16(0x0800))       // flags: bit 11 = UTF-8 names
            local.append(le16(0))            // method: 0 = stored
            local.append(le16(dosTime))
            local.append(le16(dosDate))
            local.append(le32(crc))
            local.append(le32(size))         // compressed size == size
            local.append(le32(size))         // uncompressed size
            local.append(le16(UInt16(nameBytes.count)))
            local.append(le16(0))            // extra field length
            local.append(contentsOf: nameBytes)

            output.append(local)
            output.append(entry.data)

            // Central directory record
            central.append(le32(0x02014b50))
            central.append(le16(20))         // version made by
            central.append(le16(20))         // version needed
            central.append(le16(0x0800))
            central.append(le16(0))
            central.append(le16(dosTime))
            central.append(le16(dosDate))
            central.append(le32(crc))
            central.append(le32(size))
            central.append(le32(size))
            central.append(le16(UInt16(nameBytes.count)))
            central.append(le16(0))          // extra
            central.append(le16(0))          // comment
            central.append(le16(0))          // disk number
            central.append(le16(0))          // internal attrs
            central.append(le32(0))          // external attrs
            central.append(le32(offset))     // local header offset
            central.append(contentsOf: nameBytes)

            offset += UInt32(local.count) + size
        }

        let centralOffset = offset
        output.append(central)

        // End of central directory
        var eocd = Data()
        eocd.append(le32(0x06054b50))
        eocd.append(le16(0))                 // disk
        eocd.append(le16(0))                 // disk with central dir
        eocd.append(le16(UInt16(entries.count)))
        eocd.append(le16(UInt16(entries.count)))
        eocd.append(le32(UInt32(central.count)))
        eocd.append(le32(centralOffset))
        eocd.append(le16(0))                 // comment length
        output.append(eocd)

        return output
    }

    // MARK: little-endian helpers

    private static func le16(_ v: UInt16) -> Data { withUnsafeBytes(of: v.littleEndian) { Data($0) } }
    private static func le32(_ v: UInt32) -> Data { withUnsafeBytes(of: v.littleEndian) { Data($0) } }

    private static func dosDateTime(_ date: Date) -> (time: UInt16, date: UInt16) {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC") ?? .current
        let c = cal.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        let year = max(1980, c.year ?? 1980)
        let time = UInt16(((c.hour ?? 0) << 11) | ((c.minute ?? 0) << 5) | (((c.second ?? 0) / 2)))
        let dosDate = UInt16(((year - 1980) << 9) | ((c.month ?? 1) << 5) | (c.day ?? 1))
        return (time, dosDate)
    }

    // MARK: CRC-32 (IEEE 802.3, polynomial 0xEDB88320)

    private static let crcTable: [UInt32] = {
        (0..<256).map { i -> UInt32 in
            var c = UInt32(i)
            for _ in 0..<8 { c = (c & 1) != 0 ? (0xEDB88320 ^ (c >> 1)) : (c >> 1) }
            return c
        }
    }()

    static func crc32(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFFFFFF
        for byte in data {
            crc = crcTable[Int((crc ^ UInt32(byte)) & 0xFF)] ^ (crc >> 8)
        }
        return crc ^ 0xFFFFFFFF
    }
}
