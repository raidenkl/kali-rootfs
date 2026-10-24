# 裸机编译 rootfs

不使用 Docker，直接在 Debian 系主机上跑 `scripts/build-rootfs.sh` + `build/mk-image.sh`。
仓库在 **Kali-rolling** 上验证；Debian / Ubuntu 的包名基本一致，个别可能需要微调。

---

## 1. 前置条件

| 项 | 要求 |
|---|---|
| 主机 | Linux，**x86_64 或 arm64**；WSL2 可以，Windows Git Bash 不行（`F:\` 路径会炸） |
| 权限 | `build-rootfs.sh` 需要 **root**（内部要 `mount`、`chroot`、`mknod`） |
| 磁盘 | **≥ 20 GB** 可用（rootfs 树 5~10 GB + img 5~8 GB + swapfile 2 GB + apt 缓存） |
| 内核 | 宿主内核 **≥ 5.10**（推荐 ≥ 5.14）。Kali-rolling 的 systemd 260+ 低于此基线会让 chroot 内 dpkg 失败 |
| 网络 | 默认从阿里云拉包，可改（见第 5 节） |

---

## 2. 安装依赖

### 2.1 通用依赖

```bash
sudo apt-get install -y debootstrap util-linux mount e2fsprogs sudo \
  coreutils findutils tar gzip xz-utils zstd pigz \
  build-essential gcc-aarch64-linux-gnu bison flex bc libssl-dev libncurses-dev \
  u-boot-tools device-tree-compiler rsync kmod cpio fakeroot fakechroot \
  parted fdisk dosfstools mtools udev uuid-runtime git git-lfs \
  python3 python3-minimal python-is-python3 wget curl ca-certificates file procps
```

按用途：

| 组 | 用在哪 |
|---|---|
| `debootstrap` | 生成 kali-rolling 基础系统 |
| `e2fsprogs` | `mk-image.sh` 的 `mkfs.ext4` / `e2fsck` / `resize2fs` |
| `util-linux mount` | 脚本里的 `mount` / `umount` / `findmnt` |
| `build-essential gcc-aarch64-linux-gnu` | 交叉工具链（容器/内核相关构建需要） |
| `parted fdisk dosfstools mtools` | 分区与 FAT 操作 |
| `rsync kmod cpio fakeroot fakechroot` | rootfs / initramfs 操作 |
| `u-boot-tools device-tree-compiler` | `mkimage` / `dtc` |
| `python3 python-is-python3` | 部分工具脚本依赖 |

### 2.2 x86_64 主机额外：qemu + binfmt

rootfs 是 arm64，而 `debootstrap` 第二阶段要在 chroot 里执行 arm64 的 `apt`/`dpkg`，需要 qemu 用户态模拟。

```bash
sudo apt-get install -y qemu-user qemu-user-binfmt
sudo systemctl restart systemd-binfmt
sudo ln -sf /usr/bin/qemu-aarch64 /usr/bin/qemu-aarch64-static   # 关键

# 验证：应输出 enabled
cat /proc/sys/fs/binfmt_misc/qemu-aarch64
```

两个必须知道的坑：

1. **不要装 `qemu-user-static`**：Debian #1124747（2026-01）已删除该包，`apt install` 虽能成功但**不再创建 `-static` 软链**。
2. **必须补 `-static` 软链**：`build-rootfs.sh` 用 `[ -f /usr/bin/qemu-aarch64-static ]` 判断走不走交叉流程。
   没有这条软链 → 静默改走"原生"分支，x86_64 上会失败或行为异常。

arm64 主机是原生执行，**不需要** qemu，也不需要 binfmt。

---

## 3. 构建

```bash
# 1) 生成 rootfs 目录树（约 40~90 分钟，视网络）
sudo bash scripts/build-rootfs.sh

