#!/bin/sh
sh clean.sh

echo "Creating nick.img..."
bximage -hd -mode="flat" -size=60 -q bochs/nick.img

echo "Compiling..."
# brew install i386-elf-gcc
x86_64-elf-gcc -c -o kernel/main.o kernel/main.c
x86_64-elf-ld kernel/main.o -Ttext 0xc0001500 -e main -o kernel/kernel.bin
nasm -I boot/include/ -o boot/mbr.bin boot/mbr.S
nasm -I boot/include/ -o boot/loader.bin boot/loader.S

echo "Writing mbr and loader to disk..."
dd if=boot/mbr.bin of=bochs/nick.img bs=512 count=1 conv=notrunc
dd if=boot/loader.bin of=bochs/nick.img bs=512 count=4 seek=2 conv=notrunc
dd if=kernel/kernel.bin of=bochs/nick.img bs=512 count=200 seek=9 conv=notrunc


echo "Now start bochs and have fun!"
bochs -f bochs/boot.disk 