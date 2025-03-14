#!/bin/bash

# 定义 Docker 项目根目录
DOCKER_DIR="/root/docker"

# 日志函数
log_time() {
    echo "$(date '+%Y-%m-%d %H:%M:%S')"
}

log() {
    echo -e "$(log_time) $1"
}

# 检查 Docker 是否运行
if ! docker info &> /dev/null; then
    log "❌ Docker 未运行，请检查 Docker 服务。"
    exit 1
fi

log "🛠️ 开始更新所有 docker-compose 项目..."

# 循环更新每个包含 docker-compose.yaml 文件的子目录
for PROJECT_PATH in "$DOCKER_DIR"/*; do
    if [ -d "$PROJECT_PATH" ]; then
        if [ -f "$PROJECT_PATH/docker-compose.yaml" ]; then
            # 获取子目录的名称
            PROJECT_NAME=$(basename "$PROJECT_PATH")
            log "🔄 正在更新项目：$PROJECT_NAME"
            cd "$PROJECT_PATH" || continue
            if docker compose up -d --remove-orphans --pull always; then
                log "✅ 更新完成：$PROJECT_NAME"
            else
                log "❌ 更新失败：$PROJECT_NAME"
            fi
        fi
    fi
done

log "🧹 正在清理未使用的 Docker 镜像..."
docker image prune -af
log "✅ 所有 docker-compose 项目已更新完成。"