#!/bin/sh

INIT=1

seed_mysql_servers() {
  # Add the mysql servers from orchestrator
  if [ "$DEBUG" == "1" ]; then echo "Adding mysql servers from orchestrator"; fi

  # Get the current master
  MASTER=$(curl -m 1 -s http://orc:3000/api/master/$DB_NAME | jq -r .Key.Hostname)
  if [ "$MASTER" == "null" ] || [ "$MASTER" == "" ]; then 
    echo "Could not get master from orchestrator"
    if [ "$INIT" == "1" ]; then exit 1; else return 1; fi
  fi

  # Add the master
  if [ "$DEBUG" == "1" ]; then echo "Adding master $MASTER"; fi
  mysql -u admin -padmin -h 127.0.0.1 -P 6032 -e "
  DELETE FROM mysql_servers where hostgroup_id=0;
  REPLACE into mysql_servers (hostgroup_id, hostname, port) values (0, '$MASTER', 3306);"

  # Get the list of slaves
  SLAVES=$(curl -m 1 -s http://orc:3000/api/instance-replicas/$MASTER/3306 | jq -r ".[] | select(.ReplicationSQLThreadRuning == true and .ReplicationIOThreadRuning == true and .IsLastCheckValid == true) | select(.DataCenter == \"$CLUSTER_NAME\") | .Key.Hostname")

  # Check if master is in our datacenter
  if [ "$(curl -m 1 -s http://orc:3000/api/instance/$MASTER/3306 | jq -r .DataCenter)" == "$CLUSTER_NAME" ]; then
    # Add to SLAVES list
    SLAVES="$SLAVES
    $MASTER"
  fi

  # Clear hostgroup 1 if we have SLAVES
  if [ "$SLAVES" != "" ]; then
    mysql -u admin -padmin -h 127.0.0.1 -P 6032 -e "DELETE FROM mysql_servers where hostgroup_id=1;"
  fi

  # Add the slaves
  for SLAVE in $SLAVES; do
    if [ "$DEBUG" == "1" ]; then echo "Adding slave $SLAVE"; fi
    mysql -u admin -padmin -h 127.0.0.1 -P 6032 -e "REPLACE into mysql_servers (hostgroup_id, hostname, port) values (1, '$SLAVE', 3306);"
  done

  # Save the config
  if [ "$DEBUG" == "1" ]; then echo "Saving config"; fi
  mysql -u admin -padmin -h 127.0.0.1 -P 6032 -e "LOAD MYSQL SERVERS TO RUNTIME; SAVE MYSQL SERVERS TO DISK;"
}

bootstrap() {
  echo "Bootstrapping..."

  # Make sure this proxysql node is actually online first
  while ! mysqladmin ping -u admin -padmin -h 127.0.0.1 -P 6032 --silent > /dev/null 2>&1 ; do
    sleep 5
  done

  echo "Sleeping for 5 seconds"
  sleep 5

  # If there are already servers in mysql_servers then we have already been bootstrapped
  if [ $(mysql -u admin -padmin -h 127.0.0.1 -P 6032 -e "select count(*) from mysql_servers" -s --skip-column-names) -ne 0 ]; then
    echo "mysql_servers already populated. Node has already been bootstrapped"
    return
  fi

  # Update the monitor variable
  echo "Updating monitor global variable"
  mysql -u admin -padmin -h 127.0.0.1 -P 6032 -e "
  UPDATE global_variables SET variable_value='false' WHERE variable_name='mysql-monitor_enabled';
  UPDATE global_variables SET variable_value='true' WHERE variable_name='admin-restapi_enabled';
  LOAD MYSQL VARIABLES TO RUNTIME;
  SAVE MYSQL VARIABLES TO DISK;
  LOAD ADMIN VARIABLES TO RUNTIME;
  SAVE ADMIN VARIABLES TO DISK;"

  # Add the mysql servers from orchestrator
  seed_mysql_servers

  # Add user/pass to proxysql
  echo "Adding user/pass to proxysql"
  mysql -u admin -padmin -h 127.0.0.1 -P 6032 -e "
  INSERT INTO mysql_users(username,password,default_hostgroup) VALUES ('$DB_NAME','$DB_NAME',0);
  LOAD MYSQL USERS TO RUNTIME;
  SAVE MYSQL USERS TO DISK;"

  # Add query rules
  echo "Adding query rules"
  mysql -u admin -padmin -h 127.0.0.1 -P 6032 -e "
  INSERT INTO mysql_query_rules (active, match_digest, destination_hostgroup, apply) VALUES (1, '^SELECT.*FOR UPDATE$', 0, 0);
  INSERT INTO mysql_query_rules (active, match_digest, destination_hostgroup, apply) VALUES (1, '^SELECT', 1, 1);
  LOAD MYSQL QUERY RULES TO RUNTIME;
  SAVE MYSQL QUERY RULES TO DISK;"


  touch /ready.txt
  echo "Bootstrapping complete"
}

bootstrap

while true ; do
  # Loop every 5 seconds and update the master and slaves
  sleep 5
  INIT=0
  seed_mysql_servers
done