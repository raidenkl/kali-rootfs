# Kali Linux rootfs（LubanCat）

用 `debootstrap` 做一套 Kali Linux arm64 rootfs，再打包成 RKDevTool 能直接烧的 `update.img`。整个过程三个脚本串联，产物逐级叠加：

```
scripts/build-rootfs.sh  →  build/rootfs/      rootfs 目录树（约 5~10 GB）
build/mk-image.sh        →  build/rootfs.img   ext4 根分区镜像
build/mk-updateimg.sh    →  build/update.img   整包（loader + uboot + boot + rootfs）
```

---

## 0. 开工前先备两样东西

| 需要准备 | 放到哪里 | 说明 |
|---|---|---|
| 内核 deb | `overlay/usr/local/linux-image.deb` | 仓库里没有（`.gitignore` 忽略了），得自己放目标板内核的 `linux-image-*.deb`。换内核或换 SoC 时都要跟着换，否则镜像里 `/lib/modules` 是空的，`modprobe` 一个都加载不了 |
| Bootloader 三件套 | `build/firmware/` | `MiniLoaderAll.bin`、`uboot.img`、`boot.img`。仓库不带，体积大且跟板卡绑定，从 SDK 编译后拷进来 |

这两样东西从哪来，以及「boot.img 必须和内核 deb 同一次编译」这条规矩，[build/firmware/README.md](build/firmware/README.md) 讲得比较细。

