import XCTest
import FoundationModels
@testable import ReflectLanguageModel

final class SchemaTests: XCTestCase {
    func testNoteToolSchemaWithNullableOptionalField() throws {
        let json = #"{"type":"object","properties":{"limit":{"type":"integer","minimum":1,"maximum":20},"tag":{"type":["string","null"]}},"additionalProperties":false}"#
        let schema = try JSONDecoder().decode(Schema.self, from: Data(json.utf8))
        XCTAssertEqual(schema.properties?["tag"]?.type?.name, "string")
        if #available(macOS 26.4, iOS 26.4, *) {
            let result = try GenerationSchema(root: dynamicSchema(schema, name: "RecentNotes"), dependencies: [])
            XCTAssertFalse(try JSONEncoder().encode(result).isEmpty)
        }
    }
    func testReadNotesArraySchema() throws {
        let json = #"{"type":"object","properties":{"paths":{"type":"array","items":{"type":"string"},"minItems":1,"maxItems":10}},"required":["paths"]}"#
        let schema = try JSONDecoder().decode(Schema.self, from: Data(json.utf8))
        if #available(macOS 26.4, iOS 26.4, *) {
            XCTAssertNoThrow(try GenerationSchema(root: dynamicSchema(schema, name: "ReadNotes"), dependencies: []))
        }
    }
    func testUnsupportedSchemaFailsClearly() throws {
        let schema = try JSONDecoder().decode(Schema.self, from: Data(#"{"type":"unknown"}"#.utf8))
        if #available(macOS 26.4, iOS 26.4, *) {
            XCTAssertThrowsError(try dynamicSchema(schema, name: "Unsupported"))
        }
    }
}
