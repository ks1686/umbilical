// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

#if canImport(Darwin)
    import Darwin
#elseif canImport(Glibc)
    import Glibc
#endif

/// Hosts that turn the add-sheet Video control on until the user changes it.
public enum VideoPagePolicy {
    public static let automaticHosts: [String] = [
        "bilibili.com",
        "dai.ly",
        "dailymotion.com",
        "facebook.com",
        "fb.watch",
        "instagram.com",
        "nicovideo.jp",
        "reddit.com",
        "rumble.com",
        "soundcloud.com",
        "streamable.com",
        "tiktok.com",
        "twitch.tv",
        "v.redd.it",
        "vimeo.com",
        "youtube-nocookie.com",
        "youtube.com",
        "youtu.be"
    ]

    public static func prefersVideo(urlText: String) -> Bool {
        let trimmed = urlText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed), url.scheme != nil else {
            return false
        }
        if (try? HTTPURLPolicy.validate(url)) == nil {
            return false
        }
        guard let host = url.host?.lowercased(), !host.isEmpty else {
            return false
        }
        let normalized = host.hasSuffix(".") ? String(host.dropLast()) : host
        for known in automaticHosts {
            if normalized == known || normalized.hasSuffix("." + known) {
                return true
            }
        }
        return false
    }
}

struct VideoDownloadTarget: Equatable {
    let url: URL
    let folder: URL
    let root: URL
    let outputName: String?
}

enum VideoDownloadPlan {
    static let outputTemplate = "umb-video.%(ext)s"
    /// Combined formats only. `/` is fallback. `+` would ask ffmpeg to merge.
    static let formatSelector =
        "b[acodec!=none][vcodec!=none]/best[acodec!=none][vcodec!=none]"
    static let unavailableAudioMessage =
        "This site didn't offer a version with sound that umbilical can save without extra tools."
    static let progressPrefix = "UMBPROGRESS"
    static let progressTemplate =
        "download:\(progressPrefix) %(progress.downloaded_bytes)s "
        + "%(progress.total_bytes)s %(progress.total_bytes_estimate)s "
        + "%(progress.speed)s %(progress.eta)s"
    static let stagingPrefix = "umb-video-"

    static func target(
        urlText: String,
        outputName: String,
        directory: URL?,
        root: URL
    ) throws -> VideoDownloadTarget {
        let url = try videoURL(urlText)
        let acceptedRoot = try DownloadFolderRules.acceptRoot(root)
        let folder = try folderInside(directory, root: acceptedRoot)
        let name = try videoOutputName(outputName)
        return VideoDownloadTarget(
            url: url,
            folder: folder,
            root: acceptedRoot,
            outputName: name
        )
    }

    static func makeStagingDirectory(in folder: URL) throws -> URL {
        let bytes = try POSIX.randomBytes(count: 16)
        let token = bytes.map { String(format: "%02x", $0) }.joined()
        let name = stagingPrefix + token
        guard stagingName(name) else {
            throw EngineError.videoRejected("The video download was rejected.")
        }
        let url = folder.appendingPathComponent(name, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        } catch {
            throw EngineError.temporaryDirectoryFailed(error.localizedDescription)
        }
        if chmod(url.path, mode_t(0o700)) != 0 {
            VideoDownloadCleanup.removeStaging(url)
            throw EngineError.temporaryDirectoryFailed(POSIX.errnoText())
        }
        return url
    }

    static func arguments(for target: VideoDownloadTarget, stagingDirectory: URL) throws -> [String]
    {
        let staging = try resolvedStaging(
            stagingDirectory, folder: target.folder, root: target.root)
        if formatSelector.contains("+") || formatSelector.contains(" ") {
            throw EngineError.videoRejected("The video download was rejected.")
        }
        let stagingPath = staging.path
        let arguments = [
            "--ignore-config",
            "--no-config-locations",
            "--no-plugin-dirs",
            "--no-update",
            "--no-remote-components",
            "--no-js-runtimes",
            "--no-playlist",
            "--no-cache-dir",
            "--no-exec",
            "--no-colors",
            "--restrict-filenames",
            "--no-overwrites",
            "--downloader",
            "native",
            "--ffmpeg-location",
            stagingPath,
            "--fixup",
            "never",
            "--format",
            formatSelector,
            "--paths",
            "home:\(stagingPath)",
            "--paths",
            "temp:\(stagingPath)",
            "--output",
            outputTemplate,
            "--newline",
            "--progress",
            "--progress-template",
            progressTemplate,
            "--",
            target.url.absoluteString
        ]
        try assertSafe(arguments, url: target.url.absoluteString, stagingPath: stagingPath)
        return arguments
    }

