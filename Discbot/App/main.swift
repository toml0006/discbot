//
//  main.swift
//  Discbot
//
//  Application entry point - handles both macOS 10.15 and 11+
//

import AppKit
import SwiftUI

// Create and run the application
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
