#!/usr/bin/env bash
# =============================================================================
# docker-compose-up.sh  —  Compose 项目「有更新才更新」自动更新脚本  v3.1.0
# -----------------------------------------------------------------------------
# 目标：
#   1. 发现本机正在运行的 Docker Compose 项目；
#   2. 先 pull，再用「镜像 ID 对比」判断该项目是否真的存在可用更新；
#   3. 只有存在可用更新时才执行 `up -d --remove-orphans`，否则直接跳过；
#   4. 输出详细日志 + 末尾「更新汇总」（哪个项目更新了、从什么版本到什么版本）。
#
# v3.1.0（本次改动）：改回「逐项目顺序检测」——一个项目从元数据 -> pull ->
#   判定 -> up -d 完整走完再处理下一个，日志按项目成块、时间戳单调递增。
#   彻底移除 v3.0.0 的并发 pull（PARALLEL / pull_worker / wlog / wait -n /
#   阶段拆分 / 回放 worker 日志），因为并发虽然快 ~3x，但日志里「判定标题时间」
#   与「块内 pull 行时间」对不上，可读性差。
#   代价：总耗时回到与 v2 相当（瓶颈是 26 个串行 pull 的网络等待，约 70s）。
#   但 v3 里减少 docker CLI 调用次数的优化全部保留（批量 inspect、全局镜像
#   映射、去掉三次完整快照与仅作告警的 config -q），比 v2 仍略快。
#
# 相对最初版本的保留改进：
#   - 无 JSON 摘要输出，只保留追加式 LOG_FILE；
#   - 镜像 ID 映射：每次判定前后各一次全局 `docker images --no-trunc`；
#     容器元数据：一次批量 `docker inspect` 取全部字段；
#   - 末尾「更新汇总」按项目列出镜像引用 / 服务 / 旧版本 -> 新版本
#     （OCI version 标签 > 镜像构建时间 > 短 ID）。
#
# 判定逻辑（不变）：
#   pull 前后的镜像 ID 对比 => changed_images；
#   运行容器基于的旧镜像 ID vs 引用当前镜像 ID => stale_services；
#   两者任一非空 => UPDATE（执行 up -d），皆空 => SKIP_NO_UPDATE（绝不调用 up -d）。
#
# 用法：
#   ./docker-compose-up.sh
#   DRY_RUN=true ./docker-compose-up.sh            # 只检测不执行 up -d
#   INCLUDE_PROJECTS=foo,bar ./docker-compose-up.sh
#   LOG_FILE=/tmp/u.log ./docker-compose-up.sh
#
# 可覆盖环境变量（括号为默认值）：
#   LOG_FILE(/var/log/compose-auto-update.log)   LOCK_FILE(/var/lock/compose-auto-update.lock)
#   PRUNE_IMAGES(true) 仅在本轮确有更新时才清理悬空镜像
#   MAX_RETRY(3)  RETRY_DELAYS("10 30 60")  PULL_TIMEOUT(900)  UP_TIMEOUT(900)
#   DRY_RUN(false)
#   INCLUDE_PROJECTS(空=全部)  EXCLUDE_PROJECTS(空)
#
# 退出码：0 = 全部正常（含「无更新跳过」）；1 = 至少有一个项目失败
# =============================================================================
set -Eeuo pipefail

# ---------------------------------------------------------------------------
# 可配置参数
# ---------------------------------------------------------------------------
LOG_FILE="${LOG_FILE:-/var/log/compose-auto-update.log}"
LOCK_FILE="${LOCK_FILE:-/var/lock/compose-auto-update.lock}"
PRUNE_IMAGES="${PRUNE_IMAGES:-true}"
MAX_RETRY="${MAX_RETRY:-3}"
RETRY_DELAYS="${RETRY_DELAYS:-10 30 60}"
PULL_TIMEOUT="${PULL_TIMEOUT:-900}"
UP_TIMEOUT="${UP_TIMEOUT:-900}"
DRY_RUN="${DRY_RUN:-false}"
INCLUDE_PROJECTS="${INCLUDE_PROJECTS:-}"
EXCLUDE_PROJECTS="${EXCLUDE_PROJECTS:-}"

