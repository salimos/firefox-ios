/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at http://mozilla.org/MPL/2.0/. */

import Foundation
import XCGLogger

// To keep SwiftData happy.
typealias Args = [AnyObject?]

let TableBookmarks = "bookmarks"

let TableFavicons = "favicons"
let TableHistory = "history"
let TableRemoteVisits = "remote_visits"
let TableLocalVisits = "local_visits"
let TableFaviconSites = "favicon_sites"

let ViewAllVisits = "all_visits"
let ViewWidestFaviconsForSites = "view_favicons_widest"
let ViewHistoryIDsWithWidestFavicons = "view_history_id_favicon"
let ViewIconForURL = "view_icon_for_url"

private let AllTables: Args = [
    TableFaviconSites,

    TableHistory,

    TableRemoteVisits,
    TableLocalVisits,

    TableBookmarks,
]

private let AllViews: Args = [
    ViewAllVisits,
    ViewHistoryIDsWithWidestFavicons,
    ViewWidestFaviconsForSites,
    ViewIconForURL,
]

private let AllTablesAndViews: Args = AllViews + AllTables

private let log = XCGLogger.defaultInstance()

/**
 * The monolithic class that manages the inter-related history etc. tables.
 * We rely on SQLiteHistory having initialized the favicon table first.
 */
public class BrowserTable: Table {
    var name: String { return "BROWSER" }
    var version: Int { return 2 }

    public init() {
    }

    func run(db: SQLiteDBConnection, sql: String, args: Args? = nil) -> Bool {
        let err = db.executeChange(sql, withArgs: args)
        if err != nil {
            log.error("Error running SQL in BrowserTable. \(err?.localizedDescription)")
            log.error("SQL was \(sql)")
        }
        return err == nil
    }

    // TODO: transaction.
    func run(db: SQLiteDBConnection, queries: [String]) -> Bool {
        for sql in queries {
            if !run(db, sql: sql, args: nil) {
                return false
            }
        }
        return true
    }

    func prepopulateRootFolders(db: SQLiteDBConnection) -> Bool {
        let type = BookmarkNodeType.Folder.rawValue
        let root = BookmarkRoots.RootID

        let titleMobile = NSLocalizedString("Mobile Bookmarks", tableName: "Storage", comment: "The title of the folder that contains mobile bookmarks. This should match bookmarks.folder.mobile.label on Android.")
        let titleMenu = NSLocalizedString("Bookmarks Menu", tableName: "Storage", comment: "The name of the folder that contains desktop bookmarks in the menu. This should match bookmarks.folder.menu.label on Android.")
        let titleToolbar = NSLocalizedString("Bookmarks Toolbar", tableName: "Storage", comment: "The name of the folder that contains desktop bookmarks in the toolbar. This should match bookmarks.folder.toolbar.label on Android.")
        let titleUnsorted = NSLocalizedString("Unsorted Bookmarks", tableName: "Storage", comment: "The name of the folder that contains unsorted desktop bookmarks. This should match bookmarks.folder.unfiled.label on Android.")

        let args: Args = [
            root, BookmarkRoots.RootGUID, type, "Root", root,
            BookmarkRoots.MobileID, BookmarkRoots.MobileFolderGUID, type, titleMobile, root,
            BookmarkRoots.MenuID, BookmarkRoots.MenuFolderGUID, type, titleMenu, root,
            BookmarkRoots.ToolbarID, BookmarkRoots.ToolbarFolderGUID, type, titleToolbar, root,
            BookmarkRoots.UnfiledID, BookmarkRoots.UnfiledFolderGUID, type, titleUnsorted, root,
        ]

        let sql =
        "INSERT INTO bookmarks (id, guid, type, url, title, parent) VALUES " +
            "(?, ?, ?, NULL, ?, ?), " +    // Root
            "(?, ?, ?, NULL, ?, ?), " +    // Mobile
            "(?, ?, ?, NULL, ?, ?), " +    // Menu
            "(?, ?, ?, NULL, ?, ?), " +    // Toolbar
            "(?, ?, ?, NULL, ?, ?)  "      // Unsorted

        return self.run(db, sql: sql, args: args)
    }

