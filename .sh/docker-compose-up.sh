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
    #此命令会检查并更新所有服务的镜像，如果有新版本则拉取，并在后台运行最新的容器。`--remove-orphans` 选项确保删除配置文件中已移除的旧容器，以保持环境清洁。
    docker-compose up -d --remove-orphans --pull always #
done

echo "所有 docker-compose 项目已更新完成。"