#!/bin/zsh
# Simulator build from the command line (SwiftTerm ships a build plugin → skip validation).
cd "$(dirname "$0")"
command -v xcodegen >/dev/null || PATH=/opt/homebrew/bin:$PATH
xcodegen generate --quiet
xcodebuild -project AgentHub.xcodeproj -scheme AgentHub \
  -destination "${DEST:-platform=iOS Simulator,name=iPhone 17}" \
  -clonedSourcePackagesDirPath build/spm -derivedDataPath build/dd \
  -skipPackagePluginValidation -skipMacroValidation build "$@"