SCRIPT_VERSION="3.1.0"
RUN_ID="$(date '+%Y%m%dT%H%M%S')-$$"
RUN_START_AT="$(date '+%F %T')"
RUN_START_EPOCH="$(date +%s)"
HOST_NAME="$(hostname 2>/dev/null || printf unknown)"

COMPOSE_TYPE=""
COMPOSE_BIN=()
PULL_ARGS=()
LOG_CTX=""
TMP_DIR=""
SUMMARY_FILE=""
FINAL_RC=0

COUNT_TOTAL=0
COUNT_UPDATE=0
COUNT_NOUPDATE=0
COUNT_SKIP=0
COUNT_FAIL=0
P_PULL_ATTEMPTS=0
P_PULL_DUR=0

declare -A MAP_BEFORE=() MAP_AFTER=()
declare -a PROJECTS=()
declare -a NOUPDATE_NAMES=() SKIP_NAMES=() FAIL_NAMES=()

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

timestamp() {
  local t=""
  printf -v t '%(%F %T)T' -1 2>/dev/null || t="$(date '+%F %T')"
  printf '%s' "$t"
}

log() {
  local level="$1"; shift
  local msg="${*:-}" ctx="" line
  [ -n "$LOG_CTX" ] && ctx="${LOG_CTX} "
  line="[$(timestamp)] [${level}] [run=${RUN_ID}] ${ctx}${msg}"
  printf '%s\n' "$line" >> "$LOG_FILE" 2>/dev/null || true
  printf '%s\n' "$line" || true
}

log_block() {
  local level="$1" prefix="$2" file="$3" line=""
  [ -f "$file" ] || return 0
  while IFS= read -r line || [ -n "$line" ]; do
    log "$level" "${prefix}${line}"
  done < "$file"
}

