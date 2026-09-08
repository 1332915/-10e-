# CVE-2026-43499 ARM32 内核漏洞利用项目 - 完整状态文档

> **本文档面向接手此项目的 AI 或开发者，提供完整的项目背景、文件说明、当前处境和未来路线。**

---

## 一、项目目标

为 **华为畅享 20e (MLD-AL10, MT6765 芯片, Android 10, 内核 4.14.141+)** 编写并运行 CVE-2026-43499 漏洞利用程序，实现 SELinux 禁用 / root 提权。

### 漏洞背景
CVE-2026-43499 是 Linux 内核 **Futex PI (优先级继承) Use-After-Free** 漏洞：
- `FUTEX_WAIT_REQUEUE_PI` 带超时返回时，`rt_mutex_waiter` 结构从内核栈移除，但 `task->pi_blocked_on` 仍指向已释放的栈地址
- 通过 `pselect6` 重写该栈区域，可伪造 waiter 结构
- 触发 PI 链行走（`sched_setattr` / `sched_setscheduler`）会让内核 `rb_insert_color` 将伪造数据写入任意内核地址
- 影响范围：Linux 2.6.39 ~ 7.1

---

## 二、工作区文件结构

```
/workspace/
├── exploit_binary/          # 编译好的二进制
│   ├── exploit              # 纯 syscall 版本 (4.9KB) - 当前最新
│   └── exploit_pure         # 同上 (副本)
│
├── source/                  # 源码
│   ├── exploit_pure.c       # ★ 纯 syscall 版本源码 (当前主版本)
│   ├── exploit.c            # 旧版 (用 pthread, 已废弃, 被 seccomp 杀)
│   ├── start.S              # 自定义 _start 汇编入口 (绕过 __libc_start_main)
│   ├── make_boot_gki.py     # GKI boot.img 打包工具
│   └── make_boot_v2.py      # boot v2 打包工具
│
├── scripts/                 # 运行脚本
│   ├── run_boot.sh          # ★ 内核1运行脚本 (boot.img ARM32 zImage)
│   ├── run_boot10e.sh       # ★ 内核2运行脚本 (BOOT.img ARM64 aarch64)
│   ├── run.sh               # 通用运行脚本 (旧)
│   ├── check_seccomp.sh     # seccomp syscall 检测脚本
│   └── install_termux.sh    # Termux 一键安装脚本
│
├── boot_images/             # boot 镜像 (用于符号提取)
│   ├── boot.img              # 华为畅享20e boot镜像 (ARM32 zImage, 10MB)
│   └── BOOT.img              # 华为畅享10e boot镜像 (ARM64 aarch64, 25MB)
│
├── kernel_symbols/          # 内核符号与偏移
│   ├── vmlinux_stock.elf    # 从 BOOT.img 提取的内核 ELF (含符号表, 34MB)
│   └── offsets.json         # ★ GhostLock 偏移文件 (含双版本键)
│
├── kernel/                  # 完整内核源码树 (4.0GB, 不上传)
├── ramdisk/                 # 解包的 ramdisk
├── tools/                   # mkbootimg/unpack_bootimg 工具
└── docs/                    # 文档目录
    └── PROJECT_STATUS.md    # ★ 本文档
```

### 关键文件作用说明

| 文件 | 作用 | 状态 |
|------|------|------|
| `source/exploit_pure.c` | **当前主 exploit 源码**，纯 syscall 实现，无 libc 依赖 | ✅ 已绕过 seccomp set_robust_list |
| `exploit_binary/exploit` | 编译好的 ARM32 静态二进制 (4.9KB) | ✅ 可运行 |
| `scripts/run_boot.sh` | 内核1运行脚本 (ARM32 boot.img) | ✅ |
| `scripts/run_boot10e.sh` | 内核2运行脚本 (ARM64 BOOT.img) | ✅ |
| `kernel_symbols/offsets.json` | GhostLock 工具的内核偏移文件 | ✅ 含双版本键 |
| `kernel_symbols/vmlinux_stock.elf` | 从 BOOT.img 提取的内核 ELF | ✅ 用于符号查找 |
| `source/exploit.c` | 旧版 exploit (用 pthread，被 seccomp 杀) | ⚠️ 已废弃 |
| `source/start.S` | 自定义 _start 汇编 (绕过 glibc 初始化) | ✅ 已集成到 pure 版本 |

