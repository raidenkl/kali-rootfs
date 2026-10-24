# Kali Linux rootfs（LubanCat / RK3588 · RK3576）

用 `debootstrap` 构建一套 Kali Linux arm64 rootfs，最终打包成 **RKDevTool 可直接烧录的 `update.img`**。

```
scripts/build-rootfs.sh  →  build/rootfs/      rootfs 目录树（约 5~10 GB）
build/mk-image.sh        →  build/rootfs.img   ext4 根分区镜像
build/mk-updateimg.sh    →  build/update.img   整包（loader + uboot + boot + rootfs）
```

---

## 0. 开始之前：确认两样输入

| 需要准备 | 放到哪里 | 说明 |
|---|---|---|
| **内核 deb** | `overlay/usr/local/linux-image.deb` | 仓库自带一份 `6.1.99-rk3588`。**换内核或换 SoC 必须替换**，否则镜像里 `/lib/modules` 是空的，`modprobe` 全挂 |
| **Bootloader 三件套** | `build/firmware/` | `MiniLoaderAll.bin`、`uboot.img`、`boot.img`。仓库**不含**（体积大且与板卡绑定），从 SDK 编译后拷进来 |

两者的获取方式、以及"boot.img 与内核 deb 必须同一次编译"这条硬约束，见
[build/firmware/README.md](build/firmware/README.md)。

