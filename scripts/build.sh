#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
if [[ ! -f Config/Signing.local.xcconfig ]]; then
  echo 'Missing Config/Signing.local.xcconfig; copy Signing.example.xcconfig and select an installed certificate.' >&2
  exit 1
fi
configuration="${CONFIGURATION:-Debug}"
case "$configuration" in Debug|Release) ;; *) echo 'Use CONFIGURATION=Debug or Release.' >&2; exit 1 ;; esac
compile_only=false
autofill=false
for arg in "$@"; do
  case "$arg" in
    --autofill) autofill=true ;;
    --compile-only) compile_only=true ;;
    *) echo 'Usage: scripts/build.sh [--autofill] [--compile-only]' >&2; exit 1 ;;
  esac
done
scheme=MailCodeFillerLocal
folder=LocalDerivedData
settings="build/$configuration-local-settings.json"
if $autofill; then
  scheme=MailCodeFiller
  folder=AutoFillDerivedData
  settings="build/$configuration-settings.json"
fi
if $compile_only; then
  folder="Unsigned$folder"
  settings="${settings%.json}-unsigned.json"
fi
# xcodegen rewrites the shared MailCodeFiller.xcodeproj; serialize concurrent builds so one
# regenerate cannot pull the project out from under another xcodebuild.
lock_dir=build/.build.lock
mkdir -p build
until mkdir "$lock_dir" 2>/dev/null; do
  echo "Waiting for another scripts/build.sh to finish..." >&2
  sleep 5
done
trap 'rmdir "$lock_dir"' EXIT
derived_data="${DERIVED_DATA_PATH:-build/$folder}"
mkdir -p "$derived_data"
settings="$derived_data/$(basename "$settings")"
xcodegen generate
mkdir -p build MailCodeFiller.xcodeproj/project.xcworkspace/xcshareddata/swiftpm
# SwiftPM tests and Xcode must use the same transitive dependency versions.
cp Package.resolved MailCodeFiller.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved
args=(-project MailCodeFiller.xcodeproj -scheme "$scheme"
  -configuration "$configuration" -destination "platform=macOS,arch=$(uname -m)"
  -derivedDataPath "$derived_data" -jobs "${BUILD_JOBS:-4}"
  -onlyUsePackageVersionsFromResolvedFile)
if $compile_only; then args+=(CODE_SIGNING_ALLOWED=NO REGISTER_APP_WITH_LAUNCH_SERVICES=NO); fi
xcodebuild "${args[@]}" -showBuildSettings -json > "$settings"
if $autofill && ! $compile_only; then
  python3 scripts/verify-autofill.py "$settings" --configuration-only
fi
xcodebuild "${args[@]}" build
python3 scripts/verify-launch-agent.py "$settings"
if $compile_only; then
  echo 'Compile-only succeeded. This unsigned app is not runnable delivery.'
else
  python3 scripts/verify-signature.py "$settings"
  if $autofill; then python3 scripts/verify-autofill.py "$settings"; fi
fi