板卡型号不用你操心。首启脚本里有一张识别表（`boot_init.sh` 的 `board_info()`），LubanCat 全系都在里面，从 rk3128 一路到 rk3588s。表里没有的 SoC 也不会卡住，会沿用 `boot.img` 自带的那份 dtb/uEnv 照常开机，只多打一行 WARN。要加型号，见 [docs/native-build.md §5](docs/native-build.md#5-换内核--换-soc--换源)。

主机方面：Linux 就行（x86_64 或 arm64 都可以，WSL2 也能用，Windows 的 Git Bash 不行），磁盘留 20 GB 以上，宿主内核 5.10 起步、建议 5.14 以上。

---

## 1. 构建 rootfs

两种方式任选，产物完全一样。首次全量构建大约40到90分钟，看网络和宿主架构；之后打包 `rootfs.img` 再花5到15分钟。

### 方式一：Docker（推荐，环境零配置）

```bash
# x86_64 宿主机先注册一次 binfmt（arm64 宿主跳过这步）
docker run --rm --privileged multiarch/qemu-user-static --reset -p yes

# 构建
bash build/docker/build.sh
```

产物直接落在宿主机的 `build/rootfs/` 和 `build/rootfs.img`，不用 `docker cp`。

常用参数：

```bash
SOC=rk3576 bash build/docker/build.sh       # 换 SoC（默认 rk3588；rk3566/68 写 rk356x）
FORCE_REBUILD=1 bash build/docker/build.sh  # 忽略已有 rootfs.img，强制全量重建
GPU_STACK=both bash build/docker/build.sh   # 预装 GPU 用户态驱动（见第 4 节）
```

构建期只按 SoC 分类（`rk3588` / `rk3576` / `rk356x`），不需要告诉它具体是哪块板子——5 还是 5IOB、3 还是 3IO，都是首启时按 ADC 读出来的。随 SoC 要一起换的只有三样：`build/firmware` 三件套、`overlay/usr/local/linux-image.deb`，以及打包时的 `chip` 参数。

Docker 那条路的前置条件、为什么必须 `--privileged`、手动 `docker build/run`、耗时估算，都在 [build/docker/README.md](build/docker/README.md)。

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

老教程里的 `python2` 别照抄，kali-rolling 早删了这个包，装只会报错；`qemu-user-static` 也别装，Debian 已删包、也不再建 `-static` 软链。每项依赖的作用、增量构建、换源、产物校验，都在 [docs/native-build.md](docs/native-build.md)。

常用参数（写环境变量或直接用命令行开关，两者等价）：

```bash
sudo INCREMENTAL=1 bash scripts/build-rootfs.sh                  # 增量：复用已完成的重型阶段
sudo FORCE_REBUILD=1 bash scripts/build-rootfs.sh                # 从零全量重建（连阶段状态一起清）
sudo APT_REFRESH=1 INCREMENTAL=1 bash scripts/build-rootfs.sh    # 增量模式下也重跑 apt，拉最新包
sudo SOC=rk3576 GPU_STACK=libmali bash scripts/build-rootfs.sh   # 换 SoC、预装 GPU 驱动
sudo bash scripts/build-rootfs.sh --incremental                  # 等价写法，另有 --force / --apt-refresh
```

增量模式只重跑廉价的定制阶段（overlay 拷贝、服务使能、配置覆写），所以改完 `overlay/` 里的东西，几十秒就能拿到新的 rootfs 目录树。阶段完成情况记在 `build/.build-state/`，删掉它等于回到全量。

`SOC` 决定取哪份 libmali 包、以及打包时的 chip 参数；`GPU_STACK` 见第 4 节。内核 modules 的版本目录（`KMOD_VER`）默认从 deb 的 `lib/modules/` 自动探测，探测不到才回退到 `6.1.99-<SOC>`，一般不用手动指定。

---

## 2. 打包成 update.img

```bash
cd build
bash mk-updateimg.sh rk3588 emmc      # 用法：mk-updateimg.sh <chip> <storage>
```

- `chip`：`rk3588` / `rk3576` / `rk356x`。脚本默认值是 rk3576，容易踩，**建议每次都显式写**
- `storage`：`emmc`（默认）/ `sd` / `spinor` / `sata` / `pcie`

产物是 `build/update.img`，中间目录会自动清理。

`tools/pack/` 下的 `afptool` 和 `rkImageMaker` 是 x86_64 静态二进制，所以打包这一步必须在 x86_64 机器上做；arm64 主机得另配 qemu-x86_64。分区布局、烧录细节、首启行为见 [docs/pack-and-flash.md](docs/pack-and-flash.md)。

---

## 3. 烧录与首次开机

1. 打开 RKDevTool，切到「升级固件」，`固件` 选 `build/update.img`
2. 板卡进 Loader / Maskrom 模式（按住 Recovery 上电，或短接 Maskrom）
3. 点「升级」，等它烧完自动重启

第一次开机会重启一次，这是设计好的两阶段，别当成卡死：

| 阶段 | 动作 |
|---|---|
| 第一次启动 | 按 ADC 识别板卡型号 → 选对应 DTB/uEnv → 把 rootfs 分区扩到整块存储 → 自动重启一次 |
| 第二次启动 | 直接进登录界面 |

默认账号如下，首次登录后记得改：

| 用户 | 密码 | 说明 |
|---|---|---|
| `cat` | `temppwd` | 普通用户，在 `sudo` / `video` / `audio` 组 |
| `root` | `root` | 超级用户 |

串口参数 `1500000 8N1`，控制台是 `ttyFIQ0`。

---

## 4. 可选：GPU 硬件加速

Kali 自带的 Mesa 驱动不了 Rockchip 的闭源 kbase，所以默认是 CPU 软渲染。想要加速就打开 `GPU_STACK`（具体装哪套包由 `SOC` 决定）：

```bash
# RK3588（Mali-G610）：桌面 GL 加速 + 闭源 GLES/OpenCL 都装
SOC=rk3588 GPU_STACK=both bash build/docker/build.sh

# RK3576（Mali-G52）：闭源 GLES/OpenCL（这颗的 blob 不含 Vulkan）
SOC=rk3576 GPU_STACK=libmali bash build/docker/build.sh

# RK3566 / RK3568（Mali-G52 2EE，与 rk3576 同族，共用同一份 blob）
SOC=rk356x GPU_STACK=libmali bash build/docker/build.sh
```

| GPU_STACK | 得到什么 |
|---|---|
| `none`（默认） | 无加速，GL 走 llvmpipe |
| `panfork` | X11 桌面 GL / glamor 硬件加速，唯一能给桌面加速的路线（仅 rk3588） |
| `libmali` | GLES / EGL / OpenCL / 无 X 的 GBM 直出；桌面仍软渲染 |
| `both` | 桌面走 panfork，计算按需走 libmali（仅 rk3588） |

有个限制得先讲清楚：rk3576、rk3566、rk3568 这三颗（都是 Mali-G52 / Bifrost）**只能用 `none` 或 `libmali`**。panfork 依赖的 Mesa kbase 后端在这颗 GPU 上会直接崩——`KBASE_IOCTL_MEM_JIT_INIT` 返回 ENOMEM，驱动跟着 double free，Xorg 抛 `Caught signal 6` 退出，lightdm 就起不来了。`both` 里含 panfork，同样不能用。具体现象和排查过程在 [docs/troubleshooting.md](docs/troubleshooting.md)。

rk3566/rk3568 统一写 `SOC=rk356x`，GPU 用户态跟 rk3576 是同一份 bifrost 包，不需要单独移植；要换的只有内核 deb 和 `build/firmware/` 三件套。

选型理由、验证方法、踩过的坑整理在 [packages/gpu/README.md](packages/gpu/README.md)。装完可以在板上跑这几条自检：

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
| 改了脚本但构建「什么都没做」 | `build/rootfs.img` 已存在会短路；用 `FORCE_REBUILD=1` 或 `INCREMENTAL=1` |
| 首次开机进桌面后又重启了一次 | 正常，扩容后要应用新分区表/DTB，第二次开机就好 |
| 第二次开机卡在登录界面之前 / 黑屏 | 先确认 `boot.img` 和 `linux-image.deb` 是不是同一次内核编译（模块与内核对不上会卡在等设备）；再看 [docs/troubleshooting.md](docs/troubleshooting.md) |

其余问题（apt 403、`EUNATCH`、binfmt、磁盘不足、Git Bash 路径）都在 [docs/troubleshooting.md](docs/troubleshooting.md)。
