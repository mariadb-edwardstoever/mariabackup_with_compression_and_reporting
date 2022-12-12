#!/bin/bash
# Bash script for mariabackup with compression. 
# Script by Edward Stoever of MariaDB Support.
# MariaDB Corporation is not liable for your use of this script. This script is provided as is and without warranty.
# Version 1.0

## Recommended not to run as root as there are "rm" commands which could be dangerous. 
## To run as a non-root user, add user to mysql group with command "usermod -a -G mysql myuser"
## To run as a non-root user, make sure all sub-directories of datadir are mod 750:
## find /var/lib/mysql -type d -exec chmod 750 {} \;
## ensure that future directores and files are created with the 750 umask. See https://mariadb.com/kb/en/systemd/#configuring-the-umask
## Edit the file: vi /usr/lib/systemd/system/mariadb.service - Add in the environment umasks under [SERVICE]
## Environment="UMASK=0750"
## Environment="UMASK_DIR=0750"
## systemctl daemon-reload
## systemctl stop mariadb
## systemctl start mariadb

# CREATE USER 'mariabackup'@'localhost' IDENTIFIED BY 'mypassword';
# grant insert, update, delete, select on $BAK_SCHEMA.$BAK_TABLE to `mariabackup`@`localhost`;
# grant FILE on *.* to `mariabackup`@`localhost`
# 10.5, 10.6 and higher:
# GRANT RELOAD, PROCESS, LOCK TABLES, BINLOG MONITOR ON *.* TO 'mariabackup'@'localhost'; 
# 10.4 and lower:
# GRANT RELOAD, PROCESS, LOCK TABLES, REPLICATION CLIENT ON *.* TO 'mariabackup'@'localhost'; 

#  CREATE SCHEMA IF NOT EXISTS `bak`;
#  CREATE TABLE IF NOT EXISTS `bak`.`backup_report` (
#	 `completed_at` TIMESTAMP NOT NULL DEFAULT current_timestamp(),
#	 `status` VARCHAR(250) NULL DEFAULT NULL COLLATE 'utf8mb4_general_ci',
#	 `type` ENUM('FULL','INCREMENTAL') NULL DEFAULT NULL COLLATE 'utf8mb4_general_ci',
#	 `compress` ENUM('COMPRESS','NOCOMPRESS') NULL DEFAULT NULL COLLATE 'utf8mb4_general_ci',
#        `when_compressed` TIMESTAMP NULL DEFAULT NULL,
#	 `directory` VARCHAR(250) NULL DEFAULT NULL COLLATE 'utf8mb4_general_ci',
#	 `size` VARCHAR(100) NULL DEFAULT NULL COLLATE 'utf8mb4_general_ci',
#	 `free_space_after_backup` VARCHAR(100) NULL DEFAULT NULL COLLATE 'utf8mb4_general_ci',
#	 `deleted` TIMESTAMP NULL DEFAULT NULL,
#	 `script_log` MEDIUMTEXT NULL DEFAULT NULL COLLATE 'utf8mb4_general_ci',
#	 `mariabackup_log` MEDIUMTEXT NULL DEFAULT NULL COLLATE 'utf8mb4_general_ci',
#	 INDEX `indx1` (`completed_at`, `directory`) USING BTREE
#  ) COLLATE='utf8mb4_general_ci' ENGINE=InnoDB;

# Edit these variables to suit your needs:
BKUP_DIR=/opt/backup/  # ALWAYS INCLUDE TRAILING SLASH
PERMIT_RUN_BY_ROOT="no"
DELETE_OLD="yes"
MINUTES_PASS_TO_DELETE_OLD=16 # How old must a backup be in minutes to be deleted. This will make space for new backups.
BKUP_USER="mariabackup"
BKUP_PASS="mypassword"
COMPRESS_BASE_DIR="yes" # yes means: Will not compress current backup. Will compress previous backup to support incremental backups.
ONLY_FULL_COMPRESS_ALL="no" # yes means: Will always compress full backups. Incremental backups are disabled.
BAK_SCHEMA="bak"
BAK_TABLE="backup_report"

# Do not edit these variables:
DAY_DIR=${BKUP_DIR}`date +%Y-%m-%d`/
TIMESTAMP=$(date +%H-%M-%S)
OUT_LOG=${DAY_DIR}script-$TIMESTAMP.log
BKP_LOG=${DAY_DIR}backup-$TIMESTAMP.log
FULL_STATE_FILE=${BKUP_DIR}last_full_backup
INC_STATE_FILE=${BKUP_DIR}last_inc_backup


mkdir -p $BKUP_DIR

