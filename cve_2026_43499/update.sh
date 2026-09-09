#!/system/bin/sh
# ── CVE-2026-43499 项目更新脚本 (多通道, 自动校验 hash) ──
# 用法: sh update.sh
# 会把 exploit / run_boot.sh 更新到 v2.4 并校验, 旧文件备份为 .bak

cd ~/cve_2026_43499 2>/dev/null || { echo "[!] cd 失败, 请先创建 ~/cve_2026_43499"; exit 1; }

EXP_HASH="63d396ed48931e11fd5156c24afdbfad6abdfaed0745299e0af8b762683f0df6"

# 多通道 (commit 113a552 = v2.5):
# 1. jsDelivr CDN (国内一般可达)
# 2. github.com raw 路径 (不走 raw.githubusercontent.com)
# 3. raw.githubusercontent.com (直连, 有时可达)
CHANNELS='
https://cdn.jsdelivr.net/gh/1332915/-10e-@b81403a/cve_2026_43499/exploit
https://github.com/1332915/-10e-/raw/b81403a/cve_2026_43499/exploit
https://raw.githubusercontent.com/1332915/-10e-/main/cve_2026_43499/exploit
'

echo "[*] 目标 hash: $EXP_HASH"
got=0
for u in $CHANNELS; do
    echo "[*] 尝试: $u"
    if curl -fsSL --connect-timeout 12 --max-time 60 -o exploit.new "$u" 2>/dev/null; then
        h=$(sha256sum exploit.new | cut -d' ' -f1)
        echo "    hash: $h"
        if [ "$h" = "$EXP_HASH" ]; then
            echo "[+] 校验通过, 更新成功"
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
    echo "[!] 所有通道失败。请检查网络 (可尝试切换 Wi-Fi/移动数据) 后重试。"
    echo "[!] 或手动下载后放入: ~/cve_2026_43499/exploit"
    exit 1
fi

echo "[*] 当前版本:"
sha256sum exploit
echo "[*] 运行: sh run_boot.sh"
