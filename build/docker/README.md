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

**注意：容器内默认读不到 `/proc/sys/fs/binfmt_misc`**

`binfmt_misc` 是**伪文件系统，内容不跨 mount namespace 传播**。容器的 `/proc` 是独立
procfs 实例，宿主的 `binfmt_misc` 挂载不会传播进来 —— 所以在容器里**默认看不到**
`/proc/sys/fs/binfmt_misc/qemu-aarch64`，即使宿主已注册且功能正常：

```bash
# 容器内需要手动挂载才能读到（--privileged 允许）
mount -t binfmt_misc binfmt_misc /proc/sys/fs/binfmt_misc
```

但**执行不受影响** —— 注册是内核全局状态，`multiarch/qemu-user-static --reset -p yes`
带的 `F`(fix_binary) 标志让内核在注册时就缓存了 qemu 二进制，与 namespace 无关。

`entrypoint.sh` 因此分三层判定：能读到就校验（并检查 `F` 标志）；
挂上了却无条目则报错；**读不到只告警、不阻断**，判定以宿主机侧为准。

**3. 预留 20GB 以上磁盘**

| 项 | 占用 |
|---|---|
| rootfs 目录树 | 5~10GB |
| rootfs.img（`mkfs.ext4 -d` 期间与目录树并存） | 5~8GB |
| swapfile（在 rootfs 内，脚本行为） | 2GB |
| apt 下载缓存 | 1~2GB |

**4. 宿主内核 ≥ 5.10（推荐 ≥ 5.14）**

Kali-rolling 的 systemd 260+ 把内核基线从 5.4 提到 **5.10**，并删除了老内核的兼容代码。内核低于基线时，chroot 内 apt/dpkg 的 postinst（典型如 `systemd-machine-id-setup`）会失败、dpkg 返回 100，构建无法完成。

`build.sh` 与容器内 `entrypoint.sh` 都会在入口预检：`< 5.10` 直接报错退出；`5.10~5.13` 打印一行提示后继续；`≥ 5.14` 静默通过。用 `uname -r` 自查；临时跳过（不推荐）：`SKIP_KERNEL_CHECK=1 bash build/docker/build.sh`。

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

## 五、`build-rootfs.sh` 的改动

共三处（行号会随改动漂移，以内容为准）：

1. **断点续传短路**：`rootfs.img` 存在即整套跳过（原逻辑判断两个永不生成的
   `*.tar.xz`，恒为假）。
2. **增量构建开关**：`INCREMENTAL=1 / FORCE_REBUILD=1 / APT_REFRESH=1`，详见 7.4。
   另：apt 列表显式加入 `bc`（首启脚本与内核 deb postinst 都依赖）、
   `cloud-guest-utils`（growpart）。
3. **日志/时钟策略**：journal 易失 + journal-flush 超时兜底 + fake-hwclock 提前
   恢复；删除 `rtc-hym8563.service`。详见 7.6。

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

镜像源分两层，互不相干：

| 层 | 源 | 谁决定 | 覆盖方式 |
|---|---|---|---|
| **镜像构建期**（Dockerfile 里 apt 装依赖） | 默认阿里云 `mirrors.aliyun.com/kali` | Dockerfile 的 `ARG APT_MIRROR` | `docker build --build-arg APT_MIRROR=https://http.kali.org/kali .`（CI 海外用这个） |
| **rootfs 构建期**（debootstrap + chroot 内 apt） | 阿里云 `mirrors.aliyun.com/kali/` | `build-rootfs.sh` 第 37 行 `mirror=` 变量 | 改脚本或挂载后 sed（国内速度尚可；海外慢） |

> 为什么镜像构建期不直接用 `http.kali.org`：它是 GeoIP 重定向，国内可能被分到
> 清华/东软等镜像，存在整段 IP 被 403 屏蔽、或镜像站 DNS 解析失败的情况，
> 会直接导致 `docker build` 失败（真实案例见根 README 2.9）。
> 阿里云源对国内稳定；CI 传 build-arg 切回官方源即可，两边各用最快的。
>
> **★ 换源时必须连 deb822 文件一起处理**：Kali 2026.2 起 APT 源放在
> `/etc/apt/sources.list.d/kali.sources`（deb822 格式），而 `/etc/apt/sources.list`
> 在新镜像里**已不存在**。只 `echo > /etc/apt/sources.list` 只是**新增**一份定义，
> 基础镜像自带的 `kali.sources`（`URIs: http://http.kali.org/kali/`）照旧生效，
> apt 两个源都读 —— 表现就是「明明换了阿里云，构建还是去访问清华源」。
> Dockerfile 的做法是：`rm -f /etc/apt/sources.list /etc/apt/sources.list.d/*.sources
> /etc/apt/sources.list.d/*.list` 之后，再按 deb822 格式写阿里云。
>
> **rootfs 阶段不受影响**：debootstrap 写的是传统 `sources.list`（已核实 Kali 版
> debootstrap 1.0.144 不生成 deb822 文件），且 `build-rootfs.sh` 第 62-66 行会把
> 它整份覆写成 `${mirror}`（阿里云）。`base-files` / `kali-archive-keyring` /
> `kali-defaults` 三个包也都不携带 `kali.sources`。

### 7.3 swapfile 占 2GB

`build-rootfs.sh` 第 144-152 行在 chroot 内 `dd` 一个 2GB swapfile。这是原脚本行为，未改。



