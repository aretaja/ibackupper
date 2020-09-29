#!/bin/bash
#
# ibackupper.sh
# Copyright 2018-2020 by Marko Punnar <marko[AT]aretaja.org>
# Version: 1.13
#
# Script to make incremental, SQL and file backups of your data to remote
# target. Requires bash, rsync and cat on both ends and ssh key login without
# password to remote end. Must be executed as root.
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
# 1.0 Initial release
# 1.1 Change ssh port declaration to support older rsync.
#     Fix incremental source check.
#     Fix symlink creation command.
# 1.2 Fix rsync command execution.
# 1.3 Make monthly full backups for 12 months.
# 1.4 Allow limiting full backups count.
# 1.5 Fix 'last_ok_inc_backup' not saved to last_data file if backup fails.
#     Make rsync to retry after 60s and increase rsync retry count.
# 1.6 Reorganize code.
#     Add backup start/stop timestamp to status file.
# 1.7 Make fresh incremental backup without hardlinks on every 1 day of month.
# 1.8 Show configured hostname in status file.
# 1.9 Implement lockfile (Prevent execution of multiple instances).
# 1.10 Implement lockfile (Prevent execution of multiple instances).
# 1.11 Include '.xz' compressed log files.
#      Fix error if $ldap variable is missing from config file.
#      Fix backup marked as success if mysql login fails.
#      Check exit code directly instead of indirect check with $?
# 1.12 Fix incorrect conditionals statements introduced in previous version.
# 1.13 Fix false "backup failed" error on SQL backups.

# show help if requested or no args
if [ "$1" = '-h' ] || [ "$1" = '--help' ]
then
    echo "Make monthly full and daily incremental backup using hardlinks."
    echo "Optionally MySQL, MariaDB, Postgres, OpenLDAP backup"
    echo "and compressed log removal can be made."
    echo "Reads config from /opt/ibackupper/ibackupper.conf."
    echo "Script must be executed by root."
    echo "Usage:"
    echo "       ibackupper.sh"
    exit
fi

### Functions ###############################################################
# Output formater. Takes severity (ERROR, WARNING, INEO) as first
# and output message as second arg.
write_log()
{
    tstamp=$(date -Is)
    if [ "$1" = 'INFO'  ]
    then
        echo "$tstamp [$1] $2"
    else
       echo "$tstamp [$1] $2" 1>&2
    fi
}

do_backup()
{
    cmd="$1"
    for i in $(seq 1 10)
    do
        eval "$cmd" 2>&1
        ret=$?
        if [ "$ret" -eq 0 ]; then break; fi
        write_log WARNING "rsync returned non zero exit code - $ret.! Retrying.."
        sleep 60
    done
    if [ "$ret" -ne 0 ]
    then
        write_log ERROR "rsync returned non zero exit code - $ret. Giving up"
        errors=1
    fi
}
#############################################################################
errors=0
# Make sure we are root
if [ "$EUID" -ne 0 ]
then
   write_log ERROR "ibackupper.sh must be executed as root! Interrupting.."
   exit 1
fi

ahome="/opt/ibackupper" # Application path
lock_f="${ahome}/lock" # Lockfile
status_f="${ahome}/last_data" # Status data file

# Check for running backup (lockfile)
if [ -e "$lock_f" ]
then
    write_log ERROR "Previous backup is running (lockfile set). Interrupting.."
    exit 1
fi

# Load config
if [ -r "${ahome}/ibackupper.conf" ]
then
    # shellcheck source=ibackupper.conf_example
    . "${ahome}/ibackupper.conf"
else
     write_log ERROR "Config file missing! Interrupting.."
     exit 1
fi

# Change working dir
cd "$ahome" || { echo "[ERROR] cd to $ahome failed"; exit 1; }
if [ "$PWD" != "$ahome" ]
then
    write_log ERROR "Wrong working dir - ${PWD}. Must be - ${ahome}! Interrupting.."
    exit 1
fi

# Load last backup info if present
if [ -r "$status_f" ]
then
    cp "$status_f" "${status_f}.prev"
    # shellcheck source=/dev/null
    . "$status_f"
else
     write_log WARNING "No previous backup info file"
fi

month_nr=$(date +%m)
day_nr=$(date +%d)
# Set remote directory name based on day of month
r_backup_dir=day_of_month_${day_nr}

# Set lockfile
touch "$lock_f";

# Save status data
echo "time_start=$(date +%s)" > "$status_f"
echo "hostname=${hostname}" >> "$status_f"

# Connection check
# shellcheck disable=SC2029

if result=$(ssh -q -o BatchMode=yes -o ConnectTimeout=10 -l"${hostname}" -p"${ssh_port}" "$backup_server" "cd \"$r_basedir\"" 2>&1)
then
    echo "server_connection=ok" >> "$status_f"
