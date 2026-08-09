#!/bin/zsh
set -euo pipefail

script_directory=${0:A:h}
repository_root=${script_directory:h}
source_root=${CAPTURE_LIBRARY_BENCHMARK_SOURCE_ROOT:-$repository_root}
source_root=${source_root:A}
developer_directory=/Applications/Xcode.app/Contents/Developer
build_directory=$(mktemp -d "${TMPDIR:-/tmp}/take-a-shot-capture-library-benchmark.XXXXXX")
output_path=${CAPTURE_LIBRARY_BENCHMARK_OUTPUT:-$(mktemp "${TMPDIR:-/tmp}/take-a-shot-capture-library-benchmark.XXXXXX")}

cleanup() {
    [[ -d "$build_directory" ]] && rm -rf -- "$build_directory"
}
trap cleanup EXIT HUP INT TERM

swiftc_path=$(DEVELOPER_DIR="$developer_directory" xcrun --find swiftc)
sdk_path=$(DEVELOPER_DIR="$developer_directory" xcrun --sdk macosx --show-sdk-path)
[[ -x "$swiftc_path" ]] || {
    print -u2 -- "Full-Xcode swiftc not found at $developer_directory"
    exit 1
}
[[ -f "$source_root/TakeAShot/CaptureModels.swift" &&
   -f "$source_root/TakeAShot/ImagePipeline.swift" &&
   -f "$source_root/TakeAShot/CaptureLibrary.swift" ]] || {
    print -u2 -- "CaptureLibrary sources not found below $source_root"
    exit 1
}

source_revision=$(git -C "$source_root" rev-parse --verify HEAD 2>/dev/null || true)
operating_system_version=$(sw_vers -productVersion 2>/dev/null || true)
architecture=$(uname -m)
swift_version=$("$swiftc_path" --version 2>&1 | /usr/bin/tr '\n' ' ' | /usr/bin/sed -E 's/[[:space:]]+$//')

DEVELOPER_DIR="$developer_directory" SDKROOT="$sdk_path" "$swiftc_path" -sdk "$sdk_path" -O -whole-module-optimization \
    "$source_root/TakeAShot/CaptureModels.swift" \
    "$source_root/TakeAShot/ImagePipeline.swift" \
    "$source_root/TakeAShot/CaptureLibrary.swift" \
    "$repository_root/Benchmarks/CaptureLibraryBenchmark.swift" \
    -o "$build_directory/CaptureLibraryBenchmark"

CAPTURE_LIBRARY_BENCHMARK_SOURCE_ROOT="$source_root" \
CAPTURE_LIBRARY_BENCHMARK_GIT_REVISION="$source_revision" \
CAPTURE_LIBRARY_BENCHMARK_OS_VERSION="$operating_system_version" \
CAPTURE_LIBRARY_BENCHMARK_ARCH="$architecture" \
CAPTURE_LIBRARY_BENCHMARK_SWIFT_VERSION="$swift_version" \
    "$build_directory/CaptureLibraryBenchmark" "$@" > "$output_path"
/usr/bin/plutil -convert json -o /dev/null - < "$output_path"
print -r -- "$output_path"