### 7.4 断点续传与增量构建

| 情况 | 行为 |
|---|---|
| `build/rootfs.img` 存在（默认） | `build-rootfs.sh` 短路跳过整套构建 |
| 想全量重建 | `FORCE_REBUILD=1`（或 `rm -f build/rootfs.img`） |
| 想跳过 img 重打包 | 不重跑 `build-rootfs.sh`，直接 `bash build/mk-image.sh rootfs` |
| 只更新定制内容（overlay / 脚本 / 配置） | `INCREMENTAL=1`，见下 |

**增量模式（`INCREMENTAL=1`）**：把构建拆成「重型阶段」与「廉价阶段」，
重型阶段用「完成标记 + 输入指纹」判断能否跳过，廉价阶段每次必跑。

| 阶段 | 开销 | 复用判据（输入变了自动失效重跑） |
|---|---|---|
| debootstrap | 10~40 min | `arch/release/mirror` 指纹 |
| apt（upgrade + 全部包 + full-upgrade + remove） | 30~60 min | **apt 段落的源码指纹**（增删包、换源即失效） |
| swapfile（2GB dd） | ~10 s | chroot 内 `/swapfile` 存在且正好 2GB |
| `packages/arm64/*.deb` | 秒级 | 文件名 + 大小指纹 |
| `overlay-firmware` | 视体积 | 文件清单（大小 + mtime）指纹 |
| **overlay 拷贝 / 服务使能 / 配置覆写** | **秒级** | **每次必跑** —— 这正是增量要更新的部分 |

```bash
bash scripts/build-rootfs.sh --incremental                  # 增量
APT_REFRESH=1 bash scripts/build-rootfs.sh --incremental    # 增量 + 拉最新软件包
bash scripts/build-rootfs.sh --force                        # 回到全量

# 容器里加一层环境变量（EXTRA_RUN_ARGS 是 build.sh 已有的透传口）
EXTRA_RUN_ARGS='-e INCREMENTAL=1' bash build/docker/build.sh
```

状态放在 `build/.build-state/`（阶段标记 `stages/*.done` + 指纹 `stages/*.fp`）：
**删掉它即等于全量重建**；`FORCE_REBUILD=1 / --force` 会自动删。


### 7.5 产物路径与 `.dockerignore`

仓库根的 `.dockerignore` 已忽略 `build/rootfs/` 和 `build/*.img`。这仅在**构建镜像本身**时生效（防止把 10GB 产物送进 daemon），对本方案的挂载式构建无影响。

---

### 7.6 首次开机流程与日志策略（重要）

**两段式首启是设计行为**：烧录后的第一次开机不会出现登录提示。

| 开机 | 发生什么 |
|---|---|
| boot #1 | `boot_init.service`（sysinit 阶段）：挂载 p2→/boot 并写入 fstab、建 rk-kernel.dtb/uEnv.txt 软链、扩容 p3（sgdisk/growpart/resize2fs，已改为"fs 已满分区则跳过"）、等 `kernel-install.service`（dpkg 安装内核 deb）→ `systemctl --no-block reboot` |
| boot #2 | 一切就绪：multi-user → 登录界面（getty/lightdm） |

**boot #2 曾卡死的根因**（2026-09 排查）：板卡**无 RTC 电池**，开机时钟被拨回
systemd 内置 epoch（2026-07-24 02:31:52）；跨开机持久化 journal 的最后条目总是
"未来时间"，journald 启动即 `realtime clock jumped backwards → rotating`，并卡死
`systemd-journal-flush`（oneshot 默认无启动超时）⇒ `sysinit.target` 永不完成 ⇒
无登录界面。断电重启后 journald 把损坏的 journal 改名重建、跳过 rotate，于是
"第二次开机就好了"。

**已落地的修复**：

1. `etc/systemd/journald.conf.d/10-volatile.conf`：`Storage=volatile` —— 不存在跨开机
   journal，对时钟回拨免疫。代价：重启后无 `journalctl -b -1`，诊断靠串口输出与
   ramoops/pstore。
2. `etc/systemd/system/systemd-journal-flush.service.d/override.conf`：
   `TimeoutStartSec=30` —— 即使 journald 异常也最多卡 30s 就放行 sysinit。
3. `etc/systemd/system/fake-hwclock.service.d/override.conf`：时钟恢复（eMMC 持久化）
   提前到 journald 之前；`chrony.conf` 已有 `rtcsync`（RTC 会在有电时被校正，但
   **无电池、断电后不可靠**，不能作为唯一防线）。
4. `boot_init.service` / `kernel-install.service` 增加 `StandardOutput/Error=journal+console`；
   `boot_init.sh` 每阶段向串口打 `[boot_init] …` 进度、失败时打印行号 ⇒ 首启全程可观测。
5. `rtc-hym8563.service` 已删除：依赖的 `hwclock` 不在镜像里，且内核探测 RTC 时已自动
   设置系统时钟，功能重复。`chrony.conf` 保留 `rtcsync`（有电场景维持 RTC 正确）。

**如需临时恢复持久日志**：删除
`overlay/etc/systemd/journald.conf.d/10-volatile.conf`（板上为
`/etc/systemd/journald.conf.d/10-volatile.conf`）→
`mkdir -p /var/log/journal && systemctl restart systemd-journald`。
前提：已用 rtcsync/fake-hwclock 保证时钟单调，否则会复现 boot #2 的卡死。

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
