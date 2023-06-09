///
/// Copyright (c) 2016 Dropbox, Inc. All rights reserved.
///

import Foundation

// 10 MB file chunk size
let fileChunkSize: UInt64 = 10 * 1024 * 1024
let timeoutInSec = 200

extension FilesRoutes {

    @discardableResult public func batchUploadFiles(fileUrlsToCommitInfo: [URL: Files.CommitInfo], queue: DispatchQueue? = nil, progressBlock: ProgressBlock? = nil, responseBlock: @escaping BatchUploadResponseBlock) -> BatchUploadTask {
        let uploadData = BatchUploadData(fileCommitInfo: fileUrlsToCommitInfo, progressBlock: progressBlock, responseBlock: responseBlock, queue: queue ?? DispatchQueue.main)
        let uploadTask = BatchUploadTask(uploadData: uploadData)
        let fileUrls = fileUrlsToCommitInfo.keys
        var fileUrlsToFileSize: [URL: UInt64] = [:]
        var totalUploadSize: UInt64 = 0
        // determine total upload size for progress handler
        for fileUrl: URL in fileUrls {
            var fileSize : UInt64
            
            do {
                let attr = try FileManager.default.attributesOfItem(atPath: fileUrl.path)
                fileSize = attr[FileAttributeKey.size] as! UInt64
                totalUploadSize += fileSize
                fileUrlsToFileSize[fileUrl] = fileSize
            } catch {
                uploadData.queue.sync {
                    uploadData.responseBlock(nil, nil, [fileUrl: .clientError(error)])
                }
                return uploadTask
            }
        }

        uploadData.totalUploadProgress = Progress(totalUnitCount: Int64(totalUploadSize));

        for fileUrl: URL in fileUrls {
            let fileSize = fileUrlsToFileSize[fileUrl]!
            if !uploadData.cancel {
                if fileSize < fileChunkSize {
                    // file is small, so we won't chunk upload it.
                    self.startUploadSmallFile(uploadData: uploadData, fileUrl: fileUrl, fileSize: fileSize)
                }
                else {
                    // file is somewhat large, so we will chunk upload it, repeatedly querying
                    // `/upload_session/append_v2` until the file is uploaded
                    self.startUploadLargeFile(uploadData: uploadData, fileUrl: fileUrl, fileSize: fileSize)
                }
            }
            else {
                break
            }
        }
        // small or large, we query `upload_session/finish_batch` to batch commit
        // uploaded files.
        self.batchFinishUponCompletion(uploadData: uploadData)
        return uploadTask
    }
    
    func startUploadSmallFile(uploadData: BatchUploadData, fileUrl: URL, fileSize: UInt64) {
        uploadData.uploadGroup.enter()
        // immediately close session after first API call
        // because file can be uploaded in one request
        self.uploadSessionStart(close: true, input: fileUrl).response(queue: uploadData.queue, completionHandler: { result, error in
            if let result = result {
                let sessionId = result.sessionId
                let offset = (fileSize)
                let cursor = Files.UploadSessionCursor(sessionId: sessionId, offset: offset)
                let commitInfo = uploadData.fileUrlsToCommitInfo[fileUrl]!
                let finishArg = Files.UploadSessionFinishArg(cursor: cursor, commit: commitInfo)
                // store commit info for this file
                uploadData.finishArgs.append(finishArg)
            }
            else {
//                uploadData.fileUrlsToRequestErrors[fileUrl] = error
            }
//            uploadData.taskStorage.removeUploadTask(task)
            uploadData.uploadGroup.leave()
        })
    }
    
    func startUploadLargeFile(uploadData: BatchUploadData, fileUrl: URL, fileSize: UInt64) {
        uploadData.uploadGroup.enter()
        let startBytes = 0
        let endBytes = fileChunkSize
        let fileChunkInputStream = ChunkInputStream(fileUrl: fileUrl, startBytes: startBytes, endBytes: Int(endBytes))
        // use seperate continue upload queue so we don't block other files from
        // commencing their upload
        let chunkUploadContinueQueue = DispatchQueue(label: "chunk_upload_continue_queue")
        // do not immediately close session

        self.uploadSessionStart(input: fileChunkInputStream).response(queue: chunkUploadContinueQueue, completionHandler: { result, error in
            if let result = result {
                let sessionId = result.sessionId
                self.appendRemainingFileChunks(uploadData: uploadData, fileUrl: fileUrl, fileSize: fileSize, sessionId: sessionId)
                let cursor = Files.UploadSessionCursor(sessionId: sessionId, offset: (fileSize))
                let commitInfo = uploadData.fileUrlsToCommitInfo[fileUrl]!
                let finishArg = Files.UploadSessionFinishArg(cursor: cursor, commit: commitInfo)
                // Store commit info for this file
                uploadData.finishArgs.append(finishArg)
            } else {
//                uploadData.fileUrlsToRequestErrors[fileUrl] = error
                uploadData.uploadGroup.leave()
            }
//            uploadData.taskStorage.remove(task)
        }).progress { progress in
            self.executeProgressHandler(uploadData:uploadData, progress: progress)
        }
        
//        uploadData.taskStorage.add(task)
    }