function delete_old_backup() {
  if [ -d "$1" ]; then rm -fr $1; else return; fi
  BN=$(basename $1|cut -d "_" -f 1)
  DB=$(dirname $1)
  rm -f $DB/backup-$BN*.log
  rm -f $DB/script-$BN*.log
  SQL="UPDATE $BAK_SCHEMA.$BAK_TABLE set deleted=now() where directory=concat('$1','/');"
  mariadb -u$BKUP_USER -p$BKUP_PASS -ABNe "$SQL"
  unset SQL
  printf "[`date --iso-8601=seconds`] Deleted backup dir $1\n" >> ${OUT_LOG}
}

function report_results() {
#   echo ${TARGET_DIR} > /tmp/a.txt; echo ${BKUP_DIR} > /tmp/b.txt
   FREE_SPACE=$(df -h $BKUP_DIR |tail -1| awk '{print $4}')
   if [ -d ${TARGET_DIR} ] && [ $STATUS = 'SUCCESS'  ]; then SIZE=$(du -sh ${TARGET_DIR} | cut -f1); else SIZE=0; fi
   if [[ -z $COMPRESS_STATUS ]]; then COMPRESS_STATUS="NOCOMPRESS"; WHEN_COMPRESS='NULL'; else WHEN_COMPRESS='now()'; fi
   SQL="INSERT INTO $BAK_SCHEMA.$BAK_TABLE 
          (completed_at, status, type, compress, when_compressed, directory, size, free_space_after_backup, script_log, mariabackup_log) 
        VALUES
          (now(),'$STATUS','$1','$COMPRESS_STATUS',$WHEN_COMPRESS,'$TARGET_DIR','$SIZE','$FREE_SPACE',LOAD_FILE('$OUT_LOG'),LOAD_FILE('$BKP_LOG'));"
  mariadb --local-infile=ON -u$BKUP_USER -p$BKUP_PASS -ABNe "$SQL"
  unset SQL
}

function update_report_compressed() {
  if [ -d $1 ]; then SIZE=$(du -sh $1 | cut -f1); else SIZE=0; fi
  SQL="UPDATE $BAK_SCHEMA.$BAK_TABLE set compress='COMPRESS',when_compressed=now(),size='$SIZE' where directory='$1';"
  mariadb -u$BKUP_USER -p$BKUP_PASS -ABNe "$SQL"
  unset SQL
  printf "[`date --iso-8601=seconds`] Compressed backup dir $1\n" >> ${OUT_LOG}
}

