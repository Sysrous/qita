#!/bin/bash
# DNS TCP/UDP 功能测试脚本
# 用于验证 dnsmasq 是否正确配置了 TCP+UDP 支持

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

echo "=================================="
echo "  DNS TCP/UDP 功能测试工具"
echo "=================================="
echo ""

# 检查必要工具
check_tools() {
    echo "检查必要工具..."
    
    if ! command -v dig &> /dev/null; then
        echo -e "${RED}✗ dig 命令未找到${NC}"
        echo "  安装方法："
        echo "    CentOS: yum install -y bind-utils"
        echo "    Ubuntu/Debian: apt install -y dnsutils"
        exit 1
    fi
    
    if ! command -v netstat &> /dev/null; then
        echo -e "${RED}✗ netstat 命令未找到${NC}"
        echo "  安装方法："
        echo "    CentOS: yum install -y net-tools"
        echo "    Ubuntu/Debian: apt install -y net-tools"
        exit 1
    fi
    
    echo -e "${GREEN}✓ 工具检查完成${NC}"
    echo ""
}

# 检查 dnsmasq 服务状态
check_service() {
    echo "检查 dnsmasq 服务状态..."
    
    if systemctl is-active --quiet dnsmasq; then
        echo -e "${GREEN}✓ dnsmasq 服务运行中${NC}"
    else
        echo -e "${RED}✗ dnsmasq 服务未运行${NC}"
        echo "  启动命令: systemctl start dnsmasq"
        exit 1
    fi
    echo ""
}

# 检查端口监听
check_ports() {
    echo "检查端口监听状态..."
    
    # 查找 dnsmasq 监听的端口
    DNS_PORTS=$(netstat -tulnp 2>/dev/null | grep dnsmasq | grep -oP ':\K\d+' | sort -u)
    
    if [ -z "$DNS_PORTS" ]; then
        echo -e "${RED}✗ 未检测到 dnsmasq 监听的端口${NC}"
        exit 1
    fi
    
    echo "检测到 dnsmasq 监听端口："
    for port in $DNS_PORTS; do
        echo ""
        echo "端口: $port"
        
        # 检查 TCP
        if netstat -tln 2>/dev/null | grep ":$port " > /dev/null; then
            echo -e "  ${GREEN}✓ TCP 协议已启用${NC}"
        else
            echo -e "  ${RED}✗ TCP 协议未启用${NC}"
        fi
        
        # 检查 UDP
        if netstat -uln 2>/dev/null | grep ":$port " > /dev/null; then
            echo -e "  ${GREEN}✓ UDP 协议已启用${NC}"
        else
            echo -e "  ${RED}✗ UDP 协议未启用${NC}"
        fi
    done
    echo ""
    
    # 返回第一个端口供后续测试使用
    echo "$DNS_PORTS" | head -1
}

# DNS 解析测试
test_dns_query() {
    local PORT=$1
    local SERVER=${2:-127.0.0.1}
    local TEST_DOMAIN="netflix.com"
    
    echo "执行 DNS 查询测试..."
    echo "服务器: $SERVER"
    echo "端口: $PORT"
    echo "测试域名: $TEST_DOMAIN"
    echo ""
    
    # UDP 查询测试
    echo "1. UDP 查询测试"
    if [ "$PORT" == "53" ]; then
        UDP_RESULT=$(dig @$SERVER $TEST_DOMAIN +short +time=3 +tries=1 2>&1)
    else
        UDP_RESULT=$(dig @$SERVER -p $PORT $TEST_DOMAIN +short +time=3 +tries=1 2>&1)
    fi
    
    if [ $? -eq 0 ] && [ -n "$UDP_RESULT" ]; then
        echo -e "${GREEN}✓ UDP 查询成功${NC}"
        echo "  返回结果: $UDP_RESULT"
    else
        echo -e "${RED}✗ UDP 查询失败${NC}"
        echo "  错误信息: $UDP_RESULT"
    fi
    echo ""
    
    # TCP 查询测试
    echo "2. TCP 查询测试（关键）"
    if [ "$PORT" == "53" ]; then
        TCP_RESULT=$(dig @$SERVER $TEST_DOMAIN +tcp +short +time=3 +tries=1 2>&1)
    else
        TCP_RESULT=$(dig @$SERVER -p $PORT $TEST_DOMAIN +tcp +short +time=3 +tries=1 2>&1)
    fi
    
    if [ $? -eq 0 ] && [ -n "$TCP_RESULT" ]; then
        echo -e "${GREEN}✓ TCP 查询成功（香港等地区可用）${NC}"
        echo "  返回结果: $TCP_RESULT"
    else
        echo -e "${RED}✗ TCP 查询失败${NC}"
        echo "  错误信息: $TCP_RESULT"
    fi
    echo ""
}

