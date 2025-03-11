#!/bin/bash

# 定义所有 docker-compose 项目的路径
PROJECTS=(
    "/root/docker/DPanel"
    "/root/docker/Vaultwarden"
    "/root/docker/Sun-Panel"
    "/root/docker/Nginx_Proxy"
    "/root/docker/MariaDB"
    "/root/docker/MaxKB"
    "/root/docker/Kener"
    "/root/docker/Certd"
)

# 获取当前时间的函数
log_time() {
    echo "$(date '+%Y-%m-%d %H:%M:%S')"
}

echo -e "\n$(log_time) 🛠️ 开始更新所有 docker-compose 项目..."

# 循环更新每个项目
for PROJECT_PATH in "${PROJECTS[@]}"; do
    if [ -d "$PROJECT_PATH" ]; then
        echo "$(log_time) 🔄 正在更新项目：$PROJECT_PATH"
        cd "$PROJECT_PATH" || continue
        docker compose up -d --remove-orphans --pull always
        echo "$(log_time) ✅ 更新完成：$PROJECT_PATH"
    else
        echo "$(log_time) ❌ 目录不存在，跳过：$PROJECT_PATH"
    fi
done

echo -e "\n$(log_time) 🧹 正在自动清理未使用的 Docker 镜像..."
docker image prune -af
echo "$(log_time) ✅ 所有 docker-compose 项目已更新完成。"