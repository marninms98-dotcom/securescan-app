//
//  EditorNamesStore.swift
//  SecureScan
//
//  editor-names.json in the job folder: the editor's wall names and removal
//  tags from its last load, for the AR screens (see EditorNames).
//

import Foundation

enum EditorNamesStore {
    static func url(_ folder: JobFolder) -> URL { folder.url.appendingPathComponent("editor-names.json") }

    static func load(_ folder: JobFolder) -> EditorNames? {
        guard let data = try? Data(contentsOf: url(folder)) else { return nil }
        return try? JSONDecoder().decode(EditorNames.self, from: data)
    }

    static func save(_ names: EditorNames, _ folder: JobFolder) {
        guard let data = try? JSONEncoder().encode(names) else { return }
        try? data.write(to: url(folder), options: .atomic)
    }
}
