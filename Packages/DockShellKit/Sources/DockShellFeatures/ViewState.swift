import SwiftUI

/// Selects the macOS 14 property-wrapper type rather than the SDK's same-named State macro.
/// Current CLT ships the wrapper runtime but does not ship the SwiftUIMacros plugin.
typealias ViewState<Value> = SwiftUI.State<Value>
