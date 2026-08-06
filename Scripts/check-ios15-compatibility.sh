#!/usr/bin/env bash

set -Eeuo pipefail

root_dir="$(cd "$(dirname "$0")/.." && pwd -P)"
cd "$root_dir"

fail() {
    echo "error: $*" >&2
    exit 65
}

deployment_target_count="$(
    grep -c 'IPHONEOS_DEPLOYMENT_TARGET = 15.0;' Inspector.xcodeproj/project.pbxproj || true
)"
all_deployment_target_count="$(
    grep -c 'IPHONEOS_DEPLOYMENT_TARGET =' Inspector.xcodeproj/project.pbxproj || true
)"
[[ "$deployment_target_count" -eq 2 && "$deployment_target_count" -eq "$all_deployment_target_count" ]] \
    || fail "every project deployment target must be iOS 15.0"

grep -Fq 'IPHONEOS_DEPLOYMENT_TARGET=15.0' Makefile \
    || fail "Makefile must override the deployment target to iOS 15.0"

grep -Fq 'Depends: firmware (>= 15.0), uikittools, launchctl' Packaging/DEBIAN/control \
    || fail "Debian metadata must require firmware 15.0"

forbidden_pattern='@Observable|@Bindable|@Environment\(ProcessListModel|import Observation|Navigation(Stack|SplitView)|ContentUnavailableView|ShareLink[[:space:]]*\(|(^|[^[:alnum:]_])LabeledContent[[:space:]]*\(|\.topBar(Leading|Trailing)|\.presentationDetents|\.contentShape\(\.rect\)|\.smooth([[:space:](]|$)|Task\.sleep\(for:|LocalizedStringResource|Button\(.*systemImage:|Picker\(.*systemImage:'
found_forbidden=0
while IFS= read -r -d '' source; do
    if grep -nE "$forbidden_pattern" "$source"; then
        found_forbidden=1
    fi
done < <(find Inspector -type f -name '*.swift' -print0)
[[ "$found_forbidden" -eq 0 ]] \
    || fail "an unconditional iOS 16/17-only SwiftUI API remains"

echo "iOS 15 compatibility checks passed"