    static func failureMessage(from lines: [String]) -> String {
        if describesMissingAudio(lines) {
            return unavailableAudioMessage
        }
        let line = lines.reversed().first { !$0.isEmpty } ?? ""
        let redacted = line.replacingOccurrences(
            of: "token:[0-9A-Fa-f]+",
            with: "token:[redacted]",
            options: .regularExpression
        )
        let cleaned = redacted.filter { character in
            character == "\t" || (character >= " " && character <= "~")
        }
        let clipped = String(cleaned.prefix(180))
        if clipped.isEmpty {
            return "The video download failed."
        }
        return "The video download failed. \(clipped)"
    }

    static func describesMissingAudio(_ lines: [String]) -> Bool {
        let text = lines.joined(separator: "\n").lowercased()
        return text.contains("requested format is not available")
            || text.contains("requested format not available")
    }

    static func childEnvironment(home: String) -> [String: String] {
        var environment = [
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
            "HOME": home,
            "LC_ALL": "C",
            "LANG": "C"
        ]
        let parent = ProcessInfo.processInfo.environment
        if let temporary = parent["TMPDIR"], safePath(temporary) {
            environment["TMPDIR"] = temporary
        } else {
            environment["TMPDIR"] = "/tmp"
        }
        return environment
    }

    static func finalFileName(outputName: String?, ext: String, token: String) -> String? {
        guard ext.range(of: "^[A-Za-z0-9]{1,8}$", options: .regularExpression) != nil else {
            return nil
        }
        guard stagingName(stagingPrefix + token) else {
            return nil
        }
        if let outputName {
            if outputName.contains(".") {
                return outputName
            }
            let combined = outputName + "." + ext
            if combined.count > 255 {
                return nil
            }
            return combined
        }
        return "\(stagingPrefix)\(token).\(ext)"
    }

    private static func videoURL(_ urlText: String) throws -> URL {
        let trimmed = urlText.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty || trimmed.contains(where: \.isWhitespace) {
            throw EngineError.schemeRejected(trimmed.isEmpty ? "empty" : "whitespace")
        }
        if trimmed.count > 4096 {
            throw EngineError.videoRejected("The video download was rejected.")
        }
        guard let url = URL(string: trimmed), url.scheme != nil else {
            throw EngineError.schemeRejected("unparseable")
        }
        if trimmed.hasPrefix("-") {
            throw EngineError.videoRejected("The video download was rejected.")
        }
        try HTTPURLPolicy.validate(url)
        guard let canonical = URL(string: url.absoluteString) else {
            throw EngineError.schemeRejected("unparseable")
        }
        try HTTPURLPolicy.validate(canonical)
        let absolute = canonical.absoluteString
        if absolute.hasPrefix("-") || absolute.contains("\n") || absolute.contains("\r") {
            throw EngineError.videoRejected("The video download was rejected.")
        }
        return canonical
    }

    private static func folderInside(_ directory: URL?, root: URL) throws -> URL {
        guard let directory else {
            return root
        }
        return try DownloadFolderRules.acceptChild(directory, root: root)
    }

    private static func videoOutputName(_ outputName: String) throws -> String? {
        let name = outputName.trimmingCharacters(in: .whitespacesAndNewlines)
        if name.isEmpty {
            return nil
        }
        if name.contains("%") {
            throw EngineError.videoRejected("The file name cannot include a percent sign.")
        }
        if name.count > 255 {
            throw EngineError.outputNameRejected(name)
        }
        try DownloadPath.validateOutputName(name)
        return name
    }

    private static func resolvedStaging(_ staging: URL, folder: URL, root: URL) throws -> URL {
        let resolved = try DownloadFolderRules.acceptChild(staging, root: folder)
        let rootResolved = try DownloadFolderRules.acceptRoot(root)
        _ = try DownloadPath.resolveInside(root: rootResolved, raw: resolved.path)
        let name = resolved.lastPathComponent
        if !stagingName(name) {
            throw EngineError.directoryRejected(resolved.path)
        }
        return resolved
    }

    private static func stagingName(_ name: String) -> Bool {
        name.range(of: "^umb-video-[0-9a-f]{32}$", options: .regularExpression) != nil
    }

    private static func safePath(_ value: String) -> Bool {
        value.hasPrefix("/") && !value.contains("\0") && !value.contains("\n")
            && !value.contains("\r")
    }

