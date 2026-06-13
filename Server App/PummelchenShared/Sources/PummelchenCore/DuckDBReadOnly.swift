import Foundation

public struct DuckDBReportingClient: Sendable {
    public let databasePath: String

    public init(databasePath: String) {
        self.databasePath = databasePath
    }

    public func countRows(inReportingView viewName: String) throws -> Int {
        try ContractValidation.require(
            viewName.range(of: #"^[A-Za-z_][A-Za-z0-9_]*$"#, options: .regularExpression) != nil,
            "invalid reporting view name: \(viewName)"
        )
        let output = try queryCSV("SELECT COUNT(*) FROM reporting.\"\(viewName)\";")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let value = Int(output) else {
            throw ContractValidationError.invalid("could not parse DuckDB count for \(viewName): \(output)")
        }
        return value
    }

    public func queryCSV(_ sql: String) throws -> String {
        try DuckDBDatabase(databaseURL: URL(fileURLWithPath: databasePath), readOnly: true)
            .queryCSV(sql, includeHeader: false)
    }
}
