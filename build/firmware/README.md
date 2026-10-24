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

### 换 SoC（rk3576）时的额外注意

| 项 | rk3588 | rk3576 |
|---|---|---|
| 三件套 | rk3588 的 `MiniLoaderAll.bin` / `uboot.img` / `boot.img` | **必须整套换成 rk3576 的**（loader 决定可烧录芯片，混用会烧不上/起不来） |
| 内核 release | `6.1.99-rk3588` | `6.1.99-rk3576` |
| GPU 节点 | `fb000000.gpu`（arch 10.8.6，Valhall/CSF） | `27800000.gpu`（arch 7.4.0，Bifrost/JM） |
| 分区参数 | `config/pack/parameter-rk3588.txt` | `config/pack/parameter-rk3576.txt`（三份同构：mtdparts/uuid 一致） |

`KMOD_VER` 不再写死：`build-rootfs.sh` 从 `linux-image.deb` 里的 `lib/modules/<ver>/` 自动探测
（探测不到才回退 `6.1.99-<SOC>`），所以换内核只需换 deb；`mk-updateimg.sh` 的芯片参数也跟随 `SOC`。

## 内核 deb（`overlay/usr/local/linux-image.deb`）从哪来

> 这个文件**不入库**（`.gitignore` 里有 `overlay/usr/local/linux-image.deb`）：它体积大、且与 SoC 和内核版本强绑定。
> 克隆仓库后需要你自己放进去，文件名固定为 `linux-image.deb`。

内核源码：<https://github.com/LubanCat/kernel>。**它必须与 `boot.img` 出自同一棵树、同一次编译。**

两种产出方式：

```bash
# 方式 1：在 SDK 里构建内核（会顺带产出 deb，通常在 rockdev/ 或 extboot/kerneldeb/）
cd ~/LubanCat_SDK && ./build.sh kernel

# 方式 2：在内核源码树里直接打包（会同时产出 headers / libc-dev，只需要 image 那个）
make KDEB_COMPRESS=xz bindeb-pkg
```

拷进仓库时统一改名：

```bash
cp <linux-image-*.deb> overlay/usr/local/linux-image.deb
```

先确认它真的带 modules（否则镜像里 `/lib/modules` 会是空的）：

```bash
dpkg-deb -c overlay/usr/local/linux-image.deb | grep 'lib/modules/.*/modules.dep'
```

## ⚠ boot.img 与内核 modules 必须同一次编译

`boot.img` 是 /boot 分区镜像（ext2）：内含内核 `Image-<ver>`、`dtb/`、`uEnv/`、boot.scr，
**不含任何 .ko**——模块（`/lib/modules/<ver>/`，~300 个 ko）在 rootfs.img 里。

modules 的来源是 `overlay/usr/local/linux-image.deb`：构建期 `build-rootfs.sh` 的
**kmod 阶段**用 `dpkg-deb -x` 只解出其中的 `lib/modules` 固化进 rootfs，
deb 自带的 Image/dtb/uEnv **直接忽略**，`/boot` 从头到尾不被触碰。

构建期会把 deb 内 Image 与 boot.img 内 Image 的编译串（形如
`#12 SMP Sat Jul 25 01:27:03 UTC 2026`）做对照：**不一致只给 WARN 不阻断**——
同一棵内核树连续构建时模块 vermagic 相同、可正常加载（SDK 分步打包的常态）；
但若两者跨了内核版本/配置，modprobe 会失败，届时请让 deb 与 boot.img 同源
（SDK 里重打 deb 后同步更新 boot.img）。2026-09-24 曾因首启安装 deb 覆盖
/boot（#12 被降级成 #11）导致第二次开机卡死，现已结构性杜绝。
