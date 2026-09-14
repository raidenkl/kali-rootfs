## 0.说明
一个可以构建kali-rootfs的脚本，适用于rk系列的芯片，要求主机是kali linux系统。
`/overlay/usr/local/linux-image.deb`替换成实际的内核deb包，仓库里的是6.1.99的内核，对应的内核地址：https://github.com/LubanCat/kernel

构建产物是 rootfs 分区镜像 `build/rootfs.img`，可以直接 `dd` 到板卡根分区。

构建方式有两种，任选其一：

| 方式 | 需要的环境 | 说明 |
|---|---|---|
| **裸机** | kali linux + 手工装 20 多个依赖 | 见第 1 节 |
| **Docker**（推荐） | 任意装了 docker 的机器 | 见第 2 节 |

## 1.用法（裸机）
### 安装依赖
```
sudo apt-get install -y build-essential gcc-aarch64-linux-gnu bison \
qemu-user-static qemu-system-arm u-boot-tools binfmt-support \
debootstrap flex libssl-dev bc rsync kmod cpio xz-utils fakeroot parted \
udev dosfstools uuid-runtime git-lfs device-tree-compiler python3 fdisk \
python-is-python3 python2
```
然后执行仓库里`scripts/build-rootfs.sh`这个脚本即可，然后用`build/mk-image.sh`脚本打包成img镜像，就是rootfs分区镜像。

> 注意：上面这份依赖清单来自上游，其中 `python2` 在 kali-rolling 中**已被移除**，照抄会让 `apt-get install` 直接失败，需要时请删掉该项。

## 2.用Docker构建（推荐）

裸机流程要求宿主机是 kali linux 且手工装一堆依赖。本仓库提供一个 Dockerfile 把这件事收敛成一条命令。

**构建流程**： 构建仍然由仓库里既有的两个脚本完成：

```
scripts/build-rootfs.sh   ->   build/rootfs/        # rootfs 目录树
build/mk-image.sh         ->   build/rootfs.img     # 最终产物
```

容器只是提供一个「能跑这两个脚本的环境」，并替你按正确顺序调用它们。
仓库根通过 `-v` 挂载进容器，所以产物直接落在宿主机的 `build/`，不经过 docker daemon，也不需要 `docker cp`。

```
宿主机                                     容器
──────────────────────────────────────────────────────────────────────
<repo>/  ──── (-v 挂载) ────▶  /work/kali-rootfs    ← Dockerfile 的 WORKDIR
                                 └─ ENTRYPOINT: entrypoint.sh
                                      ├─ scripts/build-rootfs.sh → <repo>/build/rootfs/
                                      └─ build/mk-image.sh       → <repo>/build/rootfs.img
                                         （直接写回宿主机，零拷贝，不需要 docker cp）
```

### 2.1 环境要求

1. **Docker**（23.0+；更老的版本先 `export DOCKER_BUILDKIT=1`，因为 `docker build --platform` 依赖 BuildKit）
2. **20GB 以上可用磁盘**：rootfs 目录树 5~10GB，`mkfs.ext4 -d` 期间 img 与目录树并存 5~8GB，另有 2GB swapfile 和 apt 缓存
3. **shell 环境**：在 Linux / macOS / **WSL2** 的 bash 里执行。Windows 的 Git Bash 直接跑会因为 `F:\...` 路径转换失败，请先进入 WSL2

### 2.2 Dockerfile 里有什么

| 项 | 内容 |
|---|---|
| 基础镜像 | `kalilinux/kali-rolling` |
| APT 源 | 默认阿里云（`--build-arg APT_MIRROR=...` 可覆盖），规避 `http.kali.org` GeoIP 分流到不可用镜像的问题 |
| 安装的依赖 | `debootstrap`、`e2fsprogs`、`sudo`、`mount`/`findmnt`、交叉编译工具链、`qemu-user`（**仅 x86_64**）等，完整清单和逐项用途见 `Dockerfile` 内的注释 |
| `ENTRYPOINT` | `/usr/local/bin/entrypoint.sh` |
| `WORKDIR` | `/work/kali-rootfs` —— 约定的仓库挂载点，`-v` 必须挂到这里 |
| 镜像体积 | arm64 不装 qemu，比 x86_64 小约 60MB |

`entrypoint.sh` 的内容，他**不含构建逻辑**：

1. 环境自检（root / 仓库是否挂上 / qemu binfmt / 磁盘空间）
2. 调用 `scripts/build-rootfs.sh` 生成 `build/rootfs/`
3. 容器适配清理：卸载 rootfs 内的残留挂载点（残留会把宿主 `/dev` 灌进 img）、删除构建期专用的 `qemu-aarch64-static`
4. 补调 `config_image_hook__<board>()`（`build-rootfs.sh` 自己不调用它，不补会丢声卡命名 / WiFi 蓝牙共存 / 音频初始化）
5. 调用 `build/mk-image.sh` 打包出 `build/rootfs.img`

### 2.3 用法一：一键脚本（推荐）

