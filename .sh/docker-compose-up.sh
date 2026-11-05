#!/usr/bin/env bash
# =============================================================================
# docker-compose-up.sh  —  Compose 项目「有更新才更新」自动更新脚本  v2.0.0
# -----------------------------------------------------------------------------
# 目标：
#   1. 发现本机正在运行的 Docker Compose 项目；
#   2. 先 pull，再用「镜像 ID 对比」判断该项目是否真的存在可用更新；
#   3. 只有存在可用更新时才执行 `up -d --remove-orphans`，否则直接跳过；
#   4. 输出结构化、详细、可机读的日志，方便 AI 做后续分析。
#
# 判定逻辑（核心）：
#   - 对每个项目，从「运行中的容器」读取 Config.Image（镜像引用）、.Image
#     （容器创建时所基于的镜像 ID），再用 docker image inspect 解析该引用当前
#     指向的镜像 ID。
#   - pull 前后各做一次快照：
#       changed_images  = pull 前后「引用 -> 镜像 ID」发生变化的镜像
#       stale_services  = 运行容器的 .Image != 该引用当前镜像 ID 的容器
#   - 决策：changed_images 或 stale_services 非空 => UPDATE（执行 up -d）
#           两者皆空                              => SKIP_NO_UPDATE（不执行任何重建）
#   这样既能覆盖「本次 pull 拉到新镜像」，也能覆盖「镜像此前已被别人更新、
#   容器还没重建」的场景。
#
# 日志产物：
#   - LOG_FILE  : 追加式人类可读日志（含每行 [级别][run_id][project] 前缀）
#   - RUN_JSON  : 单次运行的完整结构化 JSON 摘要（默认覆盖 last.json）
#   - RUN_JSON_DIR（可选）: 每次运行另存一份带 run_id 的 JSON，便于跨次分析
#
# 用法：
#   ./docker-compose-up.sh
#   DRY_RUN=true ./docker-compose-up.sh          # 只检测不执行 up -d
#   INCLUDE_PROJECTS=foo,bar ./docker-compose-up.sh
#   LOG_FILE=/tmp/u.log RUN_JSON=/tmp/u.json ./docker-compose-up.sh
#
# 可覆盖环境变量（括号为默认值）：
#   LOG_FILE(/var/log/compose-auto-update.log)   RUN_JSON(/var/log/compose-auto-update.last.json)
#   RUN_JSON_DIR(空)   LOCK_FILE(/var/lock/compose-auto-update.lock)
#   PRUNE_IMAGES(true) 仅在本轮确有更新时才清理悬空镜像
#   MAX_RETRY(3)  RETRY_DELAYS("10 30 60")  PULL_TIMEOUT(900)  UP_TIMEOUT(900)
#   VALIDATE_TIMEOUT(60)  DRY_RUN(false)
#   INCLUDE_PROJECTS(空=全部)  EXCLUDE_PROJECTS(空)
#
# 退出码：0 = 全部正常（含「无更新跳过」）；1 = 至少有一个项目失败
# =============================================================================
set -Eeuo pipefail

# ---------------------------------------------------------------------------
# 可配置参数
# ---------------------------------------------------------------------------
LOG_FILE="${LOG_FILE:-/var/log/compose-auto-update.log}"
RUN_JSON="${RUN_JSON:-/var/log/compose-auto-update.last.json}"
RUN_JSON_DIR="${RUN_JSON_DIR:-}"
LOCK_FILE="${LOCK_FILE:-/var/lock/compose-auto-update.lock}"
PRUNE_IMAGES="${PRUNE_IMAGES:-true}"
MAX_RETRY="${MAX_RETRY:-3}"
RETRY_DELAYS="${RETRY_DELAYS:-10 30 60}"
PULL_TIMEOUT="${PULL_TIMEOUT:-900}"
UP_TIMEOUT="${UP_TIMEOUT:-900}"
VALIDATE_TIMEOUT="${VALIDATE_TIMEOUT:-60}"
DRY_RUN="${DRY_RUN:-false}"
INCLUDE_PROJECTS="${INCLUDE_PROJECTS:-}"
EXCLUDE_PROJECTS="${EXCLUDE_PROJECTS:-}"

SCRIPT_VERSION="2.0.0"
RUN_ID="$(date '+%Y%m%dT%H%M%S')-$$"
RUN_START_AT="$(date '+%F %T')"
RUN_START_EPOCH="$(date +%s)"
HOST_NAME="$(hostname 2>/dev/null || printf unknown)"

COMPOSE_TYPE=""
COMPOSE_BIN=()
LOG_CTX=""
TMP_DIR=""
FINAL_RC=0

COUNT_TOTAL=0
COUNT_UPDATE=0
COUNT_NOUPDATE=0
COUNT_SKIP=0
COUNT_FAIL=0
PRUNE_RAN=false
PRUNE_OK=false

