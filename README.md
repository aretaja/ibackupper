# ibackupper
Send incremental-, SQL-, file backups of your data and move compressed old logs to remote target, using rsync and ssh. Optionally create minimal chroot environment on remote target (script included). Requires tar, gzip, bash, rsync and cat on both ends and ssh key login without password to remote end. Must be executed as root.

## Getting Started
Installation on Debian

### Prerequisites
Make sure you have **tar**, **gzip**, **bash**, **rsync** and **cat** installed on source and destination servers.

## Example setup
Lets name our source server as *src_srv* and backup server as *dst_srv* for clearity.
### Destination (dst_srv)
#### Create group *backuppers*
```
sudo addgroup backuppers
```
#### Create user *dst_srv* with homedir located in your backup directory
```
sudo adduser src_srv --shell /bin/bash --home /backupstorage/src_srv --disabled-password
sudo adduser src_srv backuppers
```
#### Allow src_srv root user to login with key via ssh to this account

#### Create minimal chroot environment for this user
* Use **make-ssh-chroot.sh** script from contrib dir
```
sudo make-ssh-chroot.sh src_srv
```
#### Setup chrooted ssh/sftp for this user
* Modify sshd config
```
# Modify sftp subsystem
Subsystem       sftp    internal-sftp

# Force all users from backuppers group to chroot
Match Group backuppers
    ChrootDirectory %h
    AllowTcpForwarding no
```
### Source (src_srv)
#### Check ssh connectivity
```
sudo -i
ssh src_srv@dst_srv
```
#### Install ibackupper
```
git clone https://github.com/aretaja/ibackupper
cd ibackupper
sudo ./install.sh
```
#### Configure ibackupper
```
sudo cp /opt/ibackupper/ibackupper.conf_example /opt/ibackupper/ibackupper.conf
sudo vim /opt/ibackupper/ibackupper.conf
sudo chmod 0600 /opt/ibackupper/ibackupper.conf
```
#### Setup cron job for backup
* Append to */etc/crontab*
```
# Backup
55 1    * * *   root    /opt/ibackupper/ibackupper.sh >>/var/log/ibackupper.log 2>&1
```
#### Configure logrotate
* Create file */etc/logrotate.d/ibackupper*
```
/var/log/ibackupper.log {
        monthly
        missingok
        rotate 12
        copytruncate
        compress
        delaycompress
        notifempty
        create 640 root adm
}
```

## Last run datafile
* After firs run file *last_data* will be created. This file can be used for monitoring if needed.
* Example content:
```
time_start=1535376270 # Backup start timestamp
server_connection=ok|errors # Status of ssh connectivity to server
last_ok_inc_backup=day_of_month_27 # Last inc backup without errors
last_inc_status=ok|errors # Last inc backup status
last_log_status=ok|errors # Last compressed log move status
last_mysql_status=ok|errors # Last mysql backup status
last_postgresql_status=ok|errors # Last postgresql backup status
last_ok_full=08 # When last full backup was successfully done
last_full_status=ok|errors # Last full backup status
time_end=1535376270 # Backup end timestamp
```
## Restore/browse backups
* To access/browse archive use **sftp**.
* To keep correct ownerships, permissions, and full directory tree on restore use **rsync** as follows:
```
rsync -aHAXR --numeric-ids -M--fake-super src_srv@dst_srv:archives/<source> <dest>
```
