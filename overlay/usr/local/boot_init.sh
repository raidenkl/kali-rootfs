#!/bin/bash -eE
# -E：让 ERR trap 在函数/子 shell 里也生效，保证任何一步失败都能在
# 串口控制台上看到失败行号（否则首启失败完全静默，看起来像卡死）。

### BEGIN INIT INFO
# Provides:          LubanCat
# Required-Start:
# Required-Stop:
# Default-Start:
# Default-Stop:
# Short-Description:
# Description:       This script initializes custom services or configurations at boot time.
### END INIT INFO

PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

trap 'echo "[boot_init] FAILED at line ${LINENO}" >/dev/console 2>&1 || true' ERR

board_info() {
	if [[ "$2" == "rk3566" ||  "$2" == "rk3568" ]]; then
		case $1 in
			0000)
				BOARD_NAME='LubanCat-1'
				BOARD_DTB='rk3566-lubancat-1.dtb'
				BOARD_uEnv='uEnvLubanCat1.txt'
				;;
			0001)
				BOARD_NAME='LubanCat-1IOF'
				BOARD_DTB='rk3566-lubancat-1io.dtb'
				BOARD_uEnv='uEnvLubanCat1IO.txt'
				;;
			0002)
				BOARD_NAME='LubanCat-1IOB'
				BOARD_DTB='rk3566-lubancat-1io.dtb'
				BOARD_uEnv='uEnvLubanCat1IO.txt'
				;;
			0007)
				BOARD_NAME='LubanCat-1IO-test'
				BOARD_DTB='rk3566-lubancat-1io-test.dtb'
				BOARD_uEnv='uEnvLubanCat1IO-test.txt'
				;;
			0100)
				BOARD_NAME='LubanCat-1N'
				BOARD_DTB='rk3566-lubancat-1n.dtb'
				BOARD_uEnv='uEnvLubanCat1N.txt'
				;;
			0102)
				BOARD_NAME='LubanCat-2IOBI'
				BOARD_DTB='rk3568-lubancat-2io.dtb'
				BOARD_uEnv='uEnvLubanCat2IO.txt'
				;;
			0200)
				BOARD_NAME='LubanCat-0N'
				BOARD_DTB='rk3566-lubancat-0.dtb'
				BOARD_uEnv='uEnvLubanCatZN.txt'
				;;
			0201)
				BOARD_NAME='LubanCat-1H'
				BOARD_DTB='rk3566-lubancat-1h.dtb'
				BOARD_uEnv='uEnvLubanCat1H.txt'
				;;
			0300)
				BOARD_NAME='LubanCat-0W'
				BOARD_DTB='rk3566-lubancat-0.dtb'
				BOARD_uEnv='uEnvLubanCatZW.txt'
				;;
			0304)
				BOARD_NAME='LubanCat-CM4'
				BOARD_DTB='rk3566-lubancat-cm4.dtb'
				BOARD_uEnv='uEnvLubanCatCM4.txt'
				;;
			0400)
				BOARD_NAME='LubanCat-2'
				BOARD_DTB='rk3568-lubancat-2.dtb'
				BOARD_uEnv='uEnvLubanCat2.txt'
				;;
			0402)
				BOARD_NAME='LubanCat-2 v1'
				BOARD_DTB='rk3568-lubancat-2-v1.dtb'
				BOARD_uEnv='uEnvLubanCat2-V1.txt'
				;;
			0403)
				BOARD_NAME='LubanCat-2 v2'
				BOARD_DTB='rk3568-lubancat-2-v2.dtb'
				BOARD_uEnv='uEnvLubanCat2-V2.txt'
				;;
			0404)
				BOARD_NAME='LubanCat-2 v3'
				BOARD_DTB='rk3568-lubancat-2-v3.dtb'
				BOARD_uEnv='uEnvLubanCat2-V3.txt'
				;;
			0500 |\
			0600)
				BOARD_NAME='LubanCat-2N'
				BOARD_DTB='rk3568-lubancat-2n.dtb'
				BOARD_uEnv='uEnvLubanCat2N.txt'
				;;
			0501)
				BOARD_NAME='LubanCat-2N v2'
				BOARD_DTB='rk3568-lubancat-2n-v2.dtb'
				BOARD_uEnv='uEnvLubanCat2N-V2.txt'
				;;
			0502)
				BOARD_NAME='LubanCat-2N v3'
				BOARD_DTB='rk3568-lubancat-2n-v3.dtb'
				BOARD_uEnv='uEnvLubanCat2N-V3.txt'
				;;
			0601)
				BOARD_NAME='LubanCat-2H'
				BOARD_DTB='rk3568-lubancat-2h.dtb'
				BOARD_uEnv='uEnvLubanCat2H.txt'
				;;
			0700)
				BOARD_NAME='LubanCat-2IOF'
				BOARD_DTB='rk3568-lubancat-2io.dtb'
				BOARD_uEnv='uEnvLubanCat2IO.txt'
				;;
			0701)
				BOARD_NAME='LubanCat-2IOB'
				BOARD_DTB='rk3568-lubancat-2io.dtb'
				BOARD_uEnv='uEnvLubanCat2IO.txt'
				;;
			*)
				echo "Device ID Error !!!"
				BOARD_NAME='LubanCat-RK356X'
				BOARD_DTB='rk356x-lubancat-generic.dtb'
				BOARD_uEnv='uEnvLubanCat.txt'
				;;
		esac
	elif [[ "$2" == "rk3588" ||  "$2" == "rk3588s" ]]; then
			case $1 in
			0101)
				BOARD_NAME='LubanCat-4'
				BOARD_DTB='rk3588s-lubancat-4.dtb'
				BOARD_uEnv='uEnvLubanCat4.txt'
				;;
			0102)
				BOARD_NAME='LubanCat-4 v1'
				BOARD_DTB='rk3588s-lubancat-4-v1.dtb'
				BOARD_uEnv='uEnvLubanCat4-V1.txt'
				;;
			0201)
				BOARD_NAME='LubanCat-4IOF'
				BOARD_DTB='rk3588s-lubancat-4io.dtb'
				BOARD_uEnv='uEnvLubanCat4IO.txt'
				;;
			0301)
				BOARD_NAME='LubanCat-4IOB'
				BOARD_DTB='rk3588s-lubancat-4io.dtb'
				BOARD_uEnv='uEnvLubanCat4IO.txt'
				;;
			0401)
				BOARD_NAME='LubanCat-5'
				BOARD_DTB='rk3588-lubancat-5.dtb'
				BOARD_uEnv='uEnvLubanCat5.txt'
				;;
			0402)
				BOARD_NAME='LubanCat-5 v2'
				BOARD_DTB='rk3588-lubancat-5-v2.dtb'
				BOARD_uEnv='uEnvLubanCat5-V2.txt'
				;;
			0501)
				BOARD_NAME='LubanCat-5IOF'
				BOARD_DTB='rk3588-lubancat-5io.dtb'
				BOARD_uEnv='uEnvLubanCat5IO.txt'
				;;
			0601)
				BOARD_NAME='LubanCat-5IOB'
				BOARD_DTB='rk3588-lubancat-5io.dtb'
				BOARD_uEnv='uEnvLubanCat5IO.txt'
				;;
            0701)
                BOARD_NAME='LubanCat-5IOBI'
                BOARD_DTB='rk3588-lubancat-5ioi.dtb'
                BOARD_uEnv='uEnvLubanCat5IO.txt'
                ;;
			*)
				echo "Device ID Error !!!"
				BOARD_NAME='LubanCat-RK3588'
				BOARD_DTB='rk3588-lubancat-generic.dtb'
				BOARD_uEnv='uEnvLubanCat.txt'
				;;
		esac
	fi

	echo "BOARD_NAME:"$BOARD_NAME
	echo "BOARD_DTB:"$BOARD_DTB
	echo "BOARD_uEnv:"$BOARD_uEnv
}

