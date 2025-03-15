#!/bin/bash

DOCKER_DIR="/root/docker"

log_time() {
    date '+%Y-%m-%d %H:%M:%S'
}

log() {
    echo -e "$(log_time) $1"
}

if ! docker info &>/dev/null; then
    log "❌ Docker 未运行，请检查 Docker 服务。"
    exit 1
fi

log "🛠️ 开始执行选择性更新..."

for PROJECT_PATH in "$DOCKER_DIR"/*; do
    if [ -d "$PROJECT_PATH" ] && [ -f "$PROJECT_PATH/docker-compose.yaml" ]; then
        PROJECT_NAME=$(basename "$PROJECT_PATH")
        cd "$PROJECT_PATH" || continue

        # 核心判断逻辑：仅更新运行中的 compose 项目[7](@ref)
        RUNNING_CONTAINERS=$(docker compose ps -q 2>/dev/null | wc -l)

        if [ "$RUNNING_CONTAINERS" -eq 0 ]; then
            log "⏸️ 已跳过停止状态项目：$PROJECT_NAME"
            continue
        fi

        log "🔄 正在更新运行中的项目：$PROJECT_NAME"
        if docker compose up -d --remove-orphans --pull always; then
            log "✅ 更新成功：$PROJECT_NAME"
        else
            log "❌ 更新失败：$PROJECT_NAME"
        fi
    fi
done

log "🧹 执行镜像清理..."
docker image prune -af
log "✅ 已更新所有运行中的 compose 项目并完成清理。"