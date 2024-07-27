# Use the official Apache Pinot image as the base image
FROM apachepinot/pinot:latest


# Download the JAR file and place it in /opt/pinot/lib
RUN curl -o /opt/pinot/lib/aws-msk-iam-auth-1.1.1-all.jar -L https://github.com/aws/aws-msk-iam-auth/releases/download/v1.1.1/aws-msk-iam-auth-1.1.1-all.jar 
RUN curl -o /opt/pinot/lib/kafka-clients-2.8.1.jar -L https://repo1.maven.org/maven2/org/apache/kafka/kafka-clients/2.8.1/kafka-clients-2.8.1.jar

# Expose the necessary ports
EXPOSE 8096 8097 8098 8099

# Set the working directory
WORKDIR /opt/pinot

# Define the entrypoint and command
ENTRYPOINT ["./bin/pinot-admin.sh"]
CMD ["-help"]
