.PHONY: build release test clean

build:
	swift build

release:
	swift build -c release

test:
	swift test

clean:
	swift package clean
