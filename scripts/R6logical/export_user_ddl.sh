#!/bin/bash

#conf_file=$(dirname $(readlink -f "$0"))"/backup8.conf"
#echo "conf file is: $conf_file"
#source $conf_file
#date=$(date '+%Y%m%d%H')

. /home/kingbase/.bashrc

LD_LIBRARY_PATH="${kdb_home}/lib"
dir=/home/kingbase/scripts/R6logical

export LD_LIBRARY_PATH=$LD_LIBRARY_PATH
        ksql -U system -c "select now();" TEMPLATE1 > /dev/null 2>&1
        if [ $? -ne 0 ] ;then
                echo "sorry, please run the script in a kingbase server" 
                exit 1
        else
                echo "kingbase user export is beginning ..."
                sys_dumpall -U system -g -f $dir/export_user_ddl.dmp
                echo "export ok."
        fi

exit 0
