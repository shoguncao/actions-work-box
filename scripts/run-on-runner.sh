#!/usr/bin/env bash
# 单轮：触发一次临时 runner，上传任务目录、执行 entry.sh、取回 output，并确认本轮结束。
set -u
set -o pipefail

usage() {
  cat <<'EOF'
用法：run-on-runner.sh --repo OWNER/REPO --ref BRANCH --pat-file FILE
                       --ssh-key FILE --task-dir DIR --output-dir DIR
                       --close-tunnel auto|manual
                       [--startup-timeout SEC] [--cleanup-timeout SEC]

每轮触发一次 cloudflare-ssh workflow，SSH 上传任务目录、前台执行 entry.sh、
取回 output/，再按 --close-tunnel 决定关闭或保留隧道。每轮目录独立，结果互不覆盖。

必填：--repo --ref --pat-file --ssh-key --task-dir --output-dir --close-tunnel
可选：--startup-timeout（默认 600）--cleanup-timeout（默认 180）--help

  --repo            owner/repo，需启用 Actions
  --ref             触发用的分支或 ref
  --pat-file        本机私有 PAT 文件，需 Actions 读写权限
  --ssh-key         登录 runner 的 SSH 私钥；公钥由它推导后作为 input 传入
  --task-dir        任务目录，需含 entry.sh
  --output-dir      结果根目录，本轮结果在其 <关联标识> 子目录
  --close-tunnel    auto：执行 pkill -x cloudflared 关闭隧道并确认 run completed
                    manual：保留隧道，脚本不取消本轮 run，需自行连接并关闭

任务目录：entry.sh 前台执行，结果写入 output/；输入里已有的 output/ 不上传；
output/ 为空属正常；依赖安装与后台任务 wait 由 entry.sh 自己负责。
依赖：curl、ssh、tar、python3、cloudflared。兼容 macOS 自带 Bash 3.2。
EOF
}

die()  { echo "错误：$*" >&2; usage >&2; exit 2; }   # 参数错误
fail() { echo "错误：$*" >&2; exit 1; }               # 运行期错误

REPO=""; REF=""; PAT_FILE=""; SSH_KEY=""; TASK_DIR=""; OUTPUT_DIR=""; CLOSE_TUNNEL=""
STARTUP_TIMEOUT=600; CLEANUP_TIMEOUT=180

# 参数去掉 -- 后大写、连字符转下划线，正好就是上面的变量名
while [ $# -gt 0 ]; do
  case "$1" in
    --help) usage; exit 0 ;;
    --repo|--ref|--pat-file|--ssh-key|--task-dir|--output-dir|--close-tunnel|--startup-timeout|--cleanup-timeout)
      [ $# -ge 2 ] || die "$1 缺少值"
      name=$(printf '%s' "${1#--}" | tr 'a-z-' 'A-Z_')
      printf -v "$name" '%s' "$2"
      shift 2 ;;
    *) die "未知参数 $1" ;;
  esac
done

for v in REPO REF PAT_FILE SSH_KEY TASK_DIR OUTPUT_DIR CLOSE_TUNNEL; do
  [ -n "${!v}" ] || die "缺少必填参数 $v"
done
case "$CLOSE_TUNNEL" in
  auto|manual) ;;
  *) die "--close-tunnel 只能是 auto 或 manual" ;;
esac
for c in curl ssh tar python3 cloudflared; do
  command -v "$c" || die "缺少依赖 $c"
done
[ -r "$PAT_FILE" ] || die "PAT 文件不可读"
[ -r "$SSH_KEY" ] || die "SSH 私钥不可读"
[ -r "$TASK_DIR/entry.sh" ] || die "任务目录缺少 entry.sh"
mkdir -p "$OUTPUT_DIR" || die "无法创建结果目录"

PAT=$(tr -d '\r\n' < "$PAT_FILE")
[ -n "$PAT" ] || die "PAT 文件为空"
case "$PAT" in *[!A-Za-z0-9_.-]*) die "PAT 含非法字符" ;; esac

API="https://api.github.com"
WORKFLOW="cloudflare-ssh.yml"
SSH_TARGET="runner@github-actions"
log() { echo "[$(date '+%H:%M:%S')] $*"; }

TMP_DIR=$(mktemp -d "${TMPDIR:-/tmp}/awb-run.XXXXXX") || fail "无法创建临时目录"
trap 'rm -rf "$TMP_DIR"' EXIT

