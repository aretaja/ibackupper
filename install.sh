#! /bin/bash
#
# Install files from repo to /opt/ibackupper
# and change permissions

destination='/opt/ibackupper'
echo "[INFO] Installing ibackupper.."

# make sure we are root
if [[ $EUID -ne 0 ]]
then
   echo '[ERROR] This script must be executed as root. Interrupting..' 1>&2
   exit 2
fi

source=$(dirname "$(readlink -f "$0")")

mkdir -p $destination
if [ ! -d "$destination" ]
then
    echo "[ERROR] $destination missing. Interrupting.." 1>&2
    exit 2;
fi

cp -vR ${source}/src/* "${destination}/"
if [ $? -ne 0 ]
then
    echo "[ERROR] Copy files to $destination failed. Interrupting.." 1>&2
    exit 2;
fi

echo '[INFO] Set owner and permissions.'
chown -vR root:root "$destination"
chmod 0700 -v "$destination"
find "$destination" -type f ! -name "*.sh" -exec chmod -v 0600 '{}' \;
find "$destination" -type f -name "*.sh" -exec chmod -v 0700 '{}' \;

echo '[INFO] Done'
echo "[INFO] Setup Your config in ${destination}/ibackupper.conf."
echo "[INFO] Example config file is provided in ${destination}/ibackupper.conf_example."
exit
