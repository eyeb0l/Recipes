import Foundation
import RecipeCore
import SwiftUI
import UIKit

enum RecipeExportFormat: String, CaseIterable, Identifiable, Sendable {
    case pdf
    case xlsx
    case png

    var id: String { rawValue }

    var title: String {
        switch self {
        case .pdf: "PDF document"
        case .xlsx: "Excel workbook"
        case .png: "PNG image"
        }
    }

    var fileExtension: String { rawValue }

    var systemImage: String {
        switch self {
        case .pdf: "doc.richtext"
        case .xlsx: "tablecells"
        case .png: "photo"
        }
    }
}

struct RecipeExportRequest: Hashable, Sendable {
    let recipe: RecipeV1
    let servings: Decimal
    let units: UnitSystemPreference
}

struct RecipeExportArtifact: Identifiable, Sendable {
    let format: RecipeExportFormat
    let url: URL

    var id: RecipeExportFormat { format }
}

enum RecipeExportError: LocalizedError {
    case unableToEncodePNG
    case timelineUnavailable(String)
    case workbookTooLarge

    var errorDescription: String? {
        switch self {
        case .unableToEncodePNG:
            "The recipe image could not be encoded."
        case let .timelineUnavailable(reason):
            "The recipe timeline could not be exported. \(reason)"
        case .workbookTooLarge:
            "The recipe workbook is too large to create."
        }
    }
}

