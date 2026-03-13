#!/bin/bash

# 自动化测试脚本：验证build-x86-64.yml工作流
# 适用于Debian 13操作系统，已安装Git和Docker

# 配置参数
REPO_URL="https://github.com/walk6834/AutoBuildImmortalWrt.git"
REPO_DIR="AutoBuildImmortalWrt"
WORKFLOW_FILE=".github/workflows/build-x86-64.yml"
TEST_REPORT="test-report.txt"
ACT_VERSION="0.2.60"

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# 错误处理函数
error_exit() {
    echo -e "${RED}错误: $1${NC}" >&2
    cleanup
    exit 1
}

# 清理函数
cleanup() {
    echo -e "${YELLOW}正在清理测试资源...${NC}"
    
    # 停止并删除Docker容器
    docker stop $(docker ps -q --filter "name=immortalwrt") 2>/dev/null || true
    docker rm $(docker ps -aq --filter "name=immortalwrt") 2>/dev/null || true
    
    # 删除临时文件
    rm -rf "$REPO_DIR" "$TEST_REPORT" act temp.txt 2>/dev/null || true
    
    echo -e "${GREEN}清理完成${NC}"
}

# 安装act工具
install_act() {
    echo -e "${YELLOW}正在安装act工具...${NC}"
    
    # 下载act
    curl -sLO "https://github.com/nektos/act/releases/download/v${ACT_VERSION}/act_Linux_x86_64.tar.gz"
    if [ $? -ne 0 ]; then
        error_exit "下载act失败"
    fi
    
    # 解压并安装
    tar xzf act_Linux_x86_64.tar.gz
    chmod +x act
    sudo mv act /usr/local/bin/
    
    # 验证安装
    if ! command -v act &> /dev/null; then
        error_exit "act安装失败"
    fi
    
    echo -e "${GREEN}act安装成功${NC}"
}

# 克隆或更新代码仓库
clone_repo() {
    echo -e "${YELLOW}正在克隆代码仓库...${NC}"
    
    if [ -d "$REPO_DIR" ]; then
        echo -e "${YELLOW}仓库已存在，执行更新...${NC}"
        cd "$REPO_DIR"
        git pull
        if [ $? -ne 0 ]; then
            error_exit "仓库更新失败"
        fi
        cd ..
    else
        git clone "$REPO_URL"
        if [ $? -ne 0 ]; then
            error_exit "仓库克隆失败"
        fi
    fi
    
    # 检查工作流文件是否存在
    if [ ! -f "$REPO_DIR/$WORKFLOW_FILE" ]; then
        error_exit "工作流文件不存在: $REPO_DIR/$WORKFLOW_FILE"
    fi
    
    echo -e "${GREEN}代码仓库准备完成${NC}"
}

# 执行工作流测试
run_workflow_test() {
    echo -e "${YELLOW}正在执行工作流测试...${NC}"
    
    cd "$REPO_DIR"
    
    # 创建事件文件
    cat > event.json << EOF
{
    "inputs": {
        "luci_version": "24.10.5",
        "custom_router_ip": "192.168.100.1",
        "profile": "1024",
        "enable_store": true,
        "include_docker": "yes",
        "enable_pppoe": "no"
    }
}
EOF
    
    # 使用act执行指定工作流，指定Medium size镜像
    act -j build -e event.json --verbose -P ubuntu-24.04=catthehacker/ubuntu:act-latest -W .github/workflows/build-x86-64.yml 2>&1 | tee "../$TEST_REPORT"
    
    # 检查执行结果
    if [ ${PIPESTATUS[0]} -eq 0 ]; then
        echo -e "${GREEN}工作流执行成功${NC}"
    else
        echo -e "${RED}工作流执行失败${NC}"
    fi
    
    cd ..
}

# 生成测试报告
generate_report() {
    echo -e "${YELLOW}正在生成测试报告...${NC}"
    
    # 创建临时文件
    cat > temp.txt << EOF
# 工作流测试报告

## 测试基本信息
- 测试时间: $(date)
- 测试环境: Debian 13
- 工作流文件: $WORKFLOW_FILE

## 执行结果
EOF
    
    # 检查工作流执行状态
    if grep -q "Successfully built" "$TEST_REPORT"; then
        echo "- 执行状态: 成功" >> temp.txt
    else
        echo "- 执行状态: 失败" >> temp.txt
    fi
    
    # 提取关键日志
    echo -e "\n## 关键日志片段" >> temp.txt
    grep -E "(Error|Failed|Success|Build completed)" "$TEST_REPORT" >> temp.txt
    
    # 合并临时文件到测试报告
    cat temp.txt > "$TEST_REPORT"
    rm temp.txt
    
    echo -e "${GREEN}测试报告已生成: $TEST_REPORT${NC}"
}

# 主函数
main() {
    echo -e "${GREEN}=== 工作流自动化测试开始 ===${NC}"
    
    # 检查依赖
    if ! command -v git &> /dev/null; then
        error_exit "Git未安装"
    fi
    
    if ! command -v docker &> /dev/null; then
        error_exit "Docker未安装"
    fi
    
    # 安装act（如果未安装）
    if ! command -v act &> /dev/null; then
        install_act
    fi
    
    # 克隆代码仓库
    clone_repo
    
    # 执行工作流测试
    run_workflow_test
    
    # 生成测试报告
    generate_report
    
    # 清理资源
    cleanup
    
    echo -e "${GREEN}=== 工作流自动化测试完成 ===${NC}"
    exit 0
}

# 捕获信号，确保清理
trap cleanup EXIT INT TERM

# 启动主函数
main