```bash
bash build/docker/build.sh
```

这一条命令内部就是 2.4 的两步（`docker build` + `docker run`），参数已经配好，跑完产物在宿主机 `build/` 下。
`PLATFORM` 按宿主架构自动推导，无需设置。

### 2.4 用法二：手动使用 Dockerfile

要自定义参数、或者想自己控制每一步时，直接对 Dockerfile 操作即可 —— 就两步。

**第 1 步，构建镜像**（在**仓库根**执行；`.` 是构建上下文，`.dockerignore` 已排除 `build/rootfs/` 和 `build/*.img` 等大文件）

```bash
docker build -t kali-rootfs-builder .
```

不写 `--platform` 时默认按宿主架构构建，通常就是你要的。要显式指定也可以加：x86_64 宿主用 `--platform linux/amd64`，arm64 宿主用 `--platform linux/arm64`。
镜像架构必须和宿主机一致，否则运行时会退化成模拟（见 2.5）。

**第 2 步，运行容器**（这就是「使用」这个镜像的方式）

```bash
docker run --rm -it --privileged \
  -v "$PWD":/work/kali-rootfs \
  -w /work/kali-rootfs \
  -e BOARD=lubancat-4 \
  kali-rootfs-builder
```

每个参数为什么这么写：

| 参数 | 作用 |
|---|---|
| `--rm` | 跑完自动删除容器（产物在宿主机，容器不需要留） |
| `-v "$PWD":/work/kali-rootfs` | 把仓库根挂进容器。**必须在仓库根目录执行**；路径要和 Dockerfile 的 `WORKDIR` 一致 |
| `-w /work/kali-rootfs` | 容器内工作目录 |
| `-e BOARD=lubancat-4` | 目标板卡，默认 `lubancat-4` |
| `-e FORCE_REBUILD=1` | 可选。`build/rootfs.img` 已存在时默认跳过构建，加这个强制全量重建 |
| `--privileged` | 必需。脚本要在 chroot 内 `mount -t proc/sysfs`、`mount -o bind /dev`、`mknod`，缺 cap 会报 `Permission denied`（详细分析见 `build/docker/README.md`） |
| 末尾不写命令 | 自动执行 `ENTRYPOINT`，即 entrypoint.sh 全流程 |

**第 3 步，取产物** —— 产物已经在宿主机上了，不需要 `docker cp`：

```
build/rootfs/        # rootfs 目录树
build/rootfs.img     # 可直接 dd 的 ext4 根分区镜像
```

> 想收紧权限（共享机器不加 `--privileged`）时，把 `--privileged` 换成：
> `--cap-add SYS_ADMIN --cap-add SYS_CHROOT --cap-add MKNOD --cap-add DAC_OVERRIDE --cap-add FOWNER --security-opt seccomp=unconfined --security-opt apparmor=unconfined`

### 2.5 按宿主机架构选择参数

两条路径的区别只剩一处：**要不要注册 binfmt**。

关于 `--platform`，**两种用法都不用操心**：

- **手动方式**：`docker build` 不写 `--platform` 时默认就按宿主架构构建，x86_64 和 arm64 都可以省略。
- **一键脚本**：`build/docker/build.sh` 会按 `uname -m` 自动推导（`aarch64/arm64 → linux/arm64`，其余 → `linux/amd64`），并打印实际使用的平台。特殊需求仍可手动覆盖：`PLATFORM=linux/amd64 bash build/docker/build.sh`。

| 宿主机 | 需先注册 qemu binfmt？ | 容器内走哪条路 | 参考耗时 |
|---|---|---|---|
| x86_64 | **需要**（见下） | `debootstrap --foreign` + chroot 第二阶段（qemu 模拟 arm64） | 90~180 分钟 |
| arm64 | 不需要 | 原生 `debootstrap` | 40~90 分钟 |

#### x86_64 宿主机：先注册 binfmt

rootfs 是 arm64，而容器是 x86_64，debootstrap 第二阶段要在 chroot 内执行 arm64 的 `apt`/`dpkg`，靠 qemu 用户态模拟。所以：

```bash
# 在宿主机上注册（不是容器内）
docker run --rm --privileged multiarch/qemu-user-static --reset -p yes

# 验证：能看到 enabled，且 flags 里有 F
cat /proc/sys/fs/binfmt_misc/qemu-aarch64
```

> `-p yes` 很关键：它给注册项加上 `F`(fix_binary) 标志 —— 内核在注册时就打开了 qemu 二进制，
> 之后 chroot 内执行 arm64 不再依赖容器命名空间里能否找到 qemu 文件。

然后正常执行 2.3 或 2.4 的步骤即可。

<details>
<summary>不想用官方镜像，改用系统包注册（永久生效）</summary>

```bash
sudo apt-get install -y qemu-user qemu-user-binfmt
sudo systemctl restart systemd-binfmt
# 或： sudo update-binfmts --enable qemu-aarch64
```