@MainActor
enum RecipeExporter {
    static func exportAll(_ request: RecipeExportRequest) throws -> [RecipeExportArtifact] {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("RecipeTimeline Exports", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let baseName = safeFilename(request.recipe.title)
        return try RecipeExportFormat.allCases.map { format in
            let url = directory.appendingPathComponent(baseName).appendingPathExtension(format.fileExtension)
            let data: Data
            switch format {
            case .pdf:
                data = try makePDF(request)
            case .xlsx:
                data = try makeWorkbook(request)
            case .png:
                data = try makePNG(request)
            }
            try data.write(to: url, options: .atomic)
            return RecipeExportArtifact(format: format, url: url)
        }
    }

    private static func safeFilename(_ title: String) -> String {
        let collapsed =
            title
            .replacingOccurrences(of: "[^A-Za-z0-9]+", with: "-", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return String((collapsed.isEmpty ? "Recipe" : collapsed).prefix(70))
    }

    private static func makePDF(_ request: RecipeExportRequest) throws -> Data {
        let (imageRenderer, canvasSize) = try timelineRenderer(for: request)
        let pageBounds = CGRect(origin: .zero, size: canvasSize)
        let format = UIGraphicsPDFRendererFormat()
        format.documentInfo = [
            kCGPDFContextTitle as String: request.recipe.title,
            kCGPDFContextCreator as String: "Recipe Timeline",
        ]

        return UIGraphicsPDFRenderer(bounds: pageBounds, format: format).pdfData { pdf in
            pdf.beginPage()
            imageRenderer.render { _, render in
                pdf.cgContext.translateBy(x: 0, y: canvasSize.height)
                pdf.cgContext.scaleBy(x: 1, y: -1)
                render(pdf.cgContext)
            }
        }
    }

    private static func makePNG(_ request: RecipeExportRequest) throws -> Data {
        let (renderer, _) = try timelineRenderer(for: request)
        guard let image = renderer.uiImage else { throw RecipeExportError.unableToEncodePNG }
        guard let data = image.pngData() else { throw RecipeExportError.unableToEncodePNG }
        return data
    }

    private static func timelineRenderer(
        for request: RecipeExportRequest
    ) throws -> (ImageRenderer<RecipeTimelineExportCanvas>, CGSize) {
        let layout: TimelineLayout
        do {
            layout = try TimelineLayoutEngine.makeLayout(for: request.recipe)
        } catch {
            throw RecipeExportError.timelineUnavailable(error.localizedDescription)
        }

        let metrics = TimelineGridMetrics()
        let geometry = TimelineGridGeometry(layout: layout, metrics: metrics)
        let timelineSize = CGSize(
            width: metrics.ingredientWidth + 1 + geometry.contentWidth + metrics.trailingMargin,
            height: geometry.contentHeight
        )
        let canvasSize = CGSize(
            width: timelineSize.width + 64,
            height: timelineSize.height + 198
        )
        let canvas = RecipeTimelineExportCanvas(
            request: request,
            timelineSize: timelineSize,
            canvasSize: canvasSize
        )
        let renderer = ImageRenderer(content: canvas)
        renderer.proposedSize = ProposedViewSize(canvasSize)
        renderer.scale = 1
        return (renderer, canvasSize)
    }

    private static func makeWorkbook(_ request: RecipeExportRequest) throws -> Data {
        let layout: TimelineLayout
        do {
            layout = try TimelineLayoutEngine.makeLayout(for: request.recipe)
        } catch {
            throw RecipeExportError.timelineUnavailable(error.localizedDescription)
        }
        let timeline = timelineSheet(request: request, layout: layout)
        let overviewRows = [
            ["Field", "Value"],
            ["Title", request.recipe.title],
            ["Summary", request.recipe.summary ?? ""],
            ["Servings", decimalString(request.servings)],
            ["Units", request.units.exportTitle],
            ["Source", request.recipe.provenance.title ?? request.recipe.provenance.url ?? request.recipe.provenance.sourceType.rawValue],
        ]

        let ingredientRows =
            [["Quantity", "Ingredient", "Notes"]]
            + request.recipe.sortedIngredients.map { ingredient in
                [
                    ingredient.displayQuantity(
                        servings: request.servings,
                        originalServings: request.recipe.recipeYield.servings,
                        units: request.units
                    ) ?? "",
                    ingredient.name,
                    ingredient.notes ?? "",
                ]
            }

        let prepRows =
            [["No.", "Instruction", "Optional"]]
            + request.recipe.prepTasks
            .sorted { $0.sortIndex < $1.sortIndex }
            .enumerated()
            .map { index, task in
                [String(index + 1), task.instruction, task.isOptional ? "Yes" : "No"]
            }

        let stepRows =
            [["No.", "Action", "Instruction", "Details", "Ready when", "Notes"]]
            + request.recipe.sortedStages
            .enumerated()
            .map { index, stage in
                [
                    String(index + 1),
                    stage.action,
                    stage.instruction,
                    stageDetails(stage, units: request.units).joined(separator: "; "),
                    stage.completionCue ?? "",
                    stage.notes ?? "",
                ]
            }

        let warningRows =
            [["Severity", "Source note"]]
            + request.recipe.uncertainties
            .filter { !$0.isResolved }
            .map { [$0.severity.rawValue.capitalized, $0.message] }

        let sheets: [(name: String, rows: [[String]], widths: [Double])] = [
            ("Timeline", timeline.rows, timeline.widths),
            ("Overview", overviewRows, [18, 72]),
            ("Ingredients", ingredientRows, [18, 38, 52]),
            ("Prep", prepRows, [8, 78, 12]),
            ("Stage Details", stepRows, [8, 18, 72, 32, 52, 44]),
            ("Source Notes", warningRows, [14, 90]),
        ]

        var files: [(String, Data)] = [
            ("[Content_Types].xml", Data(contentTypesXML(sheetCount: sheets.count).utf8)),
            ("_rels/.rels", Data(packageRelationshipsXML.utf8)),
            ("xl/workbook.xml", Data(workbookXML(sheetNames: sheets.map(\.name)).utf8)),
            ("xl/_rels/workbook.xml.rels", Data(workbookRelationshipsXML(sheetCount: sheets.count).utf8)),
            ("xl/styles.xml", Data(stylesXML.utf8)),
        ]
        for (index, sheet) in sheets.enumerated() {
            files.append(
                (
                    "xl/worksheets/sheet\(index + 1).xml",
                    Data(worksheetXML(rows: sheet.rows, widths: sheet.widths).utf8)
                ))
        }
        return try StoredZipArchive.make(files: files)
    }

    private static func timelineSheet(
        request: RecipeExportRequest,
        layout: TimelineLayout
    ) -> (rows: [[String]], widths: [Double]) {
        let stages = Dictionary(uniqueKeysWithValues: request.recipe.stages.map { ($0.id, $0) })
        let placements = layout.placements
        let placementsByColumn = Dictionary(grouping: placements, by: \.column)
        let columnLabels = placements.map { placement -> String in
            let peers = placementsByColumn[placement.column] ?? []
            let suffix: String
            if peers.count > 1,
                let peerIndex = peers.firstIndex(where: { $0.stageID == placement.stageID })
            {
                suffix = String(UnicodeScalar(65 + peerIndex)!)
            } else {
                suffix = ""
            }
            return "STAGE \(placement.column + 1)\(suffix)"
        }

        var rows = [["Quantity", "Ingredient"] + columnLabels]
        rows.append(
            ["", "Prep & global"]
                + placements.map { placement in
                    guard placement.isGlobal, let stage = stages[placement.stageID] else { return "" }
                    return timelineCell(stage, units: request.units)
                })

        for (rowIndex, ingredient) in request.recipe.sortedIngredients.enumerated() {
            let quantity =
                ingredient.displayQuantity(
                    servings: request.servings,
                    originalServings: request.recipe.recipeYield.servings,
                    units: request.units
                ) ?? ""
            let cells = placements.map { placement -> String in
                guard placement.ingredientLineage.contains(ingredient.id),
                    let stage = stages[placement.stageID]
                else { return "" }
                if placement.startRow == rowIndex {
                    return timelineCell(stage, units: request.units)
                }
                let isDirectInput = stage.ingredientUses.contains { $0.ingredientID == ingredient.id }
                return isDirectInput ? "●" : "│"
            }
            rows.append([quantity, ingredient.name] + cells)
        }

        return (rows, [18, 34] + Array(repeating: 24, count: placements.count))
    }

    private static func timelineCell(_ stage: Stage, units: UnitSystemPreference) -> String {
        let details = stageDetails(stage, units: units)
        return ([stage.action] + details).joined(separator: "\n")
    }

    private static func stageDetails(_ stage: Stage, units: UnitSystemPreference) -> [String] {
        var details: [String] = []
        if let duration = stage.duration {
            details.append(durationString(duration))
        }
        if let temperature = stage.temperature {
            details.append(temperature.converted(for: units).displayString())
        }
        if let heat = stage.heat, !heat.isEmpty {
            details.append("\(heat.capitalized) heat")
        }
        return details
    }

    private static func durationString(_ duration: StageDuration) -> String {
        if let maximum = duration.maximumSeconds, maximum != duration.minimumSeconds {
            if duration.minimumSeconds >= 3_600,
                duration.minimumSeconds.isMultiple(of: 3_600),
                maximum.isMultiple(of: 3_600)
            {
                return "\(duration.minimumSeconds / 3_600)–\(maximum / 3_600) hr"
            }
            if duration.minimumSeconds >= 60 {
                let minimumMinutes = formattedMinutes(duration.minimumSeconds)
                let maximumMinutes = formattedMinutes(maximum)
                return "\(minimumMinutes)–\(maximumMinutes) min"
            }
            return "\(duration.minimumSeconds)–\(maximum) sec"
        }
        if duration.minimumSeconds >= 3_600, duration.minimumSeconds.isMultiple(of: 3_600) {
            return "\(duration.minimumSeconds / 3_600) hr"
        }
        if duration.minimumSeconds >= 60 {
            return "\(formattedMinutes(duration.minimumSeconds)) min"
        }
        return "\(duration.minimumSeconds) sec"
    }

    private static func formattedMinutes(_ seconds: Int) -> String {
        (Double(seconds) / 60).formatted(.number.precision(.fractionLength(0...1)))
    }

    private static func decimalString(_ value: Decimal) -> String {
        NSDecimalNumber(decimal: value).stringValue
    }

    private static func contentTypesXML(sheetCount: Int) -> String {
        let sheets = (1...sheetCount).map {
            "<Override PartName=\"/xl/worksheets/sheet\($0).xml\" ContentType=\"application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml\"/>"
        }.joined()
        return """
            <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
            <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"><Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/><Default Extension="xml" ContentType="application/xml"/><Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/><Override PartName="/xl/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.styles+xml"/>\(sheets)</Types>
            """
    }

    private static let packageRelationshipsXML = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="xl/workbook.xml"/></Relationships>
        """

    private static func workbookXML(sheetNames: [String]) -> String {
        let sheets = sheetNames.enumerated().map { index, name in
            "<sheet name=\"\(xmlEscaped(name))\" sheetId=\"\(index + 1)\" r:id=\"rId\(index + 1)\"/>"
        }.joined()
        return """
            <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
            <workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships"><sheets>\(sheets)</sheets></workbook>
            """
    }

    private static func workbookRelationshipsXML(sheetCount: Int) -> String {
        let sheets = (1...sheetCount).map {
            "<Relationship Id=\"rId\($0)\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet\" Target=\"worksheets/sheet\($0).xml\"/>"
        }.joined()
        return """
            <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
            <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">\(sheets)<Relationship Id="rId\(sheetCount + 1)" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles" Target="styles.xml"/></Relationships>
            """
    }

    private static let stylesXML = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <styleSheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"><fonts count="2"><font><sz val="11"/><name val="Aptos"/></font><font><b/><color rgb="FFFFFFFF"/><sz val="11"/><name val="Aptos Display"/></font></fonts><fills count="3"><fill><patternFill patternType="none"/></fill><fill><patternFill patternType="gray125"/></fill><fill><patternFill patternType="solid"><fgColor rgb="FF88464A"/><bgColor indexed="64"/></patternFill></fill></fills><borders count="1"><border><left/><right/><top/><bottom/><diagonal/></border></borders><cellStyleXfs count="1"><xf numFmtId="0" fontId="0" fillId="0" borderId="0"/></cellStyleXfs><cellXfs count="3"><xf numFmtId="0" fontId="0" fillId="0" borderId="0" xfId="0"/><xf numFmtId="0" fontId="1" fillId="2" borderId="0" xfId="0" applyFont="1" applyFill="1" applyAlignment="1"><alignment vertical="center"/></xf><xf numFmtId="0" fontId="0" fillId="0" borderId="0" xfId="0" applyAlignment="1"><alignment vertical="top" wrapText="1"/></xf></cellXfs><cellStyles count="1"><cellStyle name="Normal" xfId="0" builtinId="0"/></cellStyles></styleSheet>
        """

    private static func worksheetXML(rows: [[String]], widths: [Double]) -> String {
        let maximumColumns = max(rows.map(\.count).max() ?? 1, widths.count)
        let columns = (0..<maximumColumns).map { index in
            let width = index < widths.count ? widths[index] : 18
            return "<col min=\"\(index + 1)\" max=\"\(index + 1)\" width=\"\(width)\" customWidth=\"1\"/>"
        }.joined()
        let rowXML = rows.enumerated().map { rowIndex, values in
            let cells = values.enumerated().map { columnIndex, value in
                let reference = "\(columnName(columnIndex + 1))\(rowIndex + 1)"
                let style = rowIndex == 0 ? 1 : 2
                return "<c r=\"\(reference)\" t=\"inlineStr\" s=\"\(style)\"><is><t xml:space=\"preserve\">\(xmlEscaped(value))</t></is></c>"
            }.joined()
            let height = rowIndex == 0 ? " ht=\"22\" customHeight=\"1\"" : ""
            return "<row r=\"\(rowIndex + 1)\"\(height)>\(cells)</row>"
        }.joined()
        let lastCell = "\(columnName(maximumColumns))\(max(rows.count, 1))"
        return """
            <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
            <worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"><dimension ref="A1:\(lastCell)"/><sheetViews><sheetView workbookViewId="0"><pane ySplit="1" topLeftCell="A2" activePane="bottomLeft" state="frozen"/></sheetView></sheetViews><sheetFormatPr defaultRowHeight="15"/><cols>\(columns)</cols><sheetData>\(rowXML)</sheetData><autoFilter ref="A1:\(lastCell)"/></worksheet>
            """
    }

    private static func columnName(_ index: Int) -> String {
        var number = index
        var result = ""
        while number > 0 {
            number -= 1
            result = String(UnicodeScalar(65 + (number % 26))!) + result
            number /= 26
        }
        return result
    }

    private static func xmlEscaped(_ input: String) -> String {
        let valid = input.unicodeScalars.compactMap { scalar -> String? in
            let value = scalar.value
            guard value == 0x9 || value == 0xA || value == 0xD || value >= 0x20 else { return nil }
            return String(scalar)
        }.joined()
        return
            valid
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&apos;")
    }
}

private struct RecipeTimelineExportCanvas: View {
    let request: RecipeExportRequest
    let timelineSize: CGSize
    let canvasSize: CGSize

    var body: some View {
        ZStack(alignment: .topLeading) {
            RecipeTheme.paper

            HStack(alignment: .bottom, spacing: 32) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(request.recipe.title)
                        .font(.system(size: 40, weight: .bold, design: .serif))
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                    if let summary = request.recipe.summary, !summary.isEmpty {
                        Text(summary)
                            .font(.system(size: 18))
                            .foregroundStyle(RecipeTheme.secondaryInk)
                            .lineLimit(2)
                    }
                }
                Spacer(minLength: 24)
                VStack(alignment: .trailing, spacing: 5) {
                    Text("COOKING TIMELINE")
                        .font(.caption.weight(.bold))
                        .tracking(1.5)
                        .foregroundStyle(RecipeTheme.focusText)
                    Text("Serves \(NSDecimalNumber(decimal: request.servings).stringValue) · \(request.units.exportTitle)")
                        .font(.headline.monospacedDigit())
                        .foregroundStyle(RecipeTheme.secondaryInk)
                }
                .fixedSize()
            }
            .frame(width: timelineSize.width, height: 110, alignment: .bottom)
            .offset(x: 32, y: 32)

            TimelineGridView(
                recipe: request.recipe,
                servings: request.servings,
                units: request.units,
                showsFullContent: true
            )
            .frame(width: timelineSize.width, height: timelineSize.height)
            .offset(x: 32, y: 166)
        }
        .frame(width: canvasSize.width, height: canvasSize.height, alignment: .topLeading)
        .foregroundStyle(RecipeTheme.ink)
        .environment(\.colorScheme, .light)
        .environment(\.dynamicTypeSize, .medium)
    }
}

