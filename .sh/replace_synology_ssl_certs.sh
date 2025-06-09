#!/bin/bash
# 群晖SSL证书自动部署脚本 v2.0
# 支持DSM 7.x系统

# 初始化配置
CERT_SOURCE_DIR="/tmp/certs"      # 默认证书源目录
DEBUG=""                          # 启用调试模式请设为非空值

# 错误处理函数
error_exit() { echo "[ERROR] $1"; exit 1; }
warn() { echo "[WARN] $1"; }
info() { echo "[INFO] $1"; }
debug() { [[ "${DEBUG}" ]] && echo "[DEBUG] $1"; }

# 证书目标目录数组
declare -a TARGET_DIRS=(
    "/usr/syno/etc/certificate/system/default"
    "/usr/syno/etc/certificate/system/FQDN"
    "/usr/local/etc/certificate/ScsiTarget/pkg-scsi-plugin-server"
    "/usr/local/etc/certificate/SynologyDrive/SynologyDrive"
    "/usr/local/etc/certificate/WebDAVServer/webdav"
    "/usr/local/etc/certificate/ActiveBackup/ActiveBackup"
    "/usr/syno/etc/certificate/smbftpd/ftpd"
)

# 需要重启的服务和套件
SERVICES=("nmbd" "avahi" "ldap-server")
PACKAGES=("ScsiTarget" "SynologyDrive" "WebDAVServer" "ActiveBackup")

# 参数验证
[[ $EUID -ne 0 ]] && error_exit "必须使用root权限执行"
[[ ! -d "$CERT_SOURCE_DIR" ]] && error_exit "证书目录不存在: $CERT_SOURCE_DIR"

# 添加默认证书目录
DEFAULT_ARCHIVE=$(cat /usr/syno/etc/certificate/_archive/DEFAULT 2>/dev/null)
[[ -n "$DEFAULT_ARCHIVE" ]] && TARGET_DIRS+=("/usr/syno/etc/certificate/_archive/$DEFAULT_ARCHIVE")

# 添加反向代理目录
for proxy_dir in /usr/syno/etc/certificate/ReverseProxy/*/; do
    TARGET_DIRS+=("$proxy_dir")
done

# 主执行流程
[[ "$DEBUG" ]] && set -x

# 证书文件检查
for cert_file in fullchain.pem cert.pem privkey.pem; do
    [[ ! -f "$CERT_SOURCE_DIR/$cert_file" ]] && error_exit "证书文件缺失: $CERT_SOURCE_DIR/$cert_file"
done

# 部署证书到所有目录
for target_dir in "${TARGET_DIRS[@]}"; do
    mkdir -p "$target_dir" || warn "目录创建失败: $target_dir"

    if [[ -d "$target_dir" ]]; then
        info "正在部署到: $target_dir"
        cp -f "$CERT_SOURCE_DIR"/{fullchain,cert,privkey}.pem "$target_dir/"
        chown root:root "$target_dir"/{fullchain,cert,privkey}.pem
    else
        warn "跳过不存在目录: $target_dir"
    fi
done

# 服务重启流程
info "重启相关服务..."
for service in "${SERVICES[@]}"; do
    systemctl restart "$service" 2>/dev/null || warn "$service 重启失败"
done

# 套件重启流程
for pkg in "${PACKAGES[@]}"; do
    if synopkg is_onoff "$pkg"; then
        info "重启套件: $pkg"
        synopkg restart "$pkg"
    fi
done

# NGINX重启
synow3tool --gen-all && systemctl restart nginx || warn "NGINX重启失败"

info "SSL证书部署完成"
