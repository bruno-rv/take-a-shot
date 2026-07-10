.PHONY: app build run

app: run

build:
	DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild \
		-project TakeAShot.xcodeproj \
		-scheme TakeAShot \
		-configuration Debug \
		-destination 'platform=macOS' \
		-derivedDataPath .build/DerivedData \
		build

run:
	./script/build_and_run.sh