# 防火墙规则检查
check_firewall() {
    local PORT=$1
    
    echo "检查防火墙规则..."
    
    # 检查 iptables
    if command -v iptables &> /dev/null; then
        echo "iptables 规则："
        
        TCP_RULE=$(iptables -L INPUT -n 2>/dev/null | grep "tcp dpt:$PORT")
        UDP_RULE=$(iptables -L INPUT -n 2>/dev/null | grep "udp dpt:$PORT")
        
        if [ -n "$TCP_RULE" ]; then
            echo -e "  ${GREEN}✓ TCP $PORT 已放行${NC}"
        else
            echo -e "  ${YELLOW}⚠ TCP $PORT 未在 iptables 中找到${NC}"
        fi
        
        if [ -n "$UDP_RULE" ]; then
            echo -e "  ${GREEN}✓ UDP $PORT 已放行${NC}"
        else
            echo -e "  ${YELLOW}⚠ UDP $PORT 未在 iptables 中找到${NC}"
        fi
    fi
    echo ""
    
    # 检查 firewalld
    if command -v firewall-cmd &> /dev/null && systemctl is-active --quiet firewalld; then
        echo "firewalld 规则："
        
        ZONE=$(firewall-cmd --get-default-zone 2>/dev/null)
        TCP_OPEN=$(firewall-cmd --zone=$ZONE --list-ports 2>/dev/null | grep "${PORT}/tcp")
        UDP_OPEN=$(firewall-cmd --zone=$ZONE --list-ports 2>/dev/null | grep "${PORT}/udp")
        
        if [ -n "$TCP_OPEN" ]; then
            echo -e "  ${GREEN}✓ TCP $PORT 已放行${NC}"
        else
            echo -e "  ${YELLOW}⚠ TCP $PORT 未在 firewalld 中找到${NC}"
        fi
        
        if [ -n "$UDP_OPEN" ]; then
            echo -e "  ${GREEN}✓ UDP $PORT 已放行${NC}"
        else
            echo -e "  ${YELLOW}⚠ UDP $PORT 未在 firewalld 中找到${NC}"
        fi
    fi
    echo ""
}

# 生成测试报告
generate_report() {
    local PORT=$1
    
    echo "=================================="
    echo "  测试完成"
    echo "=================================="
    echo ""
    echo "客户端测试命令："
    echo ""
    
    if [ "$PORT" == "53" ]; then
        echo "标准 DNS 查询:"
        echo "  dig @YOUR_SERVER_IP netflix.com"
        echo ""
        echo "强制 TCP 查询（推荐香港地区使用）:"
        echo "  dig @YOUR_SERVER_IP netflix.com +tcp"
        echo ""
        echo "Windows nslookup（TCP模式）:"
        echo "  nslookup -vc netflix.com YOUR_SERVER_IP"
    else
        echo "自定义端口查询:"
        echo "  dig @YOUR_SERVER_IP -p $PORT netflix.com"
        echo ""
        echo "强制 TCP 查询:"
        echo "  dig @YOUR_SERVER_IP -p $PORT netflix.com +tcp"
    fi
    echo ""
}

# 主函数
main() {
    # 检查是否为 root
    if [ "$EUID" -ne 0 ]; then 
        echo -e "${YELLOW}建议使用 root 权限运行以获取完整信息${NC}"
        echo ""
    fi
    
    # 执行检查
    check_tools
    check_service
    DNS_PORT=$(check_ports)
    check_firewall "$DNS_PORT"
    test_dns_query "$DNS_PORT" "127.0.0.1"
    generate_report "$DNS_PORT"
}

# 运行主函数
main

