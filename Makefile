DEVELOPER_DIR ?= /Applications/Xcode.app/Contents/Developer
.DEFAULT_GOAL := project
SIMULATOR ?= iPhone 17 Pro
XCODEBUILD = DEVELOPER_DIR=$(DEVELOPER_DIR) xcodebuild \
	-project LocalVoiceKeyboard.xcodeproj \
	-scheme LocalVoiceKeyboard \
	-packageAuthorizationProvider netrc \
	-clonedSourcePackagesDirPath $(CURDIR)/.build/SourcePackages

.PHONY: project test ui-test build-simulator build-device

.PHONY: parakeet-bootstrap
parakeet-bootstrap:
	bash Tools/Parakeet/bootstrap.sh

.build/Parakeet/SwiftPackage/Package.swift:
	bash Tools/Parakeet/bootstrap.sh

project: .build/Parakeet/SwiftPackage/Package.swift
	xcodegen generate

test:
	DEVELOPER_DIR=$(DEVELOPER_DIR) swift test

ui-test: .build/Parakeet/SwiftPackage/Package.swift
	$(XCODEBUILD) \
		-derivedDataPath $(CURDIR)/.build/UITestDerivedData \
		-destination 'platform=iOS Simulator,name=$(SIMULATOR)' \
		test

build-simulator: .build/Parakeet/SwiftPackage/Package.swift
	$(XCODEBUILD) \
		-derivedDataPath $(CURDIR)/.build/SimulatorDerivedData \
		-sdk iphonesimulator \
		-destination 'generic/platform=iOS Simulator' \
		build

build-device: .build/Parakeet/SwiftPackage/Package.swift
	$(XCODEBUILD) \
		-derivedDataPath $(CURDIR)/.build/DeviceDerivedData \
		-sdk iphoneos \
		-destination 'generic/platform=iOS' \
		CODE_SIGNING_ALLOWED=NO \
		build

.PHONY: pause-bench-build pause-bench-test pause-bench-fixtures
pause-bench-build:
	DEVELOPER_DIR=$(DEVELOPER_DIR) swift build --product pause-bench-azure
	cargo build --release --locked --manifest-path Tools/PauseBench/HandyRunner/Cargo.toml --target-dir .build/PauseBenchHandy

pause-bench-test:
	python3 -m unittest discover -s Tools/PauseBench -p 'test_*.py'

pause-bench-fixtures:
	python3 Tools/PauseBench/bench.py generate
