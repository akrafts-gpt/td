#!/usr/bin/env bash
set -euo pipefail

if [[ -z "${VERSION_NAME:-}" ]]; then
  echo "VERSION_NAME environment variable is required" >&2
  exit 1
fi

TDLIB_REF=${TDLIB_REF:-master}
REPO_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
LIBS_DIR="$REPO_ROOT/libtd/src/main/libs"
JAVA_DST_DIR="$REPO_ROOT/libtd/src/main/java/org/drinkless/td/libcore/telegram"
TD_SRC_DIR="$REPO_ROOT/.td-src"
ANDROID_NDK_DIR=${ANDROID_NDK_HOME:-${ANDROID_NDK_ROOT:-}}
TOOLCHAIN_FILE="${ANDROID_NDK_DIR}/build/cmake/android.toolchain.cmake"
ANDROID_TOOLCHAIN_DIR="$ANDROID_NDK_DIR/toolchains/llvm/prebuilt/linux-x86_64"
ANDROID_API_LEVEL=21
OPENSSL_VERSION=${OPENSSL_VERSION:-"1.1.1w"}
OPENSSL_URL=${OPENSSL_URL:-"https://www.openssl.org/source/openssl-${OPENSSL_VERSION}.tar.gz"}
OPENSSL_WORK_DIR="$REPO_ROOT/.openssl-android"
OPENSSL_ARCHIVE="$OPENSSL_WORK_DIR/openssl.tar.gz"

if [[ -z "$ANDROID_NDK_DIR" ]]; then
  echo "ANDROID_NDK_HOME or ANDROID_NDK_ROOT must be set" >&2
  exit 1
fi

if [[ ! -f "$TOOLCHAIN_FILE" ]]; then
  echo "Android NDK toolchain file not found: $TOOLCHAIN_FILE" >&2
  exit 1
fi

if [[ ! -d "$ANDROID_TOOLCHAIN_DIR" ]]; then
  echo "Unable to locate Android toolchain directory at $ANDROID_TOOLCHAIN_DIR" >&2
  exit 1
fi

if [[ ! -d "$LIBS_DIR" ]]; then
  echo "Unable to find TDLib Android libs directory at $LIBS_DIR" >&2
  exit 1
fi

mapfile -t ANDROID_ABIS < <(find "$LIBS_DIR" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' | sort)
if [[ ${#ANDROID_ABIS[@]} -eq 0 ]]; then
  echo "No ABI directories found under $LIBS_DIR" >&2
  exit 1
fi

rm -rf "$OPENSSL_WORK_DIR"
mkdir -p "$OPENSSL_WORK_DIR"

detect_jni_library_name() {
  local build_dir="$1"
  local native_client=""
  if [[ -d "$build_dir/java" ]]; then
    native_client=$(find "$build_dir/java" -name NativeClient.java -print -quit 2>/dev/null || true)
  fi
  if [[ -n "$native_client" && -f "$native_client" ]]; then
    local lib_name
    lib_name=$(perl -ne 'if (/System\\.loadLibrary\("([^"]+)"\)/) { print $1; exit }' "$native_client" || true)
    if [[ -n "$lib_name" ]]; then
      printf '%s\n' "$lib_name"
      return 0
    fi
  fi

  for candidate in tdjni tdapi; do
    if [[ -f "$build_dir/lib${candidate}.so" ]]; then
      printf '%s\n' "$candidate"
      return 0
    fi
  done

  echo "Unable to detect JNI library name under $build_dir" >&2
  return 1
}

echo "Downloading OpenSSL sources from $OPENSSL_URL"
curl -LsSf "$OPENSSL_URL" -o "$OPENSSL_ARCHIVE"

build_openssl_for_abi() {
  local abi="$1"
  local src_dir="$OPENSSL_WORK_DIR/src-$abi"
  local install_dir="$OPENSSL_WORK_DIR/install-$abi"
  local config target_host

  case "$abi" in
    arm64-v8a)
      config="android-arm64"
      target_host="aarch64-linux-android"
      ;;
    armeabi-v7a)
      config="android-arm"
      target_host="armv7a-linux-androideabi"
      ;;
    x86)
      config="android-x86"
      target_host="i686-linux-android"
      ;;
    x86_64)
      config="android-x86_64"
      target_host="x86_64-linux-android"
      ;;
    *)
      echo "Unsupported ABI for OpenSSL build: $abi" >&2
      return 1
      ;;
  esac

  {
    rm -rf "$src_dir" "$install_dir"
    mkdir -p "$src_dir" "$install_dir"
    tar -xzf "$OPENSSL_ARCHIVE" -C "$src_dir" --strip-components=1

    echo "Building OpenSSL $OPENSSL_VERSION for $abi"
    (
      set -euo pipefail
      export ANDROID_NDK_HOME="$ANDROID_NDK_DIR"
      export ANDROID_NDK_ROOT="$ANDROID_NDK_DIR"
      export PATH="$ANDROID_TOOLCHAIN_DIR/bin:$PATH"
      export AR="$ANDROID_TOOLCHAIN_DIR/bin/${target_host}-ar"
      export AS="$ANDROID_TOOLCHAIN_DIR/bin/${target_host}-as"
      export CC="$ANDROID_TOOLCHAIN_DIR/bin/${target_host}${ANDROID_API_LEVEL}-clang"
      export CXX="$ANDROID_TOOLCHAIN_DIR/bin/${target_host}${ANDROID_API_LEVEL}-clang++"
      export LD="$ANDROID_TOOLCHAIN_DIR/bin/${target_host}-ld"
      export RANLIB="$ANDROID_TOOLCHAIN_DIR/bin/${target_host}-ranlib"
      export STRIP="$ANDROID_TOOLCHAIN_DIR/bin/${target_host}-strip"
      cd "$src_dir"
      perl ./Configure "$config" -D__ANDROID_API__="$ANDROID_API_LEVEL" no-shared --prefix="$install_dir" --openssldir="$install_dir"
      make -j"$(nproc)"
      make install_sw
    )
  } >&2

  printf '%s\n' "$install_dir"
}

