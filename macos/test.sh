#!/bin/sh
# Builds and runs the tests for the parts of the app that need no AppKit.
set -e
cd "$(dirname "$0")"
mkdir -p build
swiftc -swift-version 5 Sources/RefinerProtocol.swift Sources/SessionSettings.swift Sources/ImproveKey.swift Tests/*.swift -o build/tests
./build/tests
