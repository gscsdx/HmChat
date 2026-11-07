#!/usr/bin/env bash
# Initialize a cloned checkout without replacing this machine's private configuration.
set -euo pipefail
source "$(dirname "$0")/env.sh"
[[ $# -eq 0 ]] || fail '用法：./scripts/setup.sh'
require_tool "$NODE_HOME/bin/node"

copy_template_once() {
  local template="$1" target="$2"
  [[ -f "$template" ]] || fail "缺少公开模板：$template"
  if [[ -e "$target" || -L "$target" ]]; then
    printf '保留已有配置：%s\n' "${target#"$HARLGRAM_ROOT/"}"
    return
  fi
  mkdir -p "$(dirname "$target")"
  # noclobber also protects a file created concurrently after the existence check.
  (umask 077; set -o noclobber; cat "$template" > "$target")
  printf '已初始化配置：%s\n' "${target#"$HARLGRAM_ROOT/"}"
}

copy_template_once "$HARLGRAM_ROOT/build-profile.example.json5" "$HARLGRAM_ROOT/build-profile.json5"
copy_template_once "$HARLGRAM_ROOT/config/telegram.example.json" "$HARLGRAM_ROOT/config/telegram.local.json"

if command -v git >/dev/null 2>&1; then
  git_root="$(git -C "$HARLGRAM_ROOT" rev-parse --show-toplevel 2>/dev/null || true)"
  if [[ -n "$git_root" && "$(cd "$git_root" && pwd -P)" == "$(cd "$HARLGRAM_ROOT" && pwd -P)" ]]; then
    git -C "$HARLGRAM_ROOT" config --local core.hooksPath .githooks
    printf '已配置本仓库 Git hooks。\n'
  else
    printf '当前目录不是独立 Git 工作副本，跳过 hooks；不会修改上级仓库。\n'
  fi
else
  printf '未找到 Git，跳过 hooks；脚本不会安装全局工具。\n'
fi

"$HARLGRAM_ROOT/scripts/configure-telegram.sh" debug
repair_cache_layout
printf '\n初始化完成。API 私密值只在本机编辑 config/telegram.local.json，无需发送到聊天。\n'
printf '新克隆的签名模板不含证书；请用 DevEco 配置自己的签名。已有签名保持原样。\n'
printf '首次安装工程依赖：bash -c '\''source scripts/env.sh; ohpm install'\''\n'
printf '随后运行 ./scripts/doctor.sh 和 ./scripts/build.sh。\n'