> **RK3576 说明**：首启的板卡识别表（`boot_init.sh` 的 `board_info()`）已覆盖 LubanCat 全系
> —— rk3128 / rk3528 / rk3562 / rk3566·rk3568 / rk3576 / rk3588·rk3588s。
> 万一遇到表里没有的 SoC，首启不会中断，会沿用 `boot.img` 自带的那份 dtb/uEnv —— 见
> [docs/native-build.md §5](docs/native-build.md#5-换内核--换-soc--换源)。

**主机要求**：Linux（x86_64 或 arm64；WSL2 可用，Windows 的 Git Bash 不可用）、
可用磁盘 **≥ 20 GB**、宿主内核 **≥ 5.10**（推荐 ≥ 5.14）。

---

## 1. 构建 rootfs

两种方式任选其一，产物相同。首次全量构建约 **40~90 分钟**（取决于网络与宿主架构），
打包 `rootfs.img` 再花 5~15 分钟。

### 方式一：Docker（推荐，环境零配置）

```bash
# x86_64 宿主机先注册一次 binfmt（arm64 宿主跳过这步）
docker run --rm --privileged multiarch/qemu-user-static --reset -p yes

# 构建
bash build/docker/build.sh
```

产物：`build/rootfs/` + `build/rootfs.img`（直接落在宿主机，不需要 `docker cp`）。

常用参数：

```bash
BOARD=lubancat-5 bash build/docker/build.sh          # 换板卡（默认 lubancat-4）
FORCE_REBUILD=1 bash build/docker/build.sh           # 忽略已有 rootfs.img，强制全量重建
GPU_STACK=both bash build/docker/build.sh            # 预装 GPU 用户态驱动（见第 4 节）
```

> 完整说明（前置条件、`--privileged` 的原因、手动 `docker build/run`、架构选择、耗时）：
> [build/docker/README.md](build/docker/README.md)

### 方式二：裸机（Debian 系发行版，Kali 已验证）

```bash
# 1) 依赖（x86_64 宿主要交叉构建 arm64，需要 qemu-user）
sudo apt-get install -y debootstrap util-linux mount e2fsprogs sudo \
  coreutils findutils tar gzip xz-utils zstd pigz \
  build-essential gcc-aarch64-linux-gnu bison flex bc libssl-dev libncurses-dev \
  u-boot-tools device-tree-compiler rsync kmod cpio fakeroot fakechroot \
  parted fdisk dosfstools mtools udev uuid-runtime git git-lfs \
  python3 python3-minimal python-is-python3 wget curl ca-certificates file procps

# x86_64 宿主额外装 qemu，并补一条兼容软链（新版 Debian/Kali 不再提供 -static 后缀）
sudo apt-get install -y qemu-user qemu-user-binfmt
sudo ln -sf /usr/bin/qemu-aarch64 /usr/bin/qemu-aarch64-static

# 2) 构建 rootfs 目录树（必须 root）
sudo bash scripts/build-rootfs.sh

# 3) 打包成 ext4 根分区镜像
cd build && bash mk-image.sh rootfs
```

> 注意：**不要**照抄老教程里的 `python2`（kali-rolling 已删该包，会直接装失败）；
> 也别装 `qemu-user-static`（已被 Debian 删除，且不再创建 `-static` 软链）。
> 依赖逐项用途、增量构建、换源、产物校验见 [docs/native-build.md](docs/native-build.md)。

---

## 2. 打包成 update.img

```bash
cd build
bash mk-updateimg.sh rk3588 emmc      # 用法：mk-updateimg.sh <chip> <storage>
```

- `chip`：`rk3588` / `rk3576` / `rk356x`（**默认是 rk3576，一定要显式写对**）
- `storage`：`emmc`（默认）/ `sd` / `spinor` / `sata` / `pcie`

产物：`build/update.img`（中间目录会自动清理）。

> ⚠️ `tools/pack/` 里的 `afptool`、`rkImageMaker` 是 **x86_64 静态二进制**，
> 所以**打包这一步要在 x86_64 主机上做**（arm64 主机需另配 qemu-x86_64）。
> 分区布局、烧录细节、首启行为：见 [docs/pack-and-flash.md](docs/pack-and-flash.md)。

---

## 3. 烧录与首次开机

1. 打开 **RKDevTool** → `升级固件` → `固件` 选择 `build/update.img`
2. 板卡进入 **Loader / Maskrom** 模式（按住 Recovery 上电，或短接 Maskrom）
3. 点 `升级`，等待完成并自动重启

**首次开机是两阶段**（正常现象，别以为卡死）：

| 阶段 | 动作 |
|---|---|
| 第一次启动 | 按 ADC 识别板卡型号 → 选择对应 DTB/uEnv → 扩展 rootfs 分区到整块存储 → **自动重启一次** |
| 第二次启动 | 直接进入登录界面 |

默认账号（**首次登录后请立刻修改**）：

| 用户 | 密码 | 说明 |
|---|---|---|
| `cat` | `temppwd` | 普通用户，在 `sudo` / `video` / `audio` 组 |
| `root` | `root` | 超级用户 |

串口参数：`115200 8N1`，控制台 `ttyFIQ0`。

---

## 4. 可选：GPU 硬件加速

Kali 自带的 Mesa 配不上 Rockchip 的闭源 kbase 驱动，默认是 **CPU 软渲染**。
需要加速时用 `GPU_STACK` 打开（`SOC` 决定用哪套闭源包）：

```bash
# RK3588（Mali-G610）：桌面 GL 加速 + 闭源 GLES/OpenCL 都装
SOC=rk3588 GPU_STACK=both bash build/docker/build.sh

# RK3576（Mali-G52）：闭源 GLES/OpenCL（该 SoC 的 blob 不含 Vulkan）
SOC=rk3576 GPU_STACK=libmali bash build/docker/build.sh
```

| GPU_STACK | 得到什么 |
|---|---|
| `none`（默认） | 无加速，GL 走 llvmpipe |
| `panfork` | **X11 桌面 GL / glamor 硬件加速**（唯一能给桌面加速的路线） |
| `libmali` | GLES / EGL / OpenCL / 无 X 的 GBM 直出；桌面仍软渲染 |
| `both` | 桌面走 panfork，计算按需走 libmali |

取舍、验证方法与踩过的坑见 [packages/gpu/README.md](packages/gpu/README.md)。
装完可在板上自检：

```bash
sudo bash scripts/check-gpu.sh --bench          # 分层体检
sudo bash scripts/panfork-verify.sh --verify    # 桌面 GL 验收
sudo bash scripts/libmali-verify.sh --nodisp    # 闭源计算通路验收（不需要显示器）
```

---

## 5. 目录结构

```
kali-rootfs/
├── config/           板卡/打包参数、GPU 宏（gpu-stack.conf）
├── overlay/          装进 rootfs 的配置文件（逐文件拷贝）
├── overlay-firmware/ WiFi/BT 固件（构建期合并进 /usr/lib/firmware）
├── packages/         额外 deb：arm64/（无条件安装）、gpu/<SOC>/
├── scripts/          build-rootfs.sh + 板卡侧自检脚本
├── build/            构建产物、打包脚本、firmware/（三件套放这里）
├── docs/             细节文档
└── Dockerfile        Docker 构建环境
```

---

## 6. 文档索引

| 文档 | 内容 |
|---|---|
| [build/docker/README.md](build/docker/README.md) | Docker 方案详解：前置条件、手动 build/run、`--privileged` 原因、容器适配、与裸机流程对照 |
| [docs/native-build.md](docs/native-build.md) | 裸机编译：依赖逐项说明、增量构建、换内核/换 SoC、产物校验 |
| [docs/pack-and-flash.md](docs/pack-and-flash.md) | 打包 update.img、分区布局、烧录、首启流程、默认账号 |
| [docs/troubleshooting.md](docs/troubleshooting.md) | 常见问题汇总（构建 / Docker / 打包 / 首启） |
| [build/firmware/README.md](build/firmware/README.md) | 三件套从哪来、boot.img 与内核 modules 的同源约定 |
| [packages/gpu/README.md](packages/gpu/README.md) | GPU 闭源包：选型、版本方向、两个 SoC 的能力差异 |

---

## 7. 高频问题

| 现象 | 处理 |
|---|---|
| `mk-updateimg.sh` 报缺 `MiniLoaderAll.bin` / `uboot.img` / `boot.img` | 三件套没放，见 [build/firmware/README.md](build/firmware/README.md) |
| 改了脚本但构建"什么都没做" | `build/rootfs.img` 已存在会短路；用 `FORCE_REBUILD=1` 或 `INCREMENTAL=1` |
| 首次开机进桌面后又重启了一次 | **设计行为**（扩容后应用新分区表/DTB），第二次开机正常 |
| 第二次开机卡在登录界面之前 / 黑屏 | 先确认 `boot.img` 与 `linux-image.deb` 是否同一次内核编译（模块与内核不匹配会卡在等待设备）；再看 [docs/troubleshooting.md](docs/troubleshooting.md) |

更多问题（apt 403、`EUNATCH`、binfmt、磁盘不足、Git Bash 路径）见
[docs/troubleshooting.md](docs/troubleshooting.md)。
