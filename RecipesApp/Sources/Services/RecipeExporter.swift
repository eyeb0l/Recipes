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

    private struct WorkbookWorksheet {
        let name: String
        let rows: [[String]]
        let widths: [Double]
        let rowHeights: [Double]
        let styles: [[Int]]
        let mergedCells: [String]
        let frozenRows: Int
        let frozenColumns: Int
        let autoFilterRow: Int?
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

        let recipeTitle = request.recipe.title
        let sheets: [WorkbookWorksheet] = [
            timeline,
            detailSheet(
                name: "Overview",
                title: recipeTitle,
                subtitle: "RECIPE OVERVIEW",
                rows: overviewRows,
                widths: [20, 72]
            ),
            detailSheet(
                name: "Ingredients",
                title: recipeTitle,
                subtitle: "INGREDIENTS  ·  SERVES \(decimalString(request.servings))  ·  \(request.units.exportTitle.uppercased())",
                rows: ingredientRows,
                widths: [18, 38, 52]
            ),
            detailSheet(
                name: "Prep",
                title: recipeTitle,
                subtitle: "PREPARATION",
                rows: prepRows,
                widths: [8, 78, 12]
            ),
            detailSheet(
                name: "Stage Details",
                title: recipeTitle,
                subtitle: "STAGE DETAILS",
                rows: stepRows,
                widths: [8, 18, 52, 26, 42, 32]
            ),
            detailSheet(
                name: "Source Notes",
                title: recipeTitle,
                subtitle: "SOURCE NOTES",
                rows: warningRows,
                widths: [16, 90]
            ),
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
                    Data(worksheetXML(sheet).utf8)
                ))
        }
        return try StoredZipArchive.make(files: files)
    }

    private static func timelineSheet(
        request: RecipeExportRequest,
        layout: TimelineLayout
    ) -> WorkbookWorksheet {
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

        let stageColumnCount = max(placements.count, 1)
        let columnCount = 2 + stageColumnCount
        let lastColumn = columnName(columnCount)
        let summary = request.recipe.summary ?? "A visual cooking timeline"
        let metadata = "SERVES \(decimalString(request.servings))  ·  \(request.units.exportTitle.uppercased())"

        var rows: [[String]] = [
            paddedRow([request.recipe.title], count: columnCount),
            paddedRow([summary], count: columnCount),
            paddedRow([metadata], count: columnCount),
            Array(repeating: "", count: columnCount),
            paddedRow(["QUANTITY", "INGREDIENT"] + columnLabels, count: columnCount),
            paddedRow(["", "PREP & GLOBAL"], count: columnCount),
        ]
        var styles: [[Int]] = [
            Array(repeating: 1, count: columnCount),
            Array(repeating: 2, count: columnCount),
            Array(repeating: 3, count: columnCount),
            Array(repeating: 15, count: columnCount),
            Array(repeating: 4, count: columnCount),
            [5, 7] + Array(repeating: 8, count: stageColumnCount),
        ]
        var rowHeights: [Double] = [42, textRowHeight(summary, width: 76, minimum: 28, maximum: 48), 24, 10, 30, 64]

        for ingredient in request.recipe.sortedIngredients {
            let quantity =
                ingredient.displayQuantity(
                    servings: request.servings,
                    originalServings: request.recipe.recipeYield.servings,
                    units: request.units
                ) ?? ""
            rows.append(paddedRow([quantity, ingredient.name], count: columnCount))
            styles.append([5, 6] + Array(repeating: 8, count: stageColumnCount))
            let ingredientHeight = textRowHeight(ingredient.name, width: 34, minimum: 54, maximum: 74)
            rowHeights.append(ingredientHeight)
        }

        var mergedCells = ["A1:\(lastColumn)1", "A2:\(lastColumn)2", "A3:\(lastColumn)3"]
        for (placementIndex, placement) in placements.enumerated() {
            guard let stage = stages[placement.stageID] else { continue }
            let columnIndex = placementIndex + 3
            let column = columnName(columnIndex)
            let style = placement.column.isMultiple(of: 2) ? 9 : 10
            if placement.isGlobal {
                let content = timelineCell(stage, units: request.units)
                rows[5][columnIndex - 1] = content
                styles[5][columnIndex - 1] = style
                rowHeights[5] = max(rowHeights[5], textRowHeight(content, width: 26, minimum: 64, maximum: 88))
                continue
            }

            guard let startRow = placement.startRow, let endRow = placement.endRow else { continue }
            let firstRow = startRow + 7
            let lastRow = endRow + 7
            guard firstRow >= 7, lastRow < rows.count + 1, firstRow <= lastRow else { continue }
            let content = timelineCell(stage, units: request.units)
            rows[firstRow - 1][columnIndex - 1] = content
            for row in firstRow...lastRow {
                styles[row - 1][columnIndex - 1] = style
            }
            if firstRow == lastRow {
                rowHeights[firstRow - 1] = max(
                    rowHeights[firstRow - 1],
                    textRowHeight(content, width: 26, minimum: 64, maximum: 88)
                )
            }
            if lastRow > firstRow {
                mergedCells.append("\(column)\(firstRow):\(column)\(lastRow)")
            }
        }

        return WorkbookWorksheet(
            name: "Timeline",
            rows: rows,
            widths: [18, 34] + Array(repeating: 26, count: stageColumnCount),
            rowHeights: rowHeights,
            styles: styles,
            mergedCells: mergedCells,
            frozenRows: 5,
            frozenColumns: 2,
            autoFilterRow: nil
        )
    }

    private static func detailSheet(
        name: String,
        title: String,
        subtitle: String,
        rows dataRows: [[String]],
        widths: [Double]
    ) -> WorkbookWorksheet {
        let columnCount = max(widths.count, dataRows.map(\.count).max() ?? 1)
        let lastColumn = columnName(columnCount)
        var rows = [
            paddedRow([title], count: columnCount),
            paddedRow([subtitle], count: columnCount),
            Array(repeating: "", count: columnCount),
        ]
        rows.append(contentsOf: dataRows.map { paddedRow($0, count: columnCount) })

        var styles = [
            Array(repeating: 1, count: columnCount),
            Array(repeating: 3, count: columnCount),
            Array(repeating: 15, count: columnCount),
        ]
        if !dataRows.isEmpty {
            styles.append(Array(repeating: 4, count: columnCount))
            for rowIndex in 1..<dataRows.count {
                var rowStyles = Array(repeating: rowIndex.isMultiple(of: 2) ? 12 : 11, count: columnCount)
                rowStyles[0] = 13
                styles.append(rowStyles)
            }
        }

        var rowHeights = [42.0, 26.0, 10.0]
        if !dataRows.isEmpty {
            rowHeights.append(30)
            for values in dataRows.dropFirst() {
                rowHeights.append(detailRowHeight(values: values, widths: widths))
            }
        }

        return WorkbookWorksheet(
            name: name,
            rows: rows,
            widths: widths,
            rowHeights: rowHeights,
            styles: styles,
            mergedCells: ["A1:\(lastColumn)1", "A2:\(lastColumn)2"],
            frozenRows: 4,
            frozenColumns: 0,
            autoFilterRow: dataRows.isEmpty ? nil : 4
        )
    }

    private static func paddedRow(_ values: [String], count: Int) -> [String] {
        Array((values + Array(repeating: "", count: max(count - values.count, 0))).prefix(count))
    }

    private static func detailRowHeight(values: [String], widths: [Double]) -> Double {
        let lineCount =
            values.enumerated().map { index, value in
                estimatedLineCount(value, width: index < widths.count ? widths[index] : 18)
            }.max() ?? 1
        return min(max(Double(lineCount) * 15 + 10, 28), 88)
    }

    private static func textRowHeight(
        _ value: String,
        width: Double,
        minimum: Double,
        maximum: Double
    ) -> Double {
        min(max(Double(estimatedLineCount(value, width: width)) * 15 + 10, minimum), maximum)
    }

    private static func estimatedLineCount(_ value: String, width: Double) -> Int {
        value.split(separator: "\n", omittingEmptySubsequences: false).reduce(0) { result, line in
            result + max(Int(ceil(Double(max(line.count, 1)) / max(width * 1.15, 1))), 1)
        }
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
        <styleSheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">
          <fonts count="7">
            <font><color rgb="FF2A2420"/><sz val="11"/><name val="Aptos"/><family val="2"/></font>
            <font><b/><color rgb="FF2A2420"/><sz val="22"/><name val="Georgia"/><family val="1"/></font>
            <font><color rgb="FF696058"/><sz val="11"/><name val="Aptos"/><family val="2"/></font>
            <font><b/><color rgb="FFFFFFFF"/><sz val="11"/><name val="Aptos Display"/><family val="2"/></font>
            <font><b/><color rgb="FF2A2420"/><sz val="11"/><name val="Aptos"/><family val="2"/></font>
            <font><b/><color rgb="FF88464A"/><sz val="10"/><name val="Aptos"/><family val="2"/></font>
            <font><b/><color rgb="FF2A2420"/><sz val="11"/><name val="Aptos"/><family val="2"/></font>
          </fonts>
          <fills count="10">
            <fill><patternFill patternType="none"/></fill>
            <fill><patternFill patternType="gray125"/></fill>
            <fill><patternFill patternType="solid"><fgColor rgb="FFF4F1EA"/><bgColor indexed="64"/></patternFill></fill>
            <fill><patternFill patternType="solid"><fgColor rgb="FFFBF9F4"/><bgColor indexed="64"/></patternFill></fill>
            <fill><patternFill patternType="solid"><fgColor rgb="FF88464A"/><bgColor indexed="64"/></patternFill></fill>
            <fill><patternFill patternType="solid"><fgColor rgb="FFE9DED3"/><bgColor indexed="64"/></patternFill></fill>
            <fill><patternFill patternType="solid"><fgColor rgb="FFE3D6C8"/><bgColor indexed="64"/></patternFill></fill>
            <fill><patternFill patternType="solid"><fgColor rgb="FFEEE5DD"/><bgColor indexed="64"/></patternFill></fill>
            <fill><patternFill patternType="solid"><fgColor rgb="FFF5E5D8"/><bgColor indexed="64"/></patternFill></fill>
            <fill><patternFill patternType="solid"><fgColor rgb="FFC66E71"/><bgColor indexed="64"/></patternFill></fill>
          </fills>
          <borders count="4">
            <border><left/><right/><top/><bottom/><diagonal/></border>
            <border><left style="thin"><color rgb="FFE8E0D5"/></left><right style="thin"><color rgb="FFE8E0D5"/></right><top style="thin"><color rgb="FFE8E0D5"/></top><bottom style="thin"><color rgb="FFE8E0D5"/></bottom><diagonal/></border>
            <border><left style="thin"><color rgb="FF88464A"/></left><right style="thin"><color rgb="FF88464A"/></right><top style="thin"><color rgb="FF88464A"/></top><bottom style="medium"><color rgb="FF88464A"/></bottom><diagonal/></border>
            <border><left style="medium"><color rgb="FFC66E71"/></left><right style="thin"><color rgb="FFCDBEAC"/></right><top style="thin"><color rgb="FFCDBEAC"/></top><bottom style="thin"><color rgb="FFCDBEAC"/></bottom><diagonal/></border>
          </borders>
          <cellStyleXfs count="1"><xf numFmtId="0" fontId="0" fillId="0" borderId="0"/></cellStyleXfs>
          <cellXfs count="16">
            <xf numFmtId="0" fontId="0" fillId="0" borderId="0" xfId="0"/>
            <xf numFmtId="0" fontId="1" fillId="2" borderId="0" xfId="0" applyFont="1" applyFill="1" applyAlignment="1"><alignment horizontal="left" vertical="center" wrapText="1"/></xf>
            <xf numFmtId="0" fontId="2" fillId="2" borderId="0" xfId="0" applyFont="1" applyFill="1" applyAlignment="1"><alignment horizontal="left" vertical="center" wrapText="1"/></xf>
            <xf numFmtId="0" fontId="5" fillId="2" borderId="0" xfId="0" applyFont="1" applyFill="1" applyAlignment="1"><alignment horizontal="right" vertical="center"/></xf>
            <xf numFmtId="0" fontId="3" fillId="4" borderId="2" xfId="0" applyFont="1" applyFill="1" applyBorder="1" applyAlignment="1"><alignment horizontal="center" vertical="center" wrapText="1"/></xf>
            <xf numFmtId="0" fontId="4" fillId="3" borderId="1" xfId="0" applyFont="1" applyFill="1" applyBorder="1" applyAlignment="1"><alignment horizontal="right" vertical="center" wrapText="1"/></xf>
            <xf numFmtId="0" fontId="0" fillId="3" borderId="1" xfId="0" applyFont="1" applyFill="1" applyBorder="1" applyAlignment="1"><alignment horizontal="left" vertical="center" wrapText="1" indent="1"/></xf>
            <xf numFmtId="0" fontId="5" fillId="2" borderId="1" xfId="0" applyFont="1" applyFill="1" applyBorder="1" applyAlignment="1"><alignment horizontal="left" vertical="center" wrapText="1" indent="1"/></xf>
            <xf numFmtId="0" fontId="0" fillId="2" borderId="1" xfId="0" applyFont="1" applyFill="1" applyBorder="1" applyAlignment="1"><alignment horizontal="center" vertical="center"/></xf>
            <xf numFmtId="0" fontId="6" fillId="5" borderId="3" xfId="0" applyFont="1" applyFill="1" applyBorder="1" applyAlignment="1"><alignment horizontal="center" vertical="center" wrapText="1"/></xf>
            <xf numFmtId="0" fontId="6" fillId="6" borderId="3" xfId="0" applyFont="1" applyFill="1" applyBorder="1" applyAlignment="1"><alignment horizontal="center" vertical="center" wrapText="1"/></xf>
            <xf numFmtId="0" fontId="0" fillId="3" borderId="1" xfId="0" applyFont="1" applyFill="1" applyBorder="1" applyAlignment="1"><alignment horizontal="left" vertical="top" wrapText="1" indent="1"/></xf>
            <xf numFmtId="0" fontId="0" fillId="2" borderId="1" xfId="0" applyFont="1" applyFill="1" applyBorder="1" applyAlignment="1"><alignment horizontal="left" vertical="top" wrapText="1" indent="1"/></xf>
            <xf numFmtId="0" fontId="4" fillId="7" borderId="1" xfId="0" applyFont="1" applyFill="1" applyBorder="1" applyAlignment="1"><alignment horizontal="left" vertical="top" wrapText="1" indent="1"/></xf>
            <xf numFmtId="0" fontId="0" fillId="8" borderId="1" xfId="0" applyFont="1" applyFill="1" applyBorder="1" applyAlignment="1"><alignment horizontal="left" vertical="top" wrapText="1" indent="1"/></xf>
            <xf numFmtId="0" fontId="0" fillId="2" borderId="0" xfId="0" applyFont="1" applyFill="1"/>
          </cellXfs>
          <cellStyles count="1"><cellStyle name="Normal" xfId="0" builtinId="0"/></cellStyles>
        </styleSheet>
        """

    private static func worksheetXML(_ sheet: WorkbookWorksheet) -> String {
        let maximumColumns = max(sheet.rows.map(\.count).max() ?? 1, sheet.widths.count)
        let columns = (0..<maximumColumns).map { index in
            let width = index < sheet.widths.count ? sheet.widths[index] : 18
            return "<col min=\"\(index + 1)\" max=\"\(index + 1)\" width=\"\(width)\" customWidth=\"1\"/>"
        }.joined()
        let rowXML = sheet.rows.enumerated().map { rowIndex, values in
            let cells = (0..<maximumColumns).map { columnIndex in
                let value = columnIndex < values.count ? values[columnIndex] : ""
                let reference = "\(columnName(columnIndex + 1))\(rowIndex + 1)"
                let style =
                    rowIndex < sheet.styles.count && columnIndex < sheet.styles[rowIndex].count
                    ? sheet.styles[rowIndex][columnIndex]
                    : 0
                return "<c r=\"\(reference)\" t=\"inlineStr\" s=\"\(style)\"><is><t xml:space=\"preserve\">\(xmlEscaped(value))</t></is></c>"
            }.joined()
            let height = rowIndex < sheet.rowHeights.count ? sheet.rowHeights[rowIndex] : 24
            return "<row r=\"\(rowIndex + 1)\" ht=\"\(height)\" customHeight=\"1\">\(cells)</row>"
        }.joined()
        let lastCell = "\(columnName(maximumColumns))\(max(sheet.rows.count, 1))"
        let pane = paneXML(frozenRows: sheet.frozenRows, frozenColumns: sheet.frozenColumns)
        let mergeCellXML = sheet.mergedCells.map { "<mergeCell ref=\"\($0)\"/>" }.joined()
        let mergedCells =
            sheet.mergedCells.isEmpty
            ? ""
            : "<mergeCells count=\"\(sheet.mergedCells.count)\">\(mergeCellXML)</mergeCells>"
        let autoFilter =
            sheet.autoFilterRow.map {
                "<autoFilter ref=\"A\($0):\(columnName(maximumColumns))\(max(sheet.rows.count, $0))\"/>"
            } ?? ""
        return """
            <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
            <worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"><sheetPr><tabColor rgb="FF88464A"/><pageSetUpPr fitToPage="1"/></sheetPr><dimension ref="A1:\(lastCell)"/><sheetViews><sheetView workbookViewId="0" showGridLines="0" zoomScale="90">\(pane)</sheetView></sheetViews><sheetFormatPr defaultRowHeight="24"/><cols>\(columns)</cols><sheetData>\(rowXML)</sheetData>\(mergedCells)\(autoFilter)<printOptions horizontalCentered="1"/><pageMargins left="0.35" right="0.35" top="0.5" bottom="0.5" header="0.2" footer="0.2"/><pageSetup orientation="landscape" fitToWidth="1" fitToHeight="0"/></worksheet>
            """
    }

    private static func paneXML(frozenRows: Int, frozenColumns: Int) -> String {
        guard frozenRows > 0 || frozenColumns > 0 else { return "" }
        let topLeftCell = "\(columnName(frozenColumns + 1))\(frozenRows + 1)"
        let activePane: String
        if frozenRows > 0, frozenColumns > 0 {
            activePane = "bottomRight"
        } else if frozenRows > 0 {
            activePane = "bottomLeft"
        } else {
            activePane = "topRight"
        }
        let xSplit = frozenColumns > 0 ? " xSplit=\"\(frozenColumns)\"" : ""
        let ySplit = frozenRows > 0 ? " ySplit=\"\(frozenRows)\"" : ""
        return "<pane\(xSplit)\(ySplit) topLeftCell=\"\(topLeftCell)\" activePane=\"\(activePane)\" state=\"frozen\"/>"
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
