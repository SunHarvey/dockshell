import Darwin
import Foundation

private struct CatalogFailure: Error, CustomStringConvertible {
    let description: String
}

/// A deliberately narrow String Catalog compiler, not a replacement for Apple's tools.
/// M1 supports translated, plain strings in en/zh-Hans. Unsupported input fails the build.
private enum CatalogCompiler {
    static let languages: Set<String> = ["en", "zh-Hans"]

    static func object(_ value: Any?, at path: String) throws -> [String: Any] {
        guard let object = value as? [String: Any] else {
            throw CatalogFailure(description: "Expected an object at \(path)")
        }
        return object
    }

    static func only(_ allowed: Set<String>, in object: [String: Any], at path: String) throws {
        let unknown = Set(object.keys).subtracting(allowed)
        guard unknown.isEmpty else {
            throw CatalogFailure(description: "Unsupported fields at \(path): \(unknown.sorted())")
        }
    }

    static func tables(from data: Data) throws -> [String: [String: String]] {
        let root = try object(JSONSerialization.jsonObject(with: data), at: "catalog")
        try only(["sourceLanguage", "strings", "version"], in: root, at: "catalog")
        guard root["version"] as? String == "1.0", root["sourceLanguage"] as? String == "en" else {
            throw CatalogFailure(description: "Only catalog version 1.0 with sourceLanguage en is supported")
        }
        let entries = try object(root["strings"], at: "strings")
        guard !entries.isEmpty else { throw CatalogFailure(description: "The catalog is empty") }
        var result = Dictionary(uniqueKeysWithValues: languages.map { ($0, [String: String]()) })

        for key in entries.keys.sorted() {
            guard key.range(of: #"^[a-z][a-z0-9]*(\.[a-z][a-z0-9]*)+$"#,
                            options: .regularExpression) != nil else {
                throw CatalogFailure(description: "Unsupported localization key: \(key)")
            }
            let entry = try object(entries[key], at: key)
            try only(["comment", "extractionState", "localizations"], in: entry, at: key)
            guard entry["extractionState"] as? String == "manual" else {
                throw CatalogFailure(description: "\(key) must have extractionState manual")
            }
            if let comment = entry["comment"], !(comment is String) {
                throw CatalogFailure(description: "\(key).comment must be text")
            }
            let localizations = try object(entry["localizations"], at: "\(key).localizations")
            guard Set(localizations.keys) == languages else {
                throw CatalogFailure(description: "\(key) requires exactly en and zh-Hans translations")
            }
            for language in languages.sorted() {
                let path = "\(key).\(language)"
                let localization = try object(localizations[language], at: path)
                try only(["stringUnit"], in: localization, at: path)
                let unit = try object(localization["stringUnit"], at: "\(path).stringUnit")
                try only(["state", "value"], in: unit, at: path)
                guard unit["state"] as? String == "translated",
                      let value = unit["value"] as? String, !value.isEmpty else {
                    throw CatalogFailure(description: "\(path) needs a nonempty, translated string")
                }
                // Plurals, substitutions, and format placeholders need a separate verified extension.
                guard !value.contains("%"), !value.contains("\0") else {
                    throw CatalogFailure(description: "\(path): percent formatting and NUL are unsupported in M1")
                }
                result[language]?[key] = value
            }
        }
        return result
    }

    static func compile(input: URL, output: URL) throws {
        let tables = try tables(from: Data(contentsOf: input))
        let manager = FileManager.default
        try manager.createDirectory(at: output, withIntermediateDirectories: true)
        let info: [String: Any] = [
            "CFBundleIdentifier": "dev.dockshell.resources",
            "CFBundleName": "DockShellResources",
            "CFBundlePackageType": "BNDL",
            "CFBundleVersion": "1",
            "CFBundleDevelopmentRegion": "en",
            "CFBundleLocalizations": languages.sorted(),
        ]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            .write(to: output.appendingPathComponent("Info.plist"), options: .atomic)
        for language in languages.sorted() {
            let directory = output.appendingPathComponent("\(language).lproj", isDirectory: true)
            try manager.createDirectory(at: directory, withIntermediateDirectories: true)
            // Apple's runtime accepts binary .strings plists. Serialization handles Unicode and escaping.
            let data = try PropertyListSerialization.data(
                fromPropertyList: tables[language] ?? [:], format: .binary, options: 0
            )
            try data.write(to: directory.appendingPathComponent("Localizable.strings"), options: .atomic)
        }
        print("Compiled \(tables["en"]?.count ?? 0) keys × 2 languages: \(output.path)")
    }

    static func selfTest() throws {
        func fixture(_ value: String = "中文🙂\n\"quoted\"\\path") -> [String: Any] {
            ["sourceLanguage": "en", "version": "1.0", "strings": [
                "test.value": ["extractionState": "manual", "localizations": [
                    "en": ["stringUnit": ["state": "translated", "value": value]],
                    "zh-Hans": ["stringUnit": ["state": "translated", "value": value]],
                ]],
            ]]
        }
        func encode(_ root: [String: Any]) throws -> Data {
            try JSONSerialization.data(withJSONObject: root)
        }
        let source = fixture()
        let compiled = try tables(from: encode(source))
        let data = try PropertyListSerialization.data(fromPropertyList: compiled["en"]!, format: .binary, options: 0)
        let decoded = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: String]
        guard decoded == compiled["en"] else {
            throw CatalogFailure(description: "Unicode/escaping round-trip failed")
        }

        var invalid: [[String: Any]] = []
        var unknown = source
        unknown["futureField"] = true
        invalid.append(unknown)
        var version = source
        version["version"] = "2.0"
        invalid.append(version)
        invalid.append(fixture("%lld items"))
        invalid.append(fixture("bad\0value"))
        for mode in ["missing", "unfinished", "variation", "extra-language"] {
            var root = source
            var entries = root["strings"] as! [String: Any]
            var entry = entries["test.value"] as! [String: Any]
            var translations = entry["localizations"] as! [String: Any]
            if mode == "missing" { translations.removeValue(forKey: "zh-Hans") }
            if mode == "extra-language" { translations["fr"] = translations["en"] }
            if mode == "unfinished" {
                translations["en"] = ["stringUnit": ["state": "needs_review", "value": "Review"]]
            }
            if mode == "variation" { translations["en"] = ["variations": ["plural": [:]]] }
            entry["localizations"] = translations
            entries["test.value"] = entry
            root["strings"] = entries
            invalid.append(root)
        }
        for (index, root) in invalid.enumerated() {
            do {
                _ = try tables(from: encode(root))
            } catch is CatalogFailure {
                continue
            }
            throw CatalogFailure(description: "Invalid fixture \(index) was accepted")
        }
        print("PASS catalog: Unicode/escaping round-trip; \(invalid.count) unsupported inputs rejected")
    }
}

@main
private enum CatalogCompilerMain {
    static func main() {
        do {
            let arguments = Array(CommandLine.arguments.dropFirst())
            if arguments == ["--self-test"] {
                try CatalogCompiler.selfTest()
            } else if arguments.count == 2 {
                try CatalogCompiler.compile(input: URL(fileURLWithPath: arguments[0]),
                                            output: URL(fileURLWithPath: arguments[1]))
            } else {
                throw CatalogFailure(description: "Usage: catalog-compiler <catalog.xcstrings> <output.bundle> | --self-test")
            }
        } catch {
            FileHandle.standardError.write(Data("Catalog error: \(error)\n".utf8))
            exit(EXIT_FAILURE)
        }
    }
}
