# Kali Rootfs 薄容器构建方案

把原本要求「宿主机是 kali linux + root 权限 + 手工装 20 多个依赖」的裸机流程，
收敛成一个容器化的一键构建。

**核心思路：Docker 只提供环境，构建逻辑仍由仓库里的原脚本负责。**

```
┌─────────────────────────────────────────────────────┐
│  容器 = 装好依赖的 kali-rolling 环境                  │
│                                                      │
│   scripts/build-rootfs.sh  →  build/rootfs/          │
│   build/mk-image.sh        →  build/rootfs.img       │
│                                                      │
│   仓库通过 -v 挂载，产物零拷贝直接落宿主磁盘           │
└─────────────────────────────────────────────────────┘
```

---

## 一、快速开始

### 前置条件

**1. 宿主机安装 docker**

**2. 宿主机注册 qemu-aarch64 binfmt（仅 x86_64 需要）**

> **arm64 宿主机请跳过这一步。** 见下方说明。

当容器是 x86_64 时，rootfs 是 arm64，debootstrap 第二阶段要在 chroot 内执行 arm64 的 `apt`/`dpkg`，依赖 qemu 用户态模拟：

```bash
# 方法 A：用官方镜像一次性注册（最简单，推荐）
docker run --rm --privileged multiarch/qemu-user-static --reset -p yes

# 方法 B：安装系统包（永久生效）
sudo apt-get install -y qemu-user qemu-user-binfmt
sudo systemctl restart systemd-binfmt

# 验证（必须输出 enabled）
cat /proc/sys/fs/binfmt_misc/qemu-aarch64
```

> ⚠ **注意包名**：新版 Debian/Kali 已**删除 `qemu-user-static` 包**（Debian bug #1124747，2026-01），
> 现在应装 `qemu-user` + `qemu-user-binfmt`。老教程里的 `qemu-user-static binfmt-support`
> 虽然有时还能装上（被 `Provides:` 满足），但行为已变 —— 详见下方。

> `binfmt_misc` 是全局跨 namespace 共享的。只要**宿主**注册过（带 `F` 标志），容器内无需任何额外权限即可执行 arm64 二进制。所以这一步不需要给容器 binfmt 权限。

**为什么 arm64 宿主不需要**：`build-rootfs.sh` 第 50 行按「有没有 `/usr/bin/qemu-aarch64-static`」分流。这个文件名在现代 Debian/Kali 上**已不再由任何包提供**：

| 时间 | 上游变更 |
|---|---|
| 2024-09，qemu 1:9.1.0 | 静态二进制从 `qemu-user-static` 搬到 `qemu-user`（后者现在本身就是静态链接），**去掉 `-static` 后缀** —— 真身是 `/usr/bin/qemu-aarch64`；过渡期由 transitional 包提供兼容软链 |
| 2026-01，Debian #1124747 | **`qemu-user-static` 包被整体删除**，职责由 `qemu-user-binfmt` 的 `Provides:` 承接 → 装得上，但**不再创建 `-static` 软链** |

若不处理，第 50 行判断恒为假，x86_64 上会**静默**改走原生分支。
本方案的容器在 x86_64 上装 `qemu-user` 并**补建软链** `/usr/bin/qemu-aarch64-static → qemu-aarch64`（Dockerfile 里一处、`entrypoint.sh` 里再自愈一次），脚本零改动。

| 宿主架构 | `/usr/bin/qemu-aarch64-static` | 走哪条路 | 需要 binfmt？ |
|---|---|---|---|
| x86_64 | 由 Dockerfile/entrypoint 补建 | `debootstrap --foreign` + chroot | **是** |
| arm64 | 不存在（不装 qemu，原生执行） | 原生 `debootstrap` | **否** |

`entrypoint.sh` 会按**容器自身架构**（`uname -m`）判断，只在交叉构建时才要求 binfmt。

**3. 预留 20GB 以上磁盘**

| 项 | 占用 |
|---|---|
| rootfs 目录树 | 5~10GB |
| rootfs.img（`mkfs.ext4 -d` 期间与目录树并存） | 5~8GB |
| swapfile（在 rootfs 内，脚本行为） | 2GB |
| apt 下载缓存 | 1~2GB |

### 执行

```bash
bash build/docker/build.sh
```

产物：

```
build/rootfs/            # rootfs 目录树
build/rootfs.img         # 可直接 dd 的 ext4 根分区镜像
```

### 常用变体

