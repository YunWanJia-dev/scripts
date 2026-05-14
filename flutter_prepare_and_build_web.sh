#!/usr/bin/env bash
set -euo pipefail

# Flutter 项目 自动环境准备和构建脚本
#
# 可用环境变量：
#   FLUTTER_DOWNLOAD_URL  Flutter SDK 下载地址，用于切换镜像或固定版本；未设置时自动解析最新 stable。
#   FLUTTER_RELEASES_URL  Flutter Linux releases 元数据地址，用于解析最新 stable 下载地址。
#   FLUTTER_TMP_ROOT      Flutter SDK 默认下载和解压的临时目录，默认为 /tmp。
#   FLUTTER_SDK_DIR       已有或目标 Flutter SDK 目录；若 bin/flutter 存在，则跳过下载。
#

# ===== 基础配置 =====
# 未指定下载地址时，会从 releases 元数据中解析 Linux 最新 stable 版本。
FLUTTER_RELEASES_URL="${FLUTTER_RELEASES_URL:-https://storage.googleapis.com/flutter_infra_release/releases/releases_linux.json}"
FLUTTER_DOWNLOAD_URL="${FLUTTER_DOWNLOAD_URL:-}"

# Flutter 会被下载并解压到 /tmp 下，不污染系统环境。
FLUTTER_TMP_ROOT="${FLUTTER_TMP_ROOT:-/tmp}"
FLUTTER_RELEASES_FILE="${FLUTTER_TMP_ROOT}/flutter-releases-linux.json"
FLUTTER_SDK_DIR="${FLUTTER_SDK_DIR:-${FLUTTER_TMP_ROOT}/flutter}"
FLUTTER_BIN="${FLUTTER_SDK_DIR}/bin/flutter"

# 获取当前脚本所在目录，后续始终在项目根目录中执行构建。
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd -P)"

# ===== 输出当前系统 =====
# 在安装依赖和下载 SDK 前输出系统信息，方便排查 CI 或容器环境问题。
if [[ -f /etc/os-release ]]; then
  # shellcheck disable=SC1091
  . /etc/os-release
  echo "当前系统：${PRETTY_NAME:-${NAME:-unknown}}"
else
  echo "当前系统：$(uname -s)"
fi
echo "系统架构：$(uname -m)"

# ===== 检查基础命令 =====
# 在 Debian/Ubuntu 或 yum/dnf/microdnf 系统的空环境中自动补齐 Flutter 构建需要的基础工具。
CURL_BIN="$(command -v curl || true)"
WGET_BIN="$(command -v wget || true)"
APT_GET_BIN="$(command -v apt-get || true)"
DNF_BIN="$(command -v dnf || true)"
YUM_BIN="$(command -v yum || true)"
MICRODNF_BIN="$(command -v microdnf || true)"

missing_commands=()
for command_name in git tar unzip zip awk sed; do
  command -v "$command_name" >/dev/null 2>&1 || missing_commands+=("$command_name")
done

if [[ ! -x "$CURL_BIN" && ! -x "$WGET_BIN" ]]; then
  missing_commands+=("curl 或 wget")
fi

