#!/bin/sh

echo "Backing up..."
NOW=$(date +"%Y-%m-%d_%H-%M-%S")

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

# Copy backup to /backup/$DB_NAME/latest
rm -rf /backup/$DB_NAME/latest
mkdir -p /backup/$DB_NAME/latest
cp -r /backup/$DB_NAME/$NOW/* /backup/$DB_NAME/latest

# Gzip latest backup
rm -rf /backup/$DB_NAME/latest/$DB_NAME.sql.gz
tar -zcvf /backup/$DB_NAME/latest/$DB_NAME.sql.gz /backup/$DB_NAME/latest

echo "Backup complete. Uploading to S3..."

# Upload backup directory to S3
s3cmd sync /backup/$DB_NAME s3://$S3_BUCKET

# Delete backups older than 7 days
find /backup/* -mtime +7 -exec rm {} \;

echo "Backup uploaded to S3 and local backups older than 7 days deleted."