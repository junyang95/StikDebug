import Testing
@testable import PikminRuntime

struct LocationNetworkTests {
    @Test func wifiIncludingHotspotsTakesPriorityOverCellular() {
        // A Wi-Fi hotspot remains eligible even if a cellular route is also present.
        for usesCellular in [false, true] {
            let state = LocationNetworkState(isSatisfied: true, usesWiFi: true, usesCellular: usesCellular)
            #expect(state == .wifi)
            #expect(state.isReady)
            #expect(state.blockingMessage == nil)
        }
    }

    @Test func onlyCellularGetsTheCellularReminder() {
        let state = LocationNetworkState(isSatisfied: true, usesWiFi: false, usesCellular: true)
        #expect(state == .cellular)
        #expect(!state.isReady)
        #expect(state.blockingMessage == "当前正在使用流量，无法模拟定位。请先连接 Wi-Fi 或其他设备的热点。")
        #expect(LocationNetworkState.checking.blockingMessage != state.blockingMessage)
        #expect(LocationNetworkState.unavailable.blockingMessage != state.blockingMessage)
    }

    @Test func disconnectedAndUnsupportedPathsDoNotPermitSimulation() {
        for usesWiFi in [false, true] {
            for usesCellular in [false, true] {
                let disconnected = LocationNetworkState(
                    isSatisfied: false, usesWiFi: usesWiFi, usesCellular: usesCellular
                )
                #expect(disconnected == .unavailable)
                #expect(!disconnected.isReady)
                #expect(disconnected.blockingMessage != nil)
            }
        }
        #expect(LocationNetworkState(isSatisfied: true, usesWiFi: false, usesCellular: false) == .unavailable)
        #expect(!LocationNetworkState.checking.isReady)
        #expect(LocationNetworkState.checking.blockingMessage != nil)
    }
}
