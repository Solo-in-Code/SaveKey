// SPDX-License-Identifier: AGPL-3.0-or-later
import Foundation

@MainActor public protocol View {}
public struct ModifierContent: View {}
public struct ModifiedView: View {}
@MainActor public protocol ViewModifier {
    associatedtype Body: View
    typealias Content = ModifierContent
    func body(content: Content) -> Body
}
extension View {
    public func modifier<M: ViewModifier>(_ m: M) -> ModifiedView { ModifiedView() }
    public func onAppear(perform action: (() -> Void)? = nil) -> ModifiedView { ModifiedView() }
    public func onDisappear(perform action: (() -> Void)? = nil) -> ModifiedView { ModifiedView() }
}
@propertyWrapper public struct State<Value> {
    public var wrappedValue: Value
    public init(wrappedValue: Value) { self.wrappedValue = wrappedValue }
}
extension Array {
    public mutating func move(fromOffsets source: IndexSet, toOffset destination: Int) {
        let moving = source.map { self[$0] }
        for i in source.sorted(by: >) { remove(at: i) }
        let insertAt = destination - source.filter { $0 < destination }.count
        insert(contentsOf: moving, at: insertAt)
    }
}
