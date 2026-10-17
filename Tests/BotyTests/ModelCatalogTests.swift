import XCTest

@testable import Boty

final class ModelCatalogTests: XCTestCase {
    /// Muestra con la forma real de `~/.local/share/muse/model-catalog/*.json`.
    private let sample = """
        {
          "schema_version": 2,
          "provider_id": "meta",
          "profile_id": "tbh",
          "source": "provider_catalog",
          "rows": [
            {
              "model_id": "muse-spark-1.3",
              "display_label": "muse-spark-1.3",
              "visibility": "visible",
              "is_current": false,
              "is_default": false
            },
            {
              "model_id": "muse-spark-1.3-contributor",
              "display_label": "muse-spark-1.3-contributor",
              "visibility": "visible",
              "is_current": true,
              "is_default": true,
              "description": "Your content may be used for product improvement."
            },
            {
              "model_id": "muse-image-1.0",
              "display_label": "muse-image-1.0",
              "visibility": "hidden",
              "is_current": false,
              "is_default": false
            },
            {
              "display_label": "sin id",
              "visibility": "visible"
            }
          ]
        }
        """

    func testParseVisibleModels() {
        let models = parseModelCatalogFile(Data(sample.utf8))
        XCTAssertEqual(models.map(\.modelId), ["muse-spark-1.3", "muse-spark-1.3-contributor"])
        XCTAssertEqual(models[1].displayLabel, "muse-spark-1.3-contributor")
        XCTAssertTrue(models[1].isCurrent)
        XCTAssertTrue(models[1].isDefault)
        XCTAssertEqual(models[1].details, "Your content may be used for product improvement.")
        // Ocultos y filas sin model_id se ignoran sin romper el resto.
        XCTAssertFalse(models.map(\.modelId).contains("muse-image-1.0"))
    }

    func testParseRejectsGarbage() {
        XCTAssertEqual(parseModelCatalogFile(Data()), [])
        XCTAssertEqual(parseModelCatalogFile(Data("hola".utf8)), [])
        XCTAssertEqual(parseModelCatalogFile(Data("{}".utf8)), [])
        XCTAssertEqual(parseModelCatalogFile(Data(#"{"rows": "no es lista"}"#.utf8)), [])
    }

    func testParseToleratesMissingFields() {
        let models = parseModelCatalogFile(Data(#"{"rows": [{"model_id": "x"}]}"#.utf8))
        XCTAssertEqual(models.count, 1)
        XCTAssertEqual(models[0].displayLabel, "x")
        XCTAssertFalse(models[0].isCurrent)
        XCTAssertFalse(models[0].isDefault)
        XCTAssertNil(models[0].details)
    }

    func testPickerLabelMarksDefaultAndCurrent() {
        XCTAssertEqual(
            CatalogModel(
                modelId: "a", displayLabel: "a", isCurrent: false, isDefault: true, details: nil
            ).pickerLabel,
            "a (por defecto)"
        )
        XCTAssertEqual(
            CatalogModel(
                modelId: "b", displayLabel: "b", isCurrent: true, isDefault: false, details: nil
            ).pickerLabel,
            "b (actual)"
        )
        XCTAssertEqual(
            CatalogModel(
                modelId: "c", displayLabel: "c", isCurrent: false, isDefault: false, details: nil
            ).pickerLabel,
            "c"
        )
    }

    func testLoadMergesFilesDedupesAndSortsDefaultFirst() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("boty-catalog-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        // Segundo fichero con un duplicado y un modelo extra.
        let extra = """
            {"rows": [
              {"model_id": "muse-spark-1.3", "visibility": "visible"},
              {"model_id": "muse-spark-1.2", "visibility": "visible"}
            ]}
            """
        try Data(sample.utf8).write(to: dir.appendingPathComponent("a.json"))
        try Data(extra.utf8).write(to: dir.appendingPathComponent("b.json"))
        try Data("ignorado".utf8).write(to: dir.appendingPathComponent("c.txt"))

        let models = loadModelCatalogModels(directory: dir)
        XCTAssertEqual(
            models.map(\.modelId),
            ["muse-spark-1.3-contributor", "muse-spark-1.2", "muse-spark-1.3"]
        )
    }

    func testLoadMissingDirectoryIsEmpty() {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("boty-no-existe-\(UUID().uuidString)", isDirectory: true)
        XCTAssertEqual(loadModelCatalogModels(directory: missing), [])
    }
}
