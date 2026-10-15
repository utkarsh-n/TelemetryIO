#!/bin/zsh
set -eu
SRC="$(cd "$(dirname "$0")/.." && pwd)"
WORK="${TELEMETRY_BUILD_DIR:-${TMPDIR:-/tmp}/TelemetryIOBuild}"
mkdir -p "$WORK/src"
rsync -a --delete --exclude 'Core/.build' --exclude '.git' --exclude '*.xcuserstate' --exclude 'Documentation/QA' "$SRC/" "$WORK/src/"
cd "$WORK/src"
xcodegen generate --quiet
if [[ -n "${TELEMETRY_SIMULATOR_ID:-}" ]]; then
  SIM_DESTINATION="platform=iOS Simulator,id=$TELEMETRY_SIMULATOR_ID"
else
  SIM_DESTINATION="platform=iOS Simulator,name=TelemetryIO QA"
fi
case "${1:-sim}" in
  sim) xcodebuild -project TelemetryIO.xcodeproj -scheme TelemetryIO -configuration Debug -destination "$SIM_DESTINATION" -derivedDataPath "$WORK/dd" build ;;
  test) xcodebuild -project TelemetryIO.xcodeproj -scheme TelemetryIO -configuration Debug -destination "$SIM_DESTINATION" -derivedDataPath "$WORK/dd" -parallel-testing-enabled NO "TELEMETRY_TEST_LOCATION=${TELEMETRY_TEST_LOCATION:-0}" test ;;
  # Avoid stalled asynchronous sysdiagnosis collection during UI result finalization.
  ui) /usr/bin/caffeinate -di xcodebuild -project TelemetryIO.xcodeproj -scheme TelemetryIOUI -configuration Debug -destination "$SIM_DESTINATION" -derivedDataPath "$WORK/dd" -parallel-testing-enabled NO -maximum-concurrent-test-simulator-destinations 1 -test-timeouts-enabled YES -default-test-execution-time-allowance 600 -maximum-test-execution-time-allowance 720 -collect-test-diagnostics never test ;;
  device) xcodebuild -project TelemetryIO.xcodeproj -scheme TelemetryIO -configuration Release -destination 'generic/platform=iOS' -allowProvisioningUpdates -derivedDataPath "$WORK/dd" build ;;
  *) print -u2 'Usage: Tools/build.sh sim|test|ui|device'; exit 2 ;;
esac
