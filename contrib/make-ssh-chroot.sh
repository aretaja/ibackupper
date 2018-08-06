#!/bin/bash
#
# make-ssh-chroot.sh
# Copyright 2018 by Marko Punnar <marko[AT]aretaja.org>
# Version: 1.3
#
# Creates or updates minimal ibackuper compatible chroot environment in user
# homedir. Chroot contains bash, cat, tar, gzip and rsync.
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program.  If not, see <http://www.gnu.org/licenses/>
#
# Changelog:
# 1.0 Initial release.
# 1.1 Change only user for all files in user chroot.
#     Chmod 0700 user chrooted homedir.
#     Fix symlink creation command.
# 1.2 Include tar and gzip in chroot.
#     Code optimizations
# 1.3 Make shure homedir permissions are correct.

# show help if requested or no args
if [ $# -eq 0 ] || [ "$1" = '-h' ] || [ "$1" = '--help' ]
then
    echo "Creates or updates ibackuper compatible minimal chroot environment"
    echo "in user homedir to make rsync backups over ssh."
    echo "Requires chroot enabled sshd config, installed rsync package and existing user."
    echo "Usage:"
    echo "       sudo $0 <user>"
    exit 1
fi

user=$1

# make sure we are root
if [ "$EUID" -ne 0 ]
then
   echo '[ERROR] This script must be run as root! Interrupting..' 1>&2
   exit 1
fi

# check if user exist
userinf=$(grep -P "^${user}:" /etc/passwd)
if [ $? -ne 0 ]
then
   echo "[ERROR] No such user - $user! Interrupting.." 1>&2
   exit 1
fi

# extract homedir and shell
homedir=$(echo "$userinf" |cut -d ':' -f6)
binaries[0]=$(echo "$userinf" |cut -d ':' -f7)

if [ ! -d "$homedir" ]
then
    echo "[ERROR] Homedir $homedir not exists! Interrupting.." 1>&2
    exit 1
fi

# shellcheck disable=SC2001
chhomedir=$(echo "$homedir" |sed 's/^.//')

# change to user homedir
cd "$homedir" || { echo "[ERROR] cd to $homedir failed" 1>&2; exit 1; }
if [ "$PWD" != "$homedir" ]
then
    echo "[ERROR] We are in wrong directory ${PWD}! Interrupting.." 1>&2
    exit 1
fi

# check if required binaries are installed and save their full path if true
cnt=1
for b in 'cat' 'tar' 'gzip' 'rsync'
do
    binaries[$cnt]=$(which "$b")
    if [ -z "${binaries[$cnt]}" ]
    then
        echo "[ERROR] $b is not installed! Interrupting.." 1>&2
        exit 1
    fi
    (( cnt++ ))
done

# create chroot
mkdir -p dev bin usr/bin "$chhomedir/archives"
ln -s "$chhomedir/archives" archives
chown -R "${user}" ./*
chown root:root "$homedir"
chmod 0755 "$homedir"
chmod 0700 "$chhomedir"
mknod -m 666 dev/null c 1 3
mknod -m 666 dev/tty c 5 0
mknod -m 666 dev/zero c 1 5
mknod -m 666 dev/random c 1 8

# copy binaries
for b in "${binaries[@]}"
do
    cp -v "$b" "$(dirname "$b" |sed 's/^.//')/"
done

# find and copy required libraries
for b in "${binaries[@]}"
do
    for l in $(ldd "$b" |grep -P '\s/' |sed 's/^.*\s\(\/.*\)\s.*/\1/')
    do
        if [ -z "$l" ]
        then
            continue
        fi
        mkdir -p "$(dirname "$l" |sed 's/^.//')"
        cp -v "$l" "$(dirname "$l" |sed 's/^.//')/"
    done
done

echo "[INFO] $homedir chroot done."
exit