# 单个项目处理期间的全局状态（由 reset_project_state 重置）
P_IDX=0; P_PROJECT=""; P_D=""; P_START_EPOCH=0
P_WORKDIR=""; P_CONFIG_FILES=""; P_COMPOSE_ARGS=()
P_DECISION=""; P_REASON=""; P_ERROR=""
P_PULL_ATTEMPTS=0; P_PULL_OK=null; P_PULL_DUR=0; P_PULL_TAIL=""
P_UP_EXECUTED=false; P_UP_OK=null; P_UP_DUR=0; P_UP_TAIL=""
P_STALE_AFTER=0; P_DUR=0; P_CONFIG_VALID=null; P_VALIDATE_TAIL=""

norm_bool() { case "${1,,}" in 1|true|yes|on) printf true ;; *) printf false ;; esac; }
norm_int() {
  local v="$1" d="$2"
  if [[ "$v" =~ ^[0-9]+$ ]] && [ "$v" -ge 1 ]; then printf '%s' "$v"; else printf '%s' "$d"; fi
}
DRY_RUN="$(norm_bool "$DRY_RUN")"
PRUNE_IMAGES="$(norm_bool "$PRUNE_IMAGES")"
MAX_RETRY="$(norm_int "$MAX_RETRY" 3)"
PULL_TIMEOUT="$(norm_int "$PULL_TIMEOUT" 900)"
UP_TIMEOUT="$(norm_int "$UP_TIMEOUT" 900)"
VALIDATE_TIMEOUT="$(norm_int "$VALIDATE_TIMEOUT" 60)"

timestamp() {
  local t=""
  printf -v t '%(%F %T)T' -1 2>/dev/null || t="$(date '+%F %T')"
  printf '%s' "$t"
}

# 统一日志：始终写 stdout，追加写入 LOG_FILE（失败不影响主流程）
log() {
  local level="$1"; shift
  local msg="${*:-}" ctx="" line
  [ -n "$LOG_CTX" ] && ctx="${LOG_CTX} "
  line="[$(timestamp)] [${level}] [run=${RUN_ID}] ${ctx}${msg}"
  printf '%s\n' "$line" >> "$LOG_FILE" 2>/dev/null || true
  printf '%s\n' "$line" || true
}

# 把一个文件的每一行按前缀缩进后写进日志（用于原样记录 docker 输出）
log_block() {
  local level="$1" prefix="$2" file="$3" line=""
  [ -f "$file" ] || return 0
  while IFS= read -r line || [ -n "$line" ]; do
    log "$level" "${prefix}${line}"
  done < "$file"
}

# 最小 JSON 字符串转义（不依赖 jq/python）
json_escape() {
  local s="${1-}"
  s="${s//\\/\\\\}"
  s="${s//\"/\\\"}"
  s="${s//$'\n'/\\n}"
  s="${s//$'\r'/\\r}"
  s="${s//$'\t'/\\t}"
  printf '%s' "$s" | sed 's/[[:cntrl:]]//g'
}

array_to_json() {
  local out="" x
  for x in "$@"; do out+="${out:+,}\"$(json_escape "$x")\""; done
  printf '[%s]' "$out"
}

# TSV（| 分隔）-> JSON 数组；列名由第 2 个起的参数给出
tsv_to_json_array() {
  local file="$1"; shift
  local -a keys=("$@")
  local out="" line="" obj="" val i
  local -a vals=()
  [ -f "$file" ] || { printf '[]'; return 0; }
  while IFS= read -r line || [ -n "$line" ]; do
    [ -n "$line" ] || continue
    vals=()
    IFS='|' read -r -a vals <<< "$line"
    obj=""
    for i in "${!keys[@]}"; do
      val="${vals[$i]:-}"
      obj+="${obj:+,}\"${keys[$i]}\":\"$(json_escape "$val")\""
    done
    out+="${out:+,}{${obj}}"
  done < "$file"
  printf '[%s]' "$out"
}

init() {
  local logdir jdir ldir
  logdir="$(dirname "$LOG_FILE")"
  if ! mkdir -p "$logdir" 2>/dev/null || ! : >> "$LOG_FILE" 2>/dev/null; then
    printf '[WARN] 无法写入 %s，日志仅输出到 stdout\n' "$LOG_FILE" >&2
    LOG_FILE="/dev/null"
  fi
  jdir="$(dirname "$RUN_JSON")"; mkdir -p "$jdir" 2>/dev/null || true
  ldir="$(dirname "$LOCK_FILE")"; mkdir -p "$ldir" 2>/dev/null || true
  TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/compose-auto-update.${RUN_ID}.XXXXXX")" || {
    printf '[FATAL] 无法创建临时目录\n' >&2
    exit 1
  }
}

