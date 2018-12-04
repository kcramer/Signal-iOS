//
//  Copyright (c) 2018 Open Whisper Systems. All rights reserved.
//

import Foundation
import PromiseKit
import SignalServiceKit

@objc(OWSBackupLazyRestore)
public class BackupLazyRestore: NSObject {

    // MARK: - Dependencies

    private var backup: OWSBackup {
        return AppEnvironment.shared.backup
    }

    private var primaryStorage: OWSPrimaryStorage {
        return SSKEnvironment.shared.primaryStorage
    }

    private var tsAccountManager: TSAccountManager {
        return TSAccountManager.sharedInstance()
    }

    // MARK: -

    private var isRunning = false
    private var isComplete = false

    @objc
    public required override init() {
        super.init()

        SwiftSingletons.register(self)

        AppReadiness.runNowOrWhenAppDidBecomeReady {
            self.runIfNecessary()
        }

        NotificationCenter.default.addObserver(forName: .OWSApplicationDidBecomeActive, object: nil, queue: nil) { _ in
            self.runIfNecessary()
        }
        NotificationCenter.default.addObserver(forName: .RegistrationStateDidChange, object: nil, queue: nil) { _ in
            self.runIfNecessary()
        }
        NotificationCenter.default.addObserver(forName: .reachabilityChanged, object: nil, queue: nil) { _ in
            self.runIfNecessary()
        }
    }

    // MARK: -

    private let backgroundQueue = DispatchQueue.global(qos: .background)

    @objc
    public func clearCompleteAndRunIfNecessary() {
        AssertIsOnMainThread()

        isComplete = false

        runIfNecessary()
    }

    @objc
    public func runIfNecessary() {
        AssertIsOnMainThread()

        guard CurrentAppContext().isMainAppAndActive else {
            return
        }
        guard tsAccountManager.isRegisteredAndReady() else {
            return
        }
        guard !isRunning, !isComplete else {
            return
        }

        isRunning = true

        backgroundQueue.async {
            self.restoreAttachments()
        }
    }

    private func restoreAttachments() {
        let temporaryDirectory = OWSTemporaryDirectory()
        let jobTempDirPath = (temporaryDirectory as NSString).appendingPathComponent(NSUUID().uuidString)

        guard OWSFileSystem.ensureDirectoryExists(jobTempDirPath) else {
            Logger.error("could not create temp directory.")
            complete(errorCount: 1)
            return
        }

        let backupIO = OWSBackupIO(jobTempDirPath: jobTempDirPath)

        let attachmentIds = backup.attachmentIdsForLazyRestore()
        guard attachmentIds.count > 0 else {
            Logger.info("No attachments need lazy restore.")
            complete(errorCount: 0)
            return
        }
        Logger.info("Lazy restoring \(attachmentIds.count) attachments.")
        tryToRestoreNextAttachment(attachmentIds: attachmentIds, errorCount: 0, backupIO: backupIO)
    }

    private func tryToRestoreNextAttachment(attachmentIds: [String], errorCount: UInt, backupIO: OWSBackupIO) {
        var attachmentIdsCopy = attachmentIds
        guard let attachmentId = attachmentIdsCopy.popLast() else {
            // This job is done.
            Logger.verbose("job is done.")
            complete(errorCount: errorCount)
            return
        }
        guard let attachmentPointer = TSAttachment.fetch(uniqueId: attachmentId) as? TSAttachmentPointer else {
            Logger.warn("could not load attachment.")
            // Not necessarily an error.
            // The attachment might have been deleted since the job began.
            // Continue trying to restore the other attachments.
            tryToRestoreNextAttachment(attachmentIds: attachmentIds, errorCount: errorCount + 1, backupIO: backupIO)
            return
        }
        backup.lazyRestoreAttachment(attachmentPointer,
                                     backupIO: backupIO)
            .done(on: self.backgroundQueue) { _ in
                Logger.info("Restored attachment.")

                // Continue trying to restore the other attachments.
                self.tryToRestoreNextAttachment(attachmentIds: attachmentIdsCopy, errorCount: errorCount, backupIO: backupIO)
            }.catch(on: self.backgroundQueue) { (error) in
                Logger.error("Could not restore attachment: \(error)")

                // Continue trying to restore the other attachments.
                self.tryToRestoreNextAttachment(attachmentIds: attachmentIdsCopy, errorCount: errorCount + 1, backupIO: backupIO)
            }.retainUntilComplete()
    }

    private func complete(errorCount: UInt) {
        Logger.verbose("")

        DispatchQueue.main.async {
            self.isRunning = false

            if errorCount == 0 {
                self.isComplete = true
            }
        }
    }
}