    func create(db: SQLiteDBConnection, version: Int) -> Bool {
        // We ignore the version.


        // TODO: tracking deletions. What does it mean to delete a history item?
        // TODO: shared Places table -- just id, url, guid. Rely on guid replacement coming down.
        // TODO: delete by GUID?
          // -- remove all local visits
          // -- mark as deleted, remove URL
          // -- if new visits are synced down for that guid, what do we do?

        let history =
        "CREATE TABLE IF NOT EXISTS \(TableHistory) (" +
        "id INTEGER PRIMARY KEY AUTOINCREMENT, " +
        "guid TEXT UNIQUE NOT NULL, " +    // Not null, but the value might be replaced by the server's.
        "url TEXT NOT NULL UNIQUE, " +
        "title TEXT NOT NULL, " +
        "server_modified INTEGER, " +      // Can be null. Integer milliseconds.
        "local_modified INTEGER, " +       // Can be null. Client clock. In extremis only.
        "is_deleted TINYINT, " +           // Boolean. Locally deleted.
        "should_upload TINYINT " +         // Boolean.
        ") "

        let remoteVisits =
        "CREATE TABLE IF NOT EXISTS \(TableRemoteVisits) (" +
        "id INTEGER PRIMARY KEY AUTOINCREMENT, " +
        "siteID INTEGER NOT NULL REFERENCES \(TableHistory)(id) ON DELETE CASCADE, " +
        "date REAL NOT NULL, " +           // Microseconds.
        "type INTEGER NOT NULL " +
        ") "

        let localVisits =
        "CREATE TABLE IF NOT EXISTS \(TableLocalVisits) (" +
        "id INTEGER PRIMARY KEY AUTOINCREMENT, " +
        "siteID INTEGER NOT NULL REFERENCES \(TableHistory)(id) ON DELETE CASCADE, " +
        "date REAL NOT NULL, " +           // Microseconds.
        "type INTEGER NOT NULL, " +
        "is_new TINYINT DEFAULT 1 " +      // Bool. Flipped to false when synced.
        ") "

        let allVisits =
        "CREATE VIEW IF NOT EXISTS \(ViewAllVisits) AS " +
        "SELECT siteID, date, type FROM (" +
        "SELECT siteID, date, type FROM \(TableLocalVisits) " +
        "UNION ALL " +
        "SELECT siteID, date, type FROM \(TableRemoteVisits)" +
        ")"

        let faviconSites =
        "CREATE TABLE IF NOT EXISTS \(TableFaviconSites) (" +
        "id INTEGER PRIMARY KEY AUTOINCREMENT, " +
        "siteID INTEGER NOT NULL REFERENCES \(TableHistory)(id) ON DELETE CASCADE, " +
        "faviconID INTEGER NOT NULL REFERENCES \(TableFavicons)(id) ON DELETE CASCADE, " +
        "UNIQUE (siteID, faviconID) " +
        ") "

        let widestFavicons =
        "CREATE VIEW IF NOT EXISTS \(ViewWidestFaviconsForSites) AS " +
        "SELECT " +
        "\(TableFaviconSites).siteID AS siteID, " +
        "\(TableFavicons).id AS iconID, " +
        "\(TableFavicons).url AS iconURL, " +
        "\(TableFavicons).date AS iconDate, " +
        "\(TableFavicons).type AS iconType, " +
        "MAX(\(TableFavicons).width) AS iconWidth " +
        "FROM \(TableFaviconSites), \(TableFavicons) WHERE " +
        "\(TableFaviconSites).faviconID = \(TableFavicons).id " +
        "GROUP BY siteID "

        let historyIDsWithIcon =
        "CREATE VIEW IF NOT EXISTS \(ViewHistoryIDsWithWidestFavicons) AS " +
        "SELECT \(TableHistory).id AS id, " +
        "iconID, iconURL, iconDate, iconType, iconWidth " +
        "FROM \(TableHistory) " +
        "LEFT OUTER JOIN " +
        "\(ViewWidestFaviconsForSites) ON history.id = \(ViewWidestFaviconsForSites).siteID "

        let iconForURL =
        "CREATE VIEW IF NOT EXISTS \(ViewIconForURL) AS " +
        "SELECT history.url AS url, icons.iconID AS iconID FROM " +
        "\(TableHistory), \(ViewWidestFaviconsForSites) AS icons WHERE " +
        "\(TableHistory).id = icons.siteID "

        let bookmarks =
        "CREATE TABLE IF NOT EXISTS \(TableBookmarks) (" +
        "id INTEGER PRIMARY KEY AUTOINCREMENT, " +
        "guid TEXT NOT NULL UNIQUE, " +
        "type TINYINT NOT NULL, " +
        "url TEXT, " +
        "parent INTEGER REFERENCES \(TableBookmarks)(id) NOT NULL, " +
        "faviconID INTEGER REFERENCES \(TableFavicons)(id) ON DELETE SET NULL, " +
        "title TEXT" +
        ") "

        let queries = [
            history, localVisits, remoteVisits, bookmarks, faviconSites,
            allVisits, widestFavicons, historyIDsWithIcon, iconForURL,
        ]
        assert(queries.count == AllTablesAndViews.count, "Did you forget to add your table or view to the list?")
        return self.run(db, queries: queries) &&
               self.prepopulateRootFolders(db)
    }

    func updateTable(db: SQLiteDBConnection, from: Int, to: Int) -> Bool {
        if from == to {
            log.debug("Skipping update from \(from) to \(to).")
            return true
        }

        if from == 0 {
            // This is likely an upgrade from before Bug 1160399.
            log.debug("Updating browser tables from zero. Assuming drop and recreate.")
            return drop(db) && create(db, version: to)
        }

        // TODO: real update!
        log.debug("Updating browser tables from \(from) to \(to).")
        return drop(db) && create(db, version: to)
    }

    /**
     * The Table mechanism expects to be able to check if a 'table' exists. In our (ab)use
     * of Table, that means making sure that any of our tables and views exist.
     * We do that by fetching all tables from sqlite_master with matching names, and verifying
     * that we get back more than one.
     * Note that we don't check for views -- trust to luck.
     */
    func exists(db: SQLiteDBConnection) -> Bool {
        let count = AllTables.count
        let orClause = join(" OR ", Array(count: count, repeatedValue: "name = ?"))
        let tablesSQL = "SELECT name FROM sqlite_master WHERE type = 'table' AND (\(orClause))"

        let res = db.executeQuery(tablesSQL, factory: StringFactory, withArgs: AllTables)
        log.debug("\(res.count) tables exist. Expected \(count)")
        return res.count > 0
    }

    func drop(db: SQLiteDBConnection) -> Bool {
        log.debug("Dropping all browser tables.")
        let additional = [
            "DROP TABLE IF EXISTS faviconSites",  // We renamed it to match naming convention.
            "DROP TABLE IF EXISTS visits",        // We split this into local and remote.
        ]
        let queries = AllViews.map { "DROP VIEW IF EXISTS \($0!)" } +
                      AllTables.map { "DROP TABLE IF EXISTS \($0!)" } +
                      additional

        return self.run(db, queries: queries)
    }
}