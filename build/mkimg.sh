#!/bin/bash


sudo mkdir fs
sudo dd if=/dev/zero of=fs.img bs=1G count=7
sudo mkfs.ext4 -O ^orphan_file fs.img
sudo mount fs.img fs/
sudo cp -rfp rootfs/* fs/
sudo umount fs/
sudo e2fsck -p -f fs.img
sudo resize2fs -M fs.img
