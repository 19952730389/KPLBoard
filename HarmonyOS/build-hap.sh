#!/usr/bin/env bash
# 用 DevEco Studio 自带的工具链构建 HarmonyOS HAP（无需打开 IDE）
#
# 用法（Git Bash / macOS / Linux）：
#   bash build-hap.sh            # 出 debug 包（默认）
#   bash build-hap.sh release    # 出 release 包
#
# 可移植性：脚本会自动探测 DevEco 安装目录，也可以手动指定：
#   DEVECOROOT="/d/Huawei/DevEco Studio" bash build-hap.sh
#   DEVECOROOT="/Applications/DevEco-Studio.app/Contents" bash build-hap.sh   # macOS
#
# 产物：
#   entry/build/default/outputs/default/entry-default-unsigned.hap  （未签名，仅供验证包内容）
#   entry/build/default/outputs/default/entry-default-signed.hap    （配好签名后才有，真机可装）
#
# 注意：Git Bash 下路径带空格时，必须用 POSIX 形式 /c/Program\ Files/... 加进 PATH，
#       写成 "C:/Program Files/..." 会被当成无效 PATH 项（表现为 spawn java ENOENT）。
set -euo pipefail

# ---------- 1) 定位 DevEco 安装目录 ----------
if [[ -n "${DEVECOROOT:-}" && -d "$DEVECOROOT" ]]; then
  echo "== 使用指定的 DEVECOROOT: $DEVECOROOT"
else
  CANDIDATES=(
    "/c/Program Files/Huawei/DevEco Studio"
    "/d/Huawei/DevEco Studio"
    "/e/Huawei/DevEco Studio"
    "/c/Huawei/DevEco Studio"
    "/Applications/DevEco-Studio.app/Contents"
    "/opt/huawei/DevEco Studio"
    "$HOME/Applications/DevEco-Studio.app/Contents"
    "$HOME/DevEco Studio"
  )
  for c in "${CANDIDATES[@]}"; do
    if [[ -d "$c/tools/hvigor" ]]; then
      DEVECOROOT="$c"
      echo "== 自动探测到 DevEco: $DEVECOROOT"
      break
    fi
  done
fi

if [[ -z "${DEVECOROOT:-}" || ! -d "${DEVECOROOT}/tools/hvigor" ]]; then
  cat >&2 <<'EOF'
找不到 DevEco Studio 安装目录。

请先安装 DevEco Studio（或 HarmonyOS Command Line Tools），然后用环境变量指定位置：
  # Windows（Git Bash）
  DEVECOROOT="/c/Program Files/Huawei/DevEco Studio" bash build-hap.sh
  # macOS
  DEVECOROOT="/Applications/DevEco-Studio.app/Contents" bash build-hap.sh
EOF
  exit 1
fi

NODE_HOME="$DEVECOROOT/tools/node"
JAVA_HOME="$DEVECOROOT/jbr"

# 极少数安装形态下 jbr 不叫 jbr，退回系统 JAVA_HOME
if [[ ! -d "$JAVA_HOME" ]]; then
  JAVA_HOME="${JAVA_HOME_SYS:-}"
fi

export NODE_HOME
export JAVA_HOME
if [[ -n "$JAVA_HOME" ]]; then
  export PATH="$JAVA_HOME/bin:$NODE_HOME:$PATH"
else
  export PATH="$NODE_HOME:$PATH"
fi
# 命令行构建必须让 hvigor 找得到 SDK；local.properties 里也写了一份，双保险
export DEVECO_SDK_HOME="$DEVECOROOT/sdk"

cd "$(dirname "$0")"

# ---------- 2) 同步 local.properties 的 sdk.dir ----------
# 换电脑/换盘符后，旧路径会让构建报 00303217 Invalid DEVECO_SDK_HOME，这里自动纠正
if [[ -f local.properties ]]; then
  if command -v sed >/dev/null 2>&1; then
    sed -i.bak "s#^sdk.dir=.*#sdk.dir=${DEVECO_SDK_HOME}#" local.properties && rm -f local.properties.bak || true
  fi
fi

MODE="${1:-debug}"
if [[ "$MODE" != "debug" && "$MODE" != "release" ]]; then
  echo "用法: bash build-hap.sh [debug|release]" >&2
  exit 2
fi

echo "== 工具链 =="
"$NODE_HOME/node.exe" -v
if [[ -n "$JAVA_HOME" ]]; then
  java -version 2>&1 | head -1
else
  echo "java: 未找到 jbr，使用系统默认"
fi
"$NODE_HOME/node.exe" "$DEVECOROOT/tools/hvigor/bin/hvigorw.js" --version

echo "== 构建（mode=$MODE）=="
# hvigor 6.x 不接受 --mode debug（会报 Unknown mode 'debug'），debug 是默认值，别传
if [[ "$MODE" == "release" ]]; then
  "$NODE_HOME/node.exe" "$DEVECOROOT/tools/hvigor/bin/hvigorw.js" \
    assembleHap --mode release --no-daemon
else
  "$NODE_HOME/node.exe" "$DEVECOROOT/tools/hvigor/bin/hvigorw.js" \
    assembleHap --no-daemon
fi

echo "== 产物 =="
find entry/build/default/outputs -name '*.hap' -exec ls -la {} \;