if [[ ${#missing_commands[@]} -gt 0 ]]; then
  if [[ -x "$APT_GET_BIN" ]]; then
    if ! "$APT_GET_BIN" update; then
      echo "警告：apt-get update 失败，将继续尝试后续步骤" >&2
    fi

    if ! DEBIAN_FRONTEND=noninteractive "$APT_GET_BIN" install -y \
      ca-certificates \
      curl \
      gawk \
      git \
      sed \
      tar \
      unzip \
      zip; then
      echo "警告：apt-get install 失败，将继续尝试后续步骤" >&2
    fi
  elif [[ -x "$DNF_BIN" ]]; then
    if ! "$DNF_BIN" install -y \
      ca-certificates \
      curl \
      gawk \
      git \
      sed \
      tar \
      unzip \
      zip; then
      echo "警告：dnf install 失败，将继续尝试后续步骤" >&2
    fi
  elif [[ -x "$YUM_BIN" ]]; then
    if ! "$YUM_BIN" install -y \
      ca-certificates \
      curl \
      gawk \
      git \
      sed \
      tar \
      unzip \
      zip; then
      echo "警告：yum install 失败，将继续尝试后续步骤" >&2
    fi
  elif [[ -x "$MICRODNF_BIN" ]]; then
    if ! "$MICRODNF_BIN" install -y \
      ca-certificates \
      curl \
      gawk \
      git \
      sed \
      tar \
      unzip \
      zip; then
      echo "警告：microdnf install 失败，将继续尝试后续步骤" >&2
    fi
  else
    echo "警告：缺少基础命令：${missing_commands[*]}，且当前系统没有可用的 apt-get、dnf、yum 或 microdnf，将继续尝试后续步骤" >&2
  fi
fi

# 如果上一步安装了 curl 或 wget，刷新下载命令路径。
CURL_BIN="$(command -v curl || true)"
WGET_BIN="$(command -v wget || true)"

# ===== 下载 Flutter SDK =====
# 如果指定的 SDK 目录中还没有可用的 Flutter，则下载并解压到该目录的上级目录。
mkdir -p "$FLUTTER_TMP_ROOT"

if [[ ! -x "$FLUTTER_BIN" ]]; then
  if [[ -e "$FLUTTER_SDK_DIR" ]]; then
    echo "Flutter SDK 目录已存在，但 ${FLUTTER_BIN} 不可执行。为避免误删或覆盖旧文件，请手动处理该目录，或通过 FLUTTER_SDK_DIR 指定其他目录。" >&2
    exit 1
  fi

  # ===== 解析最新 stable 下载地址 =====
  # 未配置 FLUTTER_DOWNLOAD_URL 时，从 Flutter 官方 Linux releases 元数据中读取 current_release.stable。
  if [[ -z "$FLUTTER_DOWNLOAD_URL" ]]; then
    if [[ -x "$CURL_BIN" ]]; then
      "$CURL_BIN" --fail --location --show-error --progress-bar "$FLUTTER_RELEASES_URL" --output "$FLUTTER_RELEASES_FILE"
    elif [[ -x "$WGET_BIN" ]]; then
      "$WGET_BIN" --output-document="$FLUTTER_RELEASES_FILE" "$FLUTTER_RELEASES_URL"
    else
      echo "缺少 curl 或 wget，无法下载 Flutter releases 元数据" >&2
      exit 1
    fi

    FLUTTER_RELEASES_BASE_URL="$(sed -n 's/.*"base_url"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$FLUTTER_RELEASES_FILE" | head -n 1)"
    FLUTTER_STABLE_HASH="$(sed -n 's/.*"stable"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$FLUTTER_RELEASES_FILE" | head -n 1)"
    FLUTTER_STABLE_ARCHIVE="$(
      awk -v stable_hash="$FLUTTER_STABLE_HASH" '
        $0 ~ "\"hash\"[[:space:]]*:[[:space:]]*\"" stable_hash "\"" { in_release = 1 }
        in_release && /"archive"[[:space:]]*:/ {
          gsub(/^.*"archive"[[:space:]]*:[[:space:]]*"/, "")
          gsub(/".*$/, "")
          print
          exit
        }
      ' "$FLUTTER_RELEASES_FILE"
    )"

    if [[ -z "$FLUTTER_RELEASES_BASE_URL" || -z "$FLUTTER_STABLE_HASH" || -z "$FLUTTER_STABLE_ARCHIVE" ]]; then
      echo "无法从 Flutter releases 元数据中解析 latest stable 下载地址" >&2
      exit 1
    fi

    FLUTTER_DOWNLOAD_URL="${FLUTTER_RELEASES_BASE_URL}/${FLUTTER_STABLE_ARCHIVE}"
  fi

  if [[ -x "$CURL_BIN" ]]; then
    "$CURL_BIN" --fail --location --show-error --progress-bar "$FLUTTER_DOWNLOAD_URL" --output "$FLUTTER_ARCHIVE"
  elif [[ -x "$WGET_BIN" ]]; then
    "$WGET_BIN" --output-document="$FLUTTER_ARCHIVE" "$FLUTTER_DOWNLOAD_URL"
  else
    echo "缺少 curl 或 wget，无法下载 Flutter SDK" >&2
    exit 1
  fi

  # ===== 解压 Flutter SDK =====
  mkdir -p "$(dirname "$FLUTTER_SDK_DIR")"
  case "$FLUTTER_ARCHIVE" in
    *.tar.xz)
      tar -xJf "$FLUTTER_ARCHIVE" -C "$(dirname "$FLUTTER_SDK_DIR")"
      ;;
    *.tar.gz)
      tar -xzf "$FLUTTER_ARCHIVE" -C "$(dirname "$FLUTTER_SDK_DIR")"
      ;;
    *.zip)
      unzip -q "$FLUTTER_ARCHIVE" -d "$(dirname "$FLUTTER_SDK_DIR")"
      ;;
  esac
  rm -f "$FLUTTER_ARCHIVE"
fi

# ===== 配置 Git 安全目录 =====
# 容器或 CI 中挂载目录、解压 SDK 时，Git 可能因为目录所有者不同而拒绝访问。
git config --global --add safe.directory "$FLUTTER_SDK_DIR"
git config --global --add safe.directory "$SCRIPT_DIR"

# ===== 使用绝对路径构建 Web =====
# 不依赖 PATH 中的 flutter，避免空环境或系统 Flutter 版本影响构建。
cd "$SCRIPT_DIR"
"$FLUTTER_BIN" --version
"$FLUTTER_BIN" config --enable-web
"$FLUTTER_BIN" pub get
"$FLUTTER_BIN" build web --release
