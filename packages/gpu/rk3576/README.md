# packages/gpu/rk3576 —— Mali-G52 MC3（Bifrost）

只在 `SOC=rk3576 GPU_STACK=libmali|both` 时使用。

| 项 | 值 |
|---|---|
| 包 | `libmali-bifrost-g52-g24p0-x11-wayland-gbm_1.9-1_arm64.deb` |
| 大小 | 18,561,892 B |
| SHA256 | `09A4A62C7CAFB6E8AD4BE0C730BB50C3C3557D1CC66D0A910AD34D46E3A06080` |
| 来源 | <https://github.com/tsukumijima/libmali-rockchip/releases/tag/v1.9-1-20260923-ec78b74>（Rockchip `libmali` 的 Debian 重打包，`Maintainer: Putin Lee <putin.li@rock-chips.com>`） |
| 等价来源 | LubanCat SDK：`external/libmali/` 或 `debian/packages/arm64/libmali/` 下的同名 deb（同源同大小，可互换） |
| 对应内核 | `6.1.99-rk3576`，kbase DDK `g25p0-00eac0`，GPU `arch 7.4.0`（G52 r1p0） |

## 包内容（实拆）

```
usr/lib/aarch64-linux-gnu/libmali.so.1.9.0                  56,387,136   ← 实体 blob（g24p0-00eac0）
usr/lib/aarch64-linux-gnu/mali/libEGL.so.1                       5,928
usr/lib/aarch64-linux-gnu/mali/libGLESv1_CM.so.1                 5,928
usr/lib/aarch64-linux-gnu/mali/libGLESv2.so.2                    5,928
usr/lib/aarch64-linux-gnu/mali/libgbm.so.1                       5,928
usr/lib/aarch64-linux-gnu/mali/libMaliOpenCL.so.1                5,928
usr/lib/aarch64-linux-gnu/mali/libwayland-egl.so.1               5,928
etc/ld.so.conf.d/00-aarch64-mali.conf                               32   ← 全局注入，构建期必须摘
etc/OpenCL/vendors/mali.icd                                         19   ← 裸库名 libMaliOpenCL.so.1
etc/profile.d/mali-priority.sh                                      40
```

**没有**的东西（和 rk3588 那份的关键差异）：

- ❌ `mali/libMaliVulkan.so.1` 与 `usr/share/vulkan/icd.d/mali.json` → **本包不提供 Vulkan**
- ❌ `/lib/firmware/mali_csffw.bin` → Bifrost 是 JM 架构，**没有 CSF 固件环节**
  （本板 `/lib/firmware` 下也确实没有 mali 文件，`CONFIG_MALI_CSF_*` 不会请求它）

## 依赖

`libc6 / libdrm2 / libgcc-s1 / libstdc++6 / libwayland-client0 / libwayland-server0 /
libx11-6 / libx11-xcb1 / libxcb-dri2-0 / libxcb-dri3-0 / libxcb-present0 /
libxcb-xfixes0 / libxcb1`

注意比 rk3588 那份多了 `libwayland-*` 与 `libxcb-dri3-0/present/xfixes` ——
Kali 上若没装 Wayland 运行库，`apt install ./deb` 会自动补（体积很小）。

## 验证要点（RK3576）

```bash
clinfo | grep -iE 'Device Name|Device Version'     # 期望 Mali-G52 / v1.g24p0
sudo systemctl stop lightdm
sudo env -u DISPLAY LD_LIBRARY_PATH=/usr/lib/aarch64-linux-gnu/mali kmscube
sudo systemctl start lightdm
```

- **不要用 `glxinfo` 判 libmali**：桌面 GL 仍归 Mesa/llvmpipe，属结构性限制。
- **X11 下 `es2_info` 仍会 `0x3001`**：libmali 走 X11 需要 Rockchip 打过补丁的
  `xserver-xorg-core`，stock Kali Xorg 给不出 mali 兼容的 DRI 设备；桌面 GL 请用 panfork。
- `vulkaninfo` 在本包上**不会**看到 Mali（没有 ICD），这是预期，不是故障。
