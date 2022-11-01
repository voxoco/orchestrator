#!/bin/sh

# Last backup time in seconds since epoch
LAST_BACKUP_TIME=$(date +%s)

# LAST_SLAVE_CHECK_TIME is the last time we checked slave replication status
LAST_SLAVE_CHECK_TIME=$(date +%s)

raft_leader() {
  # Get current raft leader
  RAFT_LEADER=$(curl -m 1 -s http://orc:3000/api/raft-leader | jq -r | sed 's/:.*//')
}

exit_script() {
  echo "Tearing down..."
  trap - SIGINT SIGTERM # clear the trap

  # Get raft leader
  raft_leader
  
  # Elect new master if we are the master
  if [ "$(curl -m 1 -s http://$RAFT_LEADER:3000/api/master/$DB_NAME | jq -r .Key.Hostname)" == "$PODIP" ]; then
    echo "Electing new master..."
    curl -s http://$RAFT_LEADER:3000/api/force-master-failover/$DB_NAME
    echo "force-master-failover complete"
  fi
}

bootstrap() {
  echo "Bootstrapping..."

  # Make sure this mysql node is actually online first
  while ! mysqladmin ping -u root -p$MYSQL_ROOT_PASSWORD -h 127.0.0.1 --silent > /dev/null 2>&1 ; do
    sleep 5
  done

  echo "Sleeping for 5 seconds"
  sleep 5

  # If server_id is set to to something other than 1 just return
  if [ $(mysql -u root -p$MYSQL_ROOT_PASSWORD -h 127.0.0.1 -e "select @@server_id" -s --skip-column-names) -ne 1 ]; then
    echo "server_id already set. Node has already been bootstrapped"
    return
  fi

  echo "Seeding mysql with necessary data..."
  mysql -u root -p$MYSQL_ROOT_PASSWORD -h 127.0.0.1 <<EOF
SET @@SESSION.SQL_LOG_BIN=0;

-- set server_id
SET GLOBAL server_id = ${PODIP//./};

-- create db and user
CREATE DATABASE $DB_NAME;
CREATE USER '$DB_NAME'@'%' IDENTIFIED BY '$DB_NAME';
GRANT ALL PRIVILEGES ON $DB_NAME.* TO '$DB_NAME'@'%';

-- add replication user
CREATE USER 'repl'@'%' IDENTIFIED BY 'repl';
GRANT REPLICATION SLAVE ON *.* TO 'repl'@'%';

-- add orchestrator stuff
CREATE USER 'orchestrator'@'%' IDENTIFIED BY 'orchestrator';
GRANT SUPER, PROCESS, REPLICATION SLAVE, RELOAD ON *.* TO 'orchestrator'@'%';
GRANT SELECT ON mysql.slave_master_info TO 'orchestrator'@'%';
GRANT DROP ON _pseudo_gtid_.* to 'orchestrator'@'%';
CREATE DATABASE meta;
CREATE TABLE meta.cluster (anchor TINYINT, cluster_alias VARCHAR(128), cluster_domain VARCHAR(128), dc VARCHAR(128), instance_alias VARCHAR(128), ready INT, PRIMARY KEY (anchor)) ENGINE=InnoDB DEFAULT CHARSET=utf8;
GRANT SELECT ON meta.* TO 'orchestrator'@'%';
INSERT INTO meta.cluster (anchor, cluster_alias, cluster_domain, dc, instance_alias, ready) VALUES (1, '$DB_NAME', '$DB_NAME.$POD_NAMESPACE', '$CLUSTER_NAME', '$HOSTNAME', 0);

-- mysqld exporter
CREATE USER 'mysqld_exporter'@'localhost' IDENTIFIED BY '123456';
GRANT PROCESS, REPLICATION CLIENT, SELECT ON *.* TO 'mysqld_exporter'@'localhost';
EOF

  # Check with orchestrator to see if this node exists. If not, add it
  if [ "$(curl -m 1 -s http://orc:3000/api/instance/$PODIP/3306 | jq -r .Code)" != "ERROR" ]; then return; fi

  echo "Node does not exist in orchestrator, adding..."

  # Get current master
  MASTER=$(curl -m 1 -s http://orc:3000/api/master/$DB_NAME)

  if [ "$(echo $MASTER | jq -r .Code)" == "ERROR" ]; then
    echo "No master found, this is the first node."

    # Restore latest backup from S3 if it exists
    if [ "$(s4cmd ls s3://$S3_BUCKET/$DB_NAME/latest.sql.gz | wc -l)" -gt 0 ]; then
      echo "Restoring latest backup from S3..."
      s4cmd get s3://$S3_BUCKET/$DB_NAME/latest.sql.gz /tmp
      mkdir -p /tmp/$DB_NAME
      tar -xzf /tmp/latest.sql.gz -C /tmp/$DB_NAME
      myloader -d /tmp/$DB_NAME -u root -p $MYSQL_ROOT_PASSWORD -h 127.0.0.1 -t 4
    fi

    mysql -u root -p$MYSQL_ROOT_PASSWORD -h 127.0.0.1 -e "SET GLOBAL read_only=OFF"
  else
    echo "Found master. Checking if it is ready..."

    # Get Executed GTID Set from master
    GTID_PURGED=$(echo $MASTER | jq -r .ExecutedGtidSet)

    # Set master
    MASTER=$(echo $MASTER | jq -r .Key.Hostname)
    
    while [ "$(mysql -u root -p$MYSQL_ROOT_PASSWORD -h $MASTER -e "select ready from meta.cluster where anchor=1" -s --skip-column-names)" -ne 1 ]; do
      echo "Master is not ready, checking again in 5 seconds..."
      sleep 5
    done

    # Get log file and position from master
    #LOG_FILE=$(echo $MASTER | jq -r .SelfBinlogCoordinates.LogFile)
    #LOG_POS=$(echo $MASTER | jq -r .SelfBinlogCoordinates.LogPos)

    # Restore from master
    cat << EOF > ./mydumper.ini
[mysql]
host = $MASTER
user = root
password = $MYSQL_ROOT_PASSWORD
port = 3306
database = $DB_NAME
outdir = ./dumper-sql
chunksize = 128
vars = "SQL_LOG_BIN=0;"
EOF

    # Dump from master
    mydumper -c ./mydumper.ini

    # Import dump
    myloader -d ./dumper-sql -h 127.0.0.1 -u root -p $MYSQL_ROOT_PASSWORD -t 4

    echo "Changing master to $MASTER at GTID: $GTID_PURGED"
    mysql -u root -p$MYSQL_ROOT_PASSWORD -h 127.0.0.1 -e "RESET MASTER; SET GLOBAL GTID_PURGED='$GTID_PURGED'; CHANGE MASTER TO MASTER_CONNECT_RETRY=1, MASTER_RETRY_COUNT=86400, MASTER_HOST='$MASTER', MASTER_USER='repl', MASTER_PASSWORD='repl', MASTER_AUTO_POSITION = 1; START SLAVE;"
    echo "Replication started"
  fi

  # Set meta.cluster.ready to 1
  mysql -u root -p$MYSQL_ROOT_PASSWORD -h 127.0.0.1 -e "UPDATE meta.cluster SET ready=1 WHERE anchor=1"

  # Get raft leader
  raft_leader

  # Ack recoveries
  curl -s "http://$RAFT_LEADER:3000/api/ack-recovery/cluster/$DB_NAME?comment=known"

  # Add this node to orchestrator
  echo "Adding this node $PODIP to orchestrator"
  curl -s http://$RAFT_LEADER:3000/api/discover/$PODIP/3306
}

backup() {
  echo "Checking if we are the master"
  if [ "$(curl -m 1 -s http://orc:3000/api/master/$DB_NAME | jq -r .Key.Hostname)" != "$PODIP" ]; then return; fi

  echo "Backing up..."
  NOW=$(date +"%Y_%m_%d_%H_%M_%S")

  rm -rf ./mydumper.ini

  cat << EOF > ./mydumper.ini
[mysql]
host = 127.0.0.1
user = root
password = $MYSQL_ROOT_PASSWORD
port = 3306
database = $DB_NAME
outdir = ./backup/$DB_NAME/$NOW
chunksize = 128
EOF

  mydumper -c ./mydumper.ini

  # Gzip latest backup
  rm -rf ./backup/$DB_NAME/latest.sql.gz
  tar -zcvf ./backup/$DB_NAME/latest.sql.gz ./backup/$DB_NAME/$NOW
  rm -rf ./backup/$DB_NAME/$NOW
  cp ./backup/$DB_NAME/latest.sql.gz ./backup/$DB_NAME/$NOW.sql.gz

  echo "Backup complete. Uploading to S3..."

  # Upload backup directory to S3
  s4cmd sync ./backup/$DB_NAME s3://$S3_BUCKET/$DB_NAME

  # Delete backups older than 7 days
  find ./backup/* -mtime +7 -exec rm {} \;

  echo "Backup uploaded to S3 and local backups older than 7 days deleted."
}

check_slave_status() {
  # Check read_only flag to see if we are a slave
  if [ "$(mysql -u root -p$MYSQL_ROOT_PASSWORD -h 127.0.0.1 -e "select @@read_only" -s --skip-column-names)" != "1" ]; then return; fi
  echo "Time to check if slave is still replicating..."
  
  # Check if slave is still replicating
  SLAVE_STATUS=$(mysql -u root -p$MYSQL_ROOT_PASSWORD -h 127.0.0.1 -e "show slave status\G")
  SLAVE_IO_RUNNING=$(echo "$SLAVE_STATUS" | grep "Slave_IO_Running: Yes" | wc -l)
  SLAVE_SQL_RUNNING=$(echo "$SLAVE_STATUS" | grep "Slave_SQL_Running: Yes" | wc -l)
  
  if [ $SLAVE_IO_RUNNING == 1 ] && [ $SLAVE_SQL_RUNNING == 1 ]; then return; fi
  echo "Slave not replicating, sending slack notification..."
  
  # Get errors
  SLAVE_IO_ERROR=$(echo "$SLAVE_STATUS" | grep Last_IO_Error | awk '{print $2}')
  SLAVE_SQL_ERROR=$(echo "$SLAVE_STATUS" | grep Last_SQL_Error | awk '{print $2}')
  
  # Send slack notification
  ./slack.sh "ERROR" "Slave not replicating on $PODIP" "IO Error: $SLAVE_IO_ERROR\nSQL Error: $SLAVE_SQL_ERROR"
}

# catch kill signals
trap exit_script SIGINT SIGTERM

# Bootstrap the instance
bootstrap

while true; do
  sleep 1
  # Run backup if it's time
  if [ $(($(date +%s) - $LAST_BACKUP_TIME)) -gt $(($BACKUP_INTERVAL_HOURS * 3600)) ]; then
    backup
    LAST_BACKUP_TIME=$(date +%s)
  fi

  # Slave status check every minute
  if [ $(($(date +%s) - $LAST_SLAVE_CHECK_TIME)) -gt 60 ]; then
    check_slave_status
    LAST_SLAVE_CHECK_TIME=$(date +%s)
  fi
done