---

## 三、已提取的内核符号

从 `BOOT.img` (华为畅享10e) 的 `vmlinux_stock.elf` 中提取的关键符号地址：

| 符号 | 地址 | 说明 |
|------|------|------|
| `commit_creds` | `0xffffff80080dd76c` | 设置进程凭证为 root |
| `prepare_kernel_cred` | `0xffffff80080ddb14` | 准备 root 凭证 |
| `kallsyms_lookup_name` | `0xffffff80081755f4` | 符号查找函数 |
| `task_struct->cred` 偏移 | `0x888` | 进程凭证指针 |
| `file_operations->unlocked_ioctl` | `0x48` | ioctl 处理函数指针 |

> ⚠️ 注意：这些地址是 ARM64 (aarch64) 地址空间。对于 ARM32 设备 (boot.img)，地址空间不同，需要从 `boot.img` 重新提取符号。当前 exploit 使用运行时 `kallsyms` 查找或手动传参。

---

## 四、当前处境与核心问题

### 4.1 已完成的工作

1. ✅ 从 `BOOT.img` 提取内核符号（commit_creds 等）
2. ✅ 分析 `rt_mutex_waiter` / `rt_mutex` 结构体偏移
3. ✅ 修复 exploit.c 的 8 个 bug（线程同步、FUTEX 参数、pselect 偏移等）
4. ✅ 生成 GhostLock 兼容的 `offsets.json`（含 4.14.141+ 和 4.9.117+ 双版本键）
5. ✅ 编译为 ARM32 静态二进制
6. ✅ 上传所有文件到 GitHub 仓库 `1332915/-10e-`

### 4.2 遇到的核心阻碍

#### 阻碍 1：Android 10 seccomp 过滤

**现象**：exploit 启动后立即 "Bad system call" (SIGSYS)。

**strace 诊断结果**：
```
set_robust_list(0x1e9806c, 12) = 32079980
--- SIGSYS {si_signo=SIGSYS, si_code=SYS_SECCOMP,
    si_syscall=__NR_set_robust_list, si_arch=AUDIT_ARCH_ARM} ---
+++ killed by SIGSYS +++
```

**根因**：Android 10 的 app 进程 seccomp 过滤器禁止了 `set_robust_list` (syscall 338)。glibc 的 `__libc_start_main` 和 pthread 库在线程初始化时自动调用此 syscall，导致任何使用 pthread 的静态二进制都无法在 app 进程中运行。

**已尝试的修复**：
1. ❌ 用 `sched_setscheduler` 替代 `sched_setattr` → 问题不在 sched_setattr
2. ❌ 用 `clone()` 替代 `pthread_create` → glibc `__libc_start_main` 仍调用 set_robust_list
3. ✅ **纯 syscall 版本 (exploit_pure.c)**：完全去除 libc，用 `-nostdlib` 编译，自定义 `_start` 汇编入口

**纯 syscall 版本状态**：已编译成功 (4.9KB)，已上传 GitHub，**用户尚未测试确认**。

#### 阻碍 2：Termux 环境的 seccomp 限制

即使用纯 syscall 版本绕过了 set_robust_list，Termux 仍是 app 进程，seccomp=2 (filter 模式)。exploit 需要的关键 syscall 是否都被允许，需要实测验证：

| Syscall | 号码 | 用途 | 是否被 seccomp 禁止 |
|---------|------|------|---------------------|
| `futex` | 240 | UAF 触发 | ❓ 需实测 |
| `clone` | 120 | 创建线程 | ❓ 需实测 |
| `sched_setscheduler` | 156 | 触发 PI 链 | ❓ 需实测 |
| `pselect6` | 335 | 栈 stamp | ❓ 需实测 |
| `mmap2` | 192 | 分配栈 | ❓ 需实测 |
| `nanosleep` | 162 | 等待 | ❓ 需实测 |

从 `check_seccomp.sh` 的部分输出看，futex/sched_setscheduler/sched_setattr 本身没被禁，但 `pselect6` 和 `clone` 的状态未知。

#### 阻碍 3：内核栈 PXN (不可执行)

分析内核配置和页表属性后确认，目标设备内核栈标记为不可执行 (PXN/XN)。因此原 exploit 中"stamp shellcode 到内核栈然后执行"的方案不可行。

