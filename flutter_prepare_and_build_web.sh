#!/usr/bin/env bash
set -euo pipefail

# Flutter 项目自动环境准备和 Web 构建脚本
#
# 适用于 Cloudflare Pages / CI 环境。
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

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd -P)"

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

# 不要放在仓库目录中，避免 /dev/shm/repo/... 权限问题
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

command -v ln >/dev/null 2>&1 || {
  echo "错误：缺少 ln 命令，无法创建 chmod 兼容命令。" >&2
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
export CI=true

# 清理上次失败可能留下的 pub 临时目录
rm -rf "${PUB_CACHE}/_temp"

echo "构建 HOME：${HOME}"
echo "Pub 缓存：${PUB_CACHE}"
echo "Flutter SDK 目录：${FLUTTER_SDK_DIR}"
echo "Flutter 分支：${FLUTTER_GIT_BRANCH}"

# ===== Cloudflare Pages chmod 兼容处理 =====
#
# 某些 Pages 构建环境中，/dev/shm 和 /tmp 都可能不允许 chmod。
# Dart pub 下载依赖后会调用 subprocess chmod。
# 这里把 PATH 前置一个 chmod 兼容命令，让 pub 调用 chmod 时直接成功返回。
#
# 注意：
#   这里不用创建 shell 脚本，因为当前文件系统可能无法 chmod +x。
#   使用符号链接指向系统 true 命令，避免执行权限问题。

install_chmod_compat() {
  local compat_bin="${BUILD_HOME}/bin"
  local true_bin

  true_bin="$(command -v true || true)"

  if [[ -z "$true_bin" ]]; then
    echo "错误：找不到 true 命令，无法创建 chmod 兼容命令。" >&2
    exit 1
  fi

  mkdir -p "$compat_bin"
  ln -sf "$true_bin" "${compat_bin}/chmod"

  export PATH="${compat_bin}:${PATH}"
  hash -r || true

  echo "已启用 chmod 兼容命令：${compat_bin}/chmod -> ${true_bin}"
}

test_chmod() {
  local dir="$1"
  local label="$2"
  local test_file="${dir}/.chmod-test-$$"

  mkdir -p "$dir"
  : >"$test_file"

  if chmod 755 "$test_file" >/dev/null 2>&1; then
    rm -f "$test_file"
    echo "${label} 支持 chmod：${dir}"
    return 0
  else
    rm -f "$test_file"
    echo "警告：${label} 不支持 chmod：${dir}" >&2
    return 1
  fi
}

if ! test_chmod "$BUILD_HOME" "BUILD_HOME"; then
  install_chmod_compat
fi

# 安装兼容 chmod 后，再测一次 PUB_CACHE。
# 此时即使真实文件系统不支持 chmod，pub 调用 chmod 也会得到成功返回。
if ! test_chmod "$PUB_CACHE" "PUB_CACHE"; then
  install_chmod_compat
fi

echo "当前 chmod：$(command -v chmod)"

# ===== 准备 Flutter SDK =====

if [[ ! -f "$FLUTTER_BIN" ]]; then
  if [[ -e "$FLUTTER_SDK_DIR" ]]; then
    echo "Flutter SDK 目录已存在，但 ${FLUTTER_BIN} 不存在。" >&2
    echo "将删除该临时目录并重新克隆：${FLUTTER_SDK_DIR}" >&2
    rm -rf "$FLUTTER_SDK_DIR"
  fi

  git clone --depth 1 --branch "$FLUTTER_GIT_BRANCH" "$FLUTTER_GIT_URL" "$FLUTTER_SDK_DIR"
fi

# ===== 配置 Git 安全目录 =====

git config --global --add safe.directory "$FLUTTER_SDK_DIR" || true
git config --global --add safe.directory "$PROJECT_ROOT" || true

# ===== Flutter 命令封装 =====
#
# 如果当前文件系统没有给 bin/flutter 执行权限，则用 bash 直接运行它。

flutter_cmd() {
  if [[ -x "$FLUTTER_BIN" ]]; then
    "$FLUTTER_BIN" "$@"
  else
    bash "$FLUTTER_BIN" "$@"
  fi
}

# ===== 使用绝对路径构建 Web =====

cd "$PROJECT_ROOT"

flutter_cmd --version
flutter_cmd config --enable-web
flutter_cmd pub get
flutter_cmd build web --release
