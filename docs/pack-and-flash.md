# 打包 update.img · 烧录 · 首次开机

前置：已经产出 `build/rootfs.img`（见 [native-build.md](native-build.md) 或
[../build/docker/README.md](../build/docker/README.md)）。

---

## 1. 前置检查

| 需要 | 位置 | 说明 |
|---|---|---|
| `rootfs.img` | `build/rootfs.img` | 由 `mk-image.sh` 生成 |
| `MiniLoaderAll.bin` | `build/firmware/` | DDR 初始化 + 最小系统，**决定可烧录的芯片** |
| `uboot.img` | `build/firmware/` | U-Boot |
| `boot.img` | `build/firmware/` | extboot：内核 Image + DTB + extlinux + logo |
| 打包工具 | `tools/pack/` | `afptool` / `rkImageMaker`，**x86_64 静态二进制** |

三件套仓库**不提供**，需要从 LubanCat SDK 编译后拷入，见
[../build/firmware/README.md](../build/firmware/README.md)。

> 打包必须在 **x86_64** 主机上做。arm64 主机（例如直接在板子上）跑不了这两个工具，
> 除非另装 `qemu-x86_64` + binfmt。

---

## 2. 打包

```bash
cd build
bash mk-updateimg.sh rk3588 emmc
```

| 参数 | 取值 | 说明 |
|---|---|---|
| `chip` | `rk3588` / `rk3576` / `rk356x` | **默认是 rk3576**，务必显式写对；它决定用哪份 `config/pack/parameter-*.txt` 和 loader 芯片标识 |
| `storage` | `emmc`（默认）/ `sd` / `spinor` / `spinand` / `sata` / `pcie` | 目标存储介质 |

产物：

```
build/update.img          ← RKDevTool 直接选这个
```

中间目录 `build/update-img/` 会在成功后自动清理。

打包做了什么（与 LubanCat SDK 一致）：

1. `afptool -pack`：按 `package-file` 把 `parameter.txt` + loader + uboot + boot + rootfs 打成 AFP 容器
2. `rkImageMaker`：套上带芯片标识的 RK 头，得到 `update.img`
3. 芯片标识从 `MiniLoaderAll.bin` 偏移 21 字节读取后传给 `rkImageMaker`

---

## 3. 分区布局

三份 `parameter-*.txt` 完全同构：

| 分区 | 起始 | 大小 | 内容 |
|---|---|---|---|
| `uboot` (p1) | 16 MB | 16 MB | `uboot.img`（+ loader 由 RKDevTool 单独写入） |
| `boot` (p2) | 32 MB | 256 MB | `boot.img`（内核 + DTB + extlinux + logo） |
| `rootfs` (p3) | 288 MB | 剩余全部（`grow`） | `rootfs.img`，首启自动扩容到整块存储 |

---

## 4. 烧录（RKDevTool）

**整包烧录（推荐）**

1. 打开 RKDevTool，切到 `升级固件` 页
2. `固件` → 选择 `build/update.img`
3. 板卡进入 **Loader 模式**（系统内 `reboot loader`）或 **Maskrom 模式**（按住 Recovery 上电 / 短接）
4. 工具识别到设备后点 `升级`，等待完成，板卡自动重启

**只更新某个分区（调试常用）**

切到 `下载镜像` 页，按分区名分别指定：

| 分区 | 文件 |
|---|---|
| `boot` | `build/firmware/boot.img` |
| `rootfs` | `build/rootfs.img` |

`rootfs` 分区被覆盖后，`/boot/boot_dilatation_init` 等标记仍在 boot 分区，不会重复扩容。

---

## 5. 首次开机流程

**第一次启动会自动重启一次，这是设计行为。**

```
上电
 └─ boot_init.service
     ├─ 读 ADC 识别板卡型号（LubanCat-4/5/...）
     ├─ 选择对应 DTB（/boot/rk-kernel.dtb）与 uEnv（/boot/uEnv/uEnv.txt）
     ├─ 挂载 /boot 并写入 fstab（必要时）
     ├─ 写标记 /boot/boot_init
     ├─ 按真实根设备（eMMC 是 mmcblk0、SD 卡是 mmcblk1）扩容 p3
     ├─ 写标记 /boot/boot_dilatation_init
     └─ systemctl --no-block reboot        ← 自动重启
 └─ 第二次启动
     └─ 正常进入 lightdm 登录界面
```

扩容这一段不写死设备名，而是用 `findmnt -no SOURCE /` 找当前根分区、再用 `lsblk`
拿到所在磁盘和分区号：从 eMMC 启动得到 `mmcblk0p3` / `mmcblk0`，从 SD 卡启动得到
`mmcblk1p3` / `mmcblk1`（此时 `mmcblk0` 是板载 eMMC，不能碰）。拿到之后仍是原来那套流程：
`sgdisk -e` → `growpart` → `partx -u` → `resize2fs`，执行前先比一次分区大小与文件系统大小，已占满就跳过。

串口：`1500000 8N1`，控制台 `ttyFIQ0`。所有首启动作都会以 `[boot_init]` 前缀打印，
失败时会打印 `[boot_init] FAILED at line N`。

---

## 6. 默认账号

| 用户 | 密码 | 权限 |
|---|---|---|
| `cat` | `temppwd` | 普通用户，`sudo` / `video` / `audio` 组 |
| `root` | `root` | 超级用户 |

> ⚠️ 这两个密码写死在 `scripts/build-rootfs.sh` 里，属于**公开的默认值**。
> 板子联网前请先改掉：`passwd`、`passwd cat`；或者构建前直接改脚本。

---

## 7. 排障

| 现象 | 可能原因 | 处理 |
|---|---|---|
| 烧录工具报"下载失败"/校验错 | `chip` 参数与 `MiniLoaderAll.bin` 不匹配 | 换对芯片参数重打包；loader 必须与 SoC 一致 |
| 第一次开机后自动重启 | 正常（扩容 + 应用新 DTB） | 无需处理 |
| 第二次开机卡在登录界面之前 | 内核与 modules/DTB 不匹配，或 rootfs 损坏 | 串口看 `[boot_init]` 与 `systemctl` 卡在哪个单元；确认 `boot.img` 与 `linux-image.deb` 同源 |
| HDMI 黑屏且串口刷 `dwhdmi-rockchip ... use tmds mode` | Xorg 崩溃 → lightdm 反复重启 | 多为 libmali 全局注入导致，见 [../packages/gpu/README.md](../packages/gpu/README.md) |
| 没有 WiFi | `/usr/lib/firmware` 被嵌了一层（`firmware/firmware/`） | 检查镜像里是否存在 `/usr/lib/firmware/firmware`；新版构建已修，旧镜像需重建 |
| 磁盘空间没扩 | `growpart` 失败或被跳过 | 看串口 `[boot_init]` 输出；确认 `/boot/boot_dilatation_init` 是否被误建 |

更多构建期问题见 [troubleshooting.md](troubleshooting.md)。