acquire_lock() {
  if ! command -v flock >/dev/null 2>&1; then
    log WARN "未找到 flock，跳过并发锁（建议安装 util-linux）"
    return 0
  fi
  if ! exec 9>"$LOCK_FILE"; then
    log WARN "无法打开锁文件 $LOCK_FILE，跳过并发锁"
    return 0
  fi
  if ! flock -n 9; then
    log WARN "检测到另一个实例正在运行（锁 $LOCK_FILE 被占用），本次退出"
    exit 0
  fi
  log DEBUG "已获取运行锁: $LOCK_FILE"
}

detect_compose() {
  if command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; then
    COMPOSE_TYPE="plugin"; COMPOSE_BIN=(docker compose)
  elif command -v docker-compose >/dev/null 2>&1; then
    COMPOSE_TYPE="standalone"; COMPOSE_BIN=(docker-compose)
  else
    log ERROR "未找到 docker compose(plugin) 或 docker-compose(standalone)"
    return 1
  fi
  local ver
  ver="$("${COMPOSE_BIN[@]}" version 2>/dev/null | head -n1 || true)"
  log INFO "Compose 类型=${COMPOSE_TYPE} 命令=${COMPOSE_BIN[*]} 版本=${ver:-N/A}"
}

# 在 workdir 内执行 compose 命令，输出重定向到 outfile，可带 timeout
run_compose() {
  local workdir="$1" outfile="$2" tmo="$3"; shift 3
  local rc=0
  if command -v timeout >/dev/null 2>&1; then
    ( cd "$workdir" || exit 125; exec timeout "$tmo" "${COMPOSE_BIN[@]}" "$@" ) >"$outfile" 2>&1 || rc=$?
  else
    ( cd "$workdir" || exit 125; exec "${COMPOSE_BIN[@]}" "$@" ) >"$outfile" 2>&1 || rc=$?
  fi
  return "$rc"
}