```bash
# 换板卡
BOARD=lubancat-5 bash build/docker/build.sh

# 不重建镜像（改脚本后不需要重建，因为仓库是挂载的）
REBUILD=0 bash build/docker/build.sh

# 强制全量重建（默认会因 rootfs.img 存在而跳过）
FORCE_REBUILD=1 bash build/docker/build.sh

# CI 环境（无 TTY）
INTERACTIVE=0 REBUILD=0 bash build/docker/build.sh
```

---

## 二、文件说明

| 文件 | 作用 |
|---|---|
| `Dockerfile` | 单阶段薄容器：`kalilinux/kali-rolling` + 依赖清单。**不含任何构建逻辑** |
| `build/docker/entrypoint.sh` | 容器入口：环境自检 → 调 build-rootfs.sh → 容器适配清理 → 调 mk-image.sh |
| `build/docker/build.sh` | 宿主机一键入口：`docker build` + `docker run -v` |
| `scripts/build-rootfs.sh` | **原脚本**，仅改了一处短路判断 |
| `build/mk-image.sh` | **原脚本，零改动** |

---

## 三、为什么容器需要 `--privileged`

`scripts/build-rootfs.sh` 第 67-70 行要往 chroot 里挂载伪文件系统：

```bash
mount -t proc  /proc ${chroot_dir}/proc
mount -t sysfs /sys  ${chroot_dir}/sys
mount -o bind  /dev  ${chroot_dir}/dev
mount -o bind  /dev/pts ${chroot_dir}/dev/pts
```

容器内让 `mount()` 成功需要**同时**通过四道门：

| 门 | 默认状态 | 解锁方式 |
|---|---|---|
| CAP_SYS_ADMIN | 默认 drop | `--cap-add SYS_ADMIN` 或 `--privileged` |
| seccomp | 默认 profile 拦截 mount | `--security-opt seccomp=unconfined` |
| AppArmor | `docker-default` 显式 `deny mount,` | `--security-opt apparmor=unconfined` |
| 设备访问 | — | bind mount 不需要额外设备 |

**默认采用 `--privileged`**，理由：

1. 脚本在 chroot 内的操作覆盖面广（`mount -t proc`、`mount -t sysfs`、`mknod` 各种设备节点、`umount -lf`），精确 cap 组合容易漏；
2. 容器内跑的是**本地可信的构建脚本**，不是不可信的远程内容；
3. `--rm` 用完即删、不暴露端口、入口脚本不接受外部输入。

> 补充一点：`mount -t proc` 是在**容器自己的 mount namespace** 内挂载，**不会污染宿主**。这一点 `--privileged` 和精确 cap 组合完全一样。`--privileged` 的风险在于给了块设备访问权，而非 mount 本身。

### 收紧权限（共享机器场景）

```bash
EXTRA_RUN_ARGS='--cap-add SYS_ADMIN --cap-add SYS_CHROOT --cap-add MKNOD \
  --cap-add DAC_OVERRIDE --cap-add FOWNER \
  --security-opt seccomp=unconfined --security-opt apparmor=unconfined' \
  REBUILD=0 bash build/docker/build.sh
```

各 cap 的作用：

| cap | 用途 |
|---|---|
| `SYS_ADMIN` | mount / umount / proc / sysfs |
| `SYS_CHROOT` | `chroot`（debootstrap 第二阶段必需） |
| `MKNOD` | tar 保留设备节点、创建节点 |
| `DAC_OVERRIDE` | root 读写任意文件 |
| `FOWNER` | 修复文件属主（tar / dpkg 场景） |

**不需要** `--device`：`mk-image.sh` 用 `mkfs.ext4 -d`，不涉及 loop 设备。

---

## 四、容器适配层做了什么

原脚本是按裸机设计的，容器里有两个额外的坑，由 `entrypoint.sh` 补上。**这些是环境适配，不是逻辑修改** —— 原脚本只动了一处（见第五节）。

### 4.1 挂载残留清理（最关键）

`build-rootfs.sh` 第 67-70 行 mount，第 290-291 行 umount。但第 291 行是：

```bash
umount -lf ${chroot_dir}/* 2> /dev/null || true     # 通配展开
```

在容器里这不一定能把所有挂载点清干净。残留的后果很严重：

> **`mkfs.ext4 -d rootfs` 会把宿主 `/dev` 的几百个设备节点灌进 img** —— 体积暴涨且镜像不可用。

因为在 `--privileged` 下，容器的 `/dev` 就是宿主 `/dev`，而第 69 行 `mount -o bind /dev ${chroot_dir}/dev` 把它 bind 进了 rootfs。

