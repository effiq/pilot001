#!/usr/bin/env bash
# ============================================================
# Effiq Pilot 001 · 每晚唯一入口脚本（公开仓库，无任何秘密）
# 老板每晚动作：开机 → 跑本脚本 → 看到"收工" → 关机
# 首次引导命令（永远不变）：
#   bash <(curl -fsSL https://raw.githubusercontent.com/effiq/pilot001/main/tonight.sh)
# ============================================================
set -euo pipefail

SCRIPTS_REPO_URL="https://github.com/effiq/pilot001.git"
LOGS_REPO_HOST="github.com/effiq/pilot-logs.git"   # 私有仓库，推送时拼 token
EFFIQ_HOME="$HOME/effiq"
SCRIPTS_DIR="$EFFIQ_HOME/pilot001"
LOGS_DIR="$EFFIQ_HOME/pilot-logs"
TOKEN_FILE="$HOME/pilot-env/github-token"
DATE_STR="$(date -u +%Y-%m-%d)"

say() { printf '\n\033[1;36m[pilot] %s\033[0m\n' "$*"; }
die() { printf '\n\033[1;31m[pilot][错误] %s\033[0m\n' "$*" >&2; exit 1; }

# ---- 0. 引导：脚本仓库不在本机时，先克隆自己，再接力执行 ----
if [ ! -d "$SCRIPTS_DIR/.git" ]; then
  [ "${1:-}" = "--bootstrapped" ] && die "克隆后仍找不到脚本仓库，把本行截图发给 AI"
  say "首次运行：拉取脚本仓库"
  mkdir -p "$EFFIQ_HOME"
  git clone "$SCRIPTS_REPO_URL" "$SCRIPTS_DIR" || die "脚本仓库克隆失败（检查网络）"
  exec bash "$SCRIPTS_DIR/tonight.sh" --bootstrapped
fi

# ---- 1. token 检查（token 只存在于 pod 本地，不进任何仓库）----
[ -s "$TOKEN_FILE" ] || die "没找到 $TOKEN_FILE —— 请先按《指南02》存 token（换 pod 后要重做这一步）"
TOKEN="$(tr -d '[:space:]' < "$TOKEN_FILE")"

# ---- 2. 更新脚本（AI 白天改了什么，这里自动跟上）----
say "更新脚本仓库"
git -C "$SCRIPTS_DIR" pull --ff-only || die "脚本仓库更新失败，把这段报错发给 AI"

# ---- 3. 准备私有日志仓库 ----
# 说明：token 会留在 pod 的 .git/config 里。该 token 权限只有"写 pilot-logs 这一个仓库"，
# 最坏情况是日志仓库被塞垃圾，随时可在 GitHub 吊销换新。pod 终止后该文件随之消失。
if [ ! -d "$LOGS_DIR/.git" ]; then
  say "首次运行：拉取日志仓库"
  git clone "https://x-access-token:${TOKEN}@${LOGS_REPO_HOST}" "$LOGS_DIR" \
    || die "日志仓库克隆失败（检查 token 是否按《指南01》只授了 pilot-logs 的 Contents 读写）"
fi

# ---- 4. 读当前阶段并执行（阶段由 AI 通过 STAGE 文件远程切换）----
STAGE="$(tr -d '[:space:]' < "$SCRIPTS_DIR/STAGE")"
STAGE_SCRIPT="$SCRIPTS_DIR/stages/${STAGE}.sh"
[ -f "$STAGE_SCRIPT" ] || die "阶段脚本不存在: stages/${STAGE}.sh —— 发给 AI"

OUT_DIR="$LOGS_DIR/$DATE_STR/$STAGE"
mkdir -p "$OUT_DIR"
say "今晚阶段：${STAGE} → 日志写入 ${DATE_STR}/${STAGE}/"

set +e
bash "$STAGE_SCRIPT" 2>&1 | tee "$OUT_DIR/stage.log"
RC=${PIPESTATUS[0]}
set -e
echo "$RC" > "$OUT_DIR/exit-code.txt"

# ---- 5. 安全检查：日志里不得混入 token，混了就中止推送 ----
if grep -rqF "$TOKEN" "$LOGS_DIR" --exclude-dir=.git; then
  die "安全检查触发：日志里出现 token，已中止推送。把本行发给 AI"
fi

# ---- 6. 提交并推送日志 ----
say "推送日志"
git -C "$LOGS_DIR" add -A
git -C "$LOGS_DIR" -c user.name="effiq-pilot" -c user.email="pilot@effiq.tech" \
  commit -m "${DATE_STR} ${STAGE} exit=${RC}" >/dev/null || true
git -C "$LOGS_DIR" push origin HEAD:main \
  || die "日志推送失败：把报错发给 AI（网络问题可原样重跑一次本脚本）"

# ---- 7. 收工 ----
if [ "$RC" -eq 0 ]; then
  say "✅ 今晚收工（${STAGE} 成功）。可以关机了。"
else
  say "⚠️ 阶段退出码 ${RC} —— 日志已推送，AI 会看到。可以关机了。"
fi