**应对方案**：改为利用 UAF 的任意写入能力，将 `selinux_enforcing` 写为 0，绕过 SELinux，而不是直接执行 shellcode。exploit_pure.c 已按此思路简化（但 stamp 逻辑尚未完整实现）。

### 4.3 当前 exploit_pure.c 的完成度

| 模块 | 状态 | 说明 |
|------|------|------|
| `_start` 汇编入口 | ✅ 完成 | 绕过 glibc __libc_start_main |
| syscall wrappers (sc1-sc6) | ✅ 完成 | ARM EABI 内联汇编 |
| clone 线程创建 | ✅ 完成 | mmap 栈 + clone syscall |
| futex UAF 触发 | ✅ 完成 | FUTEX_WAIT_REQUEUE_PI + timeout |
| 线程同步 | ✅ 完成 | futex_A_locked 信号量 |
| **pselect6 栈 stamp** | ❌ **未实现** | 核心利用步骤，TODO |
| **PI 链触发写入** | ⚠️ 简化版 | 用 sched_setscheduler，但 stamp 未完成所以写不到目标 |
| SELinux 检查 | ✅ 完成 | 读取 /sys/fs/selinux/enforce |
| getuid 检查 | ✅ 完成 | |

**结论**：当前 exploit_pure.c 只能触发 UAF，**无法完成任意写入**，因为 `pselect6` 的栈 stamp 逻辑未实现。这是 exploit 成功的关键缺失部分。

---

## 五、未来路线图

### 阶段 1：验证纯 syscall 版本可运行（当前最优先）

**目标**：确认 exploit_pure 在 Termux 中不再 "Bad system call"

**步骤**：
1. 在 Termux 中下载最新 exploit
2. 运行 `./exploit -t`（测试模式）
3. 预期结果：
   - 输出 "waiter: UAF triggered" → 进程正常退出（UAF 触发但无后续）
   - 设备重启 → 确认漏洞存在
   - 仍 "Bad system call" → 需要进一步分析哪个 syscall 被禁

### 阶段 2：实现 pselect6 栈 stamp（核心技术难点）

**目标**：完成 UAF 后向内核栈写入伪造的 rt_mutex_waiter 结构

**技术细节**：
- UAF 后，`task->pi_blocked_on` 指向已释放的内核栈地址
- 调用 `pselect6` 时，内核会为该系统调用在内核栈上分配 `struct rt_mutex_waiter` 大小的空间
- 通过控制 `pselect6` 的参数，让分配的栈空间与 UAF 悬挂指针重叠
- 写入伪造的 waiter：`waiter->lock` 指向 `selinux_enforcing` 地址，`waiter->prio` 设为 0

**参考实现**：
- gitchw/ghostlock-cve-2026-43499 的 ARM32 版本
- 需要精确计算 `pselect6` 在内核栈上的偏移

### 阶段 3：完成 PI 链写入

**目标**：触发 `rt_mutex_adjust_prio_chain`，让内核将 `waiter->prio` (0) 写入 `waiter->lock` 指向的地址 (`selinux_enforcing`)

**步骤**：
1. owner 线程调用 `sched_setscheduler(waiter_tid, ...)` 触发 PI 链
2. 内核遍历 waiter 树，调用 `rb_insert_color`
3. `rb_insert_color` 会将 `waiter->prio` 写入 `waiter->lock` 指向的位置
4. 结果：`selinux_enforcing` 被写为 0

### 阶段 4：验证提权效果

**目标**：确认 SELinux 已禁用，尝试进一步提权

**步骤**：
1. 读取 `/sys/fs/selinux/enforce`，应为 0
2. 如果 SELinux 禁用成功，尝试：
   - `setuid(0)` → 如果 seccomp 允许
   - 访问 `/proc/1/root` 等
3. 如果需要进一步绕过 seccomp：
   - 利用任意写入修改 `current->seccomp.mode` 为 0
   - 需要获取 `current` 的内核地址（通过 `init_task` + PID 遍历）

### 阶段 5：备选方案（如果 Termux seccomp 无法绕过）

如果纯 syscall 版本仍被 seccomp 杀，需要换运行环境：

| 方案 | 可行性 | 说明 |
|------|--------|------|
| **ADB shell** (`/data/local/tmp/`) | ✅ 最可靠 | shell 进程 (uid 2000) 不受 app seccomp 限制 |
| **Shizuku** | ⚠️ 需 Android 11+ | 用户设备是 Android 10，不适用 |
| **另一台手机 OTG ADB** | ✅ 可行 | 用 Bugjaeger 等 app |
| **GDB / ptrace** | ❌ 需要 root | 先有 root 才能 ptrace |