**包名有坑**：新版 Debian/Kali 已**删除 `qemu-user-static` 包**（Debian #1124747，2026-01）。
老教程里的 `qemu-user-static binfmt-support` 虽然还能装上（被 `Provides:` 满足），
但不再创建 `-static` 软链，导致 `build-rootfs.sh` 第 50 行的探测恒为假、静默走错分支。
本方案的 Dockerfile 与 entrypoint 都会补建 `/usr/bin/qemu-aarch64-static → qemu-aarch64`，脚本零改动。

</details>

#### arm64 宿主机：什么都不用额外做

arm64 上跑 arm64 是原生行为，不需要 qemu、不需要 binfmt，速度也最快。直接跑即可，`PLATFORM` 会自动推导成 `linux/arm64`：

```bash
bash build/docker/build.sh
```

### 2.6 进容器看一眼（排查用）

想进容器手动跑脚本、而不是让 entrypoint 自动跑完，用 `--entrypoint bash` 覆盖入口：

```bash
docker run --rm -it --privileged \
  -v "$PWD":/work/kali-rootfs \
  -w /work/kali-rootfs \
  --entrypoint bash \
  kali-rootfs-builder
```

进去以后就能像在裸机上一样操作，例如：

```bash
bash scripts/build-rootfs.sh            # 只构建 rootfs 目录树
cd build && bash mk-image.sh rootfs     # 只打包 img
```

### 2.7 build.sh 支持的环境变量

```bash
# 换板卡（默认 lubancat-4；可选 lubancat-4 / lubancat-4io / lubancat-5 / lubancat-5io / lubancat-5-v2）
BOARD=lubancat-5 bash build/docker/build.sh

# 改了脚本后不用重建镜像（仓库是挂载的）
REBUILD=0 bash build/docker/build.sh

# 强制全量重建（默认 build/rootfs.img 已存在时会跳过构建）
FORCE_REBUILD=1 bash build/docker/build.sh

# CI / 无 TTY 环境
INTERACTIVE=0 bash build/docker/build.sh

# 自定义镜像名
IMAGE=my-builder bash build/docker/build.sh
```

### 2.8 产物与验证

```bash
ls -lh build/rootfs.img

# 确认没有混入宿主 /dev 的设备节点（应只有 null / zero / random 等少数几个）
sudo debugfs -R "ls -l /dev" build/rootfs.img 2>/dev/null | head -20

# 确认构建期专用的 qemu 已删除
sudo debugfs -R "stat /usr/bin/qemu-aarch64-static" build/rootfs.img 2>&1 | grep -i 'not found'

# 确认板卡 hook 生效
sudo debugfs -R "stat /etc/udev/rules.d/90-naming-audios.rules" build/rootfs.img

# 文件系统健康度
e2fsck -fn build/rootfs.img
```

烧写到根分区：

```bash
sudo dd if=build/rootfs.img of=/dev/mmcblk0pX bs=1M status=progress conv=fsync
```

### 2.9 常见问题

| 现象 | 原因与处理 |
|---|---|
| `ERROR: 宿主机未注册 qemu-aarch64 binfmt` | x86_64 宿主没注册，回到 2.5 执行注册命令 |
| `docker: invalid reference format` 或挂载路径报错 | 在 Git Bash 里跑了。改用 WSL2，或手动把 `$PWD` 换成 `//f/work/kali-rootfs` 这类形式 |
| arm64 上构建特别慢 | 用了 `PLATFORM=linux/amd64`（或老版本脚本）导致退化成 x86_64 模拟；新版脚本按 `uname -m` 自动推导，不会出现 |
| `Exec format error` | binfmt 注册未带 `F` 标志，用 `multiarch/qemu-user-static --reset -p yes` 重注册 |
| `mkdir ... permission denied` / mount 失败 | 少了 `--privileged`（或对应的 cap 组合） |
| `apt-get` 报 `403 Forbidden` / `No address associated with hostname` | 基础镜像默认源 `http.kali.org` 是 GeoIP 重定向，国内可能被分到不可用的镜像。**新版 Dockerfile 已默认改用阿里云源**；如需换其他源：`docker build --build-arg APT_MIRROR=https://mirrors.ustc.edu.cn/kali -t kali-rootfs-builder .`（中科大示例） |
| 容器内看不到 `/proc/sys/fs/binfmt_misc` | 正常。binfmt_misc 是伪文件系统，**内容不跨 mount namespace 传播**，但**执行**不受影响（注册是内核全局状态）。entrypoint 只在「挂上后确认无条目」时才报错 |
| `可用磁盘仅 xxx MB` 告警 | 至少留 20GB |
| 想跳过构建直接重打包 img | `build/rootfs.img` 存在时 `build-rootfs.sh` 会短路跳过，只有 `mk-image.sh` 干活，等于重打包。反向操作（全量重建）用 `FORCE_REBUILD=1` |

### 2.10 相关文档

- 容器方案的设计说明、容器适配细节、与裸机流程的对照：`build/docker/README.md`