rm -rf "$TD_SRC_DIR"
git clone https://github.com/tdlib/td.git "$TD_SRC_DIR"
cd "$TD_SRC_DIR"
git checkout "$TDLIB_REF"

ensure_mapping_generated() {
  local mapping_basename="$1"
  local generator_mapping="$2"
  local description="$3"
  local output_file="$TD_SRC_DIR/tdutils/generate/auto/${mapping_basename}.cpp"

  if [[ -f "$output_file" ]]; then
    return
  fi

  local gperf_input=""
  local candidate
  local -a candidate_paths=(
    "$TD_SRC_DIR/tdutils/generate/${mapping_basename}.gperf"
    "$TD_SRC_DIR/tdutils/generate/${mapping_basename}.in.gperf"
  )

  for candidate in "${candidate_paths[@]}"; do
    if [[ -n "$candidate" && -f "$candidate" ]]; then
      gperf_input="$candidate"
      break
    fi
  done

  if [[ -z "$gperf_input" ]]; then
    gperf_input=$(find "$TD_SRC_DIR" -name "${mapping_basename}*.gperf" -print -quit 2>/dev/null || true)
  fi

  local fallback_generator="$REPO_ROOT/scripts/generate_mime_type_mapping.py"
  if [[ ! -x "$fallback_generator" ]]; then
    echo "gperf is unavailable and $fallback_generator is missing" >&2
    exit 1
  fi

  if [[ -n "$gperf_input" && -f "$gperf_input" ]]; then
    if command -v gperf >/dev/null 2>&1; then
      echo "Generating ${description} lookup via gperf (input: ${gperf_input#$TD_SRC_DIR/})"
      mkdir -p "$(dirname "$output_file")"
      if ! gperf "$gperf_input" >"$output_file"; then
        echo "Failed to generate $output_file via gperf" >&2
        exit 1
      fi
      return
    fi

    echo "gperf not found; generating ${description} mapping via $fallback_generator" >&2
    if ! python3 "$fallback_generator" --mapping "$generator_mapping" --gperf-input "$gperf_input" --output "$output_file"; then
      echo "Failed to generate $output_file via $fallback_generator" >&2
      exit 1
    fi
    return
  fi

  echo "No gperf source found under $TD_SRC_DIR; generating ${description} map via Python stdlib" >&2
  if ! python3 "$fallback_generator" --mapping "$generator_mapping" --use-stdlib --output "$output_file"; then
    echo "Failed to generate $output_file via $fallback_generator" >&2
    exit 1
  fi
}

ensure_mapping_header() {
  local header_file="$TD_SRC_DIR/tdutils/td/utils/$1.h"
  local function_name="$2"
  local argument_name="$3"

  if [[ -f "$header_file" ]]; then
    return
  fi

  mkdir -p "$(dirname "$header_file")"
  cat >"$header_file" <<EOF
#pragma once

#include "td/utils/Slice.h"

namespace td {

CSlice ${function_name}(Slice ${argument_name});

}  // namespace td
EOF
}