    private static func assertSafe(
        _ arguments: [String],
        url: String,
        stagingPath: String
    ) throws {
        let required = [
            "--ignore-config",
            "--no-config-locations",
            "--no-plugin-dirs",
            "--no-update",
            "--no-remote-components",
            "--no-js-runtimes",
            "--no-playlist",
            "--no-cache-dir",
            "--no-exec",
            "--downloader",
            "--fixup",
            "--format",
            "--output",
            "--paths"
        ]
        for flag in required where !arguments.contains(flag) {
            throw EngineError.videoRejected("The video download was rejected.")
        }
        try rejectForbidden(arguments)
        try expectPair("--downloader", "native", in: arguments)
        try expectPair("--fixup", "never", in: arguments)
        try expectPair("--format", formatSelector, in: arguments)
        try expectPair("--ffmpeg-location", stagingPath, in: arguments)
        try expectPair("--output", outputTemplate, in: arguments)
        if !arguments.contains("home:\(stagingPath)") || !arguments.contains("temp:\(stagingPath)")
        {
            throw EngineError.videoRejected("The video download was rejected.")
        }
        guard arguments.count >= 2, arguments[arguments.count - 2] == "--" else {
            throw EngineError.videoRejected("The video download was rejected.")
        }
        let http = url.hasPrefix("http://") || url.hasPrefix("https://")
        if arguments.last != url || !http {
            throw EngineError.videoRejected("The video download was rejected.")
        }
        if arguments.filter({ $0 == url }).count != 1 {
            throw EngineError.videoRejected("The video download was rejected.")
        }
    }

    private static func rejectForbidden(_ arguments: [String]) throws {
        for argument in arguments {
            if forbidden(argument) {
                throw EngineError.videoRejected("The video download was rejected.")
            }
        }
    }

    private static func forbidden(_ argument: String) -> Bool {
        if argument == "--exec" || argument.hasPrefix("--exec=") {
            return true
        }
        if argument.hasPrefix("--exec-before") {
            return true
        }
        if argument == "-U" || argument == "--update" || argument.hasPrefix("--update-to") {
            return true
        }
        if argument.hasPrefix("--cookies") {
            return true
        }
        if argument == "--config-locations" || argument.hasPrefix("--config-locations=") {
            return true
        }
        if argument == "--plugin-dirs" || argument.hasPrefix("--plugin-dirs=") {
            return true
        }
        if argument == "--batch-file" || argument.hasPrefix("--batch-file=") {
            return true
        }
        if argument == "--downloader-args" || argument.hasPrefix("--downloader-args=") {
            return true
        }
        if argument == "--external-downloader" || argument.hasPrefix("--external-downloader=") {
            return true
        }
        if argument == "--external-downloader-args"
            || argument.hasPrefix("--external-downloader-args=")
        {
            return true
        }
        if argument == "--js-runtimes" || argument.hasPrefix("--js-runtimes=") {
            return true
        }
        if argument == "--remote-components" || argument.hasPrefix("--remote-components=") {
            return true
        }
        return false
    }

    private static func expectPair(_ flag: String, _ value: String, in arguments: [String]) throws {
        var index = 0
        var found = false
        while index < arguments.count {
            if arguments[index] == flag {
                let next = index + 1
                if next >= arguments.count || arguments[next] != value {
                    throw EngineError.videoRejected("The video download was rejected.")
                }
                found = true
            }
            index += 1
        }
        if !found {
            throw EngineError.videoRejected("The video download was rejected.")
        }
    }
}

enum VideoProgressParser {
    static func parse(_ line: String) -> (completed: Int64, total: Int64, speed: Int64)? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = trimmed.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        guard parts.count == 6, parts[0] == VideoDownloadPlan.progressPrefix else {
            return nil
        }
        let fields = [
            classified(parts[1]),
            classified(parts[2]),
            classified(parts[3]),
            classified(parts[4]),
            classified(parts[5])
        ]
        if fields.contains(.invalid) {
            return nil
        }
        let done = amount(fields[0]) ?? 0
        let total = amount(fields[1]) ?? amount(fields[2]) ?? 0
        let rate = amount(fields[3]) ?? 0
        return (done, total, rate)
    }

    private enum ProgressToken: Equatable {
        case unknown
        case value(Int64)
        case invalid
    }

    private static func classified(_ token: String) -> ProgressToken {
        if token == "NA" || token == "None" || token == "null" {
            return .unknown
        }
        guard token.range(of: "^[0-9]{1,18}(\\.[0-9]+)?$", options: .regularExpression) != nil
        else {
            return .invalid
        }
        let whole = token.split(separator: ".", maxSplits: 1).first.map(String.init) ?? token
        guard let value = Int64(whole) else {
            return .invalid
        }
        return .value(value)
    }

    private static func amount(_ token: ProgressToken) -> Int64? {
        switch token {
        case .unknown, .invalid:
            return nil
        case .value(let value):
            return value
        }
    }
}

enum VideoDownloadCleanup {
    static func removeStaging(_ directory: URL) {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        for name in names {
            unlinkChild(directory, name)
        }
        _ = rmdir(directory.path)
    }

