import Foundation

/// Repairs session WAVs whose header was never finalised.
///
/// A recording interrupted by a crash or force quit keeps all of its audio but
/// leaves a `data` chunk claiming zero bytes. `AVAudioFile` honours that header
/// and reports an empty file, so playback would be silent. Patching the sizes in
/// place from the real file length recovers the recording.
///
/// `WAVReader` works around the same problem by parsing chunks itself; this
/// exists because AVFoundation playback cannot.
enum WAVHeaderRepair {

    @discardableResult
    static func repairIfNeeded(at url: URL) -> Bool {
        guard let handle = try? FileHandle(forUpdating: url) else { return false }
        defer { try? handle.close() }

        guard let header = try? handle.read(upToCount: 4096), header.count >= 44,
              header.prefix(4) == Data("RIFF".utf8),
              header.dropFirst(8).prefix(4) == Data("WAVE".utf8)
        else { return false }

        let fileSize = (try? FileManager.default
            .attributesOfItem(atPath: url.path)[.size] as? Int) as? Int ?? 0
        guard fileSize > 44 else { return false }

        func u32(_ offset: Int) -> Int {
            guard offset + 4 <= header.count else { return 0 }
            return header.subdata(in: offset..<(offset + 4)).withUnsafeBytes {
                Int($0.loadUnaligned(as: UInt32.self).littleEndian)
            }
        }

        // Locate the data chunk; it is not always immediately after `fmt `.
        var cursor = 12
        var dataSizeOffset: Int? = nil
        var dataStart = 0
        while cursor + 8 <= header.count {
            let id = header.subdata(in: cursor..<(cursor + 4))
            let size = u32(cursor + 4)
            if id == Data("data".utf8) {
                dataSizeOffset = cursor + 4
                dataStart = cursor + 8
                break
            }
            cursor += 8 + size + (size % 2)
        }

        guard let dataSizeOffset else { return false }

        let declared = u32(dataSizeOffset)
        let actual = fileSize - dataStart
        guard actual > 0, declared != actual else { return false }

        var dataSize = UInt32(actual).littleEndian
        var riffSize = UInt32(fileSize - 8).littleEndian

        try? handle.seek(toOffset: 4)
        try? handle.write(contentsOf: withUnsafeBytes(of: &riffSize) { Data($0) })
        try? handle.seek(toOffset: UInt64(dataSizeOffset))
        try? handle.write(contentsOf: withUnsafeBytes(of: &dataSize) { Data($0) })
        return true
    }
}
