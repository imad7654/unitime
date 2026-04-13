# Build stage: compile the WAR using Maven
FROM maven:3.9-eclipse-temurin-17 AS build
WORKDIR /app
COPY pom.xml .
COPY JavaSource/ JavaSource/
COPY WebContent/ WebContent/
COPY 3rd_party/ 3rd_party/
COPY build.number .
RUN mvn package -DskipTests -q

# Runtime stage: deploy WAR to Tomcat
FROM tomcat:10.1-jre17
RUN rm -rf /usr/local/tomcat/webapps/*
ADD https://repo1.maven.org/maven2/com/mysql/mysql-connector-j/8.0.33/mysql-connector-j-8.0.33.jar /usr/local/tomcat/lib/
COPY --from=build /app/target/UniTime.war /usr/local/tomcat/webapps/ROOT.war

# Use entrypoint script to handle Railway's PORT variable
RUN echo '#!/bin/bash\n\
if [ -n "$PORT" ]; then\n\
  sed -i "s/8080/$PORT/g" /usr/local/tomcat/conf/server.xml\n\
fi\n\
exec catalina.sh run' > /start.sh && chmod +x /start.sh

ENV CATALINA_OPTS="-Xmx1g"

EXPOSE 8080
CMD ["/start.sh"]