    private static func unlinkChild(_ directory: URL, _ name: String) {
        if name.isEmpty || name == "." || name == ".." || name.contains("/") {
            return
        }
        let path = directory.appendingPathComponent(name).path
        var info = stat()
        if lstat(path, &info) != 0 {
            return
        }
        let kind = info.st_mode & S_IFMT
        if kind == S_IFREG || kind == S_IFLNK {
            _ = unlink(path)
        }
    }
}

enum VideoDownloadFinisher {
    static func adopt(
        staging: URL,
        folder: URL,
        root: URL,
        outputName: String?,
        quarantine: any QuarantineApplying
    ) throws -> URL {
        let resolvedStaging = try DownloadFolderRules.acceptChild(staging, root: folder)
        let token = try stagingToken(resolvedStaging)
        let entries = try FileManager.default.contentsOfDirectory(atPath: resolvedStaging.path)
        let media = try mediaFile(entries, staging: resolvedStaging, root: root)
        try unlinkPartials(entries, media: media.name, staging: resolvedStaging)
        let finalName = VideoDownloadPlan.finalFileName(
            outputName: outputName,
            ext: media.ext,
            token: token
        )
        guard let finalName else {
            throw EngineError.videoRejected(
                "The video download did not produce a single file inside the download folder."
            )
        }
        try DownloadPath.validateOutputName(finalName)
        let destination = folder.appendingPathComponent(finalName)
        let resolvedDestination = try DownloadPath.resolveInside(root: root, raw: destination.path)
        let finalURL = URL(fileURLWithPath: resolvedDestination)
        if exists(destination.path) || exists(finalURL.path) {
            throw EngineError.videoRejected(
                "A file with that name is already in the download folder."
            )
        }
        try quarantine.markDownloaded(file: media.url)
        do {
            try FileManager.default.moveItem(at: media.url, to: finalURL)
        } catch {
            throw EngineError.videoRejected(
                "The video download did not produce a single file inside the download folder."
            )
        }
        if rmdir(resolvedStaging.path) != 0 {
            throw EngineError.videoRejected(
                "The video download did not produce a single file inside the download folder."
            )
        }
        _ = try DownloadPath.resolveInside(root: root, raw: finalURL.path)
        return finalURL
    }

    private static func stagingToken(_ staging: URL) throws -> String {
        let name = staging.lastPathComponent
        let prefix = VideoDownloadPlan.stagingPrefix
        guard name.hasPrefix(prefix) else {
            throw EngineError.directoryRejected(staging.path)
        }
        let token = String(name.dropFirst(prefix.count))
        if token.range(of: "^[0-9a-f]{32}$", options: .regularExpression) == nil {
            throw EngineError.directoryRejected(staging.path)
        }
        return token
    }

    private static func mediaFile(
        _ entries: [String],
        staging: URL,
        root: URL
    ) throws -> (name: String, ext: String, url: URL) {
        var matches: [(name: String, ext: String, url: URL)] = []
        for name in entries {
            guard let ext = mediaExtension(name) else {
                continue
            }
            let url = staging.appendingPathComponent(name)
            if !POSIX.isRegularFile(url.path) {
                throw EngineError.videoRejected(
                    "The video download did not produce a single file inside the download folder."
                )
            }
            _ = try DownloadPath.resolveInside(root: root, raw: url.path)
            matches.append((name, ext, url))
        }
        guard matches.count == 1, let media = matches.first else {
            throw EngineError.videoRejected(
                "The video download did not produce a single file inside the download folder."
            )
        }
        return media
    }

    private static func mediaExtension(_ name: String) -> String? {
        let pattern = "^umb-video\\.[A-Za-z0-9]{1,8}$"
        guard name.range(of: pattern, options: .regularExpression) != nil else {
            return nil
        }
        let ext = String(name.dropFirst("umb-video.".count))
        if ext.range(of: "^[A-Za-z0-9]{1,8}$", options: .regularExpression) == nil {
            return nil
        }
        return ext
    }

    private static func unlinkPartials(_ entries: [String], media: String, staging: URL) throws {
        for name in entries where name != media {
            if !isPartial(name) {
                throw EngineError.videoRejected(
                    "The video download did not produce a single file inside the download folder."
                )
            }
            let path = staging.appendingPathComponent(name).path
            if !POSIX.isRegularFile(path) {
                throw EngineError.videoRejected(
                    "The video download did not produce a single file inside the download folder."
                )
            }
            if unlink(path) != 0 {
                throw EngineError.videoRejected(
                    "The video download did not produce a single file inside the download folder."
                )
            }
        }
    }

    private static func isPartial(_ name: String) -> Bool {
        if !name.hasPrefix("umb-video.") {
            return false
        }
        if name.hasSuffix(".ytdl") || name.hasSuffix(".temp") {
            return true
        }
        return name.contains(".part")
    }

    private static func exists(_ path: String) -> Bool {
        var info = stat()
        return lstat(path, &info) == 0
    }
}
