# backup-rotate

  Generic backup script with rotation support

# Features

 * Backup via mysqldump MySQL Databases
 * Backup via yaz-client Zebra Databases
 * Schedule backups on hourly, daily, weekly, monthly or annually basis
 * keep all or up to specific number of backups for each period
 * copy backups to specific location on local server or upload to an AWS S3 bucket

# Prerequisites

 * [node / npm](https://nodejs.org)
 * [jq](https://jqlang.github.io/jq)
 * [toml2js](https://www.npmjs.com/package/toml2js)
 * [mysqldump](https://dev.mysql.com/doc/refman/8.0/en/mysqldump.html)
 * [yaz](https://www.indexdata.com/resources/software/yaz)
 * [s3cmd](https://s3tools.org/s3cmd)
 * [gzip](https://www.gnu.org/software/gzip)
 * [ssh / scp](https://www.openssh.com/)

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

    [zebradb]
    type="zebra"
    cpmethod="cp"
    schedule="hourly"
    host="127.0.0.1"
    database="marcdb"
    port=210
    path="./backups"
    hours=1
    days=1
    weeks=0
    months=0
    years=0

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
    [[otherdb.copies]]
    cpmethod="scp"
    path="./backups"
    sshuser="mruser@example.com"
    sshparams="-o StrictHostKeyChecking=no -i ~/.ssh/my_rsa_key"

# Run

    backuprotate.sh <config>

# Cron

    00 * * * *    root test -x /path/to/backuprotate.sh && ( cd /tmp && /path/to/backuprotate.sh /path/to/backuprotate.conf )
