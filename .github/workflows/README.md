# GitHub Actions 构建说明

用 GitHub Actions 在云端跑 docker 构建，免去本地需要一台 Linux 机器。

工作流文件：`.github/workflows/build-rootfs.yml`

---

## 一、为什么能做，以及两个硬约束

### 能做，而且比本地更快

| 项 | 说明 |
|---|---|
| **runner 免费** | 仓库是 public，标准 runner 完全免费、不限时长 |
| **arm64 原生 runner 可用** | `ubuntu-24.04-arm` —— 直接 arm64 跑 arm64，**不需要 qemu，快 3~8 倍** |
| **磁盘可扩** | runner 根分区实际 **72GB**（不是文档里那个 14GB），清理后可用 **53~55GB** |

### 约束 1：磁盘 —— 必须清理

runner 开机时预装了本项目的无关内容，占掉约 50GB：

| 路径 | x64 | arm64 | 内容 |
|---|---|---|---|
| `/usr/local/lib/android` | 9.5GB | — | Android SDK/NDK |
| `/usr/local/.ghcup` | 6.4GB | — | Haskell |
| `/opt/hostedtoolcache` | 6.0GB | — | 预缓存工具链 |
| `/usr/share/dotnet` | 3.4GB | 3.6GB | .NET |
| `/usr/share/swift` | 3.2GB | 3.2GB | Swift |
| `/usr/lib/jvm` | — | 1.5GB | Java JDK |

清理后：**x64 剩 53GB，arm64 剩 55GB**。这对 `rootfs 5~10GB + img 5~8GB` 的峰值需求是够的。

> 这一步**不能省**。不清理的话 debootstrap 装到一半就会 `No space left on device`。

### 约束 2：产物 —— 默认不上传

| 限制 | 值 |
|---|---|
| 单个 artifact 上限 | 10GB |
| 免费账号总存储 | 500MB |
| 我们产出的 `rootfs.img` | 5~8GB |

**免费额度根本装不下。** 所以 workflow 默认**只做构建验证 + 体积报告，不上传产物**。

需要产物时用 `workflow_dispatch` 手动触发并勾选 `upload_artifact`。此时会把 img 用 `xz -3` 压到 **<2GB** 再上传。如果仍超配额，考虑：

1. **发 Release**（推荐）—— Release asset 单文件上限 **2GB**，压缩后的 img 通常能过，且不占 artifact 配额
2. **只构建 rootfs 目录**，输出 `tar.zst`（比 img 小得多，因为不填充 ext4 元数据）
3. 传第三方存储（S3 / 对象存储）

---

## 二、触发方式

| 触发 | 行为 |
|---|---|
| `push` 到 master/main（改动构建相关文件） | 双架构构建，不上传产物 |
| `pull_request` 到 master/main | 同上 |
| 手动 `workflow_dispatch` | 可选板卡、是否打包 img、是否上传产物 |

改动这些路径会触发（避免改 README 也跑一次 90 分钟的构建）：

```
Dockerfile  scripts/**  build/**  overlay/**  overlay-firmware/**
packages/**  config/**  .github/workflows/build-rootfs.yml
```

### 手动触发

GitHub 仓库 → Actions → Build Kali Rootfs → Run workflow，可填：

| 参数 | 默认 | 说明 |
|---|---|---|
| `board` | `lubancat-4` | 5 个板卡可选 |
| `upload_artifact` | `false` | 上传产物（压成 xz，注意配额） |
| `run_mk_image` | `true` | 是否执行 mk-image.sh |

---

## 三、两个架构为什么要都跑

这正是你要验证的点 —— **容器方案在两种宿主架构下是否行为一致**。

| 矩阵项 | runner | 宿主架构 | qemu | 说明 |
|---|---|---|---|---|
| `arm64-native` | `ubuntu-24.04-arm` | arm64 | **不需要** | 原生执行，构建快 3~8 倍 |
| `x86_64-qemu` | `ubuntu-latest` | x86_64 | 需要 | 走 qemu 用户态模拟，和本地 x86 docker 一致 |

两者跑的是**同一个 Dockerfile、同一套脚本**，差异只在：

1. x86_64 需要注册 `qemu-aarch64` binfmt（arm64 跳过）
2. x86_64 慢得多
3. **镜像里 qemu 的安装策略不同**（见下）

**如果两边结果一致 → 说明容器方案架构无关，可靠。**
**如果不一致 → 说明有地方依赖了宿主架构，需要排查。**

矩阵配了 `fail-fast: false`，一个失败不影响另一个 —— 这样能同时看到两边的结果。

### ★ 一个容易踩的坑：qemu 的 `-static` 名字已经不在了

`build-rootfs.sh` 第 50 行按「有没有 `/usr/bin/qemu-aarch64-static`」分流：

```bash
if [ -f /usr/bin/qemu-aarch64-static ]; then
    debootstrap --foreign ...      # 交叉路径，需要 qemu
    chroot ... /debootstrap/debootstrap --second-stage
else
    debootstrap --arch arm64 ...   # 原生路径，不需要 qemu
fi
```

**这个文件名在现代 Debian/Kali 上已经不存在了**，原因是两步上游变更：

