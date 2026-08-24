//
//  ConnectionLogView.swift
//  BLESwiftExplorer
//
//  Screen 4: the scrolling connection log fed by `central.connectionEvents()`, including
//  the Task 2 `.notificationsRestored` event.
//

import SwiftUI

struct ConnectionLogView: View {
    @Environment(ExplorerModel.self) private var model

    var body: some View {
        List {
            if model.connectionLog.isEmpty {
                Text("No connection events yet.").foregroundStyle(.secondary)
            }
            ForEach(model.connectionLog.reversed()) { entry in
                VStack(alignment: .leading) {
                    Text(entry.text).font(.callout)
                    Text(entry.date, style: .time).font(.caption2).foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle("Connection Log")
    }
}
