#!/usr/bin/env bash
set -Eeuo pipefail

LOG_FILE="/var/log/compose-auto-update.log"
PRUNE_IMAGES=true

log() {
  echo "[$(date '+%F %T')] $*" | tee -a "$LOG_FILE"
}

detect_compose() {
  if command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; then
    COMPOSE_TYPE="plugin"
  elif command -v docker-compose >/dev/null 2>&1; then
    COMPOSE_TYPE="standalone"
  else
    echo "❌ 未找到 docker compose 或 docker-compose"
    exit 1
  fi

  log "检测到 Compose 类型: $COMPOSE_TYPE"
}

compose_pull_with_retry() {
  local workdir="$1"
  shift

  local max_retry=3
  local attempt=1
  local delay

  while [ "$attempt" -le "$max_retry" ]; do
    log "📥 pull 尝试 ${attempt}/${max_retry}: $workdir"

    if timeout 900 bash -c '
      workdir="$1"
      compose_type="$2"
      shift 2

      cd "$workdir" || exit 1

      if [ "$compose_type" = "plugin" ]; then
        exec docker compose "$@" pull --ignore-buildable
      else
        exec docker-compose "$@" pull
      fi
    ' _ "$workdir" "$COMPOSE_TYPE" "$@" 2>&1 | tee -a "$LOG_FILE"; then
      log "✅ pull 成功: $workdir"
      return 0
    fi

    log "⚠️ pull 失败: $workdir"

    if [ "$attempt" -lt "$max_retry" ]; then
      case "$attempt" in
        1) delay=10 ;;
        2) delay=30 ;;
        *) delay=60 ;;
      esac

      log "🔁 ${delay} 秒后重试..."
      sleep "$delay"
    fi

    attempt=$((attempt + 1))
  done

  log "❌ pull 连续失败 ${max_retry} 次，跳过项目: $workdir"
  return 1
}

compose_up() {
  local workdir="$1"
  shift

  log "🚀 执行 compose up -d: $workdir"

  (
    cd "$workdir"

    if [ "$COMPOSE_TYPE" = "plugin" ]; then
      docker compose "$@" up -d --remove-orphans
    else
      docker-compose "$@" up -d --remove-orphans
    fi
  ) 2>&1 | tee -a "$LOG_FILE"
}

get_project_metadata() {
  local project="$1"
  local cid

  cid="$(
    docker ps \
      --filter "label=com.docker.compose.project=$project" \
      --format '{{.ID}}' \
      | head -n1
  )"

  if [ -z "$cid" ]; then
    return 1
  fi

  local working_dir config_files

  working_dir="$(
    docker inspect \
      -f '{{ index .Config.Labels "com.docker.compose.project.working_dir" }}' \
      "$cid" 2>/dev/null || true
  )"

  config_files="$(
    docker inspect \
      -f '{{ index .Config.Labels "com.docker.compose.project.config_files" }}' \
      "$cid" 2>/dev/null || true
  )"

  printf '%s\n%s\n' "${working_dir:-}" "${config_files:-}"
}

build_compose_args() {
  local project="$1"
  local config_files="$2"

  COMPOSE_ARGS=(-p "$project")

  if [ -z "$config_files" ] || [ "$config_files" = "<no value>" ]; then
    return 0
  fi

  local -a files=()
  local file

  IFS=',' read -r -a files <<< "$config_files"

  for file in "${files[@]}"; do
    [ -n "$file" ] || continue
    COMPOSE_ARGS+=(-f "$file")
  done
}

main() {
  mkdir -p "$(dirname "$LOG_FILE")"
  touch "$LOG_FILE"

  detect_compose

  log "开始发现运行中的 Compose 项目..."

  mapfile -t PROJECTS < <(
    docker ps \
      --filter "label=com.docker.compose.project" \
      --format '{{.Label "com.docker.compose.project"}}' \
      | sed '/^$/d' \
      | sort -u
  )

  if [ "${#PROJECTS[@]}" -eq 0 ]; then
    log "没有发现运行中的 Compose 项目"
    exit 0
  fi

  local success=0
  local skip=0
  local fail=0

  local project meta working_dir config_files base_dir

  for project in "${PROJECTS[@]}"; do
    log "--------------------------------------------"
    log "处理项目: $project"

    if ! meta="$(get_project_metadata "$project")"; then
      log "⚠️ 无法获取项目元数据，跳过: $project"
      skip=$((skip + 1))
      continue
    fi

    working_dir="$(printf '%s\n' "$meta" | sed -n '1p')"
    config_files="$(printf '%s\n' "$meta" | sed -n '2p')"

    # 优先使用 Compose 记录的工作目录。
    # 这比从第一个 compose 文件路径推导目录更可靠。
    if [ -n "$working_dir" ] && [ "$working_dir" != "<no value>" ]; then
      base_dir="$working_dir"
    elif [ -n "$config_files" ] && [ "$config_files" != "<no value>" ]; then
      base_dir="$(dirname "${config_files%%,*}")"
    else
      base_dir=""
    fi

    if [ -z "$base_dir" ] || [ ! -d "$base_dir" ]; then
      log "⚠️ 无法定位 Compose 目录，跳过: $project"
      log "   working_dir: ${working_dir:-N/A}"
      log "   config_files: ${config_files:-N/A}"
      skip=$((skip + 1))
      continue
    fi

    build_compose_args "$project" "$config_files"

    log "📁 Compose 目录: $base_dir"

    if [ -n "$config_files" ] && [ "$config_files" != "<no value>" ]; then
      log "📄 Compose 文件: $config_files"
    fi

    if ! compose_pull_with_retry "$base_dir" "${COMPOSE_ARGS[@]}"; then
      log "❌ pull 最终失败，跳过更新: $project"
      fail=$((fail + 1))
      continue
    fi

    log "🔍 交由 Compose 判断是否需要重建服务..."

    if compose_up "$base_dir" "${COMPOSE_ARGS[@]}"; then
      log "✅ 项目检查/更新完成: $project"
      success=$((success + 1))
    else
      log "❌ compose up 失败: $project"
      fail=$((fail + 1))
    fi
  done

  log "--------------------------------------------"
  log "更新结束: 完成=$success, 跳过=$skip, 失败=$fail"

  if [ "$PRUNE_IMAGES" = true ]; then
    log "清理悬空镜像..."
    docker image prune -f >/dev/null 2>&1 || true
  fi

  log "全部完成"

  if [ "$fail" -gt 0 ]; then
    exit 1
  fi
}

main "$@"
