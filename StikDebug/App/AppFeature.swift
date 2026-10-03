//
//  AppFeature.swift
//  StikDebug
//

import SwiftUI

enum AppFeature: String, CaseIterable, Identifiable {
    case home
    case scripts
    case tools
    case console
    case deviceInfo = "deviceinfo"
    case profiles
    case processes
    case location
    case settings

    var id: String {
        rawValue
    }

    var title: String {
        switch self {
        case .home:
            return "Apps".localized
        case .scripts:
            return "Scripts".localized
        case .tools:
            return "Tools".localized
        case .console:
            return "Console".localized
        case .deviceInfo:
            return "Device Info".localized
        case .profiles:
            return "App Expiry".localized
        case .processes:
            return "Processes".localized
        case .location:
            return "Location".localized
        case .settings:
            return "Settings".localized
        }
    }

    var detail: String {
        switch self {
        case .home:
            return "Manage installed apps".localized
        case .scripts:
            return "Manage and run JS scripts".localized
        case .tools:
            return "Access additional tools".localized
        case .console:
            return "Live device logs".localized
        case .deviceInfo:
            return "View detailed device metadata".localized
        case .profiles:
            return "Check app expiration dates".localized
        case .processes:
            return "Inspect running apps".localized
        case .location:
            return "Simulate GPS location".localized
        case .settings:
            return "Configure StikDebug".localized
        }
    }

    var toolTitle: String {
        switch self {
        case .location:
            return "Location Simulation".localized
        default:
            return title
        }
    }

    var systemImage: String {
        switch self {
        case .home:
            return "square.grid.2x2"
        case .scripts:
            return "scroll"
        case .tools:
            return "wrench.and.screwdriver"
        case .console:
            return "terminal"
        case .deviceInfo:
            return "iphone.and.arrow.forward"
        case .profiles:
            return "calendar.badge.clock"
        case .processes:
            return "rectangle.stack.person.crop"
        case .location:
            return "location"
        case .settings:
            return "gearshape.fill"
        }
    }

    @ViewBuilder
    var destination: some View {
        switch self {
        case .home:
            HomeView()
        case .scripts:
            ScriptListView()
        case .tools:
            ToolsView()
        case .console:
            ConsoleLogsView()
        case .deviceInfo:
            DeviceInfoView()
        case .profiles:
            ProfileView()
        case .processes:
            ProcessInspectorView()
        case .location:
            LocationSimulationView()
        case .settings:
            SettingsView()
        }
    }
}

extension AppFeature {
    static let mainTabs: [AppFeature] = [.home, .tools, .settings]
    static let toolList: [AppFeature] = [.scripts, .console, .deviceInfo, .profiles, .processes, .location]
}
