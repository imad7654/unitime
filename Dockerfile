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

# Entrypoint: substitute PORT in server.xml and build CATALINA_OPTS safely from env vars
COPY <<'EOF' /start.sh
#!/bin/bash
set -e

# Replace Tomcat's default HTTP port with Railway's PORT
if [ -n "$PORT" ]; then
  sed -i "s/port=\"8080\"/port=\"$PORT\"/" /usr/local/tomcat/conf/server.xml
fi

# Build CATALINA_OPTS as an array, then join — avoids shell word-splitting on & in URLs
OPTS=(-Xmx1g)
if [ -n "$MYSQLHOST" ]; then
  OPTS+=("-Dconnection.url=jdbc:mysql://${MYSQLHOST}:${MYSQLPORT}/${MYSQLDATABASE}?useSSL=false")
  OPTS+=("-Dconnection.username=${MYSQLUSER}")
  OPTS+=("-Dconnection.password=${MYSQLPASSWORD}")
fi
export CATALINA_OPTS="${OPTS[*]}"
echo "CATALINA_OPTS built from env (DB host: ${MYSQLHOST:-unset})"

exec catalina.sh run
EOF
RUN chmod +x /start.sh

EXPOSE 8080
CMD ["/start.sh"]
