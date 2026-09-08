#!/data/data/com.termux/files/usr/bin/sh
# 检测哪些 syscall 被 seccomp 禁止
# 运行: sh check_seccomp.sh

echo "=== Seccomp 状态 ==="
grep -i secc /proc/self/status
echo ""

echo "=== 测试各 syscall 是否可用 ==="

# 1. futex (240)
cat > /data/data/com.termux/files/usr/tmp/test_syscall.c << 'EOF'
#include <stdio.h>
#include <sys/syscall.h>
#include <unistd.h>
#include <errno.h>
#include <string.h>
#include <signal.h>
#include <linux/futex.h>
#include <sys/time.h>
#include <sched.h>
#include <sys/prctl.h>

static volatile int got_sigsys = 0;
static void sigsys_handler(int sig) { got_sigsys = 1; }

int main() {
    struct sigaction sa = { .sa_handler = sigsys_handler, .sa_flags = 0 };
    sigemptyset(&sa.sa_mask);
    sigaction(SIGSYS, &sa, NULL);

    int tests[] = {
        __NR_futex,         /* 240 */
        __NR_sched_setaffinity, /* 122 */
        __NR_sched_setscheduler, /* 156 */
        __NR_sched_setattr, /* 380 */
        __NR_pselect6,      /* 335 */
        __NR_ioctl,         /* 54 */
        __NR_open,          /* 5 */
        __NR_execve,        /* 11 */
        __NR_setuid,        /* 23 */
        __NR_gettid,        /* 224 */
    };
    char *names[] = {
        "futex", "sched_setaffinity", "sched_setscheduler",
        "sched_setattr", "pselect6", "ioctl", "open", "execve",
        "setuid", "gettid"
    };

    for (int i = 0; i < sizeof(tests)/sizeof(tests[0]); i++) {
        got_sigsys = 0;
        errno = 0;
        long ret = syscall(tests[i], 0, 0, 0, 0, 0, 0);
        int blocked = got_sigsys;
        int err = errno;

        if (blocked) {
            printf("[BLOCKED] %d (%s): SIGSYS - seccomp 禁止\n", tests[i], names[i]);
        } else if (ret == -1) {
            printf("[  OK  ] %d (%s): 失败但允许调用 (errno=%d: %s)\n",
                   tests[i], names[i], err, strerror(err));
        } else {
            printf("[  OK  ] %d (%s): 成功\n", tests[i], names[i]);
        }
    }

    return 0;
}
EOF

cc /data/data/com.termux/files/usr/tmp/test_syscall.c -o /data/data/com.termux/files/usr/tmp/test_syscall 2>&1
if [ -f /data/data/com.termux/files/usr/tmp/test_syscall ]; then
    /data/data/com.termux/files/usr/tmp/test_syscall
else
    echo "[-] 编译失败, 检查 Termux 是否有 clang: pkg install clang"
fi
