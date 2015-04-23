/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at http://mozilla.org/MPL/2.0/. */

import Foundation
import Shared
import Storage
import XCGLogger

// TODO: same comment as for SyncAuthState.swift!
private let log = XCGLogger.defaultInstance()

public class MockSyncableHistory {
    public var mirrorPlaces = [GUID: RemotePlace]()
    public var localPlaces = [GUID: LocalPlace]()
    public var remoteVisits = [GUID: Set<Visit>]()
    public var localVisits = [GUID: Set<Visit>]()

    public init() {
    }

    private func placesForGUID(guid: GUID) -> (RemotePlace?, LocalPlace?) {
        return (mirrorPlaces[guid], localPlaces[guid])
    }

    private func placesForURL(url: String) -> (RemotePlace?, LocalPlace?) {
        func hasURL(place: Place) -> Bool {
            return place.url == url
        }
        return (findOneValue(mirrorPlaces, hasURL), findOneValue(localPlaces, hasURL))
    }
}

extension MockSyncableHistory: SyncableHistory {
    // TODO: consider comparing the timestamp to local visits, perhaps opting to
    // not delete the local place (and instead to give it a new GUID) if the visits
    // are newer than the deletion.
    // Obviously this'll behave badly during reconciling on other devices:
    // they might apply our new record first, renaming their local copy of
    // the old record with that URL, and thus bring all the old visits back to life.
    // Desktop just finds by GUID then deletes by URL.
    public func deleteByGUID(guid: GUID, deletedAt: Timestamp) -> Deferred<Result<()>> {
        self.remoteVisits.removeValueForKey(guid)
        self.localVisits.removeValueForKey(guid)
        self.mirrorPlaces.removeValueForKey(guid)
        self.localPlaces.removeValueForKey(guid)

        return succeed()
    }

    /**
     * This assumes that the provided GUID doesn't already map to a different URL!
     */
    public func ensurePlaceWithURL(url: String, hasGUID guid: GUID) -> Success {
        // Find by URL.
        let (shared, local) = self.placesForURL(url)
        if let shared = shared {
            if shared.guid != guid {
                let p = RemotePlace(guid: guid, url: url, title: shared.title, modified: shared.modified)
                self.mirrorPlaces.removeValueForKey(shared.guid)
                self.mirrorPlaces[guid] = p
            }
        }

        if let local = local {
            if local.guid != guid {
                let p = LocalPlace(guid: guid, url: url, title: local.title, modified: local.modified)
                self.localPlaces.removeValueForKey(local.guid)
                self.localPlaces[guid] = p
            }
        }

        return succeed()
    }

    /**
     * This assumes that the new GUID doesn't already exist!
     */
    public func changeGUID(old: GUID, new: GUID) -> Success {
        if let shared = self.mirrorPlaces[old] {
            let p = RemotePlace(guid: new, url: shared.url, title: shared.title, modified: shared.modified)
            self.mirrorPlaces.removeValueForKey(old)
            self.mirrorPlaces[new] = p
        }

        if let local = self.localPlaces[old] {
            let p = LocalPlace(guid: new, url: local.url, title: local.title, modified: local.modified)
            self.localPlaces.removeValueForKey(old)
            self.localPlaces[new] = p
        }

        return succeed()
    }


    // TODO: update this!
    public func storeRemoteVisits(visits: [Visit], forGUID guid: GUID) -> Success {
        // Strip out existing local visits.
        // We trust that an identical timestamp and type implies an identical visit.
        var remote = Set<Visit>(visits)
        if let local = self.localVisits[guid] {
            remote.subtractInPlace(local)
        }
        self.remoteVisits[guid] = remote
        return succeed()
    }