init() {
  local logdir ldir
  logdir="$(dirname "$LOG_FILE")"
  if ! mkdir -p "$logdir" 2>/dev/null || ! : >> "$LOG_FILE" 2>/dev/null; then
    printf '[WARN] 无法写入 %s，日志仅输出到 stdout\n' "$LOG_FILE" >&2
    LOG_FILE="/dev/null"
  fi
  ldir="$(dirname "$LOCK_FILE")"; mkdir -p "$ldir" 2>/dev/null || true
  TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/compose-auto-update.${RUN_ID}.XXXXXX")" || {
    printf '[FATAL] 无法创建临时目录\n' >&2
    exit 1
  }
  SUMMARY_FILE="$TMP_DIR/summary.txt"
  : > "$SUMMARY_FILE"
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

  local help_txt
  help_txt="$("${COMPOSE_BIN[@]}" pull --help 2>&1 || true)"
  case "$help_txt" in *--ignore-buildable*) PULL_ARGS+=(--ignore-buildable) ;; esac
  log INFO "pull 附加参数: ${PULL_ARGS[*]:-<无>}"
}

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
  COMPOSE_ARGS=(-p "$1")
  local config_files="$2" file
  local -a files=()
  [ -z "$config_files" ] && return 0
  [ "$config_files" = "<no value>" ] && return 0
  IFS=',' read -r -a files <<< "$config_files"
  for file in "${files[@]}"; do
    file="${file#"${file%%[![:space:]]*}"}"
    file="${file%"${file##*[![:space:]]}"}"
    [ -n "$file" ] || continue
    COMPOSE_ARGS+=(-f "$file")
  done
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

# 归一化镜像引用：去掉 docker.io/ 与 docker.io/library/ 前缀
norm_ref() {
  local r="$1"
  r="${r#docker.io/}"
  case "$r" in library/*) r="${r#library/}" ;; esac
  printf '%s' "$r"
}

# 一次 `docker images --no-trunc` 建立全量「引用 -> 完整镜像 ID」映射
# 每个项目在 pull 前 / pull 后各刷一次，保证 before 是该项目 pull 前的真实状态
load_map() {
  local which="$1" ref id nref
  if [ "$which" = before ]; then MAP_BEFORE=(); else MAP_AFTER=(); fi
  while IFS='|' read -r ref id; do
    [ -n "$ref" ] || continue
    [ "$ref" = "<none>:<none>" ] && continue
    nref="$(norm_ref "$ref")"
    if [ "$which" = before ]; then MAP_BEFORE["$nref"]="$id"; else MAP_AFTER["$nref"]="$id"; fi
  done < <(docker images --no-trunc --format '{{.Repository}}:{{.Tag}}|{{.ID}}' 2>/dev/null || true)
}

# 查某个引用在某张映射里的镜像 ID；未命中回退到 docker image inspect
map_get() {
  local which="$1" ref="$2" nref id=""
  nref="$(norm_ref "$ref")"
  case "$nref" in
    sha256:*)   printf '%s' "$nref"; return 0 ;;
    *@sha256:*) printf '%s' "${nref##*@}"; return 0 ;;
  esac
  if [ "$which" = before ]; then id="${MAP_BEFORE["$nref"]:-}"; else id="${MAP_AFTER["$nref"]:-}"; fi
  if [ -z "$id" ]; then
    id="$(docker image inspect -f '{{.Id}}' "$ref" 2>/dev/null || true)"
    id="${id%%$'\n'*}"
  fi
  [ -n "$id" ] || id="MISSING"
  printf '%s' "$id"
}

# 单个镜像的可读版本：OCI version 标签 > 构建时间；始终附 12 位短 ID
image_version() {
  local id="$1" sep fmt info labels created ver="" short
  short="${id#sha256:}"; short="${short:0:12}"
  sep=$'\x1f'
  fmt="{{json .Config.Labels}}${sep}{{.Created}}${sep}{{json .RepoTags}}"
  info="$(docker image inspect -f "$fmt" "$id" 2>/dev/null || true)"
  labels="null"; created=""
  if [ -n "$info" ]; then
    IFS="$sep" read -r labels created _ <<< "$info"
  fi
  ver="$(printf '%s' "$labels" | grep -o '"org.opencontainers.image.version":"[^"]*"' | head -n1 | sed 's/.*:"//; s/"$//' || true)"
  [ -n "$ver" ] || ver="$(printf '%s' "$labels" | grep -o '"org.label-schema.version":"[^"]*"' | head -n1 | sed 's/.*:"//; s/"$//' || true)"
  if [ -z "$ver" ] && [ -n "$created" ]; then
    ver="${created:0:10} ${created:11:5}"
  fi
  [ -n "$ver" ] || ver="无版本标签"
  printf '%s (%s)' "$ver" "$short"
}

# 采集单个项目元数据：1 次 docker ps + 1 次批量 docker inspect
collect_metadata() {
  local idx="$1" p="$2"
  local d="$TMP_DIR/p${idx}"
  mkdir -p "$d"
  : > "$d/containers"; : > "$d/refs"
  local -a cids=()
  local raw cid ref rid svc lwd lcf wd="" cf="" base_dir=""
  local -A seen=()

  mapfile -t cids < <(docker ps --filter "label=com.docker.compose.project=$p" --format '{{.ID}}' 2>/dev/null || true)
  [ "${#cids[@]}" -gt 0 ] || return 1

  if ! raw="$(docker inspect -f '{{.Id}}|{{.Config.Image}}|{{.Image}}|{{index .Config.Labels "com.docker.compose.service"}}|{{index .Config.Labels "com.docker.compose.project.working_dir"}}|{{index .Config.Labels "com.docker.compose.project.config_files"}}' "${cids[@]}" 2>/dev/null)"; then
    return 1
  fi

  while IFS='|' read -r cid ref rid svc lwd lcf; do
    [ -n "$cid" ] || continue
    [ "$svc" = "<no value>" ] && svc=""
    [ "$lwd" = "<no value>" ] && lwd=""
    [ "$lcf" = "<no value>" ] && lcf=""
    [ -z "$wd" ] && [ -n "$lwd" ] && wd="$lwd"
    [ -z "$cf" ] && [ -n "$lcf" ] && cf="$lcf"
    printf '%s|%s|%s|%s\n' "$svc" "$ref" "$rid" "$cid" >> "$d/containers"
    if [ -z "${seen[$ref]:-}" ]; then seen[$ref]=1; printf '%s\n' "$ref" >> "$d/refs"; fi
  done <<< "$raw"

  if [ -n "$wd" ] && [ -d "$wd" ]; then
    base_dir="$wd"
  elif [ -n "$cf" ]; then
    base_dir="$(dirname "${cf%%,*}")"
  fi
  [ -n "$base_dir" ] && [ -d "$base_dir" ] || return 1

  build_compose_args "$p" "$cf"
  printf '%s\n%s\n' "$base_dir" "$cf" > "$d/meta"
  printf '%s\n' "${COMPOSE_ARGS[@]}" > "$d/args"
  printf '%s' "$wd|$cf" > "$d/meta_display"
  return 0
}

# 顺序执行 pull（带重试 + 超时 + 完整输出直接进主日志）
pull_project() {
  local idx="$1" p="$2" wd="$3"; shift 3
  local -a args=("$@")
  local attempt=1 ok=false prc=0 delay t0 t_total
  local -a delays=()
  read -r -a delays <<< "$RETRY_DELAYS"
  t_total="$(date +%s)"

  log INFO "开始 pull: ${COMPOSE_BIN[*]} ${args[*]} pull ${PULL_ARGS[*]:-}"
  while [ "$attempt" -le "$MAX_RETRY" ]; do
    t0="$(date +%s)"
    log INFO "pull 尝试 ${attempt}/${MAX_RETRY} (timeout=${PULL_TIMEOUT}s)"
    local out="$TMP_DIR/pull_${idx}.${attempt}.out"
    : > "$out"
    prc=0
    run_compose "$wd" "$out" "$PULL_TIMEOUT" "${args[@]}" pull "${PULL_ARGS[@]}" || prc=$?
    log INFO "pull 第 ${attempt} 次结束 rc=${prc} 耗时=$(( $(date +%s) - t0 ))s"
    [ -s "$out" ] && { log INFO "pull 输出 (第 ${attempt} 次):"; log_block INFO "  " "$out"; }
    if [ "$prc" -eq 0 ]; then ok=true; log INFO "pull 成功"; break; fi
    log WARN "pull 失败 (rc=${prc})"
    if [ "$attempt" -lt "$MAX_RETRY" ]; then
      delay="${delays[$((attempt - 1))]:-60}"
      log INFO "等待 ${delay}s 后重试..."
      sleep "$delay"
    fi
    attempt=$((attempt + 1))
  done
  P_PULL_ATTEMPTS=$attempt
  P_PULL_DUR=$(( $(date +%s) - t_total ))
  [ "$ok" = true ] && return 0 || return 1
}

# up -d 后复核：批量读一次容器，确认没有容器仍基于旧镜像
verify_updated() {
  local p="$1" stale=0
  local -a cids=()
  local raw cid ref rid new
  mapfile -t cids < <(docker ps --filter "label=com.docker.compose.project=$p" --format '{{.ID}}' 2>/dev/null || true)
  [ "${#cids[@]}" -gt 0 ] || { printf '0'; return 0; }
  raw="$(docker inspect -f '{{.Id}}|{{.Config.Image}}|{{.Image}}' "${cids[@]}" 2>/dev/null || true)"
  while IFS='|' read -r cid ref rid; do
    [ -n "$cid" ] || continue
    new="$(map_get after "$ref")"
    [ "$new" = "MISSING" ] && continue
    [ "$rid" != "$new" ] && stale=$((stale + 1))
  done <<< "$raw"
  printf '%s' "$stale"
}

# shellcheck disable=SC2329  # 经 finalize() -> trap EXIT 调用
print_summary() {
  LOG_CTX=""
  local dur=$(( $(date +%s) - RUN_START_EPOCH ))
  log INFO "==================== 更新汇总 ===================="
  log INFO "检查项目=${COUNT_TOTAL} | 已更新=${COUNT_UPDATE} | 无更新=${COUNT_NOUPDATE} | 跳过=${COUNT_SKIP} | 失败=${COUNT_FAIL} | 总耗时=${dur}s"
  if [ "$COUNT_UPDATE" -gt 0 ]; then
    log INFO "已更新项目（镜像版本变化）："
    while IFS= read -r line; do log INFO "$line"; done < "$SUMMARY_FILE"
  else
    log INFO "本次没有项目需要更新（镜像均为最新）"
  fi
  if [ "${#NOUPDATE_NAMES[@]}" -gt 0 ]; then
    local joined
    joined="$(IFS=,; printf '%s' "${NOUPDATE_NAMES[*]}")"
    log INFO "无更新项目（${#NOUPDATE_NAMES[@]}）：${joined}"
  fi
  if [ "${#SKIP_NAMES[@]}" -gt 0 ]; then
    local joined
    joined="$(IFS=,; printf '%s' "${SKIP_NAMES[*]}")"
    log INFO "跳过项目（${#SKIP_NAMES[@]}）：${joined}"
  fi
  if [ "${#FAIL_NAMES[@]}" -gt 0 ]; then
    local joined
    joined="$(IFS=,; printf '%s' "${FAIL_NAMES[*]}")"
    log INFO "失败项目（${#FAIL_NAMES[@]}）：${joined}"
  fi
  log INFO "=================================================="
}

# shellcheck disable=SC2329  # 经 trap EXIT 调用
finalize() {
  local rc=$?
  set +e
  print_summary
  log INFO "===== 运行结束 rc=${rc} ====="
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
  log ERROR "未捕获错误: rc=${rc} line=${line} cmd=${cmd}" || true
}
trap on_error ERR

main() {
  init
  acquire_lock

  log INFO "===== compose-auto-update v${SCRIPT_VERSION} 开始 ====="
  log INFO "run_id=${RUN_ID} host=${HOST_NAME} pid=$$ started_at=${RUN_START_AT}"
  log INFO "配置: LOG_FILE=${LOG_FILE} LOCK_FILE=${LOCK_FILE} 检测方式=逐项目顺序"
  log INFO "配置: DRY_RUN=${DRY_RUN} PRUNE_IMAGES=${PRUNE_IMAGES} MAX_RETRY=${MAX_RETRY} RETRY_DELAYS=${RETRY_DELAYS} PULL_TIMEOUT=${PULL_TIMEOUT}s UP_TIMEOUT=${UP_TIMEOUT}s"
  log INFO "配置: INCLUDE_PROJECTS=${INCLUDE_PROJECTS:-<all>} EXCLUDE_PROJECTS=${EXCLUDE_PROJECTS:-<none>}"

  if ! detect_compose; then
    COUNT_FAIL=$((COUNT_FAIL + 1)); FINAL_RC=1
    return 1
  fi
  local dv
  dv="$(docker --version 2>/dev/null || true)"
  log INFO "Docker: ${dv:-N/A}"

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

  # ---------------- 主循环：逐项目 顺序检测 ----------------
  local idx n="${#PROJECTS[@]}" wd cf disp
  local -a m=() args=()
  for ((idx = 1; idx <= n; idx++)); do
    p="${PROJECTS[$((idx - 1))]}"
    COUNT_TOTAL=$((COUNT_TOTAL + 1))
    LOG_CTX="[project=${p}]"
    log INFO "---------- 项目 ${idx}/${n} 开始 ----------"

    if ! project_selected "$p"; then
      log INFO "决策=SKIP_FILTERED | 被 INCLUDE/EXCLUDE 过滤，跳过"
      SKIP_NAMES+=("$p"); COUNT_SKIP=$((COUNT_SKIP + 1))
      log INFO "---------- 项目 ${idx}/${n} 结束 decision=SKIP_FILTERED ----------"
      continue
    fi
    if ! collect_metadata "$idx" "$p"; then
      log INFO "决策=SKIP_METADATA | 无法采集元数据（无运行中容器 / 无法定位 Compose 目录）"
      SKIP_NAMES+=("$p"); COUNT_SKIP=$((COUNT_SKIP + 1))
      log INFO "---------- 项目 ${idx}/${n} 结束 decision=SKIP_METADATA ----------"
      continue
    fi

    mapfile -t m < "$TMP_DIR/p${idx}/meta"
    wd="${m[0]}"; cf="${m[1]:-}"
    mapfile -t args < "$TMP_DIR/p${idx}/args"
    disp="$(cat "$TMP_DIR/p${idx}/meta_display")"
    log INFO "元数据: ${disp}"
    log INFO "工作目录=${wd}"
    log INFO "Compose 参数=${args[*]}"

    # pull 前镜像映射（本次 pull 之前的真实状态）
    load_map before
    log DEBUG "pull 前本地镜像映射: ${#MAP_BEFORE[@]} 个引用"
    local line svc ref rid cid old new services
    log INFO "pull 前镜像快照 ($(wc -l < "$TMP_DIR/p${idx}/refs" | tr -d ' ') 个镜像引用):"
    while IFS= read -r ref; do
      [ -n "$ref" ] || continue
      old="$(map_get before "$ref")"
      log INFO "  BEFORE ${ref}=${old}"
    done < "$TMP_DIR/p${idx}/refs"
    while IFS='|' read -r svc ref rid cid; do
      [ -n "$ref" ] || continue
      log INFO "  容器 service=${svc:-N/A} ref=${ref} running=${rid}"
    done < "$TMP_DIR/p${idx}/containers"

    # pull（顺序执行，日志直接进主日志）
    if ! pull_project "$idx" "$p" "$wd" "${args[@]}"; then
      log INFO "决策=FAIL_PULL | pull 连续 ${P_PULL_ATTEMPTS} 次失败，跳过更新"
      log ERROR "pull 连续 ${P_PULL_ATTEMPTS} 次失败，跳过更新"
      FAIL_NAMES+=("$p"); COUNT_FAIL=$((COUNT_FAIL + 1)); FINAL_RC=1
      log INFO "---------- 项目 ${idx}/${n} 结束 decision=FAIL_PULL ----------"
      continue
    fi
    log INFO "pull 阶段耗时=${P_PULL_DUR}s（共 ${P_PULL_ATTEMPTS} 次尝试）"

    # pull 后镜像映射
    load_map after
    log DEBUG "pull 后本地镜像映射: ${#MAP_AFTER[@]} 个引用"

    local changed=0 stale=0
    local -a trans_refs=()
    local -A TRANS_OLD=() TRANS_NEW=()
    while IFS= read -r ref; do
      [ -n "$ref" ] || continue
      old="$(map_get before "$ref")"
      new="$(map_get after "$ref")"
      log INFO "  AFTER  ${ref}=${new}"
      if [ "$old" != "$new" ] && [ "$new" != "MISSING" ]; then
        changed=$((changed + 1))
        TRANS_OLD["$ref"]="$old"; TRANS_NEW["$ref"]="$new"; trans_refs+=("$ref")
        log INFO "  镜像变化: ${ref}  ${old} -> ${new}"
      fi
    done < "$TMP_DIR/p${idx}/refs"
    while IFS='|' read -r svc ref rid cid; do
      [ -n "$ref" ] || continue
      new="$(map_get after "$ref")"
      if [ -n "$rid" ] && [ "$new" != "MISSING" ] && [ "$rid" != "$new" ]; then
        stale=$((stale + 1))
        log INFO "  过时服务: service=${svc:-N/A} container=${cid:0:12} ref=${ref} running=${rid} current=${new}"
        # 无新镜像下载、但容器基于旧镜像时，也要给出「旧 -> 新」版本迁移
        if [ -z "${TRANS_OLD["$ref"]:-}" ]; then
          TRANS_OLD["$ref"]="$rid"; TRANS_NEW["$ref"]="$new"; trans_refs+=("$ref")
        fi
      fi
    done < "$TMP_DIR/p${idx}/containers"
    log INFO "判定依据: changed_images=${changed} stale_services=${stale}"

    if [ "$changed" -eq 0 ] && [ "$stale" -eq 0 ]; then
      log INFO "决策=SKIP_NO_UPDATE | 无可用更新，跳过 compose up -d（本次不执行任何重建）"
      NOUPDATE_NAMES+=("$p"); COUNT_NOUPDATE=$((COUNT_NOUPDATE + 1))
      log INFO "---------- 项目 ${idx}/${n} 结束 decision=SKIP_NO_UPDATE ----------"
      continue
    fi
    log INFO "✅ 检测到可用更新: changed_images=${changed} stale_services=${stale}"

    # 组装该项目的「从什么版本到什么版本」明细
    local detail_file="$TMP_DIR/detail_${idx}.txt"
    : > "$detail_file"
    printf '  ● %s\n' "$p" >> "$detail_file"
    for ref in "${trans_refs[@]}"; do
      old="${TRANS_OLD["$ref"]}"; new="${TRANS_NEW["$ref"]}"
      services="$(awk -F'|' -v r="$ref" '$2 == r && $1 != "" {print $1}' "$TMP_DIR/p${idx}/containers" | paste -sd, - || true)"
      printf '      %s  [%s]\n' "$ref" "${services:-N/A}" >> "$detail_file"
      printf '        %s → %s\n' "$(image_version "$old")" "$(image_version "$new")" >> "$detail_file"
    done
    if [ "$stale" -gt 0 ] && [ "$changed" -eq 0 ]; then
      printf '        （无新镜像下载，但运行容器基于旧镜像，执行重建）\n' >> "$detail_file"
    fi

    if [ "$DRY_RUN" = true ]; then
      log INFO "决策=UPDATE(DRY_RUN) | 仅模拟，不执行 up -d"
      printf '        [DRY_RUN 模拟，未实际重建]\n' >> "$detail_file"
      cat "$detail_file" >> "$SUMMARY_FILE"
      COUNT_UPDATE=$((COUNT_UPDATE + 1))
      log INFO "---------- 项目 ${idx}/${n} 结束 decision=UPDATE(DRY_RUN) ----------"
      continue
    fi

    local up_rc=0 up_start up_out
    up_start="$(date +%s)"
    up_out="$TMP_DIR/up_${idx}.out"
    : > "$up_out"
    log INFO "🚀 执行: ${COMPOSE_BIN[*]} ${args[*]} up -d --remove-orphans"
    run_compose "$wd" "$up_out" "$UP_TIMEOUT" "${args[@]}" up -d --remove-orphans || up_rc=$?
    [ -s "$up_out" ] && { log INFO "up -d 输出:"; log_block INFO "  " "$up_out"; }
    if [ "$up_rc" -ne 0 ]; then
      log INFO "决策=FAIL_UP | compose up -d 执行失败 (rc=${up_rc})"
      log ERROR "compose up -d 执行失败 (rc=${up_rc})"
      FAIL_NAMES+=("$p"); COUNT_FAIL=$((COUNT_FAIL + 1)); FINAL_RC=1
      log INFO "---------- 项目 ${idx}/${n} 结束 decision=FAIL_UP ----------"
      continue
    fi
    log INFO "✅ up -d 完成，耗时=$(( $(date +%s) - up_start ))s"

    local stale_after
    stale_after="$(verify_updated "$p")"
    if [ "$stale_after" -gt 0 ]; then
      log WARN "复核: up -d 后仍有 ${stale_after} 个容器基于旧镜像"
    else
      log INFO "复核通过: up -d 后无过时容器"
    fi

    cat "$detail_file" >> "$SUMMARY_FILE"
    log INFO "决策=UPDATE | 已重建并复核（耗时=$(( $(date +%s) - up_start ))s）"
    COUNT_UPDATE=$((COUNT_UPDATE + 1))
    log INFO "---------- 项目 ${idx}/${n} 结束 decision=UPDATE ----------"
  done
  LOG_CTX=""

  if [ "$PRUNE_IMAGES" = true ] && [ "$COUNT_UPDATE" -gt 0 ] && [ "$DRY_RUN" != true ]; then
    log INFO "本轮有 ${COUNT_UPDATE} 个项目完成更新，清理悬空镜像: docker image prune -f"
    local prc=0
    docker image prune -f >> "$LOG_FILE" 2>&1 || prc=$?
    log INFO "悬空镜像清理完成 rc=${prc}"
  else
    log INFO "跳过悬空镜像清理 (PRUNE_IMAGES=${PRUNE_IMAGES} 更新数=${COUNT_UPDATE} DRY_RUN=${DRY_RUN})"
  fi

  return "$FINAL_RC"
}

# `|| FINAL_RC=$?` 让「有失败时返回 1」不触发 ERR trap（这是预期退出码）
main "$@" || FINAL_RC=$?
exit "$FINAL_RC"