build_compose_args() {
  local project="$1" config_files="$2" file
  COMPOSE_ARGS=(-p "$project")
  [ -z "$config_files" ] && return 0
  [ "$config_files" = "<no value>" ] && return 0
  local IFS=','
  for file in $config_files; do
    # 去掉首尾空白
    file="${file#"${file%%[![:space:]]*}"}"
    file="${file%"${file##*[![:space:]]}"}"
    [ -n "$file" ] || continue
    COMPOSE_ARGS+=(-f "$file")
  done
}

get_project_metadata() {
  local project="$1" cid wd cf
  cid="$(docker ps --filter "label=com.docker.compose.project=$project" \
        --format '{{.ID}}' 2>/dev/null | head -n1 || true)"
  [ -n "$cid" ] || return 1
  wd="$(docker inspect -f '{{ index .Config.Labels "com.docker.compose.project.working_dir" }}' "$cid" 2>/dev/null || true)"
  cf="$(docker inspect -f '{{ index .Config.Labels "com.docker.compose.project.config_files" }}' "$cid" 2>/dev/null || true)"
  [ "$wd" = "<no value>" ] && wd=""
  [ "$cf" = "<no value>" ] && cf=""
  printf '%s\n%s\n' "$wd" "$cf"
}

project_selected() {
  local p="$1" item found=false
  local IFS=','
  if [ -n "$INCLUDE_PROJECTS" ]; then
    for item in $INCLUDE_PROJECTS; do [ "$item" = "$p" ] && found=true; done
    [ "$found" = true ] || return 1
  fi
  if [ -n "$EXCLUDE_PROJECTS" ]; then
    for item in $EXCLUDE_PROJECTS; do [ "$item" = "$p" ] && return 1; done
  fi
  return 0
}

# 解析某个镜像引用当前指向的镜像 ID；解析不到返回 MISSING
resolve_image_id() {
  local ref="$1" id=""
  id="$(docker image inspect -f '{{.Id}}' "$ref" 2>/dev/null || true)"
  id="${id%%$'\n'*}"
  [ -n "$id" ] || id="MISSING"
  printf '%s' "$id"
}

# 快照：
#   $2 = containers.tsv : container|service|ref|running_id|current_id
#   $3 = images.tsv     : ref|current_id （按 ref 去重）
snapshot_images() {
  local project="$1" ctb="$2" imgf="$3"
  : > "$ctb"; : > "$imgf"
  local cid ref running current service line
  local -A seen=()
  while IFS= read -r cid; do
    [ -n "$cid" ] || continue
    ref="$(docker inspect -f '{{.Config.Image}}' "$cid" 2>/dev/null || true)"
    [ -n "$ref" ] || continue
    running="$(docker inspect -f '{{.Image}}' "$cid" 2>/dev/null || true)"
    service="$(docker inspect -f '{{ index .Config.Labels "com.docker.compose.service" }}' "$cid" 2>/dev/null || true)"
    [ "$service" = "<no value>" ] && service=""
    current="$(resolve_image_id "$ref")"
    printf '%s|%s|%s|%s|%s\n' "$cid" "$service" "$ref" "$running" "$current" >> "$ctb"
    if [ -z "${seen[$ref]:-}" ]; then
      seen[$ref]=1
      printf '%s|%s\n' "$ref" "$current" >> "$imgf"
    fi
  done < <(docker ps --filter "label=com.docker.compose.project=$project" \
           --format '{{.ID}}' 2>/dev/null || true)
}

reset_project_state() {
  P_IDX="$1"; P_PROJECT="$2"
  P_D="$TMP_DIR/p${P_IDX}"
  mkdir -p "$P_D"
  P_START_EPOCH="$(date +%s)"
  P_WORKDIR=""; P_CONFIG_FILES=""; P_COMPOSE_ARGS=()
  P_DECISION=""; P_REASON=""; P_ERROR=""
  P_PULL_ATTEMPTS=0; P_PULL_OK=null; P_PULL_DUR=0; P_PULL_TAIL=""
  P_UP_EXECUTED=false; P_UP_OK=null; P_UP_DUR=0; P_UP_TAIL=""
  P_STALE_AFTER=0; P_DUR=0; P_CONFIG_VALID=null; P_VALIDATE_TAIL=""
  local f
  for f in images_before.tsv images_after.tsv changed.tsv stale.tsv \
           before.tsv after.tsv verify.tsv verify_images.tsv \
           validate.out pull.out up.out; do
    : > "$P_D/$f"
  done
}

emit_project_json() {
  local d="$P_D"
  local ib ia ch st args
  ib="$(tsv_to_json_array "$d/images_before.tsv" ref id)"
  ia="$(tsv_to_json_array "$d/images_after.tsv" ref id)"
  ch="$(tsv_to_json_array "$d/changed.tsv" ref before after)"
  st="$(tsv_to_json_array "$d/stale.tsv" container service ref running_id current_id)"
  args="$(array_to_json "${P_COMPOSE_ARGS[@]}")"
  cat > "$TMP_DIR/p${P_IDX}.json" <<EOF
{"index":${P_IDX},"project":"$(json_escape "$P_PROJECT")","workdir":"$(json_escape "$P_WORKDIR")","config_files":"$(json_escape "$P_CONFIG_FILES")","compose_args":${args},"config_valid":${P_CONFIG_VALID},"validate_output_tail":"$(json_escape "$P_VALIDATE_TAIL")","decision":"$(json_escape "$P_DECISION")","reason":"$(json_escape "$P_REASON")","error":"$(json_escape "$P_ERROR")","pull":{"attempts":${P_PULL_ATTEMPTS},"ok":${P_PULL_OK},"duration_sec":${P_PULL_DUR},"output_tail":"$(json_escape "$P_PULL_TAIL")"},"images_before":${ib},"images_after":${ia},"changed_images":${ch},"stale_services":${st},"up":{"executed":${P_UP_EXECUTED},"ok":${P_UP_OK},"duration_sec":${P_UP_DUR},"output_tail":"$(json_escape "$P_UP_TAIL")"},"stale_after_up":${P_STALE_AFTER},"duration_sec":${P_DUR}}
EOF
}

# 汇总单个项目结果、更新计数、写 JSON 片段
finish_project() {
  local decision="$1" reason="$2" error="${3:-}"
  P_DECISION="$decision"; P_REASON="$reason"; P_ERROR="$error"
  P_DUR=$(( $(date +%s) - P_START_EPOCH ))
  case "$decision" in
    UPDATE)         COUNT_UPDATE=$((COUNT_UPDATE + 1)) ;;
    SKIP_NO_UPDATE) COUNT_NOUPDATE=$((COUNT_NOUPDATE + 1)) ;;
    FAIL_*)         COUNT_FAIL=$((COUNT_FAIL + 1)); FINAL_RC=1 ;;
    *)              COUNT_SKIP=$((COUNT_SKIP + 1)) ;;
  esac
  log INFO "决策=${decision} | 原因=${reason}${error:+ | 错误=${error}} | 耗时=${P_DUR}s"
  emit_project_json || log ERROR "写入项目 JSON 片段失败: $TMP_DIR/p${P_IDX}.json"
  return 0
}