| 时间 | 变更 |
|---|---|
| 2024-09<br>qemu 1:9.1.0 | 静态二进制从 `qemu-user-static` **搬到了 `qemu-user`**（`qemu-user` 现在本身就是静态链接），且**去掉了 `-static` 后缀** —— 真身是 `/usr/bin/qemu-aarch64`。当时靠 transitional 包提供 `-static` 兼容软链 |
| 2026-01<br>Debian #1124747 | **`qemu-user-static` 包被整体删除**，职责由 `qemu-user-binfmt` 的 `Provides:` 承接 |

后果：`apt-get install qemu-user-static` **仍然会成功**（被 Provides 满足），但**不再创建任何 `-static` 软链**。于是第 50 行判断恒为假，x86_64 上会**静默**改走原生分支 —— 与脚本设计的 `--foreign` 交叉流程不符。

**本仓库的对策**：Dockerfile 在 x86_64 上装 `qemu-user`（现在它就是静态的），并**补建软链** `/usr/bin/qemu-aarch64-static → qemu-aarch64`。因为是软链到静态二进制，语义成立；`entrypoint.sh` 里还有一层运行时自愈，所以本地 docker 与 CI 都覆盖到，且脚本零改动。

| 宿主架构 | `qemu-user` 装到 | `/usr/bin/qemu-aarch64-static` | 走哪条路 |
|---|---|---|---|
| x86_64 | amd64 版 | 由 Dockerfile/entrypoint 补建 | 交叉 ✅ |
| arm64 | **不装**（原生执行，省 60MB+） | 不存在（正常） | 原生 ✅ |

> **历史 bug（已修）**：早期版本的 `entrypoint.sh` **无条件**检查
> `/proc/sys/fs/binfmt_misc/qemu-aarch64`，导致 arm64 runner 上必然报错退出
> （arm64 原生本来就不需要 binfmt）。现在改为按容器自身架构判断。

### ★★ 另一个坑：`binfmt_misc` 的内容**不跨 namespace 传播**

这是最容易误判的一点 —— **在容器里默认读不到 `/proc/sys/fs/binfmt_misc/qemu-aarch64`，
哪怕宿主已注册且功能完全正常。**

原因：`binfmt_misc` 是一个**伪文件系统**，它的**内容不跨 mount namespace 传播**。
容器的 `/proc` 是独立的 procfs 实例，宿主上 `/proc/sys/fs/binfmt_misc` 这个挂载
不会传播进来。要在容器里看到它，必须**手动挂载**（需要 `--privileged`）：

```bash
mount -t binfmt_misc binfmt_misc /proc/sys/fs/binfmt_misc
```

但**执行**不受影响：binfmt_misc 注册是**内核全局状态**，而且
`multiarch/qemu-user-static --reset -p yes` 会带上 **`F` (fix_binary) 标志** ——
内核在注册时就把 qemu 二进制打开了，之后无论在哪个 namespace 都能用。
这正是 `docker run --platform linux/arm64 alpine uname -m` 能成功的原因。

**所以 `entrypoint.sh` 的判定分三层**：

| 情况 | 处理 |
|---|---|
| 容器自己挂上了 `binfmt_misc`，条目存在 | ✅ 通过，并顺带检查 `F` 标志 |
| 挂上了但**没有**条目（用 `$BINFMT_DIR/status` 是否存在来确认真的挂上了） | ❌ 宿主确实没注册，报错退出 |
| 本就挂不上、也读不到 | ⚠️ **只告警，不阻断** —— 无法判定，以宿主机侧为准 |

> 用 `status` 文件而不是 `mountpoint -q` 来判断「是否真的挂上」：
> 若有人 bind-mount 了一个空目录到该路径，`mountpoint` 也返回真，
> 会让我们误判成「挂上了但没注册」而错误地失败。

这也是为什么 workflow **第 4 步在宿主机上**校验（`cat /proc/sys/fs/binfmt_misc/qemu-aarch64`
+ 实跑一个 arm64 二进制）—— 宿主侧才是权威判定，容器内只是尽力而为。

---

## 四、验证步骤会检查什么

构建完成后，`验证产物` 这一步会做 7 项检查，重点验证**容器适配层**是否真的生效：

| # | 检查项 | 为什么重要 |
|---|---|---|
| 1 | `build/rootfs` 存在 | 基础 |
| 2 | `build/rootfs.img` 存在 | 基础 |
| 3 | **img 内 `/dev` 条目数 < 40** | ★ 最危险的坑：`build-rootfs.sh` 把容器 `/dev` bind 进 chroot，卸不净会把宿主几百个设备节点灌进镜像 |
| 4 | **`qemu-aarch64-static` 已从 img 移除** | ★ 它是 x86_64 二进制，不该进 arm64 产物。原脚本不删 |
| 5 | **`90-naming-audios.rules` 在位** | ★ board hook 是否被正确补调 |
| 6 | **`rtl8852be-reload.service` 在位** | ★ 同上，修 WiFi+BT 共存的 |
| 7 | `e2fsck -fn` 通过 | 文件系统健康度 |