else
    if [ -z "$result" ]
    then
        write_log ERROR "$backup_server is not reachable! Interrupting.."
    else
        write_log ERROR "$backup_server returned \"${result}\"! Interrupting.."
    fi
    echo "server_connection=errors" >> "$status_f"
    echo "time_end=$(date +%s)" >> "$status_f"
    rm "$lock_f";
    exit 1
fi

### Incremental backups ###
if [ ${#src[@]} -gt 0 ]
then
    # Do rsync backups
    for i in "${!src[@]}"
    do
        # Source check
        if [ ! -d "${src[$i]}" ]; then continue; fi

        # Check excludes
        excludes=' '
        if [ ! -z "${exc[$i]+x}" ]
        then
            IFS=',' read -ra exarray <<< "${exc[$i]}"
            for e in "${exarray[@]}"
            do
                excludes="${excludes} --exclude ${e}"
            done
        fi

        # Set hardlink destination to previous backup if exists
        link_dest=''
        # shellcheck disable=SC2154
        if [ ! -z "${last_ok_inc_backup+x}" ] && [ "$day_nr" != 01 ]
        then
            link_dest="--link-dest=\"../${last_ok_inc_backup}\""
            write_log INFO "Set hardlink destination to \"../${last_ok_inc_backup}\""
        else
            write_log WARNING "No previous backup info. Can't use hardlinks"
        fi

        # Complete command
        cmd="rsync -aHAXRch --timeout=300 --delete --stats --numeric-ids -M--fake-super -e 'ssh -o BatchMode=yes -p${ssh_port}' $link_dest ${excludes} ${src[$i]} ${hostname}@${backup_server}:${r_basedir}/${r_backup_dir}/"
        write_log INFO "Command: ${cmd}"

        # Do backup
        write_log INFO "Making ${src[$i]} backup. rsync log follows:"
        do_backup "$cmd"
    done
else
     write_log WARNING "No backup sources defined for rsync!"
fi

# Save status data
if [ "$errors" -eq 0 ]
then
    echo "last_ok_inc_backup=${r_backup_dir}" >> "$status_f"
    echo "last_inc_status=ok" >> "$status_f"
    write_log INFO "Incremental backup done"
else
    # shellcheck disable=SC2154
    if [ ! -z "${last_ok_inc_backup+x}" ]
    then
        echo "last_ok_inc_backup=${last_ok_inc_backup}" >> "$status_f"
    fi
    echo "last_inc_status=errors" >> "$status_f"
    write_log WARNING "Incremental backup had errors"
    errors=0
fi
### End of incremental backups ###

### Move compressed logs ###
if [ "$logs" -eq 1 ]
then
    source='/var/log'
    includes='--include="*/" --include="*.gz" --include="*.bz2" --include="*.xz"'
    excludes='--exclude="*"'
    cmd="rsync -aHAXRh --remove-source-files --timeout=300 --stats --numeric-ids -M--fake-super -e 'ssh -o BatchMode=yes -p${ssh_port}' ${includes} ${excludes} ${source} ${hostname}@${backup_server}:${r_basedir}/${r_backup_dir}/"

    # Do backup
    write_log INFO "Making ${source} backup. rsync log follows:"
    do_backup "$cmd"

    if [ "$errors" -eq 0 ]
    then
        echo "last_log_status=ok" >> "$status_f"
        write_log INFO "Log backup done"
    else
        echo "last_log_status=errors" >> "$status_f"
        write_log WARNING "Log backup had errors"
        errors=0
    fi
fi
### End of move compressed logs ###

### DB backup ###
# mysql
if [ "$mysql" -eq 1 ]
then
    if [ -z "$m_ignore_db" ]
    then
        m_ignore_db='^$'
    fi

    write_log INFO "Making mysql/mariadb backup."
    if mysqlshow >/dev/null 2>&1
    then
        result=$(mysqlshow |grep -Pv "^\\+|Databases|${m_ignore_db}" |cut -d' ' -f2)
        for d in $result
        do
            write_log INFO "Transferring $d dump to $backup_server over ssh pipe. Console log follows:"
            # shellcheck disable=SC2029
            if mysqldump --single-transaction --events --triggers --add-drop-database --flush-logs "$d" | gzip -c - | ssh -o BatchMode=yes -p"${ssh_port}" -l"${hostname}" "${backup_server}" "cat > \"${r_basedir}/${r_backup_dir}/mysql_db_${d}.sql.gz\""
            then
                write_log INFO "$d backup done"
            else
                errors=1
                write_log ERROR "Something went wrong with $d backup!"
            fi
        done
    else
        errors=1
        write_log ERROR "mysql/mariadb backup error - DB connection failed"
    fi

    if [ "$errors" -eq 0 ]
    then
        echo "last_mysql_status=ok" >> "$status_f"
        write_log INFO "mysql/mariadb backup done"
    else
        echo "last_mysql_status=errors" >> "$status_f"
        write_log WARNING "mysql/mariadb backup had errors"
        errors=0
    fi
fi

# postgresql
if [ "$postgresql" -eq 1 ]
then
    if [ -z "$p_ignore_db" ]
    then
        p_ignore_db='^$'
    fi

    write_log INFO "Making postgresql backup."
    for d in $(sudo -u postgres psql -At -c "select datname from pg_database where not datistemplate and datallowconn" |grep -Pv "${m_ignore_db}")
    do
        write_log INFO "Transferring $d dump to $backup_server over ssh pipe. Console log follows:"
        # shellcheck disable=SC2029
        if sudo -u postgres pg_dump "$d" | gzip -c - | ssh -o BatchMode=yes -p"${ssh_port}" -l"${hostname}" "${backup_server}" "cat > \"${r_basedir}/${r_backup_dir}/postgresql_db_${d}.sql.gz\""
        then
            write_log INFO "$d backup done"
        else
            errors=1
            write_log ERROR "Something went wrong with $d backup!"
        fi
    done

    if [ "$errors" -eq 0 ]
    then
        echo "last_postgresql_status=ok" >> "$status_f"
        write_log INFO "postgresql backup done"
    else
        echo "last_postgresql_status=errors" >> "$status_f"
        write_log WARNING "postgresql backup had errors"
        errors=0
    fi
fi
### End of DB backup ###

### OpenLDAP backup ###
if [ ! -z "$ldap" ] && [ "$ldap" -eq 1 ]
then
    write_log INFO "Making openldap backup."
    write_log INFO "Transferring slapd config ldif to $backup_server over ssh pipe. Console log follows:"
    # shellcheck disable=SC2029
    if /usr/sbin/slapcat -v -n0 | gzip -c - | ssh -o BatchMode=yes -p"${ssh_port}" -l"${hostname}" "${backup_server}" "cat > \"${r_basedir}/${r_backup_dir}/ldap_config.ldif.gz\""
    then
        write_log INFO "slapd config backup done"
    else
        errors=1
        write_log ERROR "Something went wrong with slapd config backup!"
    fi

    write_log INFO "Transferring slapd data ldif to $backup_server over ssh pipe. Console log follows:"
    # shellcheck disable=SC2029
    if /usr/sbin/slapcat -v -n1 | gzip -c - | ssh -o BatchMode=yes -p"${ssh_port}" -l"${hostname}" "${backup_server}" "cat > \"${r_basedir}/${r_backup_dir}/ldap_data.ldif.gz\""
    then
        write_log INFO "slapd data backup done"
    else
        errors=1
        write_log ERROR "Something went wrong with slapd data backup!"
    fi

    if [ "$errors" -eq 0 ]
    then
        echo "last_ldap_status=ok" >> "$status_f"
        write_log INFO "openldap backup done"
    else
        echo "last_ldap_status=errors" >> "$status_f"
        write_log WARNING "openldap backup had errors"
        errors=0
    fi
fi
### End of OpenLDAP backup ###

### Full backup ###
# shellcheck disable=SC2154
if [ "$full_backup" -eq 1 ] && [ "$last_ok_full" != "$month_nr" ]
then
    # Keep only requested count of full monthly backups. Truncate the rest.
    if [ "$full_cnt" -ge 1 ] && [ "$full_cnt" -le 12 ]
    then
        write_log INFO "Truncate superfluous monthly backups. Console log follows:"
        for m in $(seq 0 11)
        do
            m_nr=$(date -d "-${m} month" +%m)
            filename="fullbackup_month_${m_nr}.tgz"
            if [ $full_cnt -le 0 ]
            then
                null="${null}: >$filename && "
            fi
            ((full_cnt--))
        done
        null="${null}true"
        # shellcheck disable=SC2029
        ssh -o BatchMode=yes -p"${ssh_port}" -l"${hostname}" "${backup_server}" "cd \"${r_basedir}\" && eval \"$null\""
    fi
    write_log INFO "Making full monthly backup. Console log follows:"
    # shellcheck disable=SC2029
    if ssh -o BatchMode=yes -p"${ssh_port}" -l"${hostname}" "${backup_server}" "tar -C \"${r_basedir}\" -cf - \"${r_backup_dir}\" | gzip -c >\"${r_basedir}/fullbackup_month_${month_nr}.tgz\""
    then
        write_log INFO "Full backup done"
        echo "last_ok_full=${month_nr}" >> "$status_f"
        echo "last_full_status=ok" >> "$status_f"
    else
        write_log ERROR "Something went wrong with monthly full backup!"
        echo "last_ok_full=${last_ok_full}" >> "$status_f"
        echo "last_full_status=errors" >> "$status_f"
    fi
else
    write_log INFO "Full backup disabled or allready exists for this month"
    echo "last_ok_full=${last_ok_full}" >> "$status_f"
fi
### End of full backup ###

echo "time_end=$(date +%s)" >> "$status_f"
rm "$lock_f";
exit
