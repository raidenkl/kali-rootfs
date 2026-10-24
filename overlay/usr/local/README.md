# overlay/usr/local

本目录里两样东西，进镜像的方式不同：

| 文件 | 是否入库 | 说明 |
|---|---|---|
| `boot_init.sh` | ✅ 入库 | 首启脚本：识别板卡型号、选 DTB/uEnv、扩容 p3、写标记、重启 |
| `linux-image.deb` | ❌ 已 `.gitignore` | **需要你自己放**。体积大，且与 SoC、内核版本强绑定 |

`linux-image.deb` 必须是目标板内核的 `linux-image-*.deb`（RK SDK `bindeb-pkg` 的产物），
文件名固定为 `linux-image.deb`。构建期只从它里面解出 `lib/modules/<ver>/` 固化进 rootfs，
deb 自带的 `/boot` 部分（Image / dtb / uEnv）会被忽略 —— `/boot` 由 `build/firmware/boot.img` 提供。

获取方式、以及「它必须与 `boot.img` 同一次编译」这条硬约束，见
[`build/firmware/README.md`](../../build/firmware/README.md)。

放入后自检：

```bash
dpkg-deb -c overlay/usr/local/linux-image.deb | grep 'lib/modules/.*/modules.dep'
```