# 鉴权头放进 600 权限的配置文件，PAT 不出现在进程命令行或日志里
CURL_CFG="$TMP_DIR/curl.cfg"
{
  printf 'header = "Authorization: Bearer %s"\n' "$PAT"
  printf 'header = "Accept: application/vnd.github+json"\n'
  printf 'connect-timeout = 10\n'
  printf 'max-time = 40\n'
} > "$CURL_CFG"
chmod 600 "$CURL_CFG"

RUN_ID=""; TUNNEL_URL=""

# api 常在命令替换的子 shell 里跑，状态码必须写文件传回父 shell
api() {
  local body="$TMP_DIR/body" c
  : > "$TMP_DIR/code"
  c=$(curl -sS --config "$CURL_CFG" -o "$body" -w '%{http_code}' "$@") || return 1
  printf '%s' "$c" > "$TMP_DIR/code"
  cat "$body"
}
http_code() { cat "$TMP_DIR/code"; }

cancel_run() {
  [ -n "$RUN_ID" ] && api -X POST "$API/repos/$REPO/actions/runs/$RUN_ID/cancel"
  return 0
}
if [ "$CLOSE_TUNNEL" = auto ]; then
  trap 'log "收到中断，取消本轮"; cancel_run; exit 130' INT TERM HUP
else
  trap 'log "收到中断，隧道保留，请自行关闭"; exit 130' INT TERM HUP
fi

run_done() {
  local info
  info=$(api "$API/repos/$REPO/actions/runs/$RUN_ID") || return 1
  [ "$(http_code)" = 200 ] && printf '%s' "$info" | tr -d ' ' | grep -q '"status":"completed"'
}

# 本轮 workflow 把隧道地址写成一条 commit status，运行中即可读取
find_url() {
  local statuses
  statuses=$(api "$API/repos/$REPO/commits/$REF/statuses?per_page=100") || return 1
  [ "$(http_code)" = 200 ] || return 1
  printf '%s' "$statuses" | python3 -c '
import json, sys
ctx = "cloudflare-ssh/" + sys.argv[1]
try:
    items = json.load(sys.stdin)
except Exception:
    items = []
for s in items:
    d = (s.get("description") or "").strip()
    if s.get("context") == ctx and d.startswith("https://") and d.endswith(".trycloudflare.com"):
        print(d)
        break
' "$CID"
}

# 按 run-name 里的关联标识精确匹配本轮 run，绝不取最新一条
find_run() {
  local runs
  runs=$(api "$API/repos/$REPO/actions/workflows/$WORKFLOW/runs?event=workflow_dispatch&per_page=50") || return 1
  [ "$(http_code)" = 200 ] || return 1
  printf '%s' "$runs" | python3 -c '
import json, sys
title = "cloudflare-ssh " + sys.argv[1]
try:
    runs = json.load(sys.stdin).get("workflow_runs", [])
except Exception:
    runs = []
print("\n".join(str(r["id"]) for r in runs
                if (r.get("display_title") or "").strip() == title))
' "$CID"
}

# ---------- 触发本轮 workflow ----------
CID="awb-$(python3 -c 'import uuid; print(uuid.uuid4().hex)')"
SSH_PUBKEY=$(ssh-keygen -y -P '' -f "$SSH_KEY") || fail "无法从私钥推导公钥"
DISPATCH_BODY=$(python3 -c 'import json,sys; print(json.dumps({"ref":sys.argv[1],"inputs":{"correlation_id":sys.argv[2],"ssh_pubkey":sys.argv[3]}}))' "$REF" "$CID" "$SSH_PUBKEY")

log "触发 workflow，关联标识=$CID"
if ! resp=$(api -X POST -H "Content-Type: application/json" -d "$DISPATCH_BODY" \
    "$API/repos/$REPO/actions/workflows/$WORKFLOW/dispatches"); then
  log "dispatch 结果不确定，按标识查询，不重复触发"
elif [ "$(http_code)" != 204 ]; then
  fail "dispatch 失败，HTTP $(http_code)：$resp"
fi

# ---------- 锁定本轮 run 并等隧道地址 ----------
deadline=$((SECONDS + STARTUP_TIMEOUT))
while [ "$SECONDS" -lt "$deadline" ]; do
  if [ -z "$RUN_ID" ]; then
    ids=$(find_run) || ids=""
    n=$(printf '%s' "$ids" | grep -c '^[0-9]' || true)
    [ "$n" -gt 1 ] && fail "关联标识匹配到多个 run，拒绝连接"
    [ "$n" -eq 1 ] && RUN_ID=$(printf '%s' "$ids" | head -1)
  fi
  if [ -n "$RUN_ID" ]; then
    TUNNEL_URL=$(find_url) || TUNNEL_URL=""
    [ -n "$TUNNEL_URL" ] && break
    run_done && { cancel_run; fail "本轮 run 已结束但未发布隧道地址"; }
  fi
  sleep 3
