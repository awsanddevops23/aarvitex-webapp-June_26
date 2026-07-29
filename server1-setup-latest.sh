#!/bin/bash
# ═══════════════════════════════════════════════════════════════
#  AARVITEX — Server 1 (App Server) Setup Script
#  Tools: Java 17, Maven 3.9.16, Git, Tomcat 9.0.120,
#         SonarQube 9.9.8, Nexus 3.80.0
#  Synced with: Complete DevOps Setup Guide — Updated Edition
#
#  Usage: Paste into EC2 User Data OR run manually:
#         chmod +x server1-setup.sh && sudo ./server1-setup.sh
#
#  Logs:  /var/log/user-data.log
#  EC2:   t2.medium (4 GB min) | Amazon Linux 2023
#  Ports: 8080 (Tomcat), 9000 (SonarQube), 8081 (Nexus)
# ═══════════════════════════════════════════════════════════════
set -e
exec > /var/log/user-data.log 2>&1

# ── Step 1: System Update ──────────────────────────────────────
dnf update -y
dnf install -y wget unzip tar gzip

# ── Step 2: Install Java 17 (Amazon Corretto) ──────────────────
dnf install -y java-17-amazon-corretto

java -version

# ── Step 3: Install Maven 3.9.16 ───────────────────────────────────
echo '>>> Installing Apache Maven 3.9.16...'
cd /opt
wget https://archive.apache.org/dist/maven/maven-3/3.9.16/binaries/apache-maven-3.9.16-bin.tar.gz

# Extract
sudo tar -xvzf apache-maven-3.9.16-bin.tar.gz
mv apache-maven-3.9.16 maven
rm -f apache-maven-3.9.16-bin.tar.gz

# Set JAVA_HOME + Maven in ONE file (prevents PATH conflicts)
cat > /etc/profile.d/java.sh << 'ENVEOF'
export JAVA_HOME=/usr/lib/jvm/java-17-amazon-corretto
export M2_HOME=/opt/maven
export PATH=$JAVA_HOME/bin:$M2_HOME/bin:$PATH
ENVEOF

source /etc/profile.d/java.sh

echo "JAVA_HOME=$JAVA_HOME"
java -version
mvn -version

# ── Step 4: Install Git + Clone Repo ──────────────────────────
dnf install -y git
git --version

cd /opt
git clone https://github.com/Aarvitexsathya/aarvitex-webapp.git

# Test build
cd /opt/aarvitex-webapp
source /etc/profile.d/java.sh
mvn clean package
echo ">>> Build successful: $(ls -lh target/AarvitexWebApp.war)"

# ── Step 5: Install Tomcat 9.0.120 (Port 8080) ────────────────
cd /opt
wget -q https://dlcdn.apache.org/tomcat/tomcat-9/v9.0.120/bin/apache-tomcat-9.0.120.tar.gz
tar -xzf apache-tomcat-9.0.120.tar.gz
rm -f apache-tomcat-9.0.120.tar.gz