`entrypoint.sh` 做**三重防护**：

```bash
# 1. 按常见挂载点显式卸载（深的先卸）
for d in dev/pts dev/shm proc sys dev run; do umount -lf "$ROOTFS/$d"; done

# 2. 反查兜底：处理非标准位置的挂载
findmnt -Rrn -o TARGET "$ROOTFS" | while read -r mp; do umount -lf "$mp"; done

# 3. 二次校验：仍有挂载就拒绝打包
findmnt -Rrn -o TARGET "$ROOTFS" | grep -q . && die "拒绝打包以免污染 img"
```

### 4.2 删除构建期专用的 qemu

`build-rootfs.sh` 第 51 行把 x86_64 的 `/usr/bin/qemu-aarch64-static`（约 5MB）拷进了 arm64 rootfs 用于交叉构建，但**不删除**。它会一起被打进 img。

`entrypoint.sh` 在打包前删掉它。

### 4.3 补调 board hook

`config/boards/<board>.conf` 里的 `config_image_hook__<board>()` 函数**只被 `scripts/config-image.sh` 调用**，`build-rootfs.sh` 和 `mk-image.sh` 都不碰它。

不补调会丢**三个功能**：

| 丢失的功能 | 影响 |
|---|---|
| `90-naming-audios.rules` | 声卡显示为 cardN 原始名，桌面默认声卡可能选错 |
| `rtl8852be-reload.service` | **官方 RTL8852BE WiFi+BT 卡开蓝牙时 WiFi 掉线** |
| `alsa-audio-config.service` | HDMI/ES8388 音频初始化缺失，可能无声 |

`entrypoint.sh` 的做法：`source` 仓库自带的 board conf，然后调用函数 —— 即把 `config-image.sh` 里本来就有的那段调用搬过来，不修改任何脚本。

### 4.4 `mk-image.sh` 的 `e2fsck` 返回码陷阱

`mk-image.sh` 第 1 行是 `#!/bin/bash -e`，而第 29 行执行 `sudo e2fsck -p -f`。

`e2fsck -p` 的返回码语义：

| 码 | 含义 |
|---|---|
| 0 | 无错误 |
| 1 | **已修复错误** |
| 2 | **已修复，需重启** |
| 4 | 未修复的错误 |

返回 `1` 或 `2` 会触发脚本自身的 `set -e` 中断，导致后面的 `resize2fs -M` 不执行 —— **img 不会收缩到最小，体积偏大**。

`set -e` 来自 shebang，外部无法关闭。所以 `entrypoint.sh` 改为「以产物为准」：

```bash
set +e
bash mk-image.sh rootfs
MK_RC=$?
set -e

# 只要 rootfs.img 产出成功，就补一次幂等的收尾
if [ -f rootfs.img ] && [ "$MK_RC" -ne 0 ]; then
    e2fsck -pf rootfs.img || true     # 显式吸收返回码
    resize2fs -M rootfs.img || true   # 幂等：已最小则 Nothing to do
fi
```

判定依据是**产物文件**而非退出码，这是不改脚本前提下最稳的做法。

---

## 五、`build-rootfs.sh` 的唯一改动

**第 15-17 行**，其余一行不动。

**改动前**（判断恒为假 —— 第 294 行 tar 被注释、第 295 行 `SERVER_ONLY=Y` 时提前 `exit 0`，两个 tar.xz 永远不会生成）：

```bash
if [[ -f ubuntu-22.04-server-arm64.rootfs.tar.xz && -f ubuntu-22.04-desktop-arm64.rootfs.tar.xz ]]; then
        exit 0
    fi
```

**改动后**：

```bash
# 断点续传：mk-image.sh 的产物 rootfs.img 已存在则跳过整套构建。
# 需要强制重建时：rm -f build/rootfs.img（或删掉整个 build/ 目录）后重跑。
if [[ -f rootfs.img ]]; then
        echo "rootfs.img already exists, skipping build. (rm build/rootfs.img to force rebuild)"
        exit 0
fi
```

**路径正确性**：脚本第 11-12 行自己 `cd $(dirname $0) && cd ..` 再 `cd build`，所以 cwd 是 `<repo>/build`。`mk-image.sh` 也必须在 `build/` 下执行，img 落在 `<repo>/build/rootfs.img` —— 与判断路径一致。

**连带的用法变化**：

