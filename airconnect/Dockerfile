ARG BUILD_FROM
FROM $BUILD_FROM

# Use the existing docker-airconnect image
FROM 1activegeek/airconnect:latest

# Copy run script
COPY run.sh /
RUN chmod a+x /run.sh

CMD [ "/run.sh" ]