function compress_files() {
   # 1st parameter directory name
   # 2nd parameter file basename
   cd $1 2>/dev/null || return

   tar -czf /tmp/$2 ./* 

   if [ $? -eq 0 ]; then
      COMPRESS_STATUS='COMPRESS'
      STATUS='SUCCESS'
      printf "[`date --iso-8601=seconds`] COMMAND tar SUCCEEDED IN $1\n" >> ${OUT_LOG}
      rm -fr ./*
      mv /tmp/$2 ./
   else
      STATUS='COMPRESS FILES FAILED'
      printf "[`date --iso-8601=seconds`] COMMAND tar FAILED IN $1\n" >> ${OUT_LOG}
   fi
}

function full_backup {

        TARGET_DIR="${DAY_DIR}`date +%H-%M`_full"/
        if [[ -e $TARGET_DIR ]]
        then
                printf "[`date --iso-8601=seconds`] Directory ${TARGET_DIR} already exists\n" >> ${OUT_LOG}
                exit 1
        fi

        mkdir -p $TARGET_DIR

        printf "[`date --iso-8601=seconds`] Starting full backup\n" >> ${OUT_LOG}

        start=`date +%s`
        mariabackup --backup --target-dir=${TARGET_DIR} --user=${BKUP_USER} --password=${BKUP_PASS} >> ${BKP_LOG} 2>> ${BKP_LOG} && STATUS='SUCCESS' || STATUS='FAILED'
        if [ "$STATUS" == "FAILED" ]; then rm -fr ${TARGET_DIR}; fi # eliminate TARGET_DIR if backup failed
        end=`date +%s`
        runtime=$((end-start))
        if [ -d ${TARGET_DIR} ]; then size=$(du -sh ${TARGET_DIR} | cut -f1); else size=0; fi

        printf "[`date --iso-8601=seconds`] Completed full backup in ${runtime} seconds. Status: ${STATUS} Size: ${size}\n" >> ${OUT_LOG}

        printf $TARGET_DIR > ${FULL_STATE_FILE}

        if [ -e ${INC_STATE_FILE} ] && [ "$ONLY_FULL_COMPRESS_ALL" != "yes" ]
        then
            BASE_DIR=$(head -n 1 ${INC_STATE_FILE})
            if [ "$COMPRESS_BASE_DIR" == "yes" ] && [ "$STATUS" == "SUCCESS" ] && [ -d ${BASE_DIR} ]; then
                COMPRESS_FILE=$(basename `dirname $BASE_DIR`)-$(basename $BASE_DIR)".tar.gz"
                compress_files ${BASE_DIR} ${COMPRESS_FILE}
                sleep 1
                unset COMPRESS_STATUS
                update_report_compressed ${BASE_DIR}
                touch ${TARGET_DIR}
                rm -f ${INC_STATE_FILE}
            fi
        elif [ "$ONLY_FULL_COMPRESS_ALL" == "yes" ] && [ "$STATUS" == "SUCCESS" ]; then
                BASE_DIR=$TARGET_DIR
                COMPRESS_FILE=$(basename `dirname $BASE_DIR`)-$(basename $BASE_DIR)".tar.gz"
                compress_files ${BASE_DIR} ${COMPRESS_FILE}
                sleep 1
                touch ${TARGET_DIR}
        fi

        report_results "FULL"
}

function incremental_backup {

        if [[ "$ONLY_FULL_COMPRESS_ALL" == "yes" ]]; then  
          printf "[`date --iso-8601=seconds`] Incremental backups disabled by ONLY_FULL_COMPRESS_ALL." >> ${OUT_LOG}
          STATUS='FAILED'
          report_results "INCREMENTAL"
          return
        fi

        TARGET_DIR="${DAY_DIR}`date +%H-%M`_inc"/

        if [[ -e $TARGET_DIR ]]
        then
                printf "[`date --iso-8601=seconds`] Directory ${TARGET_DIR} already exists\n" >> ${OUT_LOG}
                exit 1
        fi

        mkdir -p $TARGET_DIR

        if [[ -e ${INC_STATE_FILE} ]]
        then
                BASE_DIR=$(head -n 1 ${INC_STATE_FILE})
        elif [[ -e ${FULL_STATE_FILE} ]]
        then
                BASE_DIR=$(head -n 1 ${FULL_STATE_FILE})
        else
                printf "[`date --iso-8601=seconds`] No base directory (full or incremental) found\n" >> ${OUT_LOG}
                exit 1
        fi

        if [[ -z ${BASE_DIR} ]]
        then
                printf "[`date --iso-8601=seconds`] Base dir is an empty string\n" >> ${OUT_LOG}
                unset COMPRESS_BASE_DIR
                exit 1
        fi

        printf "[`date --iso-8601=seconds`] Starting incremental backup based on ${BASE_DIR}\n" >> ${OUT_LOG}

        start=`date +%s`
        mariabackup --backup --target-dir=${TARGET_DIR} --incremental-basedir=${BASE_DIR} \
                    --user=${BKUP_USER} --password=${BKUP_PASS} >> ${BKP_LOG} 2>> ${BKP_LOG} && STATUS='SUCCESS' || STATUS='FAILED'
        end=`date +%s`
        runtime=$((end-start))
        size=`du -sh ${TARGET_DIR} | cut -f1`
        printf "[`date --iso-8601=seconds`] Completed incremental backup in ${runtime} seconds. Status: ${STATUS} Size: ${size}\n" >> ${OUT_LOG}

        printf $TARGET_DIR > ${INC_STATE_FILE}


        if [ "$COMPRESS_BASE_DIR" == "yes" ] && [ "$STATUS" == "SUCCESS" ]; then
            COMPRESS_FILE=$(basename `dirname $BASE_DIR`)-$(basename $BASE_DIR)".tar.gz"
            compress_files ${BASE_DIR} ${COMPRESS_FILE}
            sleep 1
            unset COMPRESS_STATUS
            update_report_compressed ${BASE_DIR}
            touch ${TARGET_DIR}
        fi
        report_results "INCREMENTAL"
}


if [[ $# -ne 1 ]]
then
        printf "Exactly one parameter (--full or --incremental) required\n"
        exit 1
fi

# delete old backups
if [[ "$DELETE_OLD" == "yes" ]]; then
  find $BKUP_DIR -type d -mmin +$MINUTES_PASS_TO_DELETE_OLD \( -name "*inc" -o -name "*full" \) | while read file; do delete_old_backup "$file"; done
fi


if [ "$(id -u)" -eq 0 ] && [ $PERMIT_RUN_BY_ROOT != "yes" ]; then
    printf "This script is configured not to run as root.\n"; exit 0
fi


case "$1" in
        --full)
                full_backup
                ;;
        --incremental)
                incremental_backup
                ;;
        *)
                printf "Wrong parameter, run with --full or --incremental.\n"
                exit 1
                ;;
esac