```bash
# 强制全量重建
rm -f build/rootfs.img && bash build/docker/build.sh
# 或
FORCE_REBUILD=1 bash build/docker/build.sh
```

---

## 六、验证产物

```bash
# 1. 大小合理性
ls -lh build/rootfs.img

# 2. ★ 确认没有混入宿主 /dev（验证 4.1）
debugfs -R "ls -l /dev" build/rootfs.img 2>/dev/null | head -20
# 应只看到 null / zero / random 等少数几个，不应有宿主的一堆设备节点

# 3. ★ 确认 qemu 残留已删（验证 4.2）
debugfs -R "stat /usr/bin/qemu-aarch64-static" build/rootfs.img 2>&1 | grep -i 'not found'

# 4. ★ 确认 board hook 生效（验证 4.3）
debugfs -R "stat /etc/udev/rules.d/90-naming-audios.rules" build/rootfs.img
debugfs -R "ls /usr/lib/systemd/system" build/rootfs.img | grep rtl8852be

# 5. 文件系统健康度
e2fsck -fn build/rootfs.img

# 6. 挂载检查
sudo mkdir -p /mnt/r && sudo mount -o loop,ro build/rootfs.img /mnt/r
ls /mnt/r && sudo umount /mnt/r
```

### 烧写

```bash
sudo dd if=build/rootfs.img of=/dev/mmcblk0pX bs=1M status=progress conv=fsync
```

---

## 七、注意事项与已知差异

### 7.1 README 的依赖清单不能照抄

项目根的 `README.md` 列了 `python2`，但 **kali-rolling 早已移除该包**，照抄会让 `apt-get install` 直接失败。Dockerfile 里的依赖清单是从「两个脚本实际调用了什么」反推的，已剔除失效项。

### 7.2 首次构建耗时

| 阶段 | 耗时 |
|---|---|
| debootstrap + kali-linux-core + kali-desktop-xfce 下载安装 | 40~90 分钟 |
| `mkfs.ext4 -d` + `resize2fs -M` | 5~15 分钟 |

镜像源是 `mirrors.aliyun.com/kali/`（`build-rootfs.sh` 第 34 行），国内速度尚可。

### 7.3 swapfile 占 2GB

`build-rootfs.sh` 第 144-152 行在 chroot 内 `dd` 一个 2GB swapfile。这是原脚本行为，未改。

### 7.4 desktop 变体当前不可达

`build-rootfs.sh` 第 29 行 `SERVER_ONLY=Y`，第 295 行 `[[ ${SERVER_ONLY} == "Y" ]] && exit 0` 会提前退出，第 297 行之后的 desktop 分支**永远不会执行**。

如需 desktop：

1. 改第 29 行为 `SERVER_ONLY=N`
2. 注意第 432 行 `tar -cpJf ../ubuntu-22.04-desktop-arm64.rootfs.tar.xz .` 会**额外产出 8GB 的 tar.xz**，与「只产 img」目标冲突，建议一并注释掉

### 7.5 断点续传的粒度

| 情况 | 行为 |
|---|---|
| `build/rootfs.img` 存在 | `build-rootfs.sh` 短路跳过，直接重新打包 img |
| 想跳过 img 重打包 | 当前不支持（`mk-image.sh` 每次都重做） |
| 想全量重建 | `FORCE_REBUILD=1` 或 `rm -f build/rootfs.img` |

注意：`build-rootfs.sh` 第 43 行有 `rm -rf ${chroot_dir}`，所以一旦进入构建流程，rootfs 目录树**总是**从头重建。

### 7.6 产物路径与 `.dockerignore`

仓库根的 `.dockerignore` 已忽略 `build/rootfs/` 和 `build/*.img`。这仅在**构建镜像本身**时生效（防止把 10GB 产物送进 daemon），对本方案的挂载式构建无影响。

---

## 八、与原裸机流程的对照

| 项目 | 裸机流程 | 薄容器方案 |
|---|---|---|
| 环境准备 | 宿主机装 20+ 依赖 | 镜像内预装 |
| 宿主要求 | kali linux + root | 任意 docker 宿主机 |
| 可复现性 | 依赖宿主状态 | 镜像固定 |
| 改脚本后 | 直接跑 | 直接跑（仓库挂载，零重建） |
| `build-rootfs.sh` | 原样 | 仅改第 15-17 行 |
| `mk-image.sh` | 原样 | **零改动** |
| board hook | 不执行（同样的问题） | 由入口补调 |
| 产物位置 | `build/` | `build/`（挂载，零拷贝） |
