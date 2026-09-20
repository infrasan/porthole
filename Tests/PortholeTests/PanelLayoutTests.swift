import XCTest
import AppKit
import SwiftUI
@testable import Porthole

final class PanelLayoutTests: XCTestCase {
    @MainActor func testInventoriesFitSmallAndLargeScreens() {
        _ = NSApplication.shared
        for count in [0, 1, 30, 100] {
            for height in [CGFloat(440), CGFloat(700)] {
                let store = Store(startTimer: false)
                store.panelMaxHeight = height
                store.show(DemoData.result(count: count))
                store.preview(health: [:], recents: DemoData.recents)
                let view = PanelView(showOthers: true).environmentObject(store)
                let host = NSHostingController(rootView: view)
                host.view.frame = CGRect(x: 0, y: 0, width: 400, height: height)
                host.view.layoutSubtreeIfNeeded()
                XCTAssertLessThanOrEqual(host.view.fittingSize.height, height, "\(count) rows on \(height)pt screen")
                XCTAssertEqual(host.view.fittingSize.width, 400, accuracy: 1)
                XCTAssertGreaterThan(host.view.fittingSize.height, 60)
            }
        }
    }
}