# Make scripts executable
chmod u+x /opt/apache-tomcat-9.0.120/bin/*.sh

# Configure Manager Access (for Jenkins deploy later)
cat > /opt/apache-tomcat-9.0.120/conf/tomcat-users.xml << 'TCUSERS'
<?xml version="1.0" encoding="UTF-8"?>
<tomcat-users xmlns="http://tomcat.apache.org/xml"
              xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance"
              xsi:schemaLocation="http://tomcat.apache.org/xml tomcat-users.xsd"
              version="1.0">
  <role rolename="manager-gui"/>
  <role rolename="manager-script"/>
  <role rolename="admin-gui"/>
  <user username="aarvitex" password="aarvitex123"
        roles="manager-gui,manager-script,manager-jmx,manager-status,admin-gui"/>
</tomcat-users>
TCUSERS

# Allow Remote Manager Access (so Jenkins on Server 2 can deploy)
cat > /opt/apache-tomcat-9.0.120/webapps/manager/META-INF/context.xml << 'CTXEOF'
<?xml version="1.0" encoding="UTF-8"?>
<Context antiResourceLocking="false" privileged="true">
  <!-- RemoteAddrValve removed to allow Jenkins remote deploy -->
</Context>
CTXEOF

# Also fix host-manager context
cat > /opt/apache-tomcat-9.0.120/webapps/host-manager/META-INF/context.xml << 'CTXEOF2'
<?xml version="1.0" encoding="UTF-8"?>
<Context antiResourceLocking="false" privileged="true">
</Context>
CTXEOF2

# Start Tomcat
/opt/apache-tomcat-9.0.120/bin/startup.sh

# Deploy WAR
cp /opt/aarvitex-webapp/target/AarvitexWebApp.war /opt/apache-tomcat-9.0.120/webapps/

echo '>>> Tomcat installed — port 8080'

# ── Step 6: Install SonarQube 9.9.8 (Port 9000) ─────────────

# System limits for Elasticsearch
echo "vm.max_map_count=262144" >> /etc/sysctl.conf
echo "fs.file-max=65536" >> /etc/sysctl.conf
sysctl -p

cat >> /etc/security/limits.conf << 'LIMEOF'
sonar   -   nofile   65536
sonar   -   nproc    4096
LIMEOF

# Create sonar user (SonarQube can't run as root)
useradd sonar || true
echo "sonar:sonar123" | chpasswd

# Download and install
cd /opt
wget -q https://binaries.sonarsource.com/Distribution/sonarqube/sonarqube-9.9.8.100196.zip
unzip -q sonarqube-9.9.8.100196.zip
mv sonarqube-9.9.8.100196 sonarqube
rm -f sonarqube-9.9.8.100196.zip

chown -R sonar:sonar /opt/sonarqube
sed -i 's/#RUN_AS_USER=/RUN_AS_USER=sonar/' /opt/sonarqube/bin/linux-x86-64/sonar.sh

# Create systemd service
cat > /etc/systemd/system/sonarqube.service << 'SQSVC'
[Unit]
Description=SonarQube
After=network.target

[Service]
Type=forking
User=sonar
Group=sonar
ExecStart=/opt/sonarqube/bin/linux-x86-64/sonar.sh start
ExecStop=/opt/sonarqube/bin/linux-x86-64/sonar.sh stop
LimitNOFILE=65536
LimitNPROC=4096

[Install]
WantedBy=multi-user.target
SQSVC

systemctl daemon-reload
systemctl enable sonarqube
systemctl start sonarqube

echo '>>> SonarQube installed — port 9000 (takes ~60s to start)'
echo '>>> Login: admin / admin (change on first login to aarvitex123)'

# ── Step 7: Install Nexus 3.80.0-06 (Port 8081) ─────────────────

# Create nexus user
useradd nexus || true
echo "nexus:nexus123" | chpasswd

# Download and install
cd /opt
wget -q https://download.sonatype.com/nexus/3/nexus-3.80.0-06-linux-x86_64.tar.gz
tar -xzf nexus-3.80.0-06-linux-x86_64.tar.gz
mv nexus-3.80.0-06 nexus
rm -f nexus-3.80.0-06-linux-x86_64.tar.gz

chown -R nexus:nexus /opt/nexus
chown -R nexus:nexus /opt/sonatype-work
chmod -R 775 /opt/nexus
chmod -R 775 /opt/sonatype-work

# Create systemd service
cat > /etc/systemd/system/nexus.service << 'NXSVC'
[Unit]
Description=Sonatype Nexus Repository Manager
After=network.target

[Service]
Type=forking
LimitNOFILE=65536
User=nexus
Group=nexus
ExecStart=/opt/nexus/bin/nexus start
ExecStop=/opt/nexus/bin/nexus stop
Restart=on-abort

[Install]
WantedBy=multi-user.target
NXSVC

systemctl daemon-reload
systemctl enable nexus
systemctl start nexus

echo '>>> Nexus installed — port 8081 (takes ~60-90s to start)'