#!/system/bin/sh
# probe_kernel.sh - 从手机本地探测内核信息泄露源 (Termux 下执行)
# 用法: sh probe_kernel.sh > probe_out.txt 2>&1   (然后把 probe_out.txt 发回分析)
echo "===== [1] uname ====="
uname -a
echo "===== [2] /proc/version ====="
cat /proc/version 2>&1
echo "===== [3] kptr_restrict (0=地址可见 1=仅root 2=全隐藏) ====="
cat /proc/sys/kernel/kptr_restrict 2>&1
echo "===== [4] /proc/kallsyms 权限与内容 ====="
ls -l /proc/kallsyms 2>&1
head -3 /proc/kallsyms 2>&1
grep -E " selinux_enforcing$| selinux_state$| init_task$| init_cred$| kptr_restrict$| commit_creds$| modprobe_path$" /proc/kallsyms 2>&1
echo "===== [5] /proc/iomem (内核镜像/外设映射) ====="
head -25 /proc/iomem 2>&1
echo "===== [6] /sys/module/kernel/sections/ (内核段基址!) ====="
ls -l /sys/module/kernel/sections/ 2>&1
cat /sys/module/kernel/sections/.text 2>&1
cat /sys/module/kernel/sections/.data 2>&1
cat /sys/module/kernel/sections/.bss 2>&1
echo "===== [7] 其他模块 sections (取前3个) ====="
for m in $(ls /sys/module/ 2>/dev/null | head -3); do
  echo "--- module: $m"
  ls /sys/module/$m/sections/ 2>&1
  cat /sys/module/$m/sections/.text 2>&1
done
echo "===== [8] /proc/timer_list ====="
head -8 /proc/timer_list 2>&1
echo "===== [9] /proc/sched_debug ====="
head -5 /proc/sched_debug 2>&1
echo "===== [10] dmesg ====="
dmesg 2>&1 | head -10
echo "===== [11] /proc/kcore 权限 ====="
ls -l /proc/kcore 2>&1
echo "===== [12] 固件版本信息 ====="
getprop ro.build.version.release 2>&1
getprop ro.build.version.security_patch 2>&1
getprop ro.product.model 2>&1
echo "===== DONE ====="
