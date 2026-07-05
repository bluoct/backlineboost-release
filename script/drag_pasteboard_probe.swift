#!/usr/bin/env swift
// Diagnostic: watch the global drag pasteboard and print every flavor a drag
// carries. Run `swift script/drag_pasteboard_probe.swift`, start dragging a
// track from the Music app (no need to drop it anywhere), and read the
// printed types/payloads. Ctrl-C to stop.
//
// This captures the payload even when Backbeat's drop shim is not registered
// for the types a given macOS release uses — the drag pasteboard is a global
// named pasteboard readable from any process.

import AppKit

let dragPasteboard = NSPasteboard(name: .drag)
var lastChangeCount = dragPasteboard.changeCount

print("Watching the drag pasteboard. Start a drag (e.g. from Music); Ctrl-C to stop.")

while true {
    if dragPasteboard.changeCount != lastChangeCount {
        lastChangeCount = dragPasteboard.changeCount
        print("\n=== drag pasteboard change #\(lastChangeCount) ===")
        let types = (dragPasteboard.types ?? []).map(\.rawValue)
        print("pasteboard types: \(types)")

        for (index, item) in (dragPasteboard.pasteboardItems ?? []).enumerated() {
            print("item[\(index)] types: \(item.types.map(\.rawValue))")
            for type in item.types {
                if let plist = item.propertyList(forType: type) {
                    let text = String(describing: plist)
                    print("item[\(index)] \(type.rawValue) plist: \(text.prefix(4000))")
                } else if let string = item.string(forType: type) {
                    print("item[\(index)] \(type.rawValue) string: \(string.prefix(2000))")
                } else if let data = item.data(forType: type) {
                    print("item[\(index)] \(type.rawValue) data: \(data.count) bytes")
                }
            }
        }
    }
    Thread.sleep(forTimeInterval: 0.1)
}
