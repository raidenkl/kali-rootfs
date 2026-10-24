# packages/gpu —— GPU 闭源用户态（libmali）

本目录**只被 `GPU_STACK=libmali|both` 时使用**（见仓库根 `config/gpu-stack.conf`）。
这里的 `*.deb` 会在构建的「GPU 驱动栈」阶段被装进 rootfs，装完即删、不进镜像。
`GPU_STACK=none|panfork` 时本目录完全不参与构建，留在这里也没有副作用。

## 目录结构（按 SoC 分，二者互斥）

```
packages/gpu/
├── rk3588/   Mali-G610 MP4（Valhall / CSF）→ libmali-valhall-g610-*
└── rk3576/   Mali-G52 MC3（Bifrost / JM）  → libmali-bifrost-g52-*
```

构建时按 `SOC` 只取 `packages/gpu/<SOC>/*.deb`。**不要跨目录混放**：
所有 libmali 包都声明 `Provides/Conflicts/Replaces: libmali`，同一系统只能装一份；
`scripts/build-rootfs.sh` 在构建期有硬断言（同一 SoC 目录下 >1 个提供 `libmali` 的 deb 直接中止）。

| SoC | 包 | 大小 | 说明 |
|---|---|---|---|
| `rk3588` | `libmali-valhall-g610-g24p0-x11-gbm_1.9-1_arm64.deb` | 19,228,008 B | Valhall，含 Vulkan ICD |
| `rk3576` | `libmali-bifrost-g52-g24p0-x11-wayland-gbm_1.9-1_arm64.deb` | 18,561,892 B | Bifrost，**不含 Vulkan**，无 CSF 固件 |

来源：<https://github.com/rockchip-linux/libmali> 的 arm64 发行包（`Maintainer: Putin Lee
<putin.li@rock-chips.com>`、`Provides/Conflicts/Replaces: libmali`）。可复现来源：
<https://github.com/tsukumijima/libmali-rockchip/releases>（CI 重新打包，与 SDK 产物同名同大小）。

## 版本搭配：方向才是关键

变体名里的 `g24p0` 是**用户态 blob 的版本**，它与内核 kbase DDK 的版本号不是同一个数字。

> **Rockchip 官方口径**：DDK 版本与 mali-so（用户态 blob）版本难以完全对上时，
> **DDK 可以高于 mali-so，但不允许 mali-so 高于 DDK。**

两台板子的实测都符合这条：RK3588 内核 `g25p0` + blob `g24p0`、RK3576 内核 `g25p0` + blob
`g24p0`（`arm_release_ver: g24p0-00eac0`）—— DDK 更高，允许且实测可用。
反过来才要警惕（`g26p0` 用户态 + `g25p0` 内核官方明说不允许）。

`scripts/libmali-verify.sh` 的 `gen_cmp()` 实现了这个方向判定（先比 `g` 后 major、再比 `p` 后 minor），
`status` / `--probe` 会直接告诉你属于"允许 / 一致 / 不允许"哪一种。

## 两个 SoC 的能力差异（实拆 deb + 板上实测）

| 通路 | rk3588（G610） | rk3576（G52） |
|---|---|---|
| OpenGL ES / EGL | ✅ | ✅（`OpenGL_ES 1.5 Bifrost-"g24p0-00eac0"`） |
| OpenCL | ✅ | ✅（`libMaliOpenCL.so.1` + `mali.icd`） |
| **Vulkan** | ✅ `vulkan/icd.d/mali.json`（1.3.276） | ❌ **包内无 `mali/libMaliVulkan.so.1`、无 ICD json** |
| CSF 固件 `mali_csffw.bin` | 包内含（内核对本板惰性） | **包内没有**（Bifrost 无 CSF 环节） |
| `mali/` 包装库 | EGL / GLESv1 / GLESv2 / GBM / OpenCL / Vulkan | EGL / GLESv1 / GLESv2 / GBM / OpenCL / **wayland-egl** |
| 无 X 的 GBM/DRM 直出 | ✅ 60fps | ✅ 同机制（`kmscube` 验证） |
| X11 窗口 / 桌面 GL | ❌ `0x3001`（需厂商补丁 xserver） | ❌ 同（stock Xorg 给不出 mali DRI 设备） |

> ⚠️ **RK3576 不要期待 Vulkan**：这份 `x11-wayland-gbm` 包里没有 Vulkan 库与 ICD 注册。
> 构建脚本给 `libMaliVulkan.so.1` 建软链时会因为文件不存在而自动跳过（`[ -e ]` 守卫），属预期。

## 装进镜像后会自动做两件事（由 `scripts/build-rootfs.sh` 完成）

1. **摘掉全局库注入**：该 deb 自带 `/etc/ld.so.conf.d/00-aarch64-mali.conf`，把
   `/usr/lib/aarch64-linux-gnu/mali` 插到全局搜索最前。留着它会让 **Xorg 也加载
   libmali 的 EGL/GBM** → glamor 的 glyph 着色器需要 `GL_EXT_blend_func_extended`
   （libmali 的 GLES 不支持）→ `GLSL compile failure` → **Xorg fatal → lightdm
   重启死循环 + HDMI 狂刷 `use tmds mode` + 桌面黑屏**。构建脚本会把它注释掉，
   libmali 只按需启用。
2. **给 ICD 建软链**：`libMaliOpenCL.so.1`（两台 SoC 都有）、`libMaliVulkan.so.1`
   （仅 rk3588 存在）在标准库目录建软链，让 `clinfo` / Vulkan 免设置可用
   （这两个名字唯一，Xorg 不会加载，可逆）。

## 怎么按需用（不靠全局注入）

```bash
LD_LIBRARY_PATH=/usr/lib/aarch64-linux-gnu/mali clinfo          # OpenCL
LD_LIBRARY_PATH=/usr/lib/aarch64-linux-gnu/mali kmscube         # 无 X 的 DRM 直出
env -u DISPLAY LD_LIBRARY_PATH=/usr/lib/aarch64-linux-gnu/mali glmark2-es2 --off-screen
```

排查/验证用仓库的 `scripts/libmali-verify.sh`（`--route` 看路由、`--which <程序>`
看某程序会走哪套、`--nodisp` 是不依赖显示器的探针）。

## 换成别的变体 / 别的版本

- 换 libmali 变体（例如 `wayland-gbm`、或与内核 DDK 同代的版本）：把对应的 `*.deb`
  放进**对应 SoC 的子目录**、删掉旧的即可。指纹里带文件名与大小，换包会自动让 GPU 阶段重跑。
- ⚠️ **同一 SoC 目录下不要放多个提供 `libmali` 的 deb。** 后果不是"报个冲突"那么简单，
  而是**系统里出现两个 OpenCL 平台、两份 blob**（各 40~57 MB），程序按平台序号选，
  可能选到不同版本 —— 板上手工装过 `libmali-g610-x11`（PPA，g13p0）+ Rockchip deb（g24p0）
  就是这个状态，`clinfo` 会显示 `Number of platforms 2`。
- 判断某个 deb 是不是"提供 libmali 的那份"：`dpkg-deb -f <deb> Package Provides | grep -i libmali`
- 完全不想用 libmali：把 `GPU_STACK` 设成 `none` 或 `panfork`，本目录内容不参与构建。
