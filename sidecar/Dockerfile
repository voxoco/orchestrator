FROM alpine:3.15

RUN apk add --no-cache curl jq mysql-client py-pip python3 libc6-compat && pip install s4cmd

ADD orchestrator.sh /orchestrator.sh
ADD mysql.sh /mysql.sh
ADD proxysql.sh /proxysql.sh
ADD slack.sh /slack.sh
ADD bin /usr/local/bin

RUN chmod +x /orchestrator.sh /mysql.sh /proxysql.sh /slack.sh /usr/local/bin/*

CMD ["/bin/sh"]