    public func insertOrUpdatePlace(place: RemotePlace) -> Deferred<Result<GUID>> {
        // See if we've already applied this one.
        if self.mirrorPlaces[place.guid]?.modified == place.modified {
            log.debug("Already seen unchanged record \(place.guid).")
            return deferResult(place.guid)
        }

        // Make sure that we collide with any matching URLs -- whether locally
        // modified or not. Then overwrite the upstream and merge any local changes.
        return self.ensurePlaceWithURL(place.url, hasGUID: place.guid)
           >>> {
            if let existingLocal = self.localPlaces[place.guid] {
                log.debug("Record \(existingLocal.guid) modified locally and remotely.")
                log.debug("Local modified: \(existingLocal.modified); remote: \(place.modified).")

                if existingLocal.modified > place.modified {
                    // Nothing to do: it's marked as changed.
                    log.debug("Discarding remote non-visit changes!")
                } else {
                    log.debug("Discarding local non-visit changes!")
                    self.localPlaces.removeValueForKey(place.guid)
                }
            } else {
                log.debug("Remote record doesn't exist locally.")
            }

            // Apply the new remote record to the upstream mirror.
            self.mirrorPlaces[place.guid] = place
            return deferResult(place.guid)
        }
    }
}

extension MockSyncableHistory: BrowserHistory {
    public func clear() -> Success {
        self.remoteVisits.removeAll(keepCapacity: true)
        self.localVisits.removeAll(keepCapacity: true)
        self.mirrorPlaces.removeAll(keepCapacity: true)
        self.localPlaces.removeAll(keepCapacity: true)

        return succeed()
    }

    public func get(options: QueryOptions?) -> Deferred<Result<Cursor>> {

    }

    public func addVisit(visit: SiteVisit) -> Success {
        self.localVisits[visit.]
    }
}


public class HistorySynchronizer: BaseSingleCollectionSynchronizer, Synchronizer {
    public required init(scratchpad: Scratchpad, delegate: SyncDelegate, basePrefs: Prefs) {
        super.init(scratchpad: scratchpad, delegate: delegate, basePrefs: basePrefs, collection: "history")
    }

    private func applyIncomingToStorage(storage: SyncableHistory, response: StorageResponse<[Record<HistoryPayload>]>) -> Success {
        return self.applyIncomingToStorage(storage, records: response.value, fetched: response.metadata.lastModifiedMilliseconds!)
    }

    // TODO: this function should establish a transaction at suitable points.
    func applyIncomingToStorage(storage: SyncableHistory, records: [Record<HistoryPayload>], fetched: Timestamp) -> Success {
        func applyRecord(rec: Record<HistoryPayload>) -> Success {
            let guid = rec.id
            let payload = rec.payload
            let modified = rec.modified

            log.debug("Record: \(guid): \(payload.title)")

            // We apply deletions immediately. Yes, this will throw away local visits
            // that haven't yet been synced. That's how Sync works, alas.
            if payload.deleted {
                return storage.deleteByGUID(guid, deletedAt: modified)
            }

            // It's safe to apply other remote records, too -- even if we re-download, we know
            // from our local cached server timestamp on each record that we've already seen it.
            // We have to reconcile on-the-fly: we're about to overwrite the server record, which
            // is our shared parent.
            let place = rec.payload.asPlaceWithModifiedTime(modified)
            return storage.insertOrUpdatePlace(place)
               >>> { storage.storeRemoteVisits(payload.visits, forGUID: guid) }
        }

        func allSucceed(arr: [Success]) -> Success {
            return all(arr).map {
                for x in $0 {
                    if x.isFailure {
                        log.error("Record application failed: \(x.failureValue)")
                        return x
                    }
                }
                log.debug("Record application succeeded.")
                return Result(success: ())
            }
        }

        return allSucceed(records.map(applyRecord))
           >>> {
            log.debug("Bumping fetch timestamp to \(fetched).")
            self.lastFetched = fetched
            return succeed()
        }
    }



    public func synchronizeLocalHistory(history: SyncableHistory, withServer storageClient: Sync15StorageClient, info: InfoCollections) -> Success {
        let keys = self.scratchpad.keys?.value
        let encoder = RecordEncoder<HistoryPayload>(decode: { HistoryPayload($0) }, encode: { $0 })
        if let encrypter = keys?.encrypter(self.collection, encoder: encoder) {
            let historyClient = storageClient.clientForCollection(self.collection, encrypter: encrypter)

            let since: Timestamp = 0       // self.lastFetched

            // TODO: wipe if we're starting over.
            // TODO: buffer downloaded records. Do this by marking items as unprocessed?

            return historyClient.getSince(since)
              >>== { self.applyIncomingToStorage(history, response: $0) }
        }

        log.error("Couldn't make history factory.")
        return deferResult(FatalError(message: "Couldn't make history factory."))
    }
}