private extension UnitSystemPreference {
    var exportTitle: String {
        switch self {
        case .source: "Source"
        case .metric: "Metric"
        case .imperial: "Imperial"
        }
    }
}

private enum StoredZipArchive {
    private struct Entry {
        let name: Data
        let data: Data
        let checksum: UInt32
        let offset: UInt32
    }

    static func make(files: [(String, Data)]) throws -> Data {
        var archive = Data()
        var entries: [Entry] = []

        for (name, contents) in files {
            let nameData = Data(name.utf8)
            guard archive.count <= UInt32.max,
                contents.count <= UInt32.max,
                nameData.count <= UInt16.max
            else { throw RecipeExportError.workbookTooLarge }
            let entry = Entry(
                name: nameData,
                data: contents,
                checksum: crc32(contents),
                offset: UInt32(archive.count)
            )
            entries.append(entry)
            archive.appendLittleEndian(UInt32(0x0403_4B50))
            archive.appendLittleEndian(UInt16(20))
            archive.appendLittleEndian(UInt16(0))
            archive.appendLittleEndian(UInt16(0))
            archive.appendLittleEndian(UInt16(0))
            archive.appendLittleEndian(UInt16(0))
            archive.appendLittleEndian(entry.checksum)
            archive.appendLittleEndian(UInt32(contents.count))
            archive.appendLittleEndian(UInt32(contents.count))
            archive.appendLittleEndian(UInt16(nameData.count))
            archive.appendLittleEndian(UInt16(0))
            archive.append(nameData)
            archive.append(contents)
        }

        guard archive.count <= UInt32.max, entries.count <= UInt16.max else {
            throw RecipeExportError.workbookTooLarge
        }
        let centralDirectoryOffset = UInt32(archive.count)
        for entry in entries {
            archive.appendLittleEndian(UInt32(0x0201_4B50))
            archive.appendLittleEndian(UInt16(20))
            archive.appendLittleEndian(UInt16(20))
            archive.appendLittleEndian(UInt16(0))
            archive.appendLittleEndian(UInt16(0))
            archive.appendLittleEndian(UInt16(0))
            archive.appendLittleEndian(UInt16(0))
            archive.appendLittleEndian(entry.checksum)
            archive.appendLittleEndian(UInt32(entry.data.count))
            archive.appendLittleEndian(UInt32(entry.data.count))
            archive.appendLittleEndian(UInt16(entry.name.count))
            archive.appendLittleEndian(UInt16(0))
            archive.appendLittleEndian(UInt16(0))
            archive.appendLittleEndian(UInt16(0))
            archive.appendLittleEndian(UInt16(0))
            archive.appendLittleEndian(UInt32(0))
            archive.appendLittleEndian(entry.offset)
            archive.append(entry.name)
        }
        guard archive.count <= UInt32.max else { throw RecipeExportError.workbookTooLarge }
        let centralDirectorySize = UInt32(archive.count) - centralDirectoryOffset
        archive.appendLittleEndian(UInt32(0x0605_4B50))
        archive.appendLittleEndian(UInt16(0))
        archive.appendLittleEndian(UInt16(0))
        archive.appendLittleEndian(UInt16(entries.count))
        archive.appendLittleEndian(UInt16(entries.count))
        archive.appendLittleEndian(centralDirectorySize)
        archive.appendLittleEndian(centralDirectoryOffset)
        archive.appendLittleEndian(UInt16(0))
        return archive
    }

    private static func crc32(_ data: Data) -> UInt32 {
        var checksum: UInt32 = 0xFFFF_FFFF
        for byte in data {
            checksum ^= UInt32(byte)
            for _ in 0..<8 {
                checksum = (checksum >> 1) ^ ((checksum & 1) == 1 ? 0xEDB8_8320 : 0)
            }
        }
        return checksum ^ 0xFFFF_FFFF
    }
}

private extension Data {
    mutating func appendLittleEndian<T: FixedWidthInteger>(_ value: T) {
        var littleEndian = value.littleEndian
        Swift.withUnsafeBytes(of: &littleEndian) { append(contentsOf: $0) }
    }
}