# ---------------------------------------------------------------------------
# 单个项目的完整处理流程
# 注意：本函数被 `if ! process_project ...` 调用，errexit 在函数内被抑制，
#       因此所有外部命令的返回码都显式检查，单个项目出错不影响其它项目。
# ---------------------------------------------------------------------------
process_project() {
  local idx="$1" project="$2"
  reset_project_state "$idx" "$project"
  local d="$P_D"
  local meta wd cf base_dir line rc
  local changed_count=0 stale_count=0

  # 1) 元数据
  if ! meta="$(get_project_metadata "$project")"; then
    finish_project "SKIP_METADATA" "无法获取项目元数据（无运行中容器或 docker inspect 失败）" ""
    return 0
  fi
  wd="$(printf '%s\n' "$meta" | sed -n '1p')"
  cf="$(printf '%s\n' "$meta" | sed -n '2p')"
  log INFO "元数据: working_dir=${wd:-N/A} config_files=${cf:-N/A}"

  if [ -n "$wd" ]; then
    base_dir="$wd"
  elif [ -n "$cf" ]; then
    base_dir="$(dirname "${cf%%,*}")"
  else
    base_dir=""
  fi
  if [ -z "$base_dir" ] || [ ! -d "$base_dir" ]; then
    finish_project "SKIP_METADATA" "无法定位 Compose 目录（working_dir/config_files 不可用或目录不存在）" "base_dir=${base_dir:-N/A}"
    return 0
  fi

  P_WORKDIR="$base_dir"; P_CONFIG_FILES="$cf"
  build_compose_args "$project" "$cf"
  P_COMPOSE_ARGS=("${COMPOSE_ARGS[@]}")
  log INFO "工作目录=${base_dir}"
  log INFO "Compose 参数=${COMPOSE_ARGS[*]}"

  # 2) 软校验 compose 配置（仅告警，不阻断；避免 env 变量差异造成误跳过）
  rc=0
  run_compose "$base_dir" "$d/validate.out" "$VALIDATE_TIMEOUT" \
    "${COMPOSE_ARGS[@]}" config -q || rc=$?
  if [ "$rc" -ne 0 ]; then
    P_CONFIG_VALID=false
    P_VALIDATE_TAIL="$(tail -n 20 "$d/validate.out" 2>/dev/null || true)"
    log WARN "compose config 校验未通过 (rc=${rc})，后续 pull/up 仍会尝试；输出:"
    log_block WARN "  " "$d/validate.out"
  else
    P_CONFIG_VALID=true
    log DEBUG "compose config 校验通过"
  fi

  # 3) pull 前镜像快照
  snapshot_images "$project" "$d/before.tsv" "$d/images_before.tsv"
  log INFO "pull 前镜像快照 ($(wc -l < "$d/images_before.tsv" | tr -d ' ') 个镜像引用):"
  while IFS= read -r line; do
    [ -n "$line" ] && log INFO "  BEFORE ${line%%|*}=${line#*|}"
  done < "$d/images_before.tsv"

  # 4) pull（带重试 + 超时 + 完整输出记录）
  local -a PULL_ARGS=()
  local help_txt
  help_txt="$("${COMPOSE_BIN[@]}" pull --help 2>&1 || true)"
  case "$help_txt" in *--ignore-buildable*) PULL_ARGS+=(--ignore-buildable) ;; esac
  log INFO "pull 附加参数: ${PULL_ARGS[*]:-<无>}"

  local attempt=1 ok=false prc=0 pull_start pull_total_start delay
  local -a delays=()
  read -r -a delays <<< "$RETRY_DELAYS"
  pull_total_start="$(date +%s)"
  while [ "$attempt" -le "$MAX_RETRY" ]; do
    P_PULL_ATTEMPTS=$attempt
    pull_start="$(date +%s)"
    log INFO "pull 尝试 ${attempt}/${MAX_RETRY} (timeout=${PULL_TIMEOUT}s): ${COMPOSE_BIN[*]} ${COMPOSE_ARGS[*]} pull ${PULL_ARGS[*]:-}"
    : > "$d/pull.out"
    prc=0
    run_compose "$base_dir" "$d/pull.out" "$PULL_TIMEOUT" \
      "${COMPOSE_ARGS[@]}" pull "${PULL_ARGS[@]}" || prc=$?
    log INFO "pull 第 ${attempt} 次结束 rc=${prc} 耗时=$(( $(date +%s) - pull_start ))s"
    if [ -s "$d/pull.out" ]; then
      log INFO "pull 输出 (第 ${attempt} 次):"
      log_block INFO "  " "$d/pull.out"
    fi
    if [ "$prc" -eq 0 ]; then
      ok=true
      log INFO "pull 成功"
      break
    fi
    log WARN "pull 失败 (rc=${prc})"
    if [ "$attempt" -lt "$MAX_RETRY" ]; then
      delay="${delays[$((attempt - 1))]:-60}"
      log INFO "等待 ${delay}s 后重试..."
      sleep "$delay"
    fi
    attempt=$((attempt + 1))
  done
  P_PULL_OK="$ok"
  P_PULL_DUR=$(( $(date +%s) - pull_total_start ))
  P_PULL_TAIL="$(tail -n 40 "$d/pull.out" 2>/dev/null || true)"
  if [ "$ok" != true ]; then
    finish_project "FAIL_PULL" "pull 连续 ${MAX_RETRY} 次失败" "last_rc=${prc}"
    return 0
  fi

  # 5) pull 后镜像快照
  snapshot_images "$project" "$d/after.tsv" "$d/images_after.tsv"
  log INFO "pull 后镜像快照:"
  while IFS= read -r line; do
    [ -n "$line" ] && log INFO "  AFTER  ${line%%|*}=${line#*|}"
  done < "$d/images_after.tsv"

  # 6) 计算 changed_images
  local ref b a r2 i2
  : > "$d/changed.tsv"
  while IFS='|' read -r ref b; do
    [ -n "${ref:-}" ] || continue
    a=""
    while IFS='|' read -r r2 i2; do
      if [ "$r2" = "$ref" ]; then a="$i2"; break; fi
    done < "$d/images_after.tsv"
    [ -n "$a" ] || a="MISSING"
    if [ "$b" != "$a" ] && [ "$a" != "MISSING" ]; then
      printf '%s|%s|%s\n' "$ref" "$b" "$a" >> "$d/changed.tsv"
      log INFO "  镜像变化: ${ref}  ${b} -> ${a}"
    fi
  done < "$d/images_before.tsv"
  changed_count="$(wc -l < "$d/changed.tsv" | tr -d ' ')"

  # 7) 计算 stale_services（运行容器基于的旧镜像 != 引用当前镜像）
  local cid svc rr run cur
  : > "$d/stale.tsv"
  while IFS='|' read -r cid svc rr run cur; do
    [ -n "${cid:-}" ] || continue
    if [ -n "$run" ] && [ -n "$cur" ] && [ "$cur" != "MISSING" ] && \
       [ "$run" != "MISSING" ] && [ "$run" != "$cur" ]; then
      printf '%s|%s|%s|%s|%s\n' "$cid" "$svc" "$rr" "$run" "$cur" >> "$d/stale.tsv"
      log INFO "  过时服务: service=${svc:-N/A} container=${cid:0:12} ref=${rr} running=${run} current=${cur}"
    fi
  done < "$d/after.tsv"
  stale_count="$(wc -l < "$d/stale.tsv" | tr -d ' ')"
  P_STALE_AFTER="$stale_count"

  log INFO "判定依据: changed_images=${changed_count} stale_services=${stale_count}"

  # 8) 决策：无可用更新则跳过，绝不执行 up -d
  local reason
  if [ "$stale_count" -gt 0 ] && [ "$changed_count" -gt 0 ]; then
    reason="pull 拉取到 ${changed_count} 个新镜像，且 ${stale_count} 个运行容器基于旧镜像"
  elif [ "$stale_count" -gt 0 ]; then
    reason="pull 未下载新镜像，但 ${stale_count} 个运行容器基于旧镜像（镜像此前已更新，待重建）"
  elif [ "$changed_count" -gt 0 ]; then
    reason="pull 拉取到 ${changed_count} 个新镜像（无过时运行容器，仍需 up -d 使新镜像生效）"
  else
    reason="pull 前后镜像 ID 无变化且所有运行容器均基于当前镜像，无可用更新"
  fi

  if [ "$changed_count" -eq 0 ] && [ "$stale_count" -eq 0 ]; then
    log INFO "⏭️ 无可用更新，跳过 compose up -d（本次不执行任何重建）"
    finish_project "SKIP_NO_UPDATE" "$reason" ""
    return 0
  fi

  log INFO "✅ 检测到可用更新：${reason}"

  # 9) DRY_RUN 只报告不执行
  if [ "$DRY_RUN" = true ]; then
    log INFO "DRY_RUN=true，仅模拟，不执行 up -d"
    P_UP_EXECUTED=false; P_UP_OK=null; P_UP_DUR=0
    P_UP_TAIL="DRY_RUN: up -d 未执行"
    finish_project "UPDATE" "DRY_RUN 模拟：${reason}（未实际执行 up -d）" ""
    return 0
  fi

  # 10) 执行 up -d --remove-orphans
  local up_start up_rc=0
  up_start="$(date +%s)"
  : > "$d/up.out"
  log INFO "🚀 执行: ${COMPOSE_BIN[*]} ${COMPOSE_ARGS[*]} up -d --remove-orphans"
  run_compose "$base_dir" "$d/up.out" "$UP_TIMEOUT" \
    "${COMPOSE_ARGS[@]}" up -d --remove-orphans || up_rc=$?
  P_UP_DUR=$(( $(date +%s) - up_start ))
  P_UP_EXECUTED=true
  P_UP_TAIL="$(tail -n 40 "$d/up.out" 2>/dev/null || true)"
  if [ -s "$d/up.out" ]; then
    log INFO "up -d 输出:"
    log_block INFO "  " "$d/up.out"
  fi
  if [ "$up_rc" -ne 0 ]; then
    P_UP_OK=false
    finish_project "FAIL_UP" "compose up -d 执行失败 (rc=${up_rc})" "up_rc=${up_rc}"
    return 0
  fi
  P_UP_OK=true
  log INFO "✅ up -d 完成，耗时=${P_UP_DUR}s"

  # 11) 复核：更新后是否还有容器基于旧镜像
  snapshot_images "$project" "$d/verify.tsv" "$d/verify_images.tsv"
  local vcid vrun vcur stale_after=0
  while IFS='|' read -r vcid _ _ vrun vcur; do
    [ -n "${vcid:-}" ] || continue
    if [ -n "$vrun" ] && [ -n "$vcur" ] && [ "$vcur" != "MISSING" ] && \
       [ "$vrun" != "MISSING" ] && [ "$vrun" != "$vcur" ]; then
      stale_after=$((stale_after + 1))
    fi
  done < "$d/verify.tsv"
  P_STALE_AFTER="$stale_after"
  if [ "$stale_after" -gt 0 ]; then
    log WARN "复核: up -d 后仍有 ${stale_after} 个容器基于旧镜像（可能重建未完成）"
  else
    log INFO "复核通过: up -d 后无过时容器"
  fi

  finish_project "UPDATE" "$reason" ""
  return 0
}

