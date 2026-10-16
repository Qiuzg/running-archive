import Foundation

// Small offline OOXML/ZIP writer. STORE entries avoid a runtime or network dependency.
// Files are streamed in chunks; ZIP32 limits are checked before emitting an archive.
enum ExportError: LocalizedError {
    case invalid(String)
    var errorDescription: String? { if case .invalid(let message) = self { return message }; return nil }
}

enum ExportCell {
    case text(String), number(Double), date(Date), blank
    static func optional(_ value: Double?) -> Self { value.map { $0.isFinite ? .number($0) : .blank } ?? .blank }
    static func integer(_ value: Int?) -> Self { optional(value.map(Double.init)) }
}

struct ExportSheet {
    let name: String
    let headers: [String]
    var rows: [[ExportCell]]
    var widths: [Double] = []
}

enum ExportText {
    static func xml(_ value: String) -> String {
        String(String.UnicodeScalarView(value.unicodeScalars.filter {
            $0.value == 9 || $0.value == 10 || $0.value == 13 || (0x20...0xD7FF).contains($0.value)
                || (0xE000...0xFFFD).contains($0.value) || (0x10000...0x10FFFF).contains($0.value)
        })).replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }
    static func csv(_ value: String) -> String {
        // CSV has no text type; prevent spreadsheet formula execution for user text.
        let first = value.trimmingCharacters(in: .whitespacesAndNewlines).first
        let safe = first.map { "=+-@".contains($0) } == true ? "'" + value : value
        return "\"" + safe.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }
    static func column(_ index: Int) -> String {
        var value = index + 1, result = ""
        while value > 0 { value -= 1; result = String(UnicodeScalar(65 + value % 26)!) + result; value /= 26 }
        return result
    }
    static func iso(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }
}

enum ExportZIP {
    private static let table: [UInt32] = (0..<256).map { value in
        var crc = UInt32(value)
        for _ in 0..<8 { crc = (crc & 1) != 0 ? 0xEDB88320 ^ (crc >> 1) : crc >> 1 }
        return crc
    }
    private static func update(_ crc: UInt32, with data: Data) -> UInt32 {
        var result = crc
        for byte in data { result = table[Int((result ^ UInt32(byte)) & 255)] ^ (result >> 8) }
        return result
    }
    static func write(files: [(name: String, url: URL)], to destination: URL) throws {
        guard files.count < 65_535 else { throw ExportError.invalid("文件数量过多，请缩小日期范围") }
        FileManager.default.createFile(atPath: destination.path, contents: nil)
        let output = try FileHandle(forWritingTo: destination)
        defer { try? output.close() }
        var central = Data()
        for file in files {
            try Task.checkCancellation()
            let name = Data(file.name.utf8)
            guard !file.name.hasPrefix("/"), !file.name.split(separator: "/").contains(".."), name.count < 65_535 else {
                throw ExportError.invalid("导出文件名无效")
            }
            let input = try FileHandle(forReadingFrom: file.url)
            defer { try? input.close() }
            let size = try input.seekToEnd(), offset = try output.offset()
            guard size < UInt32.max, offset + size + UInt64(name.count) + 30 < UInt32.max else {
                throw ExportError.invalid("数据包超过 4 GB，请分批导出")
            }
            try input.seek(toOffset: 0)
            var crc: UInt32 = 0xFFFFFFFF
            while let chunk = try input.read(upToCount: 262_144), !chunk.isEmpty {
                try Task.checkCancellation(); crc = update(crc, with: chunk)
            }
            crc ^= 0xFFFFFFFF
            var local = Data()
            local.u32(0x04034b50); local.u16(20); local.u16(0x800); local.u16(0)
            local.u16(0); local.u16(33); local.u32(crc); local.u32(UInt32(size)); local.u32(UInt32(size))
            local.u16(UInt16(name.count)); local.u16(0); local.append(name)
            try output.write(contentsOf: local)
            try input.seek(toOffset: 0)
            while let chunk = try input.read(upToCount: 262_144), !chunk.isEmpty {
                try Task.checkCancellation(); try output.write(contentsOf: chunk)
            }
            central.u32(0x02014b50); central.u16(20); central.u16(20); central.u16(0x800); central.u16(0)
            central.u16(0); central.u16(33); central.u32(crc); central.u32(UInt32(size)); central.u32(UInt32(size))
            central.u16(UInt16(name.count)); central.u16(0); central.u16(0); central.u16(0); central.u16(0)
            central.u32(0); central.u32(UInt32(offset)); central.append(name)
        }
        let start = try output.offset()
        guard start + UInt64(central.count) + 22 < UInt32.max else { throw ExportError.invalid("数据包过大，请分批导出") }
        try output.write(contentsOf: central)
        var end = Data()
        end.u32(0x06054b50); end.u16(0); end.u16(0); end.u16(UInt16(files.count)); end.u16(UInt16(files.count))
        end.u32(UInt32(central.count)); end.u32(UInt32(start)); end.u16(0)
        try output.write(contentsOf: end)
    }
}

