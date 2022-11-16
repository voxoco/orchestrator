#!/bin/sh

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

# Start consul-template
consul-template -log-level="info" -template="/proxysql.ctmpl:/proxysql.sql:sh -c 'mysql -u admin -padmin -h 127.0.0.1 -P 6032 < /proxysql.sql'"