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
