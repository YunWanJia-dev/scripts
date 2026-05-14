#!/usr/bin/env bash
set -euo pipefail

# Flutter 项目自动环境准备和 Web 构建脚本
#
# 可用环境变量：
#   FLUTTER_GIT_URL     Flutter SDK Git 仓库地址，默认为官方仓库。
#   FLUTTER_GIT_BRANCH  Flutter SDK Git 分支，默认为 stable。
#   FLUTTER_TMP_ROOT    Flutter SDK 默认克隆目录的上级目录，默认为 /tmp。
#   FLUTTER_SDK_DIR     已有或目标 Flutter SDK 目录；若 bin/flutter 存在，则跳过克隆。
#   BUILD_HOME          构建时使用的 HOME 目录，默认为 /tmp/flutter-build-home。
#   PUB_CACHE           Dart/Flutter pub 缓存目录，默认为 BUILD_HOME/.pub-cache。

# ===== 基础配置 =====
FLUTTER_GIT_URL="${FLUTTER_GIT_URL:-https://github.com/flutter/flutter.git}"
FLUTTER_GIT_BRANCH="${FLUTTER_GIT_BRANCH:-stable}"
FLUTTER_TMP_ROOT="${FLUTTER_TMP_ROOT:-/tmp}"
FLUTTER_SDK_DIR="${FLUTTER_SDK_DIR:-${FLUTTER_TMP_ROOT}/flutter}"
FLUTTER_BIN="${FLUTTER_SDK_DIR}/bin/flutter"
BUILD_HOME="${BUILD_HOME:-${SCRIPT_DIR}/.flutter-build-home}"

# 获取当前脚本所在目录，后续始终在项目根目录中执行构建。
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd -P)"

# ===== 输出当前系统 =====
# 在准备 SDK 前输出系统信息，方便排查 CI 或 Pages 环境问题。
if [[ -f /etc/os-release ]]; then
  # shellcheck disable=SC1091
  . /etc/os-release
  echo "当前系统：${PRETTY_NAME:-${NAME:-unknown}}"
else
  echo "当前系统：$(uname -s)"
fi
echo "系统架构：$(uname -m)"

# ===== 检查基础命令 =====
# Pages 环境通常没有 root 权限，所以这里只检查，不尝试安装系统依赖。
command -v git >/dev/null 2>&1 || { echo "缺少 git 命令，无法克隆 Flutter SDK" >&2; exit 1; }

# ===== 配置构建缓存目录 =====
# Pages 环境中的默认 HOME 或 /tmp 可能不支持 pub 执行 chmod。
# 这里把 HOME 和 PUB_CACHE 放到项目目录中，并在必要时提供 chmod 兼容命令。
mkdir -p "$BUILD_HOME"
export HOME="$BUILD_HOME"
export PUB_CACHE="${PUB_CACHE:-${HOME}/.pub-cache}"
export FLUTTER_SUPPRESS_ANALYTICS=true
export DART_SUPPRESS_ANALYTICS=true
mkdir -p "$PUB_CACHE"

CHMOD_TEST_FILE="${PUB_CACHE}/.chmod-test"
: >"$CHMOD_TEST_FILE"
if ! chmod 755 "$CHMOD_TEST_FILE" >/dev/null 2>&1; then
  BUILD_BIN="${BUILD_HOME}/bin"
  TRUE_BIN="$(command -v true || true)"
  mkdir -p "$BUILD_BIN"

  if [[ -n "$TRUE_BIN" ]]; then
    ln -sf "$TRUE_BIN" "${BUILD_BIN}/chmod"
    export PATH="${BUILD_BIN}:${PATH}"
    echo "警告：当前环境不允许对 Pub 缓存执行 chmod，已启用 chmod 兼容命令" >&2
  else
    echo "警告：当前环境不允许对 Pub 缓存执行 chmod，且找不到 true 命令，pub 可能仍会失败" >&2
  fi
fi
rm -f "$CHMOD_TEST_FILE"

echo "构建 HOME：${HOME}"
echo "Pub 缓存：${PUB_CACHE}"

# ===== 准备 Flutter SDK =====
# 如果指定的 SDK 目录中还没有可用的 Flutter，则通过 Git 克隆官方 stable 分支。
mkdir -p "$FLUTTER_TMP_ROOT"

if [[ ! -x "$FLUTTER_BIN" ]]; then
  if [[ -e "$FLUTTER_SDK_DIR" ]]; then
    echo "Flutter SDK 目录已存在，但 ${FLUTTER_BIN} 不可执行。为避免误删或覆盖旧文件，请手动处理该目录，或通过 FLUTTER_SDK_DIR 指定其他目录。" >&2
    exit 1
  fi

  git clone --depth 1 --branch "$FLUTTER_GIT_BRANCH" "$FLUTTER_GIT_URL" "$FLUTTER_SDK_DIR"
fi

# ===== 配置 Git 安全目录 =====
# 容器、CI 或 Pages 中的挂载目录可能触发 Git safe.directory 检查。
git config --global --add safe.directory "$FLUTTER_SDK_DIR"
git config --global --add safe.directory "$SCRIPT_DIR"

# ===== 使用绝对路径构建 Web =====
# 不依赖 PATH 中的 flutter，避免系统 Flutter 版本影响构建。
cd "$SCRIPT_DIR"
"$FLUTTER_BIN" --version
"$FLUTTER_BIN" config --enable-web
"$FLUTTER_BIN" pub get
"$FLUTTER_BIN" build web --release
