// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

#if canImport(FoundationXML)
    import FoundationXML
#endif

#if canImport(Darwin)
    import Darwin
#elseif canImport(Glibc)
    import Glibc
#endif

struct MetalinkDocument {
    struct FileEntry {
        var name: String
        var urls: [String]
    }

    var files: [FileEntry]

    static func readFile(_ url: URL) throws -> Data {
        var info = stat()
        if stat(url.path, &info) != 0 {
            throw EngineError.metalinkRejected("unreadable")
        }
        if (info.st_mode & S_IFMT) != S_IFREG {
            throw EngineError.metalinkRejected("type")
        }
        if info.st_size <= 0 || info.st_size > 1_048_576 {
            throw EngineError.metalinkRejected("size")
        }
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw EngineError.metalinkRejected("unreadable")
        }
        if data.count != Int(info.st_size) {
            throw EngineError.metalinkRejected("size")
        }
        return data
    }

    static func parse(_ data: Data, downloadRoot: URL) throws -> MetalinkDocument {
        if data.isEmpty || data.count > 1_048_576 {
            throw EngineError.metalinkRejected("size")
        }
        let parsed = try parseXML(data)
        if parsed.files.isEmpty {
            throw EngineError.metalinkRejected("empty")
        }
        if parsed.files.count > 4096 {
            throw EngineError.metalinkRejected("file")
        }
        for file in parsed.files {
            try validateName(file.name, downloadRoot: downloadRoot)
            if file.urls.isEmpty {
                throw EngineError.metalinkRejected("url")
            }
            for urlText in file.urls {
                try validateMirror(urlText)
            }
        }
        return parsed
    }

    static func validateName(_ name: String, downloadRoot: URL) throws {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("-") {
            throw EngineError.outputNameRejected(name)
        }
        if trimmed.hasPrefix("/") {
            throw EngineError.outputNameRejected(name)
        }
        try DownloadPath.validateOutputName(trimmed)
        _ = try DownloadPath.resolveInside(root: downloadRoot, raw: trimmed)
    }

    static func validateMirror(_ text: String) throws {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            throw EngineError.schemeRejected("empty")
        }
        if trimmed.hasPrefix("-") {
            throw EngineError.schemeRejected("option")
        }
        if trimmed.count > 4096 {
            throw EngineError.metalinkRejected("url")
        }
        guard let parsed = URL(string: trimmed), parsed.scheme != nil else {
            throw EngineError.schemeRejected("unparseable")
        }
        try acceptMirror(parsed)
    }

    private static func acceptMirror(_ url: URL) throws {
        let absolute = url.absoluteString
        if absolute.hasPrefix("-") {
            throw EngineError.schemeRejected("option")
        }
        switch url.scheme?.lowercased() {
        case "http", "https", "ftp", "sftp":
            try HTTPURLPolicy.validateTransfer(url)
        case "magnet":
            _ = try MagnetLink.canonical(url)
        case let scheme?:
            throw EngineError.schemeRejected(scheme)
        case nil:
            throw EngineError.schemeRejected("")
        }
    }

    private static func parseXML(_ data: Data) throws -> MetalinkDocument {
        let parser = XMLParser(data: data)
        let collector = Collector()
        parser.delegate = collector
        parser.shouldProcessNamespaces = true
        parser.shouldResolveExternalEntities = false
        parser.shouldReportNamespacePrefixes = false
        guard parser.parse() else {
            throw collector.failure ?? EngineError.metalinkRejected("xml")
        }
        if let failure = collector.failure {
            throw failure
        }
        return MetalinkDocument(files: collector.files)
    }
}

private final class Collector: NSObject, XMLParserDelegate {
    var files: [MetalinkDocument.FileEntry] = []
    var failure: EngineError?
    private var inFile = false
    private var currentName = ""
    private var currentURLs: [String] = []
    private var currentText = ""
    private var capturingURL = false

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI _: String?,
        qualifiedName _: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        let local = localName(elementName)
        if local == "file" {
            inFile = true
            currentName = attributeDict["name"] ?? ""
            currentURLs = []
            currentText = ""
            capturingURL = false
            return
        }
        if inFile && isMirrorElement(local) {
            capturingURL = true
            currentText = ""
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if capturingURL {
            currentText += string
        }
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI _: String?,
        qualifiedName _: String?
    ) {
        let local = localName(elementName)
        if capturingURL && isMirrorElement(local) {
            currentURLs.append(currentText)
            capturingURL = false
            currentText = ""
            return
        }
        if local == "file" && inFile {
            files.append(MetalinkDocument.FileEntry(name: currentName, urls: currentURLs))
            inFile = false
            capturingURL = false
        }
    }

    func parser(_ parser: XMLParser, parseErrorOccurred _: Error) {
        failure = EngineError.metalinkRejected("xml")
        parser.abortParsing()
    }

    func parser(_ parser: XMLParser, validationErrorOccurred _: Error) {
        failure = EngineError.metalinkRejected("xml")
        parser.abortParsing()
    }

    private func localName(_ name: String) -> String {
        if let colon = name.lastIndex(of: ":") {
            return String(name[name.index(after: colon)...])
        }
        return name
    }

    private func isMirrorElement(_ name: String) -> Bool {
        name == "url" || name == "metaurl"
    }
}
