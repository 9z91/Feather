//
//  enum.swift
//  Feather
//
//  Created by samara on 3.05.2025.
//

import Foundation
import Combine
import UIKit

class Download: Identifiable, @unchecked Sendable {
	@Published var progress: Double = 0.0
	@Published var bytesDownloaded: Int64 = 0
	@Published var totalBytes: Int64 = 0
	@Published var unpackageProgress: Double = 0.0
	
	var overallProgress: Double {
		onlyArchiving
		? unpackageProgress
		: (0.3 * unpackageProgress) + (0.7 * progress)
	}
	
    var task: URLSessionDownloadTask?
    var resumeData: Data?
	
	let id: String
	let url: URL
	let fileName: String
	let onlyArchiving: Bool
    
    init(
		id: String,
		url: URL,
		onlyArchiving: Bool = false
	) {
		self.id = id
        self.url = url
		self.onlyArchiving = onlyArchiving
        self.fileName = url.lastPathComponent
    }
}

class DownloadManager: NSObject, ObservableObject {
	static let shared = DownloadManager()
	
    @Published var downloads: [Download] = []
	
	var manualDownloads: [Download] {
		downloads.filter { isManualDownload($0.id) }
	}
	
    private var _session: URLSession!
	private let backgroundSessionIdentifier = "thewonderofyou.Feather.downloads"
	
	var backgroundCompletionHandler: (() -> Void)?
    
    override init() {
        super.init()
        setupBackgroundSession()
    }
	
	private func setupBackgroundSession() {
		let configuration = URLSessionConfiguration.background(withIdentifier: backgroundSessionIdentifier)
		configuration.isDiscretionary = false
		configuration.sessionSendsLaunchEvents = true
		configuration.shouldUseExtendedBackgroundIdleMode = true
		
		configuration.timeoutIntervalForRequest = 0
		configuration.timeoutIntervalForResource = 0
		
		_session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
	}
    
    func startDownload(
		from url: URL,
		id: String = UUID().uuidString
	) -> Download {
        if let existingDownload = downloads.first(where: { $0.url == url }) {
            resumeDownload(existingDownload)
            return existingDownload
        }
        
		let download = Download(id: id, url: url)
        
        let task = _session.downloadTask(with: url)
        download.task = task
        task.resume()
        
        downloads.append(download)
        return download
    }
	
	func startArchive(
		from url: URL,
		id: String = UUID().uuidString
	) -> Download {
		let download = Download(id: id, url: url, onlyArchiving: true)
		downloads.append(download)
		return download
	}
    
    func resumeDownload(_ download: Download) {
        if let resumeData = download.resumeData {
            let task = _session.downloadTask(withResumeData: resumeData)
            download.task = task
            task.resume()
        } else if let url = download.task?.originalRequest?.url {
            let task = _session.downloadTask(with: url)
            download.task = task
            task.resume()
        }
    }
    
    func cancelDownload(_ download: Download) {
        download.task?.cancel()
        
        if let index = downloads.firstIndex(where: { $0.id == download.id }) {
            downloads.remove(at: index)
        }
    }
    
	func isManualDownload(_ string: String) -> Bool {
		return string.contains("FeatherManualDownload")
	}
	
	func getDownload(by id: String) -> Download? {
		return downloads.first(where: { $0.id == id })
	}
	
	func getDownloadIndex(by id: String) -> Int? {
		return downloads.firstIndex(where: { $0.id == id })
	}
	
	func getDownloadTask(by task: URLSessionDownloadTask) -> Download? {
		return downloads.first(where: { $0.task == task })
	}
	
	func handleBackgroundSessionEvents() {
		_session.getTasksWithCompletionHandler { [weak self] (dataTasks, uploadTasks, downloadTasks) in
			guard let self = self else { return }
			
			for downloadTask in downloadTasks {
				if let existingDownload = self.getDownloadTask(by: downloadTask) {
					if downloadTask.state == .running {
						DispatchQueue.main.async {
							existingDownload.progress = downloadTask.progress.fractionCompleted
							existingDownload.bytesDownloaded = downloadTask.countOfBytesReceived
							existingDownload.totalBytes = downloadTask.countOfBytesExpectedToReceive
						}
					}
				} else if let originalURL = downloadTask.originalRequest?.url {
					let download = Download(id: UUID().uuidString, url: originalURL)
					download.task = downloadTask
					
					if downloadTask.state == .running {
						download.progress = downloadTask.progress.fractionCompleted
						download.bytesDownloaded = downloadTask.countOfBytesReceived
						download.totalBytes = downloadTask.countOfBytesExpectedToReceive
					}
					
					DispatchQueue.main.async {
						self.downloads.append(download)
					}
				}
			}
		}
	}
	
	func pauseAllDownloads() {
		for download in downloads {
			download.task?.suspend()
		}
	}
	
	func resumeAllDownloads() {
		for download in downloads {
			download.task?.resume()
		}
	}
	
	var isBackgroundDownloadSupported: Bool {
		return UIApplication.shared.backgroundRefreshStatus == .available
	}
}

extension DownloadManager: URLSessionDownloadDelegate {
	
	func handlePachageFile(url: URL, dl: Download) throws {
		FR.handlePackageFile(url, download: dl) { err in
			if err != nil {
				let generator = UINotificationFeedbackGenerator()
				generator.notificationOccurred(.error)
			}
			
			DispatchQueue.main.async {
				if let index = DownloadManager.shared.getDownloadIndex(by: dl.id) {
					DownloadManager.shared.downloads.remove(at: index)
				}
			}
		}
	}
	
	func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
		guard let download = getDownloadTask(by: downloadTask) else { return }
		
		let tempDirectory = FileManager.default.temporaryDirectory
		let customTempDir = tempDirectory.appendingPathComponent("FeatherDownloads", isDirectory: true)
		
		do {
			try FileManager.default.createDirectoryIfNeeded(at: customTempDir)
			
			let suggestedFileName = downloadTask.response?.suggestedFilename ?? download.fileName
			let destinationURL = customTempDir.appendingPathComponent(suggestedFileName)
			
			try FileManager.default.removeFileIfNeeded(at: destinationURL)
			try FileManager.default.moveItem(at: location, to: destinationURL)
			
			try handlePachageFile(url: destinationURL, dl: download)
		} catch {
			print("error handling downloaded file: \(error.localizedDescription)")
		}
	}
    
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        guard let download = getDownloadTask(by: downloadTask) else { return }
        
        DispatchQueue.main.async {
            download.progress = totalBytesExpectedToWrite > 0
			? Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
			: 0
            download.bytesDownloaded = totalBytesWritten
            download.totalBytes = totalBytesExpectedToWrite
        }
    }
    
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard
			let _ = error,
			let downloadTask = task as? URLSessionDownloadTask,
			let download = getDownloadTask(by: downloadTask)
		else {
			return
		}
		
		DispatchQueue.main.async {
			if let index = self.getDownloadIndex(by: download.id) {
				self.downloads.remove(at: index)
			}
		}
    }
	
	func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
		DispatchQueue.main.async {
			self.backgroundCompletionHandler?()
			self.backgroundCompletionHandler = nil
		}
	}
}
