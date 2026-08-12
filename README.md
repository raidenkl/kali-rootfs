## 0.说明
一个可以构建kali-rootfs的脚本，适用于rk系列的芯片，要求主机是kali linux系统。
`/overlay/usr/local/linux-image.deb`替换成实际的内核deb包，仓库里的是6.1.99的内核，对应的内核地址：https://github.com/LubanCat/kernel
## 1.用法
### 安装依赖
```
sudo apt-get install -y build-essential gcc-aarch64-linux-gnu bison \
qemu-user-static qemu-system-arm u-boot-tools binfmt-support \
debootstrap flex libssl-dev bc rsync kmod cpio xz-utils fakeroot parted \
udev dosfstools uuid-runtime git-lfs device-tree-compiler python3 fdisk \
python-is-python3 python2
```
然后执行仓库里`scripts/build-rootfs.sh`这个脚本即可，然后用`build/mk-image.sh`脚本打包成img镜像，就是rootfs分区镜像。
