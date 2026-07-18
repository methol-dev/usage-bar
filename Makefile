.PHONY: build app zip dmg release-artifacts verify-release install clean extension-zip

build:
	cd macos && swift build -c release

app:
	bash macos/scripts/build.sh

zip:
	bash macos/scripts/build.sh --zip
	bash macos/scripts/verify-release.sh macos/UsageBar.zip

dmg:
	bash macos/scripts/build.sh --dmg
	bash macos/scripts/verify-release.sh macos/UsageBar.dmg

release-artifacts:
	bash macos/scripts/build.sh --zip --dmg
	bash macos/scripts/verify-release.sh macos/UsageBar.zip
	bash macos/scripts/verify-release.sh macos/UsageBar.dmg

verify-release:
	bash macos/scripts/verify-release.sh macos/UsageBar.zip
	if [ -f macos/UsageBar.dmg ]; then bash macos/scripts/verify-release.sh macos/UsageBar.dmg; fi

extension-zip:
	bash scripts/package-extension.sh usage-bar-extension.zip

install: app
	rm -rf /Applications/UsageBar.app
	cp -R macos/UsageBar.app /Applications/

clean:
	cd macos && swift package clean
	rm -rf macos/UsageBar.app macos/UsageBar.zip macos/UsageBar.dmg
