# CVE-2026-43499 ARM32 内核漏洞利用项目 - 状态文档 v2

> **本文档面向接手此项目的 AI 或开发者，提供完整的项目背景、文件说明、当前处境和未来路线。**
> 最后更新: 2026-09-08 (v2 重写: 触发方式修正)

---

## 一、项目目标

为 **华为畅享 20e (MLD-AL10, MT6765 芯片, Android 10, 内核 4.14.141+)** 编写并运行 CVE-2026-43499 漏洞利用程序，实现 SELinux 禁用 / root 提权。

### 漏洞背景（v2 修正版）
CVE-2026-43499 是 Linux 内核 **Futex PI 代理锁死锁回滚 Use-After-Free** 漏洞：

- **真实触发路径**：`FUTEX_CMP_REQUEUE_PI` 在检测到优先级反转死锁后执行**代理锁回滚**，回滚路径调用 `remove_waiter()`。4.14 中该函数错误地使用 `current` 而非 `waiter->task` 做解锁清理，导致**被 requeue 线程的 `task->pi_blocked_on` 未被清除**，悬垂指向已释放的内核栈帧
- **修复补丁**：`3bfdc63936dd` "rtmutex: Use waiter::task instead of current in remove_waiter()"
- **影响范围**：Linux 2.6.39 ~ 7.1（Android GKI 6.12 仍受影响）
- **⚠️ v1 的错误认知**：v1 认为 `FUTEX_WAIT_REQUEUE_PI` 带超时返回就会留下悬垂 `pi_blocked_on`。**逐行对照 4.14 内核源码后确认这是错的**——超时路径不经过 futex_requeue 的代理锁回滚，打不到 `remove_waiter()` 的 bug。v2 已重写为正确的 3 线程死锁回滚触发。

### 利用链（v2）
```
触发:   owner/waiter/main 三线程 + CMP_REQUEUE_PI 死锁回滚 → UAF
stamp:  waiter 用 pselect6/prctl/setsockopt/futex 多向量覆盖悬垂栈帧
        写入伪造 rt_mutex_waiter (每 4 字节重复布局, 提高命中率)
触发链: consumer 调 sched_setscheduler(waiter_tid, SCHED_NORMAL)
        (4.14: pi=true → rt_mutex_adjust_pi → 链行走)
写入:   链行走 [7] rt_mutex_dequeue → rb_erase_cached → __rb_change_child
        对 fake[0]&~1 指向地址做 4 字节原子写
```

---

## 二、仓库文件结构 (cve_2026_43499/)

| 文件 | 作用 | 状态 |
|------|------|------|
| `exploit_pure.c` | **v2 主源码**（纯 syscall + naked _start + 3线程触发 + 4向量 stamp + 链行走） | ✅ 已重写 |
| `exploit` | v2 编译好的 ARM32 EABI5 静态二进制 (8KB, stripped) | ✅ 可运行 |
| `run.sh` | 通用运行脚本（MT 管理器/Termux），支持 -t/-d/-s/-k/-p | ✅ v2 |
| `run_boot.sh` | Termux 运行脚本（同 run.sh v2 逻辑） | ✅ v2 |
| `run_boot10e.sh` | Termux 运行脚本（同 run.sh v2 逻辑） | ✅ v2 |
| `install_termux.sh` | Termux 一键安装（直链下载 exploit + 脚本） | ✅ |
| `RUN_ON_PHONE.md` | **手机端分阶段运行步骤（必读）** | ✅ 新增 |
| `offsets.json` | GhostLock 格式偏移（含 4.14.141 键，selinux_enforcing=0xC211E598 等） | ✅ |
| `check_seccomp.sh` | per-syscall seccomp 检测 | ✅ |
| `make_boot_v2.py` | 华为 boot v2 打包（kernel=zImage, dtb=k62v1_32_mexico.dtb） | ✅ |
| `make_boot_gki.py` | GKI boot 打包 | ✅ |
| `exploit.c` | v1 旧版（pthread，seccomp 杀） | ⚠️ 废弃保留 |
| `start.S` | v1 的 _start（v2 已用 naked asm 内联替代） | ⚠️ 保留参考 |
| `test_exploit.sh` / `update_exploit.sh` | 辅助脚本 | ✅ |
| `cve_2026_43499_full.tar.gz` / `exploit_package.tar.gz` | 打包分发 | ✅ |

