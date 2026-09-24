# build/firmware — Bootloader / 内核固件目录

本目录存放打包 update.img 所需的板级固件，**不入库**（二进制体积大且与板卡/内核版本绑定），
由用户自行从 SDK 构建后拷贝进来。

## 需要的文件

| 文件 | 说明 |
|---|---|
| `MiniLoaderAll.bin` | Loader（DDR 初始化 + 最小系统），决定可烧录的芯片 |
| `uboot.img` | U-Boot 固件 |
| `boot.img` | extboot 分区镜像（内核 Image + DTB + extlinux + initrd + logo，ext2 格式） |

三个文件的分区名固定为 `uboot`(p1) / `boot`(p2) / `rootfs`(p3)，
与 `config/pack/parameter-*.txt` 的 CMDLINE 一致，rootfs.img 由 `build/mk-image.sh` 生成。

## 从 LubanCat_SDK 获取

```bash
cd ~/LubanCat_SDK
./build.sh            # 选择对应板卡的 defconfig（注意芯片要与目标板一致）
./build.sh uboot kernel
cp rockdev/{MiniLoaderAll.bin,uboot.img,boot.img} ~/kali-rootfs/build/firmware/
```

> 同一套 rootfs.img 配不同芯片时，只需要换 firmware/ 里的三个文件 +
> 打包时选对芯片参数（`mk-updateimg.sh rk356x|rk3576|rk3588`），rootfs 本身不用重建。

## ⚠ boot.img 与内核 modules 必须同一次编译

`boot.img` 是 /boot 分区镜像（ext2）：内含内核 `Image-<ver>`、`dtb/`、`uEnv/`、boot.scr，
**不含任何 .ko**——模块（`/lib/modules/<ver>/`，~300 个 ko）在 rootfs.img 里。

modules 的来源是 `overlay/usr/local/linux-image.deb`：构建期 `build-rootfs.sh` 的
**kmod 阶段**会把它在 chroot 里安装后清掉 /boot（参考 LubanCat SDK 通道 A），
只把 `lib/modules` 留在 rootfs 中。

因此：**重新编译内核时，boot.img 和 linux-image.deb 必须一起更新**（同一份构建产物）。
否则烧录后内核与 modules 不匹配（vermagic 不同 → modprobe 全挂）。构建期的 kmod
阶段会提取两者的编译串（形如 `#12 SMP Sat Jul 25 01:27:03 UTC 2026`）做一致性校验，
不一致直接 FATAL 拒绝出镜像——2026-09-24 曾因 deb(#11) 旧于 boot.img(#12) 且首启
安装覆盖 /boot，导致第二次开机卡死在 lightdm 之前。
