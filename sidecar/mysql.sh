#!/bin/sh

# Last backup time in seconds since epoch
LAST_BACKUP_TIME=$(date +%s)

exit_script() {
  echo "Tearing down..."
  trap - SIGINT SIGTERM # clear the trap
  
  # Elect new master if we are the master
  if [ "$(curl -m 1 -s http://orc:3000/api/master/$DB_NAME | jq -r .Key.Hostname)" == "$PODIP" ]; then
    echo "Electing new master..."
    curl -s http://orc:3000/api/graceful-master-takeover-auto/$DB_NAME
    echo "Graceful master takeover complete"
    sleep 5
  fi

  # Remove this node from the orchestrator cluster
  echo "Removing this node $PODIP from orchestrator"
  curl -s http://orc:3000/api/forget/$PODIP/3306 | jq .
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
    if [ "$(s3cmd ls s3://$S3_BUCKET/$DB_NAME/latest | wc -l)" -gt 0 ]; then
      echo "Restoring latest backup from S3..."
      mkdir -p /tmp/$DB_NAME
      s3cmd --recursive get s3://$S3_BUCKET/$DB_NAME/latest/ /tmp/$DB_NAME
      myloader -d /tmp/$DB_NAME -u root -p $MYSQL_ROOT_PASSWORD -h 127.0.0.1 -t 4
    fi

    mysql -u root -p$MYSQL_ROOT_PASSWORD -h 127.0.0.1 -e "SET GLOBAL read_only=OFF"
  else
    echo "Found master. Checking if it is ready..."
    MASTER=$(echo $MASTER | jq -r .Key.Hostname)
    
    while [ "$(mysql -u root -p$MYSQL_ROOT_PASSWORD -h $MASTER -e "select ready from meta.cluster where anchor=1" -s --skip-column-names)" -ne 1 ]; do
      echo "Master is not ready, checking again in 5 seconds..."
      sleep 5
    done

    # Get log file and position from master
    LOG_INFO=$(mysql -u root -p$MYSQL_ROOT_PASSWORD -h $MASTER -e "show master status" -s --skip-column-names)
    LOG_FILE=$(echo $LOG_INFO | awk '{print $1}')
    LOG_POS=$(echo $LOG_INFO | awk '{print $2}')

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
EOF
    
    mydumper -c ./mydumper.ini
    myloader -d ./dumper-sql -h 127.0.0.1 -u root -p $MYSQL_ROOT_PASSWORD -t 4

    echo "Changing master to $MASTER at $LOGFILE:$LOGPOS"
    mysql -u root -p$MYSQL_ROOT_PASSWORD -h 127.0.0.1 -e "CHANGE MASTER TO MASTER_HOST='$MASTER', MASTER_USER='repl', MASTER_PASSWORD='repl', MASTER_LOG_FILE='$LOGFILE', MASTER_LOG_POS=$LOGPOS; START SLAVE;"
    echo "Replication started"
  fi

  # Add this node to orchestrator
  echo "Adding this node $PODIP to orchestrator"
  curl -s http://orc:3000/api/discover/$PODIP/3306

  # Set meta.cluster.ready to 1
  mysql -u root -p$MYSQL_ROOT_PASSWORD -h 127.0.0.1 -e "UPDATE meta.cluster SET ready=1 WHERE anchor=1"
}

# catch kill signals
trap exit_script SIGINT SIGTERM

# Bootstrap the instance
bootstrap

while true; do
  sleep 1
  # BACKUP_INTERVAL_HOURS is in hours so convert to seconds
  if [ $(($(date +%s) - $LAST_BACKUP_TIME)) -gt $(($BACKUP_INTERVAL_HOURS * 3600)) ]; then
    # Check if we are the master before backing up
    if [ "$(curl -m 1 -s http://orc:3000/api/master/$DB_NAME | jq -r .Key.Hostname)" == "$PODIP" ]; then
      ./backup.sh
      LAST_BACKUP_TIME=$(date +%s)
    fi
  fi
done