# voltage_scale
# 1.7578125 1.8v/10bit
# 3.222656250 3.3v/10bit
# 0.439453125 1.8v/12bit
# 0.8056640625 3.3v/12bit
get_index(){

	ADC_RAW=$(cat /sys/bus/iio/devices/iio\:device0/in_voltage${1}_raw 2>/dev/null || echo 0)
	echo ADC_CH:$1 ADC_RAW:$ADC_RAW
	INDEX=0xff

	if awk -v s="$ADC_voltage_scale" 'BEGIN{exit !(s > 1)}' ; then
		declare -a ADC_INDEX=(229 344 460 595 732 858 975 1024)
	else
		declare -a ADC_INDEX=(916 1376 1840 2380 2928 3432 3900 4096)
	fi

	for i in 00 01 02 03 04 05 06 07; do
		if [ $ADC_RAW -lt ${ADC_INDEX[$i]} ]; then
			INDEX=$i
			break
		fi
	done
}

board_id() {
	ADC_voltage_scale=$(cat /sys/bus/iio/devices/iio\:device0/in_voltage_scale 2>/dev/null || echo 0)
	echo "ADC_voltage_scale:"$ADC_voltage_scale

	SOC_type=$(cat /proc/device-tree/compatible | cut -d,  -f 3 | sed 's/\x0//g')
	echo "SOC_type:"$SOC_type

	if [[ "$SOC_type" == "rk3128" ]]; then
		get_index 0; ADC_INDEX_H=$INDEX
		get_index 2; ADC_INDEX_L=$INDEX
	else
		get_index 2; ADC_INDEX_H=$INDEX
		get_index 3; ADC_INDEX_L=$INDEX
	fi

	BOARD_ID=$ADC_INDEX_H$ADC_INDEX_L
	echo "BOARD_ID:"$BOARD_ID
}

board_id
board_info ${BOARD_ID} ${SOC_type}

# first boot configure

# until [ -e "/dev/disk/by-partlabel/boot" ]
# do
# 	echo "wait /dev/disk/by-partlabel/boot"
# 	sleep 0.1
# done
sleep 0.2

echo "[boot_init] board=$BOARD_NAME dtb=$BOARD_DTB uEnv=$BOARD_uEnv"
echo "[boot_init] checking first-boot state ..."

