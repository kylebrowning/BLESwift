//
//  RootView.swift
//  BLESwiftExplorer
//

import SwiftUI

struct RootView: View {
    @Environment(ExplorerModel.self) private var model

    var body: some View {
        TabView {
            NavigationStack {
                ScanView()
            }
            .tabItem { Label("Scan", systemImage: "dot.radiowaves.left.and.right") }

            NavigationStack {
                StateView()
            }
            .tabItem { Label("State", systemImage: "bolt.horizontal") }

            NavigationStack {
                ConnectionLogView()
            }
            .tabItem { Label("Log", systemImage: "list.bullet.rectangle") }

            NavigationStack {
                SavedDevicesView()
            }
            .tabItem { Label("Saved", systemImage: "star") }

            NavigationStack {
                SystemEventsView()
            }
            .tabItem { Label("System", systemImage: "antenna.radiowaves.left.and.right") }

            NavigationStack {
                RestorationDemoView()
            }
            .tabItem { Label("Restore", systemImage: "arrow.clockwise.circle") }
        }
    }
}