# 2) 打包 ext4 根分区镜像（约 5~15 分钟）
cd build && bash mk-image.sh rootfs
```

产物：

```
build/rootfs/        rootfs 目录树
build/rootfs.img     ext4 根分区镜像（可直接 dd）
```

> `build-rootfs.sh` 内部会自己 `cd` 到仓库根再进 `build/`，所以在哪个目录执行都可以；
> 但 `mk-image.sh` 的输出路径是**当前目录**，必须在 `build/` 下执行。

### 脚本做了什么（按顺序）

| 阶段 | 内容 |
|---|---|
| 1 | `debootstrap` 生成 kali-rolling arm64 基础系统 |
| 2 | chroot 内 `apt` 安装软件包（含 XFCE 桌面） |
| 2.5 | **可选** GPU 用户态驱动栈（`GPU_STACK`） |
| 3 | 创建 2 GB swapfile |
| 4 | 安装 `packages/arm64/*.deb` |
| — | 逐文件拷贝 `overlay/`（配置、服务、脚本） |
| 5 | 合并 `overlay-firmware/` 的 WiFi/BT 固件 |
| kmod | 从 `linux-image.deb` 只解出 `lib/modules` 固化进 rootfs（**不碰 /boot**） |

每个重型阶段都有指纹（`build/.build-state/stages/*`），输入没变就跳过。

---

## 4. 增量构建与缓存

| 目的 | 命令 |
|---|---|
| 只改了 `overlay/`，想快速出新镜像 | `INCREMENTAL=1 sudo bash scripts/build-rootfs.sh` |
| 想重新拉最新软件包 | `APT_REFRESH=1 INCREMENTAL=1 sudo bash scripts/build-rootfs.sh` |
| 从零全量重建 | `FORCE_REBUILD=1 sudo bash scripts/build-rootfs.sh` |
| 只是重打包 img | 直接 `cd build && bash mk-image.sh rootfs` |

行为说明：

- `build/rootfs.img` 已存在时，脚本默认**整套跳过**（断点续传）。想继续构建用 `INCREMENTAL=1` 或 `FORCE_REBUILD=1`。
- 删掉 `build/.build-state/` 等价于回到全量重建。
- 改了包列表 / 镜像源，apt 阶段会自动失效重跑；改了 `overlay-firmware/` 的文件，firmware 阶段自动重跑。
- **例外**：firmware 阶段的指纹只覆盖 `overlay-firmware/` 的文件清单，**不覆盖脚本正文**。
  如果你改了该阶段命令，需要手动清标记：
  ```bash
  rm -f build/.build-state/stages/firmware.done build/.build-state/stages/firmware.fp
  ```

---

## 5. 换内核 / 换 SoC / 换源

### 换内核

```bash
cp <新的 linux-image-*.deb> overlay/usr/local/linux-image.deb
rm -f build/.build-state/stages/kmod.*        # 让 modules 固化阶段重跑
INCREMENTAL=1 sudo bash scripts/build-rootfs.sh
```

> `overlay/usr/local/linux-image.deb` **不入库**（`.gitignore` 忽略），是纯本地输入：
> 克隆仓库后需要自己放，换内核/换 SoC 时替换它即可。

内核版本目录名（`KMOD_VER`）由脚本从 deb 的 `lib/modules/<ver>/` **自动探测**，不用手改。
但 **`build/firmware/boot.img` 必须换成同一次编译的产物**，否则会出现"内核与模块/DTB 不匹配"，
详见 [../build/firmware/README.md](../build/firmware/README.md)。

### 换 SoC（RK3576）

```bash
SOC=rk3576 GPU_STACK=libmali INCREMENTAL=1 sudo bash scripts/build-rootfs.sh
```

`SOC` 会影响：`packages/gpu/<SOC>/` 取哪个 libmali、是否需要 CSF 固件、`mk-updateimg.sh` 用哪个芯片参数。
同时 `build/firmware/` 三件套也要换成 RK3576 的。

> **首启的板卡识别（`board_info()`）已覆盖全系**：`rk3128` / `rk3528(3528a)` / `rk3562` /
> `rk3566·rk3568` / `rk3576` / `rk3588·rk3588s`，按 ADC 得到的板卡 ID 查表选 DTB 与 uEnv。
> 表里没有的 SoC 不会中断首启：跳过 dtb/uEnv 覆盖（沿用 `boot.img` 自带的那份）、
> 只打一行 WARN，扩容等后续步骤照常执行。
>
> 新增板卡型号时改两处：`board_info()` 的那个 `if/elif` 链加 ID 分支，以及（rk3128 之外的
> SoC 共用）`board_id()` 里 ADC 通道的选择 —— 目前除 rk3128 用 `CH0/CH2` 外，其余都用 `CH2/CH3`。

### 换 APT 源

`build-rootfs.sh` 里的 `mirror=` 变量（默认阿里云）：

```bash
mirror=https://mirrors.aliyun.com/kali/
```

改完 `APT_REFRESH=1` 重跑。注意 Kali 2026.2 起 APT 源是 deb822 格式，
如果你在**宿主**上换源（不是 rootfs 内），要改 `/etc/apt/sources.list.d/kali.sources` 而不是 `sources.list`。

---

## 6. 产物校验

```bash
ls -lh build/rootfs.img

# 1) 不应混入宿主 /dev 的设备节点（只该有 null/zero/random 等少数几个）
sudo debugfs -R "ls -l /dev" build/rootfs.img 2>/dev/null | head -20

# 2) 构建期专用的 qemu 必须已被删除
sudo debugfs -R "stat /usr/bin/qemu-aarch64-static" build/rootfs.img 2>&1 | grep -i 'not found'

# 3) 内核模块已固化
sudo debugfs -R "ls /lib/modules" build/rootfs.img 2>/dev/null

# 4) 文件系统健康度
e2fsck -fn build/rootfs.img
```

---

## 7. 常见错误

| 现象 | 原因 / 处理 |
|---|---|
| `Please run as root` | 用 `sudo bash scripts/build-rootfs.sh` |
| `apt-get install` 报 `python2` 找不到 | 不要装 `python2`，kali-rolling 已移除 |
| chroot 内 `Exec format error` | x86_64 宿主没注册 binfmt，或缺 `qemu-aarch64-static` 软链（见 2.2） |
| `E: Unable to locate package` / 一直走错镜像 | 换源没生效（deb822 文件未覆盖），见第 5 节 |
| `apt/dpkg` 报 `EUNATCH` / `Protocol driver not attached`，dpkg 返回 100 | 宿主内核 < 5.10，升级内核 |
| 构建"秒退"，提示 `rootfs.img already exists` | `INCREMENTAL=1` 或 `FORCE_REBUILD=1` |
| 镜像起来后 `modprobe` 报找不到模块 | `overlay/usr/local/linux-image.deb` 不是有效的内核 deb（`/lib/modules` 为空） |

更多问题见 [troubleshooting.md](troubleshooting.md)。
