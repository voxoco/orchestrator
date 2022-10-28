FROM alpine:3.15

RUN apk add --no-cache curl jq mysql-client py-pip ca-certificates libc6-compat && pip install s4cmd

ADD orchestrator.sh /orchestrator.sh
ADD mysql.sh /mysql.sh
ADD proxysql.sh /proxysql.sh
ADD backup.sh /backup.sh
ADD bin /usr/local/bin

RUN chmod +x /orchestrator.sh /mysql.sh /proxysql.sh /backup.sh /usr/local/bin/*

CMD ["/bin/sh"]
