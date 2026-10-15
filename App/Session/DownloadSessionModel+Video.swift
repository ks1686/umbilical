// umbilical downloads files. It never seeds.
// Copyright (C) 2026 Karim Smires
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import UmbilicalEngine

extension DownloadSessionModel {
    public func addVideo(urlText: String, outputName: String, folder: URL?) async throws {
        guard let directory else {
            throw SessionError.folderMissing
        }
        guard phase == .running else {
            throw SessionError.engineNotRunning
        }
        guard let ytDlp = video.ytDlp else {
            throw EngineError.executableMissing("yt-dlp")
        }
        guard let watch = video.watch else {
            throw EngineError.executableMissing("umb-watch")
        }
        let job = try VideoDownloadJob.start(
            ytDlp: ytDlp,
            watch: watch,
            urlText: urlText,
            outputName: outputName,
            directory: folder,
            root: directory,
            quarantine: quarantine
        )
        videoJobs[job.id] = job
        tracked.insert(makeVideoItem(job), at: 0)
        setMessage(nil)
        rebuild()
    }

    func refreshVideos() {
        var finished: [String] = []
        for (id, job) in videoJobs {
            guard let index = index(of: id) else {
                finished.append(id)
                continue
            }
            if applyVideo(job.progress(), at: index) {
                finished.append(id)
            }
        }
        for id in finished {
            videoJobs.removeValue(forKey: id)
        }
    }

    func stopVideoProcesses() {
        let jobs = videoJobs
        videoJobs.removeAll()
        for job in jobs.values {
            job.cancel()
        }
    }

    func markVideoStopped(_ message: String) {
        for index in tracked.indices where tracked[index].cancelsLiveVideo {
            tracked[index].track = false
            tracked[index].state = .error
            tracked[index].downloadSpeed = 0
            if tracked[index].errorMessage == nil {
                tracked[index].errorMessage = message
            }
        }
    }

    private func makeVideoItem(_ job: VideoDownloadJob) -> TrackedDownload {
        TrackedDownload(
            id: job.id,
            engineGID: nil,
            track: true,
            outputName: job.outputName,
            url: job.url,
            detail: job.url.absoluteString,
            state: .active,
            totalLength: 0,
            completedLength: 0,
            downloadSpeed: 0,
            errorMessage: nil,
            filePath: nil,
            historyID: nil,
            fixedTitle: nil,
            pausable: false
        )
    }

    private func applyVideo(_ progress: VideoDownloadProgress, at index: Int) -> Bool {
        let previous = tracked[index].state
        tracked[index].completedLength = progress.completed
        tracked[index].totalLength = progress.total
        tracked[index].downloadSpeed = progress.phase == .running ? progress.speed : 0
        switch progress.phase {
        case .running:
            tracked[index].state = .active
            return false
        case .finished:
            return finishVideo(progress, at: index, previous: previous)
        case .failed:
            return failVideo(progress.message, at: index, previous: previous)
        case .cancelled:
            tracked[index].state = .error
            tracked[index].track = false
            if tracked[index].errorMessage == nil {
                tracked[index].errorMessage = "Cancelled."
            }
            return true
        }
    }

    private func finishVideo(
        _ progress: VideoDownloadProgress,
        at index: Int,
        previous: DownloadStatus.State
    ) -> Bool {
        guard
            let path = progress.filePath,
            let accepted = acceptedFile([URL(fileURLWithPath: path)])
        else {
            return failVideo(
                "The video download did not produce a single file inside the download folder.",
                at: index,
                previous: previous
            )
        }
        tracked[index].state = .complete
        tracked[index].filePath = accepted
        tracked[index].downloadSpeed = 0
        if previous != .complete {
            finish(index)
        }
        return true
    }

    private func failVideo(
        _ message: String?,
        at index: Int,
        previous: DownloadStatus.State
    ) -> Bool {
        tracked[index].state = .error
        tracked[index].track = false
        tracked[index].downloadSpeed = 0
        tracked[index].errorMessage = message.map(DownloadMessage.redact)
        if previous != .error, settings.notifyOnFailure {
            notices.append(notice(kind: .failed, item: tracked[index]))
        }
        return true
    }
}