private extension Data {
    mutating func u16(_ value: UInt16) { append(UInt8(value & 255)); append(UInt8(value >> 8)) }
    mutating func u32(_ value: UInt32) { u16(UInt16(value & 65535)); u16(UInt16(value >> 16)) }
}

enum ExportWorkbook {
    static func write(_ sheets: [ExportSheet], to url: URL, timeZone: TimeZone) throws {
        let folder = url.deletingLastPathComponent().appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        var files: [(name: String, url: URL)] = []
        func part(_ name: String, _ content: String) throws {
            let file = folder.appendingPathComponent(UUID().uuidString)
            try content.write(to: file, atomically: false, encoding: .utf8)
            files.append((name, file))
        }
        let ns = "http://schemas.openxmlformats.org/spreadsheetml/2006/main"
        let rel = "http://schemas.openxmlformats.org/officeDocument/2006/relationships"
        let package = "http://schemas.openxmlformats.org/package/2006/relationships"
        var overrides = "", workbook = "", relationships = ""
        for (index, sheet) in sheets.enumerated() {
            guard sheet.rows.count < 1_048_576, sheet.headers.count <= 16_384 else {
                throw ExportError.invalid("超过 Excel 行数限制，请缩小日期范围")
            }
            let id = index + 1
            overrides += "<Override PartName=\"/xl/worksheets/sheet\(id).xml\" ContentType=\"application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml\"/>"
            workbook += "<sheet name=\"\(ExportText.xml(sheet.name))\" sheetId=\"\(id)\" r:id=\"rId\(id)\"/>"
            relationships += "<Relationship Id=\"rId\(id)\" Type=\"\(rel)/worksheet\" Target=\"worksheets/sheet\(id).xml\"/>"
            let path = folder.appendingPathComponent("sheet\(id).xml")
            FileManager.default.createFile(atPath: path.path, contents: nil)
            let handle = try FileHandle(forWritingTo: path)
            defer { try? handle.close() }
            func emit(_ text: String) throws { try handle.write(contentsOf: Data(text.utf8)) }
            let last = ExportText.column(max(0, sheet.headers.count - 1))
            try emit("<?xml version=\"1.0\" encoding=\"UTF-8\"?><worksheet xmlns=\"\(ns)\"><dimension ref=\"A1:\(last)\(sheet.rows.count + 1)\"/><sheetViews><sheetView showGridLines=\"0\" workbookViewId=\"0\"><pane xSplit=\"1\" ySplit=\"1\" topLeftCell=\"B2\" activePane=\"bottomRight\" state=\"frozen\"/></sheetView></sheetViews><cols>")
            for c in sheet.headers.indices {
                let width = c < sheet.widths.count ? sheet.widths[c] : 22
                try emit("<col min=\"\(c + 1)\" max=\"\(c + 1)\" width=\"\(width)\" customWidth=\"1\"/>")
            }
            try emit("</cols><sheetData>")
            for rowIndex in 0...sheet.rows.count {
                try Task.checkCancellation()
                let cells = rowIndex == 0 ? sheet.headers.map(ExportCell.text) : sheet.rows[rowIndex - 1]
                let lineCount = cells.enumerated().map { column, cell -> Int in
                    guard case .text(let text) = cell else { return 1 }
                    let width = column < sheet.widths.count ? sheet.widths[column] : 22
                    let capacity = max(1, width - 3)
                    return text.components(separatedBy: "\n").reduce(0) { lines, part in
                        let units = part.unicodeScalars.reduce(0.0) { $0 + ($1.value > 255 ? 2 : 1) }
                        return lines + max(1, Int(ceil(units / capacity)))
                    }
                }.max() ?? 1
                let height = min(409, max(rowIndex == 0 ? 44 : 32, lineCount * 16 + 12))
                try emit("<row r=\"\(rowIndex + 1)\" ht=\"\(height)\" customHeight=\"1\">")
                for (column, cell) in cells.enumerated() {
                    let ref = "\(ExportText.column(column))\(rowIndex + 1)"
                    switch cell {
                    case .blank: break
                    case .text(let text):
                        // inlineStr is always literal, including user notes beginning with '='.
                        guard text.utf16.count <= 32_767 else { throw ExportError.invalid("手记内容超过 Excel 单元格限制，请缩小范围或缩短手记") }
                        try emit("<c r=\"\(ref)\" s=\"\(rowIndex == 0 ? 1 : 0)\" t=\"inlineStr\"><is><t xml:space=\"preserve\">\(ExportText.xml(text))</t></is></c>")
                    case .number(let value):
                        if value.isFinite { try emit("<c r=\"\(ref)\" s=\"\(value.rounded() == value ? 4 : 2)\" t=\"n\"><v>\(value)</v></c>") }
                    case .date(let date):
                        let serial = (date.timeIntervalSince1970 + Double(timeZone.secondsFromGMT(for: date))) / 86400 + 25569
                        try emit("<c r=\"\(ref)\" s=\"3\" t=\"n\"><v>\(serial)</v></c>")
                    }
                }
                try emit("</row>")
            }
            try emit("</sheetData><autoFilter ref=\"A1:\(last)\(sheet.rows.count + 1)\"/></worksheet>")
            try handle.close()
            files.append(("xl/worksheets/sheet\(id).xml", path))
        }
        try part("[Content_Types].xml", "<?xml version=\"1.0\"?><Types xmlns=\"http://schemas.openxmlformats.org/package/2006/content-types\"><Default Extension=\"rels\" ContentType=\"application/vnd.openxmlformats-package.relationships+xml\"/><Default Extension=\"xml\" ContentType=\"application/xml\"/><Override PartName=\"/xl/workbook.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml\"/><Override PartName=\"/xl/styles.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.spreadsheetml.styles+xml\"/>\(overrides)</Types>")
        try part("_rels/.rels", "<Relationships xmlns=\"\(package)\"><Relationship Id=\"rId1\" Type=\"\(rel)/officeDocument\" Target=\"xl/workbook.xml\"/></Relationships>")
        try part("xl/workbook.xml", "<workbook xmlns=\"\(ns)\" xmlns:r=\"\(rel)\"><sheets>\(workbook)</sheets></workbook>")
        try part("xl/_rels/workbook.xml.rels", "<Relationships xmlns=\"\(package)\">\(relationships)<Relationship Id=\"styles\" Type=\"\(rel)/styles\" Target=\"styles.xml\"/></Relationships>")
        try part("xl/styles.xml", """
        <styleSheet xmlns="\(ns)"><numFmts count="2"><numFmt numFmtId="164" formatCode="0.00"/><numFmt numFmtId="165" formatCode="yyyy-mm-dd hh:mm:ss"/></numFmts><fonts count="2"><font><sz val="11"/><name val="Calibri"/><color rgb="FF243D45"/></font><font><b/><sz val="11"/><name val="Calibri"/><color rgb="FFFFFFFF"/></font></fonts><fills count="3"><fill><patternFill patternType="none"/></fill><fill><patternFill patternType="gray125"/></fill><fill><patternFill patternType="solid"><fgColor rgb="FF1B535B"/><bgColor indexed="64"/></patternFill></fill></fills><borders count="1"><border/></borders><cellStyleXfs count="1"><xf numFmtId="0" fontId="0" fillId="0" borderId="0"/></cellStyleXfs><cellXfs count="5"><xf numFmtId="0" fontId="0" fillId="0" borderId="0" xfId="0" applyAlignment="1"><alignment vertical="center" wrapText="1" indent="1"/></xf><xf numFmtId="0" fontId="1" fillId="2" borderId="0" xfId="0" applyAlignment="1"><alignment vertical="center" wrapText="1" indent="1"/></xf><xf numFmtId="164" fontId="0" fillId="0" borderId="0" xfId="0" applyNumberFormat="1" applyAlignment="1"><alignment vertical="center" horizontal="right" indent="1"/></xf><xf numFmtId="165" fontId="0" fillId="0" borderId="0" xfId="0" applyNumberFormat="1" applyAlignment="1"><alignment vertical="center" horizontal="right" indent="1"/></xf><xf numFmtId="0" fontId="0" fillId="0" borderId="0" xfId="0" applyAlignment="1"><alignment vertical="center" horizontal="right" indent="1"/></xf></cellXfs><cellStyles count="1"><cellStyle name="Normal" xfId="0" builtinId="0"/></cellStyles></styleSheet>
        """)
        try ExportZIP.write(files: files, to: url)
    }
}