if [ ! -e "/boot/boot_init" ] ; then
	if [ ! -e "/dev/disk/by-partlabel/userdata" ] ; then
		if [ ! -L "/boot/rk-kernel.dtb" ] ; then
			for x in $(cat /proc/cmdline); do
				case $x in
				root=*)
					Root_Part=${x#root=}
					Boot_Part="${Root_Part::-2}"p2
					;;
				esac
			done

			echo "[boot_init] mount $Boot_Part -> /boot"
			mount "$Boot_Part" /boot
			echo "$Boot_Part  /boot  auto  defaults  0 2" >> /etc/fstab
			echo "[boot_init] /boot fstab entry added"
		fi

		# service lightdm stop || echo "skip error"

		# apt install -fy --allow-downgrades /boot/kerneldeb/* || true
		# apt-mark hold linux-headers-$(uname -r) linux-image-$(uname -r) || true

		echo "[boot_init] select dtb/uEnv: $BOARD_DTB / $BOARD_uEnv"
		ln -sf dtb/$BOARD_DTB /boot/rk-kernel.dtb
		ln -sf $BOARD_uEnv /boot/uEnv/uEnv.txt

		touch /boot/boot_init
		rm -f /boot/kerneldeb/*
		cp -f /boot/logo_kernel.bmp /boot/logo.bmp
		echo "[boot_init] first-boot markers written (/boot/boot_init)"
		#reboot
	else
		echo "PARTLABEL=oem  /oem  ext2  defaults  0 2" >> /etc/fstab
		echo "PARTLABEL=userdata  /userdata  ext2  defaults  0 2" >> /etc/fstab
		touch /boot/boot_init
	fi
fi

#判断/boot/boot_dilatation_init文件是否存在,不存在则进行扩容
if [ ! -e "/boot/boot_dilatation_init" ] ;
   then

   #先判断是否需要扩容：文件系统已占满分区就整段跳过，
   #避免在运行中的根盘上做不必要的分区表操作
   PART_BYTES="$(blockdev --getsize64 /dev/mmcblk0p3 2>/dev/null || echo 0)"
   FS_BYTES="$(dumpe2fs -h /dev/mmcblk0p3 2>/dev/null | awk -F: '/Block count/{c=$2} /Block size/{s=$2} END{print c*s}')"
   echo "[boot_init] partition=${PART_BYTES:-0} bytes, filesystem=${FS_BYTES:-unknown} bytes"

   NEED_RESIZE=1
   if [ -n "${FS_BYTES}" ] && [ -n "${PART_BYTES}" ] && [ "${FS_BYTES}" -ge "${PART_BYTES}" ] 2>/dev/null; then
      NEED_RESIZE=0
      echo "[boot_init] filesystem already fills the partition, skip resize"
   fi

   if [ "${NEED_RESIZE}" = "1" ]; then
      #转换MBR -> GPT分区表（失败不致命）
      sgdisk -e /dev/mmcblk0 || true

      #扩展根分区：优先 growpart（非交互、支持在线分区），退化为 parted -s。
      #原来的 printf|parted ---pretend-input-tty 会被部分 parted 版本拒绝
      #（"Error: Invalid number."），非零返回被 set -e 捕获后脚本直接退出，
      #导致 resize2fs / touch / reboot 全部执行不到。
      if command -v growpart >/dev/null 2>&1; then
         growpart /dev/mmcblk0 3 || parted -s /dev/mmcblk0 resizepart 3 100% || true
      else
         parted -s /dev/mmcblk0 resizepart 3 100% || true
      fi

      #刷新内核分区表：只作用于具体分区，避免全盘重读
      partx -u /dev/mmcblk0p3 2>/dev/null || partprobe /dev/mmcblk0 2>/dev/null || true

      #根据配置重新分配空间
      resize2fs /dev/mmcblk0p3 || true
   fi

	#创建判断文件，第二次启动存在该文件不再执行此扩容
	touch /boot/boot_dilatation_init
	echo "[boot_init] resize stage done, marker written"

	# 等待首启内核 deb 安装完成，再重启（避免重启打断 dpkg 造成半安装）
	if systemctl is-enabled --quiet kernel-install.service 2>/dev/null; then
		echo "[boot_init] waiting for kernel-install.service (dpkg linux-image.deb) ..."
		systemctl start kernel-install.service || true
		echo "[boot_init] kernel-install finished"
	fi

	# 不能直接用 `reboot`：脚本由 systemd 服务(或 SysV 兼容单元)承载时，
	# 阻塞式 reboot 会自锁——重启事务要求先停止承载本脚本的服务，而脚本
	# 进程正阻塞在 reboot 里等待重启完成，重启因此永远不会发生
	# （首次开机不自动重启的根因）。--no-block 立即返回，重启交给
	# systemd 异步执行。
	sync
	echo "[boot_init] all done, rebooting to apply new dtb/partition table ..."
	if [ -d /run/systemd/system ]; then
		systemctl --no-block reboot
	else
		reboot
	fi
fi