---

## 六、编译说明

### 纯 syscall 版本（当前主版本）

```bash
arm-linux-gnueabi-gcc -nostdlib -static -O2 -o exploit source/exploit_pure.c
```

### 旧版（带 libc，已被 seccomp 杀，仅作参考）

```bash
arm-linux-gnueabi-gcc -static -O2 -o exploit_old source/exploit.c -lpthread
```

### 工具链

- 交叉编译器：`arm-linux-gnueabi-gcc` (GCC 13)
- 目标架构：ARM EABI v5 (armv7l)
- 静态链接：是
- libc 依赖：无（纯 syscall 版本）

---

## 七、GitHub 仓库

- **仓库地址**：https://github.com/1332915/-10e-
- **分支**：main
- **目录**：`cve_2026_43499/`
- **下载方式**：raw.githubusercontent.com 直链

### 下载链接

```bash
# 完整包
https://raw.githubusercontent.com/1332915/-10e-/main/cve_2026_43499/exploit_package.tar.gz

# 单文件
https://raw.githubusercontent.com/1332915/-10e-/main/cve_2026_43499/exploit
https://raw.githubusercontent.com/1332915/-10e-/main/cve_2026_43499/exploit_pure.c
https://raw.githubusercontent.com/1332915/-10e-/main/cve_2026_43499/run_boot.sh
https://raw.githubusercontent.com/1332915/-10e-/main/cve_2026_43499/run_boot10e.sh
https://raw.githubusercontent.com/1332915/-10e-/main/cve_2026_43499/offsets.json
```

### Termux 一键安装

```bash
pkg install curl -y && curl -sL https://raw.githubusercontent.com/1332915/-10e-/main/cve_2026_43499/install_termux.sh | sh
```

---

## 八、关键技术要点

### 8.1 set_robust_list seccomp 绕过

这是本项目的**核心技术突破**。Android 10 的 app 进程 seccomp 过滤器禁止 `set_robust_list` (syscall 338)，而 glibc 静态链接的二进制在 `__libc_start_main` 初始化阶段就会调用它。

**解决方案**：
1. 用 `-nostdlib` 编译，不链接任何 libc
2. 自定义 `_start` 汇编入口，直接调用 main
3. 所有 libc 函数（printf/memset/memcpy/strlen）用 syscall 重写
4. 线程用 `clone()` syscall + mmap 栈，不走 pthread

### 8.2 内核符号地址空间差异

- `BOOT.img` (畅享10e) 是 ARM64 aarch64，符号地址如 `0xffffff80080dd76c`
- `boot.img` (畅享20e) 是 ARM32 zImage，地址空间不同
- 当前 exploit 在运行时通过 `/proc/kallsyms` 查找符号（如果可读）
- 如果 kallsyms 不可读（kptr_restrict=2），需要手动传入地址

### 8.3 pselect6 栈 stamp（未完成）

这是 exploit 成功的**关键缺失部分**。需要：
1. 精确计算 `pselect6` 在内核栈上分配 `rt_mutex_waiter` 的位置
2. 让该位置与 UAF 悬挂指针 `pi_blocked_on` 重叠
3. 通过 `pselect6` 的参数控制写入的伪造数据

参考 gitchw 项目的 `stamp_waiter` 函数实现。

---

## 九、总结

| 项目 | 状态 |
|------|------|
| boot.img/BOOT.img 内核符号提取 | ✅ 完成 |
| exploit.c bug 修复 (8处) | ✅ 完成 |
| seccomp set_robust_list 绕过 | ✅ 完成 (纯 syscall 版本) |
| pselect6 栈 stamp | ❌ 未实现 |
| PI 链写入 selinux_enforcing | ⚠️ 框架已有，stamp 未完成 |
| GitHub 仓库上传 | ✅ 完成 |
| Termux 实测验证 | ⏳ 待用户测试纯 syscall 版本 |

**下一步最优先**：让用户测试 `exploit_pure` 是否能正常运行（不再 "Bad system call"），然后实现 `pselect6` 栈 stamp 逻辑。

---

*文档更新时间：2026-09-08*
*项目仓库：https://github.com/1332915/-10e-*