# shellcheck disable=SC2329  # 由 finalize() 调用（finalize 经 trap 间接触发）
write_run_json() {
  local rc="$1"
  local tmp="$TMP_DIR/run.json" projects="" f result="ok"
  [ "$COUNT_FAIL" -gt 0 ] && result="degraded"
  [ "$rc" -ne 0 ] && result="error"
  for f in "$TMP_DIR"/p*.json; do
    [ -f "$f" ] || continue
    projects+="${projects:+,}$(cat "$f")"
  done
  cat > "$tmp" <<EOF
{
  "schema": "compose-auto-update/run/1",
  "script_version": "${SCRIPT_VERSION}",
  "run_id": "${RUN_ID}",
  "host": "$(json_escape "$HOST_NAME")",
  "started_at": "${RUN_START_AT}",
  "finished_at": "$(timestamp)",
  "duration_sec": $(( $(date +%s) - RUN_START_EPOCH )),
  "compose_type": "$(json_escape "$COMPOSE_TYPE")",
  "compose_cmd": "$(json_escape "${COMPOSE_BIN[*]:-}")",
  "log_file": "$(json_escape "$LOG_FILE")",
  "run_json": "$(json_escape "$RUN_JSON")",
  "config": {
    "dry_run": ${DRY_RUN},
    "prune_images": ${PRUNE_IMAGES},
    "max_retry": ${MAX_RETRY},
    "retry_delays": "$(json_escape "$RETRY_DELAYS")",
    "pull_timeout_sec": ${PULL_TIMEOUT},
    "up_timeout_sec": ${UP_TIMEOUT},
    "validate_timeout_sec": ${VALIDATE_TIMEOUT},
    "include_projects": "$(json_escape "$INCLUDE_PROJECTS")",
    "exclude_projects": "$(json_escape "$EXCLUDE_PROJECTS")",
    "lock_file": "$(json_escape "$LOCK_FILE")"
  },
  "summary": {
    "total": ${COUNT_TOTAL},
    "updated": ${COUNT_UPDATE},
    "skipped_no_update": ${COUNT_NOUPDATE},
    "skipped_other": ${COUNT_SKIP},
    "failed": ${COUNT_FAIL}
  },
  "prune": {"ran": ${PRUNE_RAN}, "ok": ${PRUNE_OK}},
  "projects": [${projects}],
  "exit_code": ${rc},
  "result": "${result}"
}
EOF
  if ! cp "$tmp" "$RUN_JSON" 2>/dev/null; then
    log ERROR "写入 JSON 摘要失败: $RUN_JSON"
    return 0
  fi
  if [ -n "$RUN_JSON_DIR" ]; then
    mkdir -p "$RUN_JSON_DIR" 2>/dev/null && \
      cp "$tmp" "$RUN_JSON_DIR/compose-auto-update.${RUN_ID}.json" 2>/dev/null || true
  fi
  log INFO "结构化摘要 (JSON) 已写入: $RUN_JSON"
  log_block INFO "  " "$tmp"
}

