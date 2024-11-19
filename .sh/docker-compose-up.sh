#!/bin/bash

# 定义所有 docker-compose 项目的路径
PROJECTS=(
    "/Docker/AList"
    "/Docker/DPanel"
    "/Docker/HomeAssistant"
    "/Docker/RustDesk"
    "/Docker/Vaultwarden"
    "/Docker/AdGuardHome"
)

# 循环更新每个项目
for PROJECT_PATH in "${PROJECTS[@]}"; do
    echo "正在更新项目：$PROJECT_PATH"
    cd "$PROJECT_PATH" || continue
    docker-compose up -d --remove-orphans --pull always
done

echo "以下是未使用的 Docker 镜像："
docker image prune -a

echo -e "\n正在自动清理未使用的 Docker 镜像..."
docker image prune -af

echo "所有 docker-compose 项目已更新完成。"
