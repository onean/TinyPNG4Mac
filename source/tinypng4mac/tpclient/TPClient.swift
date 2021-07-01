//
//  TPTools.swift
//  tinypng
//
//  Created by kyle on 16/6/30.
//  Copyright © 2016年 kyleduo. All rights reserved.
//

import Foundation
import Alamofire
import SwiftyJSON

protocol TPClientCallback {
	func taskStatusChanged(task: TPTaskInfo)
}

class TPClient {
	let MAX_TASKS: Int = 1
	let BASE_URL = "https://api.tinify.com/shrink"
	
	static let sharedClient = TPClient()
    static var sApiKey:String {
        get {
            return _sApiKey
        }
        set {
            _sApiKey = newValue
            sApiKeys.removeAll()
            let keys = newValue.split(separator: ",").compactMap { "\($0)"}
            sApiKeys = keys
            debugPrint(sApiKeys)
        }
    }
    static var _sApiKey = ""
    static var sApiKeys = [String]()
    var apiIndex = 0
	static var sOutputPath = "" {
		didSet {
			IOHeler.sOutputPath = sOutputPath
		}
	}
	
	var callback:TPClientCallback!
	
	fileprivate init() {}
	
	let queue = TPQueue()
	let lock: NSLock = NSLock()
	var runningTasks = 0
	var finishTasksCount = 0
	
	func add(_ tasks: [TPTaskInfo]) {
		TPStore.sharedStore.add(tasks);
		for task in tasks {
			queue.enqueue(task)
		}
	}
	
	func checkExecution() {
		lock.lock()
		while runningTasks < MAX_TASKS {
			let task = queue.dequeue()
			if let t = task {
				self.updateStatus(t, newStatus: .prepare)
				runningTasks += 1
				debugPrint("prepare to upload: " + t.fileInfo.relativePath + " tasks: " + String(self.runningTasks))
                executeTask(t)
			} else {
				break;
			}
		}
		lock.unlock()
	}
	
	func executeTask(_ task: TPTaskInfo) {
		var imageData: Data!
		do {
			let fileHandler = try FileHandle(forReadingFrom:task.originFile as URL)
			imageData = fileHandler.readDataToEndOfFile()
			
//			let auth = "api:\(TPClient.sApiKey)"
            let auth = "api:\(TPClient.sApiKeys[apiIndex])"
			let authData = auth.data(using: String.Encoding.utf8)?.base64EncodedString(options: NSData.Base64EncodingOptions.lineLength64Characters)
			let authorizationHeader = "Basic " + authData!
			
			self.updateStatus(task, newStatus: .uploading)
			debugPrint("uploading: " + task.fileInfo.relativePath)
			
			let headers: HTTPHeaders = [
				"Authorization": authorizationHeader,
				"Accept": "application/json"
			]
			Alamofire.upload(imageData, to: BASE_URL, method: .post, headers: headers)
				.uploadProgress(closure: { (progress) in
					if progress.fractionCompleted == 1 {
						self.updateStatus(task, newStatus: .processing)
						debugPrint("processing: " + task.fileInfo.relativePath)
					} else {
						self.updateStatus(task, newStatus: .uploading, progress: progress)
					}
				})
				.responseJSON(completionHandler: { (response) in
					if let jsonstr = response.result.value {
                        // 当前api key上传超过上限
                        if response.response?.statusCode == 429 {
                            if self.apiIndex < TPClient.sApiKeys.count - 1 {
                                self.apiIndex += 1
                                self.reexcuteTask(task)
                            }
                        }else{
                            let json = JSON(jsonstr)
                            if json != JSON.null {
                                if let error = json["error"].string {
                                    debugPrint("error: " + task.fileInfo.relativePath + error)
                                    self.markError(task, errorMessage: json["message"].string)
                                    return
                                }
                                let output = json["output"]
                                if output != JSON.null {
                                    let resultUrl = output["url"]
                                    task.resultUrl = String(describing: resultUrl)
                                    task.resultSize = output["size"].doubleValue
                                    task.compressRate = task.resultSize / task.originSize
                                    self.onUploadFinish(task)
                                } else {
                                    self.markError(task, errorMessage: "response data error")
                                }
                            } else {
                                self.markError(task, errorMessage: "response format error")
                            }
                        }
					} else {
                        
						self.markError(task, errorMessage: response.result.description)
					}
				})
		} catch {
			self.markError(task, errorMessage: "execute error")
		}
	}
	
	fileprivate func onUploadFinish(_ task: TPTaskInfo) {
		debugPrint("downloading: " + task.fileInfo.relativePath)
		self.updateStatus(task, newStatus: .downloading)
		if TPConfig.shouldReplace() {
			task.outputFile = task.originFile;
		} else {
			let folder = IOHeler.getOutputPath()
			task.outputFile = folder.appendingPathComponent(task.fileInfo.relativePath)
		}
		downloadCompressImage(task)
	}
	
	fileprivate func downloadCompressImage(_ task: TPTaskInfo) {
		let destination: DownloadRequest.DownloadFileDestination = { _, _ in
			return (task.outputFile!, [.createIntermediateDirectories, .removePreviousFile])
		}
		
		Alamofire.download(task.resultUrl, to: destination)
			.downloadProgress(closure: { (progress) in
				self.updateStatus(task, newStatus: .downloading, progress: progress)
			})
			.response { response in
				let error = response.error
				if (error != nil) {
					self.markError(task, errorMessage: "download error")
				} else {
					self.updateStatus(task, newStatus: .finish)
					debugPrint("finish: " + task.fileInfo.relativePath + " tasks: " + String(self.runningTasks))
                    do {
                        try FileManager.default.setAttributes([FileAttributeKey.posixPermissions: task.filePermission], ofItemAtPath: task.fileInfo.filePath.path)
                    } catch {
                        debugPrint("FileManager set posixPermissions error")
                    }
				}
				
				self.checkExecution()
			}
	}
    
    fileprivate func reexcuteTask(_ task: TPTaskInfo) {
        updateStatus(task, newStatus: .retry)
        checkExecution()
    }
    
	fileprivate func markError(_ task: TPTaskInfo, errorMessage: String?) {
		task.errorMessage = errorMessage
		updateStatus(task, newStatus: .error)
        checkExecution()
	}
	
	fileprivate func updateStatus(_ task: TPTaskInfo, newStatus: TPTaskStatus, progress: Progress) {
		task.status = newStatus
		task.progress = progress
		if newStatus == .error || newStatus == .finish {
			self.runningTasks -= 1
			if newStatus == .finish {
				self.finishTasksCount += 1
			}
        } else {
            if newStatus == .retry {
                self.runningTasks -= 1
                self.queue.enqueue(task)
            }
        }
		callback.taskStatusChanged(task: task)
	}
	
	fileprivate func updateStatus(_ task: TPTaskInfo, newStatus: TPTaskStatus) {
		self.updateStatus(task, newStatus: newStatus, progress: Progress())
	}
}
