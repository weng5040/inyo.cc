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
}

compose_pull_once() {
  local workdir="$1"
  shift || true

  if [ "$COMPOSE_TYPE" = "plugin" ]; then
    (cd "$workdir" && docker compose "$@" pull --ignore-buildable)
  else
    (cd "$workdir" && docker-compose "$@" pull)
  fi
}

compose_pull_with_retry() {
  local workdir="$1"
  shift || true

  local max_retry=3
  local attempt=1

  while [ "$attempt" -le "$max_retry" ]; do
    log "📥 pull 尝试 ${attempt}/${max_retry}: $workdir"

    if timeout 900 bash -c '
      workdir="$1"
      compose_type="$2"
      shift 2
      if [ "$compose_type" = "plugin" ]; then
        cd "$workdir" && docker compose "$@" pull --ignore-buildable
      else
        cd "$workdir" && docker-compose "$@" pull
      fi
    ' _ "$workdir" "$COMPOSE_TYPE" "$@"; then
      log "✅ pull 成功: $workdir"
      return 0
    fi

    log "⚠️ pull 失败: $workdir"

    if [ "$attempt" -lt "$max_retry" ]; then
      log "🔁 立即重试..."
    fi

    attempt=$((attempt + 1))
  done

  log "❌ pull 连续失败 3 次，跳过项目: $workdir"
  return 1
}

compose_up() {
  local workdir="$1"
  shift || true

  if [ "$COMPOSE_TYPE" = "plugin" ]; then
    (cd "$workdir" && docker compose "$@" up -d --remove-orphans --force-recreate)
  else
    (cd "$workdir" && docker-compose "$@" up -d --remove-orphans --force-recreate)
  fi
}

get_project_metadata() {
  local project="$1"
  local cid

  cid="$(docker ps \
    --filter "label=com.docker.compose.project=$project" \
    --format '{{.ID}}' | head -n1)"

  if [ -z "$cid" ]; then
    return 1
  fi

  local working_dir config_files
  working_dir="$(docker inspect -f '{{ index .Config.Labels "com.docker.compose.project.working_dir" }}' "$cid" 2>/dev/null || true)"
  config_files="$(docker inspect -f '{{ index .Config.Labels "com.docker.compose.project.config_files" }}' "$cid" 2>/dev/null || true)"

  printf '%s\n%s\n' "${working_dir:-}" "${config_files:-}"
}

build_compose_file_args() {
  local config_files="$1"
  COMPOSE_FILE_ARGS=()

  if [ -n "$config_files" ] && [ "$config_files" != "<no value>" ]; then
    IFS=',' read -r -a files <<< "$config_files"
    for f in "${files[@]}"; do
      [ -n "$f" ] || continue
      COMPOSE_FILE_ARGS+=(-f "$f")
    done
  fi
}

get_project_containers() {
  local project="$1"
  docker ps \
    --filter "label=com.docker.compose.project=$project" \
    --format '{{.ID}}'
}

need_recreate_project() {
  local project="$1"
  local cid
  local changed=1

  while read -r cid; do
    [ -n "$cid" ] || continue

    local service image_ref old_image_id new_image_id
    service="$(docker inspect -f '{{ index .Config.Labels "com.docker.compose.service" }}' "$cid" 2>/dev/null || true)"
    image_ref="$(docker inspect -f '{{.Config.Image}}' "$cid" 2>/dev/null || true)"
    old_image_id="$(docker inspect -f '{{.Image}}' "$cid" 2>/dev/null || true)"
    new_image_id="$(docker image inspect "$image_ref" --format '{{.Id}}' 2>/dev/null || true)"

    log "🔍 服务: ${service:-unknown}"
    log "   image_ref: ${image_ref:-N/A}"
    log "   pull前容器ImageID: ${old_image_id:-N/A}"
    log "   pull后标签ImageID: ${new_image_id:-N/A}"

    if [ -z "$image_ref" ] || [ -z "$old_image_id" ] || [ -z "$new_image_id" ]; then
      log "   ⚠️ 该服务无法完整比对，先按无变化处理"
      continue
    fi

    if [ "$old_image_id" != "$new_image_id" ]; then
      log "   ✅ 检测到镜像变化"
      changed=0
      break
    else
      log "   ➖ 镜像未变化"
    fi
  done < <(get_project_containers "$project")

  return "$changed"
}

main() {
  detect_compose
  mkdir -p "$(dirname "$LOG_FILE")"
  touch "$LOG_FILE"

  log "开始发现运行中的 Compose 项目..."

  mapfile -t PROJECTS < <(
    docker ps \
      --filter "label=com.docker.compose.project" \
      --format '{{.Label "com.docker.compose.project"}}' \
      | sort -u
  )

  if [ "${#PROJECTS[@]}" -eq 0 ]; then
    log "没有发现运行中的 Compose 项目"
    exit 0
  fi

  success=0
  skip=0
  fail=0

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

    build_compose_file_args "$config_files"

    base_dir=""
    if [ -n "$config_files" ] && [ "$config_files" != "<no value>" ]; then
      IFS=',' read -r -a files <<< "$config_files"
      base_dir="$(dirname "${files[0]}")"
    elif [ -n "$working_dir" ] && [ "$working_dir" != "<no value>" ]; then
      base_dir="$working_dir"
    fi

    if [ -z "$base_dir" ] || [ ! -d "$base_dir" ]; then
      log "⚠️ 无法定位 compose 目录，跳过: $project"
      skip=$((skip + 1))
      continue
    fi

    log "📁 定位目录: $base_dir"
    if [ -n "$config_files" ] && [ "$config_files" != "<no value>" ]; then
      log "📄 配置文件: $config_files"
    fi

    if ! compose_pull_with_retry "$base_dir" "${COMPOSE_FILE_ARGS[@]}"; then
    log "❌ pull 最终失败，跳过项目: $project"
    fail=$((fail + 1))
    continue
    fi

    if need_recreate_project "$project"; then
      log "🔄 项目存在镜像更新，执行 up -d 重建..."
      if compose_up "$base_dir" "${COMPOSE_FILE_ARGS[@]}"; then
        log "✅ 更新并重建完成: $project"
        success=$((success + 1))
      else
        log "❌ 重建失败: $project"
        fail=$((fail + 1))
      fi
    else
      log "✅ 项目镜像无变化，跳过重建: $project"
      skip=$((skip + 1))
    fi
  done

  log "--------------------------------------------"
  log "更新结束: 成功=$success, 跳过=$skip, 失败=$fail"

  if [ "$PRUNE_IMAGES" = true ]; then
    log "清理悬空镜像..."
    docker image prune -f >/dev/null 2>&1 || true
  fi

  log "全部完成"
}

main "$@"
