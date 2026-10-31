# 常见问题

按出问题的阶段分类。先定位属于哪一段，再查对应表。

- [1. 环境与依赖](#1-环境与依赖)
- [2. 构建 rootfs（裸机 / Docker 公共）](#2-构建-rootfs裸机--docker-公共)
- [3. Docker 专属](#3-docker-专属)
- [4. 打包 update.img](#4-打包-updateimg)
- [5. 首次开机与运行](#5-首次开机与运行)

---

## 1. 环境与依赖

| 现象 | 原因 | 处理 |
|---|---|---|
| `apt-get install` 报 `python2` 找不到 | kali-rolling 已删除 `python2` 包 | 不要装它；按 [native-build.md](native-build.md#2-安装依赖) 的清单来 |
| `E: Unable to locate package qemu-user-static`，或装了却没有 `-static` 软链 | Debian #1124747（2026-01）删除了该包 | 装 `qemu-user qemu-user-binfmt`，并 `ln -sf /usr/bin/qemu-aarch64 /usr/bin/qemu-aarch64-static` |
| `Please run as root` | `build-rootfs.sh` 需要 root | `sudo bash scripts/build-rootfs.sh` |
| 磁盘告警 / `No space left on device` | 空间不足 | 至少留 20 GB（目录树 5~10 GB + img 5~8 GB + swap 2 GB） |

---

## 2. 构建 rootfs（裸机 / Docker 公共）

| 现象 | 原因 | 处理 |
|---|---|---|
| 脚本"秒退"，提示 `rootfs.img already exists, skipping build` | 断点续传：`build/rootfs.img` 存在时默认整套跳过 | 要更新：`INCREMENTAL=1`；要从零：`FORCE_REBUILD=1`（或 `rm -f build/rootfs.img`） |
| 改了 `overlay/` 但镜像没变 | 同上，或用了全量模式但被 img 短路 | 用 `INCREMENTAL=1`；确认产物时间戳 |
| 改了 `overlay-firmware/` 或 firmware 阶段命令却没生效 | 该阶段指纹只覆盖文件清单，不覆盖脚本正文 | `rm -f build/.build-state/stages/firmware.done build/.build-state/stages/firmware.fp` 后重跑 |
| `apt-get` 报 `403 Forbidden` / `No address associated with hostname` | Kali 官方源 `http.kali.org` 是 GeoIP 重定向，可能被分到屏蔽了 IP 段的镜像 | 换阿里云/中科大源。**注意 Kali 2026.2 起是 deb822**：要改 `/etc/apt/sources.list.d/kali.sources`，只写 `sources.list` 不生效 |
| `dpkg` 返回 100，日志有 `EUNATCH` / `Protocol driver not attached` | 宿主内核 < 5.10，Kali-rolling 的 systemd 260+ 不兼容 | 升级宿主内核到 ≥ 5.10（推荐 ≥ 5.14）；`SKIP_KERNEL_CHECK=1` 只能跳过预检，不能解决 |
| chroot 内 `Exec format error` | x86_64 宿主没有 binfmt / 没有 `qemu-aarch64-static` | 见 [native-build.md §2.2](native-build.md#22-x86_64-主机额外qemu--binfmt) |
| `mount: permission denied` / `mknod` 失败 | 缺少特权（Docker 场景） | 加 `--privileged`，或见 [docker/README §三](../build/docker/README.md) |
| 构建特别慢 | x86_64 上做 arm64 交叉构建（正常 90~180 分钟）；或 arm64 误用了 `PLATFORM=linux/amd64` | 确认平台参数；arm64 宿主不要强制 amd64 |
| `modprobe` 找不到任何模块 | `overlay/usr/local/linux-image.deb` 不是有效内核 deb，`/lib/modules` 为空 | 换正确的 deb（见 [firmware/README](../build/firmware/README.md)） |

---

## 3. Docker 专属

| 现象 | 原因 | 处理 |
|---|---|---|
| `ERROR: 宿主机未注册 qemu-aarch64 binfmt` | x86_64 宿主没注册 | `docker run --rm --privileged multiarch/qemu-user-static --reset -p yes` |
| `Exec format error`（容器内） | binfmt 注册没带 `F` 标志 | 用上面那条命令重注册（`-p yes` 就是加 `F`） |
| `docker: invalid reference format` / 挂载路径报错 | 在 Windows Git Bash 里跑了，`F:\` 被路径转换 | 改用 WSL2；或手动把 `$PWD` 写成 `//f/work/kali-rootfs` |
| `mkdir ... permission denied` / mount 失败 | 少了 `--privileged`（或对应 cap） | 加 `--privileged`；收紧方案见 [docker/README §三](../build/docker/README.md) |
| 容器内看不到 `/proc/sys/fs/binfmt_misc` | 它是伪文件系统，内容不跨 namespace 传播 | **正常**：执行不受影响，判定以宿主机为准 |
| `docker build` 卡在 apt / 403 | 基础镜像默认源是 `http.kali.org`（GeoIP） | 默认已换阿里云；海外可 `docker build --build-arg APT_MIRROR=https://http.kali.org/kali .` |
| 想跳过构建只重打包 img | `rootfs.img` 存在时 `build-rootfs.sh` 会短路 | 只跑 `cd build && bash mk-image.sh rootfs` |

Docker 方案的设计细节、`--privileged` 的逐项原因、与裸机流程的差异，见
[build/docker/README.md](../build/docker/README.md)。

---

## 4. 打包 update.img

| 现象 | 原因 | 处理 |
|---|---|---|
| `Error: build/firmware/MiniLoaderAll.bin not found`（或 uboot.img / boot.img） | 三件套没准备 | 见 [build/firmware/README.md](../build/firmware/README.md) |
| `Error: build/rootfs.img not found` | 还没打包 rootfs，或不在 `build/` 下执行 | 先生成 `build/rootfs.img`；命令要在 `build/` 目录里跑 |
| `unknown chip` | `chip` 参数写错 | 只能是 `rk356x` / `rk3576` / `rk3588` |
| `afptool: cannot execute binary file` | 在 arm64 主机上打包，而工具是 x86_64 静态二进制 | 换 x86_64 主机打包 |
| 打包出来烧录失败 / 校验错 | `chip` 与 `MiniLoaderAll.bin` 不匹配 | loader 必须是目标 SoC 的；`chip` 参数同步改对 |

---

## 5. 首次开机与运行

| 现象 | 原因 | 处理 |
|---|---|---|
| 第一次开机进桌面后又自动重启 | **设计行为**：扩容 p3 + 应用新 DTB 后 `--no-block reboot` | 不用处理，第二次启动正常 |
| 第二次开机卡在登录界面之前 | 内核 / modules / DTB 不同源，或某个 systemd 单元卡住 | 串口看 `[boot_init]` 与最后停在哪个单元；确认 `boot.img` 与 `linux-image.deb` 是**同一次内核编译** |
| HDMI 黑屏，串口一直刷 `dwhdmi-rockchip ... use tmds mode` | X 崩溃 → lightdm 反复重启（每次重启重新 modeset HDMI） | 先看 `/var/log/Xorg.0.log` 的 `(EE)`：<br>• 报 `GLSL compile failure` / `GL_EXT_blend_func_extended` → libmali 的全局库注入没摘干净，见 [packages/gpu/README.md](../packages/gpu/README.md)<br>• 报 `Cannot run in framebuffer mode` → 见下一行 |
| `lightdm` 起不来（`start-limit-hit`），Xorg 报 `Cannot run in framebuffer mode. Please specify busIDs` | rk3576/rk3588 的 **rknpu 也注册了一张 DRM 卡**（`/sys/devices/platform/27700000.npu/drm/cardN`）。Xorg 找不到 primary 平台设备时会退回第一张，modesetting 驱动不了 NPU 那张 → 退到 fbdev → fatal | 镜像已带 `etc/X11/xorg.conf.d/20-rockchip-display.conf` 把 modesetting 钉在 `display-subsystem` 上。旧镜像手工放进同一路径后 `systemctl restart lightdm`；自检：`grep "using /dev/dri" /var/log/Xorg.0.log` 应指向 `platform-display-subsystem-card` |
| 桌面能起但非常卡（`glamor initialization failed` / `Refusing to try glamor on llvmpipe`） | `GPU_STACK=libmali` 或 `none` 的镜像没有可用的硬件 GL：libmali 不提供 GLX 且缺 `GL_EXT_blend_func_extended`，Debian 的 xserver 又拒绝用 llvmpipe 跑 glamor | 这是预期行为。要桌面硬件加速用 `GPU_STACK=both`（panfork 负责 X11/glamor，libmali 负责 GLES/OpenCL/Vulkan） |
| 装了 panfork、重启 lightdm 后直接黑屏，Xorg 日志 `Caught signal 6 (Aborted)` | **panfork 的 pan_base UAPI 与内核 kbase DDK 不匹配**：`ioctl(KBASE_IOCTL_MEM_JIT_INIT): Cannot allocate memory` → 驱动 `double free` → abort。Bifrost/JM（rk3576 G52）上实测必现；rk3588 的 CSF/Valhall 路径不受影响 | `sudo bash panfork-verify.sh --rollback` 后 `systemctl restart lightdm`。**回滚必须显式给版本号**（PPA 带 epoch，apt 认为 panfork 版"更新"，`--allow-downgrades` 也会静默跳过）。G52 上就别折腾 panfork 了，GPU 走 libmali 的 GLES/EGL |
| 没有 WiFi / 蓝牙 | `/usr/lib/firmware` 被多嵌了一层（`firmware/firmware/aic8800/...`） | 检查镜像里有没有 `/usr/lib/firmware/firmware`；旧版本构建问题，重建即可 |
| 根分区没扩到整块盘（`df -h /` 只有镜像的 6 G 左右，SD 卡启动时尤其明显） | 旧版脚本把根分区写死成 `/dev/mmcblk0p3`、磁盘写死成 `/dev/mmcblk0`：从 SD 卡启动时根其实是 `/dev/mmcblk1p3`（`mmcblk0` 是板载 eMMC），于是拿 eMMC 的数字做判断、甚至去扩 eMMC，正在用的 SD 卡永远不扩 | 当前脚本已按 `findmnt -no SOURCE /` + `lsblk` 推出真实的磁盘与分区号。旧镜像临时补救：`sudo rm -f /boot/boot_dilatation_init && sudo reboot`，或直接 `sudo resize2fs $(findmnt -no SOURCE /)`（分区本身已占满整盘时这一条就够） |
| 登录后没有网络 | NetworkManager 未托管 / 未配置 | `nmcli device status`；`nmtui` 配置 |

串口是排查首启问题最有效的手段：`115200 8N1`，控制台 `ttyFIQ0`。
