FROM alpine:3.15

ARG VERSION=3.2.6

RUN apk add --no-cache bash curl libc6-compat

RUN mkdir /opt/orchestrator

# Download orchestrator
RUN curl -L https://github.com/openark/orchestrator/releases/download/v$VERSION/orchestrator-$VERSION-linux-amd64.tar.gz > /tmp/orchestrator.tar.gz && \
  mkdir /tmp/orchestrator && \
  tar -xzf /tmp/orchestrator.tar.gz -C /tmp/orchestrator

# Copy orchestrator stuff
RUN cp /tmp/orchestrator/usr/local/orchestrator/orchestrator /opt/orchestrator && \
  cp /tmp/orchestrator/usr/local/orchestrator/resources/bin/orchestrator-client /opt/orchestrator && \
  cp -r /tmp/orchestrator/usr/local/orchestrator/resources /opt/orchestrator

# Cleanup
RUN rm -rf /tmp/orchestrator*

ADD entrypoint.sh /entrypoint.sh
ADD sidecar/slack.sh /opt/orchestrator/slack.sh
RUN chmod +x /entrypoint.sh /opt/orchestrator/slack.sh

CMD /entrypoint.sh
