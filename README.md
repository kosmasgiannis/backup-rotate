# backup-rotate

  Generic backup script with rotation support

# Features

 * Backup via mysqldump MySQL Databases
 * Schedule backups on hourly, daily, weekly, monthly or annually basis
 * keep all or up to specific number of backups for each period
 * copy backups to specific location on local server or upload to an AWS S3 bucket

# Prerequisites

 * [node / npm](https://nodejs.org)
 * [jq](https://jqlang.github.io/jq)
 * [toml2js](https://www.npmjs.com/package/toml2js)
 * [mysqldump](https://dev.mysql.com/doc/refman/8.0/en/mysqldump.html)
 * [s3cmd](https://s3tools.org/s3cmd)

# sample config
    
    [_backuprotate_]
    dumpdir="/tmp"
    log="/path/to/backuprotate.log"

    [mydb]
    # schedule: hourly, daily, weekly,  monthly, annually
    type="mysql"
    extradumpparameters="--no-tablespaces --column-statistics=0 --compression-algorithms=zlib"
    cpmethod="cp"
    schedule="hourly"
    host="127.0.0.1"
    username="mruser"
    password="very.secret"
    database="mydb"
    sslkey="/path/to/client-key.pem"
    sslcert="/path/to/client-cert.pem"
    sslca="/path/to/ca-cert.pem"
    path="./backups"
    hours=240
    days=60
    weeks=52
    months=24
    years="all"

    [otherdb]
    # schedule: hourly, daily, weekly,  monthly, annually
    skip="yes"
    type="mysql"
    extradumpparameters="--no-tablespaces --column-statistics=0 --compression-algorithms=zlib"
    cpmethod="s3"
    s3cfg="./s3.cfg"
    schedule="weekly"
    host="db.example.com"
    username="master"
    password="top.secret"
    database="smalldb"
    #sslkey="/path/to/client-key.pem"
    #sslcert="/path/to/client-cert.pem"
    #sslca="/path/to/ca-cert.pem"
    bucket="my-database-dump-location"
    path="/backups/cloud-service"
    hours=240
    days=60
    weeks=52
    months=24
    years="all"

# Run

    backuprotate.sh <config>

# Cron

    00 * * * *    root test -x /path/to/backuprotate.sh && ( cd /tmp && /path/to/backuprotate.sh /path/to/backuprotate.conf )
