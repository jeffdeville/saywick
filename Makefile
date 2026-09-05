DEVELOPER_DIR ?= /Applications/Xcode.app/Contents/Developer
SIMULATOR ?= iPhone 17 Pro
XCODEBUILD = DEVELOPER_DIR=$(DEVELOPER_DIR) xcodebuild \
	-project LocalVoiceKeyboard.xcodeproj \
	-scheme LocalVoiceKeyboard \
	-packageAuthorizationProvider netrc \
	-clonedSourcePackagesDirPath $(CURDIR)/.build/SourcePackages

.PHONY: project test ui-test build-simulator build-device

project:
	xcodegen generate

test:
	DEVELOPER_DIR=$(DEVELOPER_DIR) swift test

ui-test:
	$(XCODEBUILD) \
		-derivedDataPath $(CURDIR)/.build/UITestDerivedData \
		-destination 'platform=iOS Simulator,name=$(SIMULATOR)' \
		test

build-simulator:
	$(XCODEBUILD) \
		-derivedDataPath $(CURDIR)/.build/SimulatorDerivedData \
		-sdk iphonesimulator \
		-destination 'generic/platform=iOS Simulator' \
		build

build-device:
	$(XCODEBUILD) \
		-derivedDataPath $(CURDIR)/.build/DeviceDerivedData \
		-sdk iphoneos \
		-destination 'generic/platform=iOS' \
		CODE_SIGNING_ALLOWED=NO \
		build