# shellcheck disable=SC2329  # 经 trap EXIT 调用
finalize() {
  local rc=$?
  set +e
  log INFO "===== 运行结束 rc=${rc} 项目=${COUNT_TOTAL} 执行更新=${COUNT_UPDATE} 无更新跳过=${COUNT_NOUPDATE} 其他跳过=${COUNT_SKIP} 失败=${COUNT_FAIL} 总耗时=$(( $(date +%s) - RUN_START_EPOCH ))s ====="
  write_run_json "$rc" || log ERROR "生成 JSON 摘要时出错"
  if [ -n "${TMP_DIR:-}" ] && [ -d "$TMP_DIR" ]; then
    rm -rf -- "$TMP_DIR" || log WARN "临时目录清理失败: $TMP_DIR"
  fi
  exit "$rc"
}
trap finalize EXIT

# shellcheck disable=SC2329  # 经 trap ERR 调用
on_error() {
  local rc=$? line=${BASH_LINENO[0]:-?} cmd=${BASH_COMMAND:-?}
  trap - ERR
  log ERROR "未捕获错误: rc=${rc} line=${line} cmd=$(json_escape "$cmd")" || true
}
trap on_error ERR

main() {
  init
  acquire_lock

  log INFO "===== compose-auto-update v${SCRIPT_VERSION} 开始 ====="
  log INFO "run_id=${RUN_ID} host=${HOST_NAME} pid=$$ started_at=${RUN_START_AT}"
  log INFO "配置: LOG_FILE=${LOG_FILE} RUN_JSON=${RUN_JSON} RUN_JSON_DIR=${RUN_JSON_DIR:-<disabled>} LOCK_FILE=${LOCK_FILE}"
  log INFO "配置: DRY_RUN=${DRY_RUN} PRUNE_IMAGES=${PRUNE_IMAGES} MAX_RETRY=${MAX_RETRY} RETRY_DELAYS=${RETRY_DELAYS} PULL_TIMEOUT=${PULL_TIMEOUT}s UP_TIMEOUT=${UP_TIMEOUT}s VALIDATE_TIMEOUT=${VALIDATE_TIMEOUT}s"
  log INFO "配置: INCLUDE_PROJECTS=${INCLUDE_PROJECTS:-<all>} EXCLUDE_PROJECTS=${EXCLUDE_PROJECTS:-<none>}"

  if ! detect_compose; then
    COUNT_FAIL=$((COUNT_FAIL + 1)); FINAL_RC=1
    return 1
  fi
  local dv
  dv="$(docker --version 2>/dev/null || true)"
  log INFO "Docker: ${dv:-N/A}"

  local -a PROJECTS=()
  mapfile -t PROJECTS < <(
    docker ps --filter "label=com.docker.compose.project" \
      --format '{{.Label "com.docker.compose.project"}}' 2>/dev/null \
      | sed '/^$/d' | sort -u || true
  )
  log INFO "发现 ${#PROJECTS[@]} 个运行中的 Compose 项目"
  local p
  for p in "${PROJECTS[@]}"; do log DEBUG "  候选项目: ${p}"; done

  if [ "${#PROJECTS[@]}" -eq 0 ]; then
    log INFO "没有运行中的 Compose 项目，无需处理"
    return 0
  fi

  local idx=0
  for p in "${PROJECTS[@]}"; do
    idx=$((idx + 1))
    COUNT_TOTAL=$((COUNT_TOTAL + 1))
    LOG_CTX="[project=${p}]"
    log INFO "---------- 项目 ${idx}/${#PROJECTS[@]} 开始 ----------"
    if ! project_selected "$p"; then
      log INFO "被 INCLUDE/EXCLUDE 过滤，跳过"
      reset_project_state "$idx" "$p"
      finish_project "SKIP_FILTERED" "被 INCLUDE_PROJECTS/EXCLUDE_PROJECTS 过滤" ""
    elif ! process_project "$idx" "$p"; then
      log ERROR "项目处理函数异常返回: ${p}"
      reset_project_state "$idx" "$p"
      finish_project "FAIL_INTERNAL" "处理函数异常返回" ""
    fi
    log INFO "---------- 项目 ${idx}/${#PROJECTS[@]} 结束 decision=${P_DECISION} ----------"
  done
  LOG_CTX=""

  if [ "$PRUNE_IMAGES" = true ] && [ "$COUNT_UPDATE" -gt 0 ] && [ "$DRY_RUN" != true ]; then
    log INFO "本轮有 ${COUNT_UPDATE} 个项目完成更新，清理悬空镜像: docker image prune -f"
    local prc=0
    docker image prune -f >> "$LOG_FILE" 2>&1 || prc=$?
    PRUNE_RAN=true
    if [ "$prc" -eq 0 ]; then PRUNE_OK=true; else PRUNE_OK=false; fi
    log INFO "悬空镜像清理完成 rc=${prc}"
  else
    log INFO "跳过悬空镜像清理 (PRUNE_IMAGES=${PRUNE_IMAGES} 更新数=${COUNT_UPDATE} DRY_RUN=${DRY_RUN})"
  fi

  log INFO "===== 汇总: 项目总数=${COUNT_TOTAL} 执行更新=${COUNT_UPDATE} 无更新跳过=${COUNT_NOUPDATE} 其他跳过=${COUNT_SKIP} 失败=${COUNT_FAIL} ====="
  return "$FINAL_RC"
}

# `|| FINAL_RC=$?` 让「有失败时返回 1」不触发 ERR trap（这是预期退出码，不是未捕获错误）
main "$@" || FINAL_RC=$?
exit "$FINAL_RC"