---

## 三、v2 关键实现细节

### 3.1 触发（exploit_pure.c 核心修正）

```
owner:   futex_pi_lock(&f_pi_target)
         → 等 waiter 持有 f_pi_chain
         → futex_pi_lock(&f_pi_chain)      [永久阻塞: 被 waiter 持有]
waiter:  futex_pi_lock(&f_pi_chain)
         → 等 owner 锁定 f_pi_target
         → futex_wait_requeue_pi(&f_wait, &f_pi_target, 50ms)
main:    等 a_waiting && b_started + 20ms
         → futex_cmp_requeue_pi(&f_wait, &f_pi_target, nr_wake=1, nr_requeue=1, cmpval=0)
         → 内核代理锁检测死锁 → 回滚 → remove_waiter() bug → UAF
```

- **CMP_REQUEUE_PI 的 syscall 参数映射**（关键）：`val→nr_wake, utime(第4参)→nr_requeue, val3→cmpval`，即 `(1, 1, 0)`
- waiter 在 W2 返回（ETIMEDOUT）后栈帧释放，此刻开始 stamp
- 冒烟测试（x86_64 同构逻辑）已验证：CMP_REQUEUE_PI 返回 **EDEADLK**（死锁回滚路径命中）、W2 ETIMEDOUT 返回、sched_setscheduler 成功、全流程无卡死

### 3.2 伪造 waiter 布局（ARM32, 4.14）

```
struct rt_mutex_waiter (ARM32):
  tree_entry   rb_node  @0x00  (12B: rb_parent_color+rb_right+rb_left)
  pi_tree_entry rb_node @0x0c  (12B)
  task         @0x18   ← 非 current (使 rt_mutex_waiter_equal 不成立)
  lock         @0x1c   ← 用户态伪锁 0xDEAD0000 或 -k/-s 指定
  prio         @0x20   ← 0 (≠ task->prio≈120, 保证进入链行走)
  deadline     @0x24
  size ≈ 0x28
```
- stamp 缓冲区每 4 字节重复整个伪造结构 → 任意 4 对齐窗口命中
- `tree_entry` 全 0 → rb_erase 时 pc=0(红) 无重平衡回卷，只走 `__rb_change_child` 单次写
- 链行走写原语：`__rb_change_child(node=NULL, child=NULL, parent=fake[0]&~1, root)` →
  对 `fake[0]&~1` 指向地址做 WRITE_ONCE 4 字节写（写 0 或 child），偏移 +0 或 +4 由一次读比较决定

### 3.3 链行走触发方式（4.14 权限路径）

- **SCHED_DEADLINE 在 4.14 的 user 路径被 `-EPERM` 拒绝**（原版 x86_64 PoC 的触发方式不可直接移植）
- **正确方式**：`sched_setscheduler(waiter_tid, SCHED_NORMAL, {0})` —— 普通用户对**自己线程**下调 low prio 是允许的；`__sched_setscheduler` 在 `task_rq_unlock` 后无条件 `if (pi) rt_mutex_adjust_pi(p)`（core.c ~4239 行）
- `rt_mutex_adjust_pi`：持 task->pi_lock 读悬垂 `pi_blocked_on`，`rt_mutex_waiter_equal(waiter, task_to_waiter)` 比较 prio 与 task 指针 → 伪造 prio=0 ≠ 120 → 继续链行走
- 链行走 [2] 检查 `next_lock != waiter->lock` 会退出 → **lock 必须指向真实可用的 rt_mutex**（默认用户态伪锁满足：raw_spinlock_trylock、owner 判断、rb_first 全部走用户内存，安全且可观测）
- 若 `!rt_mutex_owner(lock)` 链终止 → 伪锁 owner 字段保持 0 即可（首次写发生在 enqueue/erase 时）

### 3.4 用户态伪锁泄露验证（v2 新增，安全默认模式）

- `mmap(0xDEAD0000, RW, FIXED|ANON)` 建用户态伪 rt_mutex
- 链行走的 rb 操作全落在用户内存 → **不写任何内核地址，零崩溃风险**
- 链行走成功后，`user_lock[1]/[2]`（rb_node/leftmost）会被写入**伪造 waiter 的内核栈地址**
- 日志出现 `CHAIN WALK OK: kernel stack ptr leaked to user!` 即证明完整利用链打通

