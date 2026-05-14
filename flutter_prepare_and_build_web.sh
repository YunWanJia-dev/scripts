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
#   FLUTTER_TMP_ROOT    Flutter SDK 默认克隆目录的上级目录。
#   FLUTTER_SDK_DIR     已有或目标 Flutter SDK 目录；若 bin/flutter 存在，则跳过克隆。
#   BUILD_HOME          构建时使用的 HOME 目录。
#   PUB_CACHE           Dart/Flutter pub 缓存目录。
#
# Cloudflare Pages 配置建议：
#   Build command: bash scripts/flutter_prepare_and_build_web.sh
#   Build output directory: build/web

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

# ===== 选择可写构建目录 =====

pick_base_dir() {
  local candidates=(
    "/opt/buildhome"
    "/tmp"
    "${PROJECT_ROOT}"
  )

  local dir
  for dir in "${candidates[@]}"; do
    if [[ -d "$dir" ]] && [[ -w "$dir" ]]; then
      echo "$dir"
      return 0
    fi
  done

  echo "错误：找不到可写的构建目录。" >&2
  exit 1
}

BASE_BUILD_DIR="${BASE_BUILD_DIR:-$(pick_base_dir)}"

FLUTTER_GIT_URL="${FLUTTER_GIT_URL:-https://github.com/flutter/flutter.git}"
FLUTTER_GIT_BRANCH="${FLUTTER_GIT_BRANCH:-stable}"

FLUTTER_TMP_ROOT="${FLUTTER_TMP_ROOT:-${BASE_BUILD_DIR}}"
FLUTTER_SDK_DIR="${FLUTTER_SDK_DIR:-${FLUTTER_TMP_ROOT}/flutter}"
FLUTTER_BIN="${FLUTTER_SDK_DIR}/bin/flutter"

BUILD_HOME="${BUILD_HOME:-${BASE_BUILD_DIR}/flutter-build-home}"
PUB_CACHE="${PUB_CACHE:-${BASE_BUILD_DIR}/pub-cache}"
COMPAT_BIN="${COMPAT_BIN:-${BASE_BUILD_DIR}/flutter-compat-bin}"

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
echo "基础构建目录：${BASE_BUILD_DIR}"

# ===== 检查基础命令 =====

command -v git >/dev/null 2>&1 || {
  echo "错误：缺少 git 命令，无法克隆 Flutter SDK。" >&2
  exit 1
}

command -v ln >/dev/null 2>&1 || {
  echo "错误：缺少 ln 命令，无法创建 chmod 兼容命令。" >&2
  exit 1
}

# ===== 配置目录和环境变量 =====

mkdir -p "$BUILD_HOME"
mkdir -p "$PUB_CACHE"
mkdir -p "$FLUTTER_TMP_ROOT"
mkdir -p "$COMPAT_BIN"

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

# ===== 安装 chmod 兼容命令 =====
#
# Cloudflare Pages 某些构建环境中，pub 调用 subprocess chmod 会失败。
# 这里在 PATH 最前面放一个名为 chmod 的兼容命令，让 Dart pub 调用 chmod 时直接成功返回。
#
# 注意：
#   不能用 command -v true，因为它可能返回 bash 内置命令 true。
#   必须使用真正的外部二进制：/usr/bin/true 或 /bin/true。

find_real_true() {
  if [[ -x "/usr/bin/true" ]]; then
    echo "/usr/bin/true"
    return 0
  fi

  if [[ -x "/bin/true" ]]; then
    echo "/bin/true"
    return 0
  fi

  local true_path
  true_path="$(type -P true || true)"

  if [[ -n "$true_path" ]] && [[ -x "$true_path" ]]; then
    echo "$true_path"
    return 0
  fi

  echo "错误：找不到可执行的 true 命令，无法创建 chmod 兼容命令。" >&2
  exit 1
}

install_chmod_compat() {
  local true_bin
  true_bin="$(find_real_true)"

  mkdir -p "$COMPAT_BIN"

  rm -f "${COMPAT_BIN}/chmod"
  ln -s "$true_bin" "${COMPAT_BIN}/chmod"

  export PATH="${COMPAT_BIN}:${PATH}"
  hash -r || true

  echo "已启用 chmod 兼容命令：${COMPAT_BIN}/chmod -> ${true_bin}"
  echo "当前 chmod：$(command -v chmod)"

  if ! "${COMPAT_BIN}/chmod" 755 "${COMPAT_BIN}/chmod" >/dev/null 2>&1; then
    echo "错误：chmod 兼容命令不可执行：${COMPAT_BIN}/chmod" >&2
    echo "请尝试在 Cloudflare Pages 环境变量中设置：" >&2
    echo "  BASE_BUILD_DIR=/opt/buildhome" >&2
    exit 1
  fi
}

install_chmod_compat

# ===== 测试真实 chmod，仅用于日志，不再因此退出 =====

test_real_chmod_for_log() {
  local dir="$1"
  local label="$2"
  local test_file="${dir}/.chmod-test-$$"

  mkdir -p "$dir"
  : >"$test_file"

  if /bin/chmod 755 "$test_file" >/dev/null 2>&1 || /usr/bin/chmod 755 "$test_file" >/dev/null 2>&1; then
    echo "${label} 真实 chmod 可用：${dir}"
  else
    echo "提示：${label} 真实 chmod 不可用，已使用兼容 chmod：${dir}"
  fi

  rm -f "$test_file"
}

test_real_chmod_for_log "$BUILD_HOME" "BUILD_HOME"
test_real_chmod_for_log "$PUB_CACHE" "PUB_CACHE"

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
# 如果 bin/flutter 没有执行权限，则用 bash 直接运行它。

flutter_cmd() {
  if [[ -x "$FLUTTER_BIN" ]]; then
    "$FLUTTER_BIN" "$@"
  else
    bash "$FLUTTER_BIN" "$@"
  fi
}

# ===== 使用绝对路径构建 Web =====

cd "$PROJECT_ROOT"

echo "PATH：${PATH}"
echo "最终 chmod：$(command -v chmod)"

flutter_cmd --version
flutter_cmd config --enable-web
flutter_cmd pub get
flutter_cmd build web --release
