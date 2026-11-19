#!/bin/zsh
set -euo pipefail

project_root="${0:A:h:h}"
sdk_root="${QUICKBOUNCE_PTSL_SDK_ROOT:-$project_root/PTSL_SDK_CPP.2026.04.0.1301892}"
sdk_root="${sdk_root:A}"
python_command="${QUICKBOUNCE_PTSL_PYTHON:-python3.12}"
cache_root="$project_root/.quickbounce-build-cache"
vendor_root="$project_root/Vendor/AvidPTSL"

if [[ ! -f "$sdk_root/setup/build_cpp_ptsl_sdk.py" ]]; then
    print -u2 "PTSL SDK not found at $sdk_root. See Vendor/AvidPTSL/README.md."
    exit 1
fi
if ! command -v "$python_command" >/dev/null; then
    print -u2 "Python executable not found: $python_command. Set QUICKBOUNCE_PTSL_PYTHON to a compatible Python 3 executable."
    exit 1
fi

mkdir -p "$cache_root/tmp" "$cache_root/pip" "$cache_root/pycache" "$cache_root/clang" "$vendor_root"

export PIP_CACHE_DIR="$cache_root/pip"
export PYTHONPYCACHEPREFIX="$cache_root/pycache"
export TMPDIR="$cache_root/tmp"
export CLANG_MODULE_CACHE_PATH="$cache_root/clang"
export PIP_DISABLE_PIP_VERSION_CHECK=1

cd "$sdk_root"
"$python_command" setup/build_cpp_ptsl_sdk.py \
    --target ptsl.client.cpp \
    --config Release \
    --arch x86_64_arm64 \
    --os_version 14.0

framework="$sdk_root/install/x86_64_arm64/Release/PTSLC_CPP/PTSLC_CPP.framework"
if [[ ! -d "$framework" ]]; then
    print -u2 "Expected framework not found: $framework"
    exit 1
fi

/usr/bin/ditto "$framework" "$vendor_root/PTSLC_CPP.framework"
/usr/bin/file "$vendor_root/PTSLC_CPP.framework/PTSLC_CPP"