done
[ -n "$TUNNEL_URL" ] || { cancel_run; fail "${STARTUP_TIMEOUT}s 内未读到隧道地址"; }
log "本轮 run_id=$RUN_ID"
log "隧道地址：$TUNNEL_URL"

# ---------- SSH 上传、执行、下载 ----------
ssh_do() {
  ssh -i "$SSH_KEY" -o BatchMode=yes -o StrictHostKeyChecking=no \
    -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o ConnectTimeout=30 \
    -o "ProxyCommand=cloudflared access tcp --hostname $TUNNEL_URL" \
    "$SSH_TARGET" "$@"
}

REMOTE_DIR="awb-task-$CID"
RESULT_DIR="$OUTPUT_DIR/$CID"
mkdir -p "$RESULT_DIR" || { cancel_run; fail "无法创建结果目录"; }

biz=0; down=1; done_ok=0
# 先等权威 DNS 登记好新域名，本机再去查；否则内网 DNS 会记下 NXDOMAIN 负缓存，卡约 60 秒
host=${TUNNEL_URL#https://}
deadline=$((SECONDS + 60))
until curl -fsS --max-time 6 -H 'accept: application/dns-json' \
    "https://cloudflare-dns.com/dns-query?name=$host&type=A" |
    python3 -c 'import json,sys; d=json.load(sys.stdin); sys.exit(0 if any(a.get("type")==1 for a in d.get("Answer",[])) else 1)'; do
  [ "$SECONDS" -lt "$deadline" ] || { cancel_run; fail "域名 60s 内未生效"; }
  sleep 2
done

log "等待隧道就绪"
deadline=$((SECONDS + 90))
until ssh_do true; do
  [ "$SECONDS" -lt "$deadline" ] || { cancel_run; fail "隧道域名 90s 内未生效"; }
  sleep 3
done

log "上传任务目录"
if ! tar --exclude='./output' -cf - -C "$TASK_DIR" . | \
    ssh_do "rm -rf '$REMOTE_DIR' && mkdir -p '$REMOTE_DIR' && tar -xf - -C '$REMOTE_DIR'"; then
  cancel_run
  fail "任务目录上传失败"
fi

log "执行 entry.sh"
ssh_do "cd '$REMOTE_DIR' && mkdir -p output && bash entry.sh"
biz=$?
if [ "$biz" -eq 255 ]; then
  echo "错误：SSH 连接异常（255）" >&2
  biz=1
fi
log "业务退出码：$biz"

log "取回 output/"
ssh_do "cd '$REMOTE_DIR' && tar -cf - -C output ." | tar -xf - -C "$RESULT_DIR" || down=0
[ "$down" -eq 1 ] || echo "错误：结果下载失败" >&2

# ---------- 收尾 ----------
if [ "$CLOSE_TUNNEL" = auto ]; then
  log "关闭隧道"
  ssh_do 'pkill -x cloudflared' || true

  deadline=$((SECONDS + CLEANUP_TIMEOUT))
  while [ "$SECONDS" -lt "$deadline" ]; do
    run_done && { done_ok=1; break; }
    sleep 3
  done
  [ "$done_ok" -eq 1 ] || { echo "错误：${CLEANUP_TIMEOUT}s 内未完成" >&2; cancel_run; }
else
  done_ok=1
  log "保留隧道，本轮不自动关闭；请自行执行："
  log "ssh -i $SSH_KEY -o ProxyCommand='cloudflared access tcp --hostname $TUNNEL_URL' -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null $SSH_TARGET"
  log "进入后执行 pkill -x cloudflared 关闭；或在 Actions 页面 Cancel。run 仍受 360 分钟上限约束。"
fi

# 下载或收尾失败则整体非零，否则如实返回业务退出码
if [ "$down" -ne 1 ] || [ "$done_ok" -ne 1 ]; then
  rc=1
else
  rc=$biz
fi
log "本轮结束：业务=${biz}，下载=${down}，收尾=${done_ok}，最终=${rc}"
log "结果目录：$RESULT_DIR"
exit "$rc"
