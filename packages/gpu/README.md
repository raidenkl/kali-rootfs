# packages/gpu —— GPU 闭源用户态（libmali）

本目录**只被 `GPU_STACK=libmali|both` 时使用**（见仓库根 `config/gpu-stack.conf`）。
这里的 `*.deb` 会在构建的「GPU 驱动栈」阶段被装进 rootfs，装完即删、不进镜像。
`GPU_STACK=none|panfork` 时本目录完全不参与构建，留在这里也没有副作用。

## 当前内容

| 文件 | 说明 |
|---|---|
| `libmali-valhall-g610-g24p0-x11-gbm_1.9-1_arm64.deb` | Rockchip 官方 libmali 用户态（19 MB） |

来源：<https://github.com/rockchip-linux/libmali> 的 arm64 发行包（`Maintainer: Putin Lee
<putin.li@rock-chips.com>`、`Provides/Conflicts/Replaces: libmali`）。变体名里的
`g24p0` 是**用户态 blob 的版本**，与本板内核的 kbase DDK（`g25p0-00eac0`）不是同一个数字
—— 但这**不是问题**，方向才是关键：

> **Rockchip 官方口径**：DDK 版本与 mali-so（用户态 blob）版本难以完全对上时，
> **DDK 可以高于 mali-so，但不允许 mali-so 高于 DDK。**

所以本组合（内核 `g25p0` + blob `g24p0`，DDK 更高）是**正常且允许**的；实测也印证了这一点：
OpenCL 能枚举 `Mali-G610 r0p0`、`kmscube` 稳定 60fps，`g13p0` 那份同样能跑。
反过来才要警惕 —— **blob 比内核新（如 `g26p0` 用户态配 `g25p0` 内核）官方明说不允许**，
那是最可能"一切都对但就是起不来"的原因。

`scripts/libmali-verify.sh` 里的 `gen_cmp()` 实现了这个方向判定（先比 `g` 后的 major、
再比 `p` 后的 minor），`status` / `--probe` 会直接告诉你属于"允许 / 一致 / 不允许"哪一种。

## 它提供什么 / 不提供什么

| 通路 | 状态 | 证据 |
|---|---|---|
| OpenGL ES 3.2 / EGL 1.5 | ✅ | `es2_info` → `GL_RENDERER: Mali-G610` |
| OpenCL 3.0 | ✅ | `clinfo` → `ARM Platform / Mali-G610 r0p0` |
| Vulkan 1.3.276 | ✅ | `vulkan/icd.d/mali.json`（枚举需在正常 X 会话里跑 vulkaninfo） |
| 无 X 的 GBM/DRM 直出 | ✅ | `kmscube` → 稳定 60.00 fps |
| **X11 窗口 / 桌面 GL（glamor）** | ❌ | `eglInitialize 0x3001` —— stock Debian Xorg 给不出 mali 兼容的 DRI 设备。**桌面加速请用 panfork** |

## 装进镜像后会自动做两件事（由 `scripts/build-rootfs.sh` 完成）

1. **摘掉全局库注入**：该 deb 自带 `/etc/ld.so.conf.d/00-aarch64-mali.conf`，把
   `/usr/lib/aarch64-linux-gnu/mali` 插到全局搜索最前。留着它会让 **Xorg 也加载
   libmali 的 EGL/GBM** → glamor 的 glyph 着色器需要 `GL_EXT_blend_func_extended`
   （libmali 的 GLES 不支持）→ `GLSL compile failure` → **Xorg fatal → lightdm
   重启死循环 + HDMI 狂刷 `use tmds mode` + 桌面黑屏**。构建脚本会把它注释掉，
   libmali 只按需启用。
2. **给 ICD 建软链**：`libMaliOpenCL.so.1` / `libMaliVulkan.so.1` 在标准库目录建软链，
   让 `clinfo` / Vulkan 免设置可用（这两个名字唯一，Xorg 不会加载，可逆）。

## 怎么按需用（不靠全局注入）

```bash
LD_LIBRARY_PATH=/usr/lib/aarch64-linux-gnu/mali clinfo          # OpenCL
LD_LIBRARY_PATH=/usr/lib/aarch64-linux-gnu/mali kmscube         # 无 X 的 DRM 直出
env -u DISPLAY LD_LIBRARY_PATH=/usr/lib/aarch64-linux-gnu/mali glmark2-es2 --off-screen
```

排查/验证用仓库的 `scripts/libmali-verify.sh`（`--route` 看路由、`--which <程序>`
看某程序会走哪套、`--nodisp` 是不依赖显示器的探针）。

## 换成别的变体 / 别的版本

- 想换 libmali 变体（例如 `wayland-gbm`、或与内核 DDK 同代的 g25p0 版本）：把对应的
  `*.deb` 放进本目录、删掉旧的即可。构建脚本按 `packages/gpu/*.deb` 通配安装，
  指纹里带文件名与大小，换包会自动让 GPU 阶段重跑。
- ⚠️ **不要同时放多个提供 `libmali` 的 deb。** 它们都声明 `Conflicts/Replaces: libmali`，
  装上两份的后果不是"报个冲突"那么简单，而是**系统里出现两个 OpenCL 平台、两份 blob**
  （各 40~57 MB），程序按平台序号选，可能选到不同版本 —— 板上手工装过
  `libmali-g610-x11`（PPA，g13p0）+ 本目录的 Rockchip deb（g24p0）就是这个状态，
  `clinfo` 会显示 `Number of platforms 2`、两个不同的 `Device Version`。
  `scripts/build-rootfs.sh` 已在构建期做**硬断言**：`packages/gpu/` 下超过一个提供
  `libmali` 的 deb 就直接中止构建，不会产出这种镜像。
- 判断某个 deb 是不是"提供 libmali 的那份"：`dpkg-deb -f <deb> Package Provides | grep -i libmali`
- 完全不想用 libmali：把 `GPU_STACK` 设成 `none` 或 `panfork`，本目录内容不参与构建。
