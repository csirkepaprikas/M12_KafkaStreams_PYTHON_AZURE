FROM confluentinc/cp-server-connect:7.6.0 AS base

USER root

RUN confluent-hub install --no-prompt confluentinc/kafka-connect-azure-blob-storage:latest
RUN confluent-hub install --no-prompt confluentinc/kafka-connect-azure-blob-storage-source:latest

USER appuser


