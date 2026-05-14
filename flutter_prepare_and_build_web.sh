#!/usr/bin/env bash
set -euo pipefail

# Flutter 项目自动环境准备和 Web 构建脚本
#
# 可用环境变量：
#   PROJECT_ROOT        Flutter 项目根目录；默认自动识别 pubspec.yaml 所在目录。
#   FLUTTER_GIT_URL     Flutter SDK Git 仓库地址，默认为官方仓库。
#   FLUTTER_GIT_BRANCH  Flutter SDK Git 分支，默认为 stable。
#   FLUTTER_TMP_ROOT    Flutter SDK 默认克隆目录的上级目录，默认为 /tmp。
#   FLUTTER_SDK_DIR     已有或目标 Flutter SDK 目录；若 bin/flutter 存在，则跳过克隆。
#   BUILD_HOME          构建时使用的 HOME 目录，默认为 /tmp/flutter-build-home。
#   PUB_CACHE           Dart/Flutter pub 缓存目录，默认为 /tmp/pub-cache。

# ===== 基础配置 =====

# 当前脚本所在目录，例如：项目根目录/scripts
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd -P)"

# 自动识别 Flutter 项目根目录
if [[ -n "${PROJECT_ROOT:-}" ]]; then
  PROJECT_ROOT="$(cd -- "$PROJECT_ROOT" >/dev/null 2>&1 && pwd -P)"
elif [[ -f "${SCRIPT_DIR}/pubspec.yaml" ]]; then
  PROJECT_ROOT="$SCRIPT_DIR"
elif [[ -f "${SCRIPT_DIR}/../pubspec.yaml" ]]; then
  PROJECT_ROOT="$(cd -- "${SCRIPT_DIR}/.." >/dev/null 2>&1 && pwd -P)"
else
  echo "错误：无法找到 pubspec.yaml。请通过 PROJECT_ROOT 指定 Flutter 项目根目录。" >&2
  exit 1
fi

FLUTTER_GIT_URL="${FLUTTER_GIT_URL:-https://github.com/flutter/flutter.git}"
FLUTTER_GIT_BRANCH="${FLUTTER_GIT_BRANCH:-stable}"
FLUTTER_TMP_ROOT="${FLUTTER_TMP_ROOT:-/tmp}"
FLUTTER_SDK_DIR="${FLUTTER_SDK_DIR:-${FLUTTER_TMP_ROOT}/flutter}"
FLUTTER_BIN="${FLUTTER_SDK_DIR}/bin/flutter"

# 关键修复：
# 不要把 BUILD_HOME / PUB_CACHE 放在仓库目录里。
# Cloudflare Pages 的仓库目录可能位于 /dev/shm/repo/...，pub 在那里 chmod 会失败。
BUILD_HOME="${BUILD_HOME:-/tmp/flutter-build-home}"
PUB_CACHE="${PUB_CACHE:-/tmp/pub-cache}"

# ===== 输出当前系统 =====

if [[ -f /etc/os-release ]]; then
  # shellcheck disable=SC1091
  . /etc/os-release
  echo "当前系统：${PRETTY_NAME:-${NAME:-unknown}}"
else
  echo "当前系统：$(uname -s)"
fi

echo "系统架构：$(uname -m)"
echo "脚本目录：${SCRIPT_DIR}"
echo "项目根目录：${PROJECT_ROOT}"

# ===== 检查基础命令 =====

command -v git >/dev/null 2>&1 || {
  echo "错误：缺少 git 命令，无法克隆 Flutter SDK。" >&2
  exit 1
}

# ===== 配置构建缓存目录 =====

mkdir -p "$BUILD_HOME"
mkdir -p "$PUB_CACHE"
mkdir -p "$FLUTTER_TMP_ROOT"

export HOME="$BUILD_HOME"
export PUB_CACHE="$PUB_CACHE"
export FLUTTER_SUPPRESS_ANALYTICS=true
export DART_SUPPRESS_ANALYTICS=true

# 清理上次失败可能留下的 pub 临时目录
rm -rf "${PUB_CACHE}/_temp"

# 检查目录是否真的支持 chmod
check_chmod_supported() {
  local dir="$1"
  local label="$2"
  local test_file="${dir}/.chmod-test-$$"

  mkdir -p "$dir"
  : >"$test_file"

  if ! chmod 755 "$test_file" >/dev/null 2>&1; then
    rm -f "$test_file"
    echo "错误：${label} 不支持 chmod：${dir}" >&2
    echo "请不要把 BUILD_HOME 或 PUB_CACHE 放在 /dev/shm 或仓库目录下。" >&2
    echo "建议使用：BUILD_HOME=/tmp/flutter-build-home PUB_CACHE=/tmp/pub-cache" >&2
    exit 1
  fi

  rm -f "$test_file"
}

check_chmod_supported "$BUILD_HOME" "BUILD_HOME"
check_chmod_supported "$PUB_CACHE" "PUB_CACHE"

echo "构建 HOME：${HOME}"
echo "Pub 缓存：${PUB_CACHE}"
echo "Flutter SDK 目录：${FLUTTER_SDK_DIR}"
echo "Flutter 分支：${FLUTTER_GIT_BRANCH}"

# ===== 准备 Flutter SDK =====

if [[ ! -x "$FLUTTER_BIN" ]]; then
  if [[ -e "$FLUTTER_SDK_DIR" ]]; then
    echo "Flutter SDK 目录已存在，但 ${FLUTTER_BIN} 不可执行。" >&2
    echo "将删除该临时目录并重新克隆：${FLUTTER_SDK_DIR}" >&2
    rm -rf "$FLUTTER_SDK_DIR"
  fi

  git clone --depth 1 --branch "$FLUTTER_GIT_BRANCH" "$FLUTTER_GIT_URL" "$FLUTTER_SDK_DIR"
fi

# ===== 配置 Git 安全目录 =====

git config --global --add safe.directory "$FLUTTER_SDK_DIR"
git config --global --add safe.directory "$PROJECT_ROOT"

# ===== 使用绝对路径构建 Web =====

cd "$PROJECT_ROOT"

"$FLUTTER_BIN" --version
"$FLUTTER_BIN" config --enable-web
"$FLUTTER_BIN" pub get
"$FLUTTER_BIN" build web --release
