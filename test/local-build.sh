#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

CONFIG_FILE="${SCRIPT_DIR}/local-build.config"
LOG_DIR="${SCRIPT_DIR}/logs"
BUILD_LOG="${LOG_DIR}/build-$(date +%Y%m%d-%H%M%S).log"
TEMP_DIR="${SCRIPT_DIR}/.build-temp"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

PROJECT_ROOT=""
declare -A CONFIG

load_config() {
    if [[ ! -f "$CONFIG_FILE" ]]; then
        echo -e "${RED}[错误] 配置文件不存在: $CONFIG_FILE${NC}"
        echo -e "${YELLOW}[提示] 请复制 local-build.config.example 为 local-build.config 并修改配置${NC}"
        exit 1
    fi

    while IFS='=' read -r key value; do
        [[ "$key" =~ ^[[:space:]]*# ]] && continue
        [[ -z "$key" ]] && continue
        key=$(echo "$key" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
        value=$(echo "$value" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
        CONFIG["$key"]="$value"
    done < "$CONFIG_FILE"

    if [[ -n "${CONFIG[PROJECT_ROOT]:-}" ]]; then
        PROJECT_ROOT="${CONFIG[PROJECT_ROOT]}"
    else
        PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
    fi

    echo -e "${BLUE}[INFO] 项目根目录: $PROJECT_ROOT${NC}"
}

init_environment() {
    echo -e "${CYAN}[初始化] 初始化构建环境...${NC}"

    mkdir -p "$LOG_DIR"
    mkdir -p "$TEMP_DIR"

    exec > >(tee -a "$BUILD_LOG") 2>&1

    echo -e "${GREEN}[INFO] 构建日志: $BUILD_LOG${NC}"
}

check_dependencies() {
    echo -e "${CYAN}[检查] 验证依赖项...${NC}"

    local missing_deps=()

    if ! command -v docker &> /dev/null; then
        missing_deps+=("docker")
    fi

    if ! command -v git &> /dev/null; then
        missing_deps+=("git")
    fi

    if ! command -v curl &> /dev/null; then
        missing_deps+=("curl")
    fi

    if ! command -v wget &> /dev/null; then
        missing_deps+=("wget")
    fi

    if [[ ${#missing_deps[@]} -gt 0 ]]; then
        echo -e "${RED}[错误] 缺少必要依赖: ${missing_deps[*]}${NC}"
        echo -e "${YELLOW}[提示] 请运行: sudo apt-get install -y ${missing_deps[*]}${NC}"
        exit 1
    fi

    if ! docker info &> /dev/null; then
        echo -e "${RED}[错误] Docker 未运行或无权限${NC}"
        echo -e "${YELLOW}[提示] 请将当前用户添加到 docker 组: sudo usermod -aG docker \$USER${NC}"
        exit 1
    fi

    echo -e "${GREEN}[OK] 所有依赖项已就绪${NC}"
}

pull_docker_image() {
    local image="${CONFIG[LUCI_VERSION]:-24.10.5}"
    local image_name="immortalwrt/imagebuilder:x86-64-openwrt-${image}"

    echo -e "${CYAN}[拉取] Docker 镜像: $image_name${NC}"

    if docker images -q "$image_name" &> /dev/null; then
        echo -e "${GREEN}[INFO] 镜像已存在，跳过拉取${NC}"
        return 0
    fi

    echo -e "${YELLOW}[警告] 首次拉取可能需要较长时间（约 2-3GB）...${NC}"

    if docker pull "$image_name"; then
        echo -e "${GREEN}[OK] 镜像拉取成功${NC}"
    else
        echo -e "${RED}[错误] 镜像拉取失败${NC}"
        echo -e "${YELLOW}[提示] 请检查网络连接或使用代理${NC}"
        exit 1
    fi
}

prepare_build_directories() {
    echo -e "${CYAN}[准备] 创建构建目录...${NC}"

    local build_dir="${TEMP_DIR}/immortalwrt"

    rm -rf "$build_dir"
    mkdir -p "$build_dir"/{bin,files,extra-packages,packages,shell}

    cp -r "${PROJECT_ROOT}/shell" "$build_dir/" 2>/dev/null || true
    cp -r "${PROJECT_ROOT}/files" "$build_dir/" 2>/dev/null || true

    if [[ -f "${PROJECT_ROOT}/x86-64/build.sh" ]]; then
        cp "${PROJECT_ROOT}/x86-64/build.sh" "$build_dir/"
    fi

    if [[ -f "${PROJECT_ROOT}/x86-64/imm.config" ]]; then
        cp "${PROJECT_ROOT}/x86-64/imm.config" "$build_dir/.config"
    fi

    if [[ -f "${PROJECT_ROOT}/x86-64/build.sh" ]]; then
        cp "${PROJECT_ROOT}/x86-64/build.sh" "$build_dir/"
    fi

    if [[ -f "${PROJECT_ROOT}/x86-64/imm.config" ]]; then
        cp "${PROJECT_ROOT}/x86-64/imm.config" "$build_dir/.config"
    fi

    local custom_ip="${CONFIG[CUSTOM_ROUTER_IP]:-192.168.100.1}"
    mkdir -p "$build_dir/files/etc/config"
    echo "$custom_ip" > "$build_dir/files/etc/config/custom_router_ip"

    echo -e "${GREEN}[OK] 构建目录准备完成${NC}"
    echo -e "${BLUE}[目录] $build_dir${NC}"
}

build_firmware() {
    echo -e "${CYAN}[构建] 开始编译固件...${NC}"
    echo -e "${BLUE}[配置]${NC}"
    echo -e "  - 固件大小: ${CONFIG[PROFILE]:-1024}MB"
    echo -e "  - LuCI 版本: ${CONFIG[LUCI_VERSION]:-24.10.5}"
    echo -e "  - 包含 Docker: ${CONFIG[INCLUDE_DOCKER]:-yes}"
    echo -e "  - 启用 PPPoE: ${CONFIG[ENABLE_PPPOE]:-no}"
    echo -e "  - 启用 Store: ${CONFIG[ENABLE_STORE]:-true}"

    local image="immortalwrt/imagebuilder:x86-64-openwrt-${CONFIG[LUCI_VERSION]:-24.10.5}"

    local docker_opts=(
        "--rm" "-i"
        "--user" "root"
        "--network" "host"
        "--dns" "8.8.8.8"
        "--dns" "114.114.114.114"
        "-w" "/home/build/immortalwrt"
        "-v" "${TEMP_DIR}/immortalwrt/bin:/home/build/immortalwrt/bin"
        "-v" "${TEMP_DIR}/immortalwrt/files:/home/build/immortalwrt/files"
        "-v" "${TEMP_DIR}/immortalwrt/packages:/home/build/immortalwrt/packages"
        "-v" "${PROJECT_ROOT}/x86-64/imm.config:/home/build/immortalwrt/.config"
        "-v" "${PROJECT_ROOT}/shell:/home/build/immortalwrt/shell"
        "-v" "${PROJECT_ROOT}/x86-64/build.sh:/home/build/immortalwrt/build.sh"
    )

    if [[ "${CONFIG[ENABLE_STORE]:-true}" == "true" ]]; then
        local custom_packages="${CONFIG[CUSTOM_PACKAGES]:-}"
        if [[ -n "$custom_packages" ]]; then
            docker_opts+=("-e" "CUSTOM_PACKAGES=$custom_packages")
        fi
    fi

    local env_vars=(
        "-e" "PROFILE=${CONFIG[PROFILE]:-1024}"
        "-e" "INCLUDE_DOCKER=${CONFIG[INCLUDE_DOCKER]:-yes}"
        "-e" "ENABLE_PPPOE=${CONFIG[ENABLE_PPPOE]:-no}"
        "-e" "PPPOE_ACCOUNT=${CONFIG[PPPOE_ACCOUNT]:-}"
        "-e" "PPPOE_PASSWORD=${CONFIG[PPPOE_PASSWORD]:-}"
    )

    if [[ -n "${CONFIG[HTTP_PROXY]:-}" ]]; then
        env_vars+=("-e" "HTTP_PROXY=${CONFIG[HTTP_PROXY]}")
    fi

    if [[ -n "${CONFIG[HTTPS_PROXY]:-}" ]]; then
        env_vars+=("-e" "HTTPS_PROXY=${CONFIG[HTTPS_PROXY]}")
    fi

    local all_opts=("${docker_opts[@]}" "${env_vars[@]}")

    echo -e "${YELLOW}[构建] 执行 Docker 构建...${NC}"

    if docker run "${all_opts[@]}" "$image" /bin/bash /home/build/immortalwrt/build.sh; then
        echo -e "${GREEN}[OK] 固件构建成功！${NC}"
    else
        echo -e "${RED}[错误] 固件构建失败！${NC}"
        echo -e "${YELLOW}[提示] 请查看日志: $BUILD_LOG${NC}"
        exit 1
    fi
}

package_output() {
    echo -e "${CYAN}[打包] 处理构建产物...${NC}"

    local output_dir="${PROJECT_ROOT}/output"
    local source_dir="${TEMP_DIR}/immortalwrt/bin"

    mkdir -p "$output_dir"

    if [[ -d "$source_dir/targets/x86/64" ]]; then
        local firmware_file
        firmware_file=$(find "$source_dir/targets/x86/64" -name "*squashfs-combined-efi.img.gz" | head -n 1)

        if [[ -n "$firmware_file" && -f "$firmware_file" ]]; then
            local output_file="${output_dir}/immortalwrt-x86-64-$(date +%Y%m%d).img.gz"
            cp "$firmware_file" "$output_file"
            echo -e "${GREEN}[OK] 固件已保存: $output_file${NC}"

            local size_mb
            size_mb=$(du -h "$output_file" | cut -f1)
            echo -e "${BLUE}[固件] 大小: $size_mb${NC}"
        else
            echo -e "${RED}[错误] 未找到固件文件${NC}"
            exit 1
        fi
    else
        echo -e "${RED}[错误] 构建产物目录不存在: $source_dir/targets/x86/64${NC}"
        exit 1
    fi
}

cleanup() {
    echo -e "${CYAN}[清理] 清理临时文件...${NC}"
    rm -rf "$TEMP_DIR"
    echo -e "${GREEN}[OK] 清理完成${NC}"
}

show_help() {
    cat << EOF
用法: $(basename "$0") [选项]

选项:
    -h, --help           显示帮助信息
    -c, --config FILE    指定配置文件 (默认: local-build.config)
    -l, --list-logs      显示构建日志列表
    -v, --view-log LOG   查看指定日志
    --no-cleanup        保留临时文件用于调试
    --incremental       增量构建模式 (保留之前的构建缓存)

示例:
    $(basename "$0")                    # 使用默认配置构建
    $(basename "$0") -c my-config.config # 使用自定义配置
    $(basename "$0") --incremental       # 增量构建
    $(basename "$0") -l                  # 查看历史构建日志
EOF
}

list_logs() {
    echo -e "${CYAN}构建日志列表:${NC}"
    if [[ -d "$LOG_DIR" ]]; then
        ls -lh "$LOG_DIR"/*.log 2>/dev/null || echo "暂无日志"
    else
        echo "暂无日志"
    fi
}

view_log() {
    local log_file="$1"
    if [[ -f "$log_file" ]]; then
        cat "$log_file"
    else
        echo -e "${RED}[错误] 日志文件不存在: $log_file${NC}"
        exit 1
    fi
}

main() {
    local use_config="${CONFIG_FILE}"
    local no_cleanup=false
    local incremental=false

    while [[ $# -gt 0 ]]; do
        case "$1" in
            -h|--help)
                show_help
                exit 0
                ;;
            -c|--config)
                use_config="$2"
                shift 2
                ;;
            -l|--list-logs)
                list_logs
                exit 0
                ;;
            -v|--view-log)
                view_log "$2"
                exit 0
                ;;
            --no-cleanup)
                no_cleanup=true
                shift
                ;;
            --incremental)
                incremental=true
                shift
                ;;
            *)
                echo -e "${RED}[错误] 未知选项: $1${NC}"
                show_help
                exit 1
                ;;
        esac
    done

    CONFIG_FILE="$use_config"

    echo -e "${BLUE}========================================${NC}"
    echo -e "${BLUE}  ImmortalWrt 本地构建脚本${NC}"
    echo -e "${BLUE}========================================${NC}"
    echo ""

    load_config
    init_environment
    check_dependencies
    pull_docker_image
    prepare_build_directories
    build_firmware
    package_output

    if [[ "$no_cleanup" == "false" ]]; then
        cleanup
    else
        echo -e "${YELLOW}[提示] 临时文件保留在: $TEMP_DIR${NC}"
    fi

    echo ""
    echo -e "${GREEN}========================================${NC}"
    echo -e "${GREEN}  构建完成！${NC}"
    echo -e "${GREEN}========================================${NC}"
}

main "$@"
