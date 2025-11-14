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
TOOLCHAIN_FILE="${ANDROID_NDK_HOME:-${ANDROID_NDK_ROOT:-}}/build/cmake/android.toolchain.cmake"

if [[ ! -f "$TOOLCHAIN_FILE" ]]; then
  echo "Android NDK toolchain file not found: $TOOLCHAIN_FILE" >&2
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

rm -rf "$TD_SRC_DIR"
git clone https://github.com/tdlib/td.git "$TD_SRC_DIR"
cd "$TD_SRC_DIR"
git checkout "$TDLIB_REF"

JAVA_SRC_DIR=""
for ABI in "${ANDROID_ABIS[@]}"; do
  BUILD_DIR="$TD_SRC_DIR/build-android-$ABI"
  rm -rf "$BUILD_DIR"
  cmake -S "$TD_SRC_DIR" -B "$BUILD_DIR" \
    -G Ninja \
    -DCMAKE_BUILD_TYPE=Release \
    -DTD_ENABLE_JNI=ON \
    -DTD_ENABLE_DOTNET=OFF \
    -DCMAKE_TOOLCHAIN_FILE="$TOOLCHAIN_FILE" \
    -DANDROID_ABI="$ABI" \
    -DANDROID_PLATFORM=android-21 \
    -DANDROID_STL=c++_shared
  cmake --build "$BUILD_DIR" --target tdjni
  mkdir -p "$LIBS_DIR/$ABI"
  rm -f "$LIBS_DIR/$ABI/libtdjni.so"
  cp "$BUILD_DIR/libtdjni.so" "$LIBS_DIR/$ABI/libtdjni.so"
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
rm -rf "$TD_SRC_DIR"