    func appendRemainingFileChunks(uploadData: BatchUploadData, fileUrl: URL, fileSize: UInt64, sessionId: String) {
        // use seperate response queue so we don't block response thread
        // with dispatch_semaphore_t
        let chunkUploadResponseQueue = DispatchQueue(label: "chunk_upload_response_queue")

        chunkUploadResponseQueue.async {
            var numFileChunks = fileSize / fileChunkSize
            if fileSize % fileChunkSize != 0 {
                numFileChunks += 1
            }
            var totalBytesSent: UInt64 = 0
            let chunkUploadFinished = DispatchSemaphore(value: 0)
            // iterate through all remaining chunks and upload each one sequentially
            for i in 1..<numFileChunks {
                let startBytes = fileChunkSize * i
                let endBytes = (i != numFileChunks - 1) ? fileChunkSize * (i + 1) : fileSize
                let fileChunkInputStream = ChunkInputStream(fileUrl: fileUrl, startBytes: Int(startBytes), endBytes: Int(endBytes))
                totalBytesSent += fileChunkSize
                let cursor = Files.UploadSessionCursor(sessionId: sessionId, offset: (totalBytesSent))
                let shouldClose = (i != numFileChunks - 1) ? false : true
                let shouldContinue = true
                self.appendFileChunk(uploadData: uploadData, fileUrl: fileUrl, cursor: cursor, shouldClose: shouldClose, fileChunkInputStream: fileChunkInputStream, chunkUploadResponseQueue: chunkUploadResponseQueue, chunkUploadFinished: chunkUploadFinished, retryCount: 0, startBytes: startBytes, endBytes: endBytes, shouldContinue: shouldContinue)
                // wait until each chunk upload completes before resuming loop iteration
                _ = chunkUploadFinished.wait(timeout: DispatchTime.now() + .seconds(480))
            }
            uploadData.uploadGroup.leave()
        }
    }
    
    func appendFileChunk(uploadData: BatchUploadData, fileUrl: URL, cursor: Files.UploadSessionCursor, shouldClose: Bool, fileChunkInputStream: ChunkInputStream, chunkUploadResponseQueue: DispatchQueue, chunkUploadFinished: DispatchSemaphore, retryCount: Int, startBytes: UInt64, endBytes: UInt64, shouldContinue: Bool) {
        // close session on final append call
        
        self.uploadSessionAppendV2(cursor: cursor, close: shouldClose, input: fileChunkInputStream).response(queue: DispatchQueue(label: "testing"), completionHandler: { result, error in
            if result == nil {
                if let error = error {
                    switch error as CallError {
                    case .rateLimitError(let rateLimitError, _, _, _):
                        let backoffInSeconds = rateLimitError.retryAfter
                        DispatchQueue.main.asyncAfter(deadline: .now() + Double(backoffInSeconds)) {
                            if retryCount <= 3 {
                                self.appendFileChunk(uploadData: uploadData, fileUrl: fileUrl, cursor: cursor, shouldClose: shouldClose, fileChunkInputStream: fileChunkInputStream, chunkUploadResponseQueue: chunkUploadResponseQueue, chunkUploadFinished: chunkUploadFinished, retryCount: retryCount + 1, startBytes: startBytes, endBytes: endBytes, shouldContinue: shouldContinue)
                            } else {
//                                uploadData.fileUrlsToRequestErrors[fileUrl] = error
//                                shouldContinue = false
                            }
                        }
                    default:
                        print("hi")
                    }
                    //            uploadData.taskStorage.remove(task)
                }
            }
            chunkUploadFinished.signal()
        }) .progress { progress in
            if retryCount == 0 {
                self.executeProgressHandler(uploadData:uploadData, progress: progress)
            }
        }

//        uploadData.taskStorage.add(task)
    }

    func finishBatch(uploadData: BatchUploadData,
                     entries: Array<Files.UploadSessionFinishBatchResultEntry>) {
        uploadData.queue.async {
            var dropboxFilePathToNSURL = [String: URL]()
            for (fileUrl, commitInfo) in uploadData.fileUrlsToCommitInfo {
                dropboxFilePathToNSURL[commitInfo.path] = fileUrl
            }
            var fileUrlsToBatchResultEntries: [URL: Files.UploadSessionFinishBatchResultEntry] = [:]
            var index = 0
            for finishArg in uploadData.finishArgs {
                let path = finishArg.commit.path
                let resultEntry: Files.UploadSessionFinishBatchResultEntry? = entries[index]
                fileUrlsToBatchResultEntries[dropboxFilePathToNSURL[path]!] = resultEntry
                index += 1
            }
            uploadData.responseBlock(fileUrlsToBatchResultEntries, nil, uploadData.fileUrlsToRequestErrors)
        }
    }

    func batchFinishUponCompletion(uploadData: BatchUploadData) {
        uploadData.uploadGroup.notify(queue: DispatchQueue.main) {
            uploadData.finishArgs.sort { $0.commit.path < $1.commit.path }

            self.uploadSessionFinishBatchV2(entries: uploadData.finishArgs).response { result, error in
                if let result = result {
                    self.finishBatch(uploadData: uploadData, entries: result.entries)
                } else {
                    uploadData.queue.async {
//                        uploadData.responseBlock(nil, nil, error, uploadData.fileUrlsToRequestErrors)
                    }
                }
            }
        }
    }
    
    func executeProgressHandler(uploadData: BatchUploadData, progress: Progress) {
        if let progressBlock = uploadData.progressBlock {
            uploadData.queue.async {
                let workDone = progress.completedUnitCount - uploadData.totalUploadProgress!.completedUnitCount
                uploadData.totalUploadProgress?.becomeCurrent(withPendingUnitCount: workDone)
                uploadData.totalUploadProgress?.resignCurrent()
                progressBlock(uploadData.totalUploadProgress!)
//                progressBlock(progress.completedUnitCount, uploadData.totalUploadedSoFar, uploadData.totalUploadSize)
            }
        }
    }
}