另外第 5 步（构建 docker 镜像）也会按架构检查镜像内的 qemu 策略是否正确。

第 3 项如果失败，会打印 img 内 `/dev` 的前 20 行内容，方便直接看到混入了什么。

任何一项失败都会 `::error::` 并在 Summary 里标红。

---

## 五、构建耗时预期

| 架构 | 首次全量 | 说明 |
|---|---|---|
| arm64 原生 | **40~70 分钟** | 主要是 apt 下载安装 |
| x86_64 + qemu | **90~180 分钟** | qemu 模拟慢 3~8 倍 |

超时设了 **240 分钟**（GitHub 单 job 上限是 6 小时）。

> 建议：日常验证只跑 arm64（改 workflow 的 matrix 注释掉另一项），x86_64 只在需要确认兼容性时跑。

---

## 六、和本地构建的对照

workflow 里的构建命令与 `build/docker/build.sh` **完全同源**：

```bash
# workflow 第 6 步（去掉 tee 和 GITHUB 相关包装后）
docker run --rm \
    --privileged \
    -v "${GITHUB_WORKSPACE}":/work/kali-rootfs \
    -w /work/kali-rootfs \
    -e BOARD=lubancat-4 \
    -e FORCE_REBUILD=1 \
    kali-rootfs-builder:ci
```

所以：

- **CI 跑通 = 本地也大概率跑通**（同一个镜像、同一条命令）
- **CI 挂了，本地用同样命令能复现**（把 `-v` 的路径换成你自己的仓库路径）

这是这个 workflow 的主要价值 —— 它不是另一条构建路径，而是把本地那条搬到云端。

---

## 七、如果构建失败怎么排查

1. **下载构建日志** —— 每次运行都会上传 `build-logs-<arch>` artifact（保留 14 天），含完整日志
2. **看 Summary** —— 体积报告在 Actions 运行的 Summary 页
3. **常见失败点**：

| 现象 | 原因 | 处理 |
|---|---|---|
| `No space left on device` | 清理步骤没生效 | 检查第 1 步输出，确认释放后可用 >20GB |
| **arm64 腿报「qemu-aarch64 binfmt 未注册」** | **entrypoint 旧版无条件检查 binfmt** | **已修：改为按容器架构判断** |
| **x86_64 腿报「镜像缺少 qemu-aarch64-static」** | **Debian 2026-01 删除了 `qemu-user-static` 包，不再创建 `-static` 软链** | **已修：Dockerfile/entrypoint 补建软链指向静态的 `qemu-aarch64`** |
| **x86_64 腿报「宿主机未注册 qemu-aarch64 binfmt」但宿主明明注册了** | **`binfmt_misc` 内容不跨 mount namespace，容器里默认读不到** | **已修：entrypoint 先自行 `mount -t binfmt_misc`；挂不上时只告警不阻断** |
| `Exec format error` | x86_64 上 binfmt 未注册 | 检查第 4 步，`/proc/sys/fs/binfmt_misc/qemu-aarch64` 应存在 |
| `/dev` 条目数告警 | 挂载残留 | 看 entrypoint.sh 的 `umount`/`findmnt` 逻辑 |
| board hook 不生效 | `config_image_hook__` 未补调 | 看日志里 `执行 hook : config_image_hook__lubancat-4` 那行 |
| apt 下载超时 | 镜像源问题 | 见下方「镜像源」说明 |
| `permission denied` 访问 docker | 缺 `sudo` | 本 workflow 已给 `docker run --privileged` 加 `sudo` |
| 超时 | 240 分钟不够 | 调 `timeout-minutes`，或只跑 arm64 |

### 镜像源说明（易误解）

`build-rootfs.sh` 第 37 行配的是 **阿里云** `mirrors.aliyun.com/kali/`，但
**Dockerfile 阶段 `apt-get update` 用的是镜像基础自带的官方源**
（`kali.download` / `http.kali.org`）。

两者互不影响：阿里云只作用于 `debootstrap`（脚本第 53/58 行）。

> GitHub runner 在海外，**官方源反而更快**，所以不要为了「加速」去改 Dockerfile 的源。
> 阿里云那行只有在国内本地调试时才体现优势。本次 Dockerfile 阶段约 27 秒完成，无需优化。

---

## 八、注意事项

### runner 是公开的，代码和产物对所有人可见

仓库是 public，所以：

- workflow 日志**任何人可见**
- 上传的 artifact **任何人可下载**
- 构建产出的 rootfs **含默认弱口令**（`cat/temppwd`、`root/root`），**不要把它当生产镜像分发**

如果 rootfs 要用于生产，至少在首次开机脚本里强制改密。

### 不要在 public 仓库用 self-hosted runner

工作流用的是 GitHub 托管的 runner，没有这个问题。但如果将来想换成 self-hosted，**public 仓库绝不能配 self-hosted runner** —— PR 里的恶意代码会在你的机器上执行。

### 磁盘清理删掉的是 runner 的预装内容

删的都是本项目不需要的（Android SDK、Haskell、.NET、Swift、Java）。如果你的 workflow 后续要加需要这些的步骤，记得保留对应目录。
