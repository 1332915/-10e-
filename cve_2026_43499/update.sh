#!/system/bin/sh
# ── CVE-2026-43499 项目更新脚本 v3.2.1 ──
# 用法: sh update.sh
# 更新内容 (一次性全部更新):
#   exploit          (二进制, 强制 sha256 校验)
#   run_boot.sh      (Termux 主运行脚本, 含 -L 崩溃日志)
#   run.sh           (通用运行脚本)
#   run_boot10e.sh   (10e 内核运行脚本)
# 旧 exploit 备份为 exploit.bak

cd ~/cve_2026_43499 2>/dev/null || { echo "[!] cd 失败, 请先创建 ~/cve_2026_43499"; exit 1; }

# ── 版本与通道 ──
# 所有文件统一引用最新 HEAD commit (@56ef52d = v3.2.1)
COMMIT="227902d"
BASE="https://cdn.jsdelivr.net/gh/1332915/-10e-@${COMMIT}/cve_2026_43499"
EXP_HASH="7b8245d640984cb89a16fbf949f6356f621b284abc7e8a4aa8f72c829a4332f5"

# 备用通道 (CDN 缓存异常时逐个尝试)
BACKUP_BASE="https://github.com/1332915/-10e-/raw/${COMMIT}/cve_2026_43499"

# ── 1) 更新 exploit (多通道 + hash 校验) ──
echo "[*] 目标 hash: $EXP_HASH"
got=0
for u in "${BASE}/exploit" "${BACKUP_BASE}/exploit"; do
    echo "[*] 尝试: $u"
    if curl -fsSL --connect-timeout 12 --max-time 60 -o exploit.new "$u" 2>/dev/null; then
        h=$(sha256sum exploit.new | cut -d' ' -f1)
        echo "    hash: $h"
        if [ "$h" = "$EXP_HASH" ]; then
            echo "[+] 校验通过, exploit 更新成功"
            [ -f exploit ] && cp exploit exploit.bak 2>/dev/null
            mv exploit.new exploit
            chmod 755 exploit
            got=1
            break
        else
            echo "[!] hash 不符 (可能是 CDN 缓存旧版), 换下一通道"
        fi
    else
        echo "[!] 下载失败, 换下一通道"
    fi
done
rm -f exploit.new

if [ "$got" = "0" ]; then
    echo "[!] exploit 所有通道失败。请检查网络后重试, 或手动下载放入: ~/cve_2026_43499/exploit"
    exit 1
fi

# ── 2) 更新运行脚本 (下载 + 关键标记校验, 失败保留原文件) ──
echo ""
echo "[*] 更新运行脚本 (run_boot.sh / run.sh / run_boot10e.sh)..."
for f in run_boot.sh run.sh run_boot10e.sh; do
    ok=0
    for u in "${BASE}/${f}" "${BACKUP_BASE}/${f}"; do
        if curl -fsSL --connect-timeout 12 --max-time 60 -o "${f}.new" "$u" 2>/dev/null; then
            if [ -s "${f}.new" ] && grep -q "CVE-2026-43499" "${f}.new" 2>/dev/null; then
                chmod 755 "${f}.new"
                mv -f "${f}.new" "$f"
                echo "[+] $f 更新成功 (v3.2)"
                ok=1
                break
            else
                echo "[!] $f 内容异常, 换下一通道"
            fi
        else
            echo "[!] $f 下载失败, 换下一通道"
        fi
        rm -f "${f}.new"
    done
    if [ "$ok" = "0" ]; then
        echo "[!] $f 更新失败, 保留原文件 (不影响 exploit 使用)"
    fi
done

# ── 3) 结果 ──
echo ""
echo "[*] 当前版本:"
sha256sum exploit
echo "[*] 运行脚本: $(ls -la run_boot.sh 2>/dev/null | awk '{print $5}' 2>/dev/null || echo '?') bytes"
echo "[*] 运行: sh run_boot.sh   (全模式)"
echo "[*]        sh run_boot.sh -t   (先验证触发)"