ensure_mapping_generated "mime_type_to_extension" "mime-to-extension" "MIME type to extension"
ensure_mapping_generated "extension_to_mime_type" "extension-to-mime" "extension to MIME type"
ensure_mapping_header "mime_type_to_extension" "mime_type_to_extension" "mime_type"
ensure_mapping_header "extension_to_mime_type" "extension_to_mime_type" "extension"

JAVA_SRC_DIR=""
JNI_LIB_NAME=""
for ABI in "${ANDROID_ABIS[@]}"; do
  BUILD_DIR="$TD_SRC_DIR/build-android-$ABI"
  rm -rf "$BUILD_DIR"
  OPENSSL_DIR=$(build_openssl_for_abi "$ABI")
  cmake -S "$TD_SRC_DIR" -B "$BUILD_DIR" \
    -G Ninja \
    -DCMAKE_BUILD_TYPE=Release \
    -DTD_ENABLE_JNI=ON \
    -DTD_ENABLE_DOTNET=OFF \
    -DCMAKE_TOOLCHAIN_FILE="$TOOLCHAIN_FILE" \
    -DANDROID_ABI="$ABI" \
    -DANDROID_PLATFORM="android-$ANDROID_API_LEVEL" \
    -DANDROID_STL=c++_shared \
    -DOPENSSL_ROOT_DIR="$OPENSSL_DIR" \
    -DOPENSSL_INCLUDE_DIR="$OPENSSL_DIR/include" \
    -DOPENSSL_CRYPTO_LIBRARY="$OPENSSL_DIR/lib/libcrypto.a" \
    -DOPENSSL_SSL_LIBRARY="$OPENSSL_DIR/lib/libssl.a" \
    -DOPENSSL_USE_STATIC_LIBS=ON
  cmake --build "$BUILD_DIR"
  if [[ -z "$JNI_LIB_NAME" ]]; then
    JNI_LIB_NAME=$(detect_jni_library_name "$BUILD_DIR")
  fi
  if [[ -z "$JNI_LIB_NAME" ]]; then
    echo "Unable to determine JNI library name" >&2
    exit 1
  fi
  JNI_LIB_FILE="lib${JNI_LIB_NAME}.so"
  if [[ ! -f "$BUILD_DIR/$JNI_LIB_FILE" ]]; then
    echo "Unable to find $JNI_LIB_FILE under $BUILD_DIR" >&2
    exit 1
  fi
  mkdir -p "$LIBS_DIR/$ABI"
  rm -f "$LIBS_DIR/$ABI"/*.so
  cp "$BUILD_DIR/$JNI_LIB_FILE" "$LIBS_DIR/$ABI/$JNI_LIB_FILE"
  if [[ -z "$JAVA_SRC_DIR" ]]; then
    JAVA_SRC_DIR="$BUILD_DIR/java/org/drinkless/td/libcore/telegram"
  fi
done

if [[ -z "$JAVA_SRC_DIR" || ! -d "$JAVA_SRC_DIR" ]]; then
  echo "Unable to locate generated Java sources under $JAVA_SRC_DIR" >&2
  exit 1
fi

rm -rf "$JAVA_DST_DIR"
mkdir -p "$JAVA_DST_DIR"
cp -R "$JAVA_SRC_DIR/"* "$JAVA_DST_DIR/"

BUILD_GRADLE="$REPO_ROOT/libtd/build.gradle"
README_MD="$REPO_ROOT/README.md"
CURRENT_VERSION_CODE=$(grep -m1 -oP 'versionCode\s+\K\d+' "$BUILD_GRADLE" || true)
if [[ -z "$CURRENT_VERSION_CODE" ]]; then
  echo "Unable to find versionCode in $BUILD_GRADLE" >&2
  exit 1
fi
NEW_VERSION_CODE=$((CURRENT_VERSION_CODE + 1))
perl -0pi -e "s/(versionCode\s+)$CURRENT_VERSION_CODE/\1$NEW_VERSION_CODE/" "$BUILD_GRADLE"
perl -0pi -e "s/(versionName\s+\")([^"]+)(\")/\1${VERSION_NAME}\3/" "$BUILD_GRADLE"
perl -0pi -e "s|(com\\.github\\.tdlibx:td:)[^"']+|\1${VERSION_NAME}|g" "$README_MD"

echo "TDLib update complete. Version code bumped to $NEW_VERSION_CODE with version name $VERSION_NAME."
rm -rf "$TD_SRC_DIR" "$OPENSSL_WORK_DIR"