### 3.5 Stamp 向量（4 种）

| 向量 | 机制 | 内核栈覆盖 |
|---|---|---|
| pselect6 | 用户 fd_set 拷入内核栈 stack_fds（nfds≤512 才用栈缓冲，>512 走 kmalloc） | 512B 量级，nfds/偏移扫描 |
| prctl PR_SET_NAME | 拷 16B | 小覆盖 |
| setsockopt IPV6 MCAST_JOIN_SOURCE_GROUP | 拷 group_source_req 24B | 小覆盖 |
| futex 序列 | LOCK_PI/UNLOCK_PI/WAIT_REQUEUE_PI/CMP_REQUEUE_PI 栈上建/毁 waiter | 栈 waiter 结构 |

- 多轮 × 多 nfds × 多偏移扫描，SIGSYS handler 兜底被 seccomp 屏蔽的向量

---

## 四、编译说明

```sh
# 工具链: zig 0.16.0 (pip3 install ziglang 获得)
ZIG=/home/user/.local/lib/python3.12/site-packages/ziglang/zig

$ZIG cc -target arm-linux-gnueabi -nostdlib -ffreestanding -static -O2 \
       -fno-stack-protector -fno-pic -s -o exploit exploit_pure.c
```

### 编译要点（踩过的坑）
1. `-nostdlib` 时 clang 会把自写 memset/strlen 优化成 libc 内置调用 → **改名 + `-ffreestanding`**
2. clang 严格要求 `main` 标准签名 `int main(int, char**)`
3. `_start` 用 C 写会被优化掉 argc/argv 加载 → **用 `__attribute__((naked))` + 内联 asm**
4. ARM EABI syscall: `svc #0`, r7=编号, r0-r5=参数（sc6 通用封装）
5. 产物验证: entry=0x20730 `ldr r0,[sp]/add r1,sp,#4/bl main/mov r1,r0/mov r0,#0xf8/svc #0`，102 个 svc，无未定义 libc 符号

---

## 五、当前处境

### ✅ 已完成
- v2 exploit 重写（正确触发 + 多向量 stamp + 伪锁泄露验证 + -s/-k 试验模式）
- ARM32 交叉编译环境（zig 0.16.0）与产物验证
- x86_64 同构冒烟测试通过（EDEADLK 回滚路径命中、无卡死）
- 手机端分阶段运行文档（RUN_ON_PHONE.md）

### ⏳ 待实机验证（无法在本机完成，需要用户设备）
| 项目 | 说明 |
|---|---|
| `uname -m` 实测 | 确认 ARM32 boot.img 镜像（v2 二进制是 ARM32） |
| Termux seccomp 放行情况 | futex(PI)/clone/pselect6/sched_setscheduler 是否放行（check_seccomp.sh 可测；exploit 有 SIGSYS 兜底） |
| pselect6 栈 stamp 偏移 | ARM32 实机内核栈布局，需按崩溃/泄露现象微调 nfds_list/off_list |
| -t 崩溃验证 | 设备崩溃重启 = UAF 确认（若已打 3bfdc63936dd 补丁则不触发） |
| -s selinux_enforcing 写 0 | 试验功能，可能崩溃，需链打通后使用 |

### 路线（实机阶段）
1. `sh run.sh -t` → 崩溃 = 漏洞确认
2. `sh run.sh` → 看 `CHAIN WALK OK` 泄露 = 链打通
3. `sh run.sh -s` → selinux_enforcing 写 0（试验，可能崩溃）
4. 链打通后可继续：-k 任意 4 字节写 → 构建完整提权链（改 cred / fops 劫持，参考 knowlily/cve-2026-43499-honor）

---

## 六、参考资源

- 修复补丁: `3bfdc63936dd` (rtmutex: Use waiter::task instead of current in remove_waiter())
- 公开 PoC: NebuSec/CyberMeowfia → IonStack/CVE-2026-43499/poc/poc.c (x86_64, 3线程+8向量)
- 4.14 内核源码: gregkh/linux v4.14.141 (rtmutex.c / core.c / rbtree.c / rbtree_aug.h)
- MTK 完整链参考: knowlily/cve-2026-43499-honor (Magic6 Pro: kgsl/fmps 栈覆写 + 符号表 + fops 劫持)
- 同型号参考: 233laoliu/mt6985-CVE-2026-43499
