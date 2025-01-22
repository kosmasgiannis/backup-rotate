#!/bin/bash
#
# backuprotate
#
# Author  : Giannis Kosmas <kosmasgiannis@gmail.com>
# Date    : 01 Sep 2017
# License : MIT
#
# Requirements : s3cmd, jq, node, toml2js, mysqldump
debug=false

[ -h $0 ] && scriptname=`readlink $0` || scriptname=$0
scriptdir=$(dirname $scriptname)
scriptname=$(basename $scriptname .sh)
lockfile="/tmp/$scriptname.lock"

if [ -r $lockfile ]; then
  pid=`cat $lockfile`
  if kill -0 $pid > /dev/null 2>&1 ; then
    #echo $pid" running"
    exit;
  else
    #echo "$pid not running"
    echo "$$" > $lockfile
  fi
else
  echo "$$" > $lockfile
fi

function abort() {
 rm -f $lockfile
 local log="$3"
 #[ -n "$3" ] || log="/var/log/backuprotate.log"
 [ -n "$2" ] && echo "$2" | tee $log
 exit $1;
}

if [ -n "$1" ]; then
  config=$1
else
  abort 2 "Please specify config file." 
fi

if [ ! -r "$config" ]; then
  echo "Unable to read $config, exiting..."
  exit 2
fi

which mysqldump > /dev/null 2>&1

if [ $? -ne 0 ]; then
  abort 2 "Please install mysqldump. Exiting..." 
fi

which toml2js > /dev/null 2>&1

if [ $? -ne 0 ]; then
  abort 2 "Please install toml2js. Exiting..." 
fi

os=`uname -s`
case $os in
  'Darwin')
      dateexe="gdate"
  ;;
  *)
      dateexe="date"
  ;;
esac

which $dateexe > /dev/null 2>&1

if [ $? -ne 0 ]; then
  abort 2 "Please install $dateexe. Exiting..."
fi

datestamp=`$dateexe +%Y%m%d%H`
datestamp="$datestamp""00"

date=`$dateexe +%Y-%m-%dT%H:%M`
day=`$dateexe -d $date +%d`
weekday=`$dateexe -d $date +%w`
week=`$dateexe -d $date +%V`
month=`$dateexe -d $date +%m`
hour=`$dateexe -d $date +%H`
pdate=`$dateexe -d "-1 days" +%Y-%m-%dT%H:%M`
pweek=`$dateexe -d $pdate +%V`
week=$((10#$week))
pweek=$((10#$pweek))
dday=$((10#$day))

which jq > /dev/null 2>&1

if [ $? -ne 0 ]; then
  abort 2 "Please install jq. Exiting..." 
fi

toml2js "$config" > /dev/null 2>&1
if [ $? -ne 0 ]; then
  abort 2 "Check and fix config file"
fi

LOGFILE=`toml2js "$config" | jq -r -M "._backuprotate_.log"`
if [ $LOGFILE == "null" ]; then
  LOGFILE="/var/log/backuprotate.log"
fi

dumpdir=`toml2js "$config" | jq -r -M "._backuprotate_.dumpdir"`
if [ $dumpdir == "null" ]; then
 abort 2 "Please specify directory to store backup dump" "$LOGFILE"
fi

mkdir -p "$dumpdir"

function prune () {
  local base=$1
  local dir=$2
  local keep=$3
  local cpcmp=$4
 if [ $cpmethod == "s3" ]; then
   s3cmd -c $S3CFG ls "$base/$dir/" 2>&1 | sed 's/^ *DIR *//' > /tmp/.backuprotate.tmp
   grep '^ERROR' /tmp/.backuprotate.tmp 2>&1
   rc=$?
   if [ $rc != 0 ]; then
     cat /tmp/.backuprotate.tmp | sort -rn | awk " NR > $keep" | while read f; do s3cmd --no-progress -c $S3CFG rm --recursive "$f"; done
   else
     echo "Fix the error and retry." >> $LOGFILE
   fi
   rm -f /tmp/.backuprotate.tmp
 else
   if [ -d "$base/$dir" ]; then
     find "$base/$dir" -mindepth 1 -maxdepth 1 -type d | sort -rn | awk " NR > $keep" | while read f; do rm -rf "$f"; done
   fi
 fi
}

for section in `toml2js "$config" | jq -r -M 'keys' | jq -r -M '.[]'`; do
  if [ $section != "_backuprotate_" ]; then
    skip="no"
    bucket=""
    skipme=`toml2js "$config" | jq -r -M ".$section.skip"`
    if [ "$skipme" == "yes" ]; then
      echo "Skipping $section..." >> $LOGFILE
      skip="yes"
    fi

    cpmethod=`toml2js "$config" | jq -r -M ".$section.cpmethod"`
    if [ $cpmethod == "null" ]; then
      echo "Please specify method of copy (cpmethod)..." >> $LOGFILE
      skip="yes"
    fi
   
    if [ $cpmethod == "s3" ]; then
      which s3cmd > /dev/null 2>&1

      if [ $? -ne 0 ]; then
        echo "Please install s3cmd or specify a different copy method" >> $LOGFILE
        skip="yes"
      fi

      S3CFG=`toml2js "$config" | jq -r -M ".$section.s3cfg"`
      if [ $S3CFG == "null" ]; then
        echo "Please specify config file for s3cmd" >> $LOGFILE
        skip="yes"
      fi

      if [ ! -r "$S3CFG" ]; then
        echo "Please specify a valid config file for s3cmd" >> $LOGFILE
        skip="yes"
      fi

      bucket=`toml2js "$config" | jq -r -M ".$section.bucket"`
      if [ $bucket == "null" ]; then
        echo "Bucket not set in $section, skipping..." >> $LOGFILE
        skip="yes"
      fi
    fi
    mypath=`toml2js "$config" | jq -r -M ".$section.path"`
    if [ $mypath == "null" ]; then
      echo "Path not set in $section, skipping..." >> $LOGFILE
      skip="yes"
    fi
    hours=`toml2js "$config" | jq -r -M ".$section.hours"`
    if [ $hours == "null" ]; then
      hours="all"
    fi
    days=`toml2js "$config" | jq -r -M ".$section.days"`
    if [ $days == "null" ]; then
      days="all"
    fi
    weeks=`toml2js "$config" | jq -r -M ".$section.weeks"`
    if [ $weeks == "null" ]; then
      weeks="all"
    fi
    months=`toml2js "$config" | jq -r -M ".$section.months"`
    if [ $months == "null" ]; then
      months="all"
    fi
    years=`toml2js "$config" | jq -r -M ".$section.years"`
    if [ $years == "null" ]; then
      years="all"
    fi

    schedule=`toml2js "$config" | jq -r -M ".$section.schedule"`
    if [ $schedule == "null" ]; then
      echo "Schedule not set in $section, skipping..." >> $LOGFILE
      skip="yes"
    fi

    if [ $debug == true ]; then
      echo "bucket=$bucket, path=$mypath" >> $LOGFILE;
      echo "hours=$hours, days=$days, weeks=$weeks, months=$months, years=$years" >> $LOGFILE;
    fi

    type=`toml2js "$config" | jq -r -M ".$section.type"`
    case "$type" in
      'mysql') 

              port=`toml2js "$config" | jq -r -M ".$section.port"`
              if [ "x$port" == "xnull" ]; then
                port=""
              fi

              host=`toml2js "$config" | jq -r -M ".$section.host"`
              if [ "x$host" == "xnull" ]; then
                host="localhost"
              fi

              username=`toml2js "$config" | jq -r -M ".$section.username"`
              if [ "x$username" == "xnull" ]; then
                username=""
              fi

              password=`toml2js "$config" | jq -r -M ".$section.password"`
              if [ "x$password" == "xnull" ]; then
                password=""
              fi

              extradumpparameters=`toml2js "$config" | jq -r -M ".$section.extradumpparameters"`
              if [ "x$extradumpparameters" == "xnull" ]; then
                extradumpparameters=""
              fi

              database=`toml2js "$config" | jq -r -M ".$section.database"`
              if [ "x$database" == "xnull" ]; then
                echo "Database not set in $section, skipping..."
                skip="yes"
              fi
              if [ $debug == true ]; then
                echo "host=$host, username=$username, password=$password, database=$database, schedule=$schedule" >> $LOGFILE
              fi

              MYSQLUSER=""
              MYSQLPASS=""
              MYSQLHOST=""
              MYSQLPORT=""
              [ -n "$username" ] && MYSQLUSER=" -u$username "
              [ -n "$password" ] && MYSQLPASS=" -p$password "
              [ -n "$host" ] && MYSQLHOST=" -h$host "
              [ -n "$port" ] && MYSQLPORT=" -P$port "
      ;;

      *) 
              skip="yes"
      ;;
    esac

    if [ $skip == "no" ]; then
      $debug && echo "Processing..." >> $LOGFILE
      dir=`echo "/$mypath/" | sed 's/^\/\/*/\//' | sed 's/\/\/*$/\//'`
      if [ $cpmethod == "s3" ]; then
        dir="s3://$bucket/$dir$section"
      else
        dir=`echo "$mypath/" | sed 's/\/\/*$/\//'`
        dir="$dir$section"
      fi

      $debug && echo $dir >> $LOGFILE
      outputfile=""

      if [[ ((($schedule == "hourly" ) && ($hour != "00")) || (( $hour == "00") && (( $schedule == "hourly" ) || ($schedule == "daily") || (($schedule == "weekly") && ($weekday == "1")) || (($schedule == "monthly") && ($day=="01")) || (($schedule == "annually") && ("$month/$day" == "01/01")) ))) ]]; then

        case "$type" in
            'mysql') 
                    outputfile="$dumpdir/$database.sql.gz"
                    rm -f "$outputfile"
		    mysqldump "$extradumpparameters" $MYSQLUSER $MYSQLPASS $MYSQLHOST $MYSQLPORT $database | gzip > "$outputfile"
                    rc=${PIPESTATUS[0]}
                    $debug && echo "mysqldump $extradumpparameters $MYSQLUSER $MYSQLPASS $MYSQLHOST $MYSQLPORT $database " >> $LOGFILE
                    if [ $rc -ne 0 ]; then
                      echo "mysqldump exited with code = $rc" >> $LOGIFILE
                    fi
            ;;
            *) 
            ;;
        esac

        if [ $rc -eq 0 ]; then
          if [[ ((( $hour == "00") && ($day == "01") && ($month == "01") && (( $schedule == "hourly" ) || ($schedule == "daily") || ($schedule == "monthly") || ($schedule == "annually"))) ||
             (( $hour == "00") && ($month == "01") && ($weekday == "1") && ( $schedule == "weekly" ) && ($dday -lt 8))) ]]; then
            if [ $cpmethod == "s3" ]; then
              s3cmd --no-progress -c $S3CFG put "$dumpdir/$database.sql.gz" "$dir/annually/$datestamp/$database.sql.gz" 2>&1 >> $LOGFILE
            else
              mkdir -p "$dir/annually/$datestamp"
              mv "$dumpdir/$database.sql.gz" "$dir/annually/$datestamp/$database.sql.gz" 2>&1 >> $LOGFILE
            fi
          elif [[ ((( $hour == "00") && ($day == "01") && (( $schedule == "hourly" ) || ($schedule == "daily") || ($schedule == "monthly"))) ||
             (( $hour == "00") && ($weekday == "1") && ( $schedule == "weekly" ) && ($dday -lt 8))) ]]; then
            if [ $cpmethod == "s3" ]; then
              s3cmd --no-progress -c $S3CFG put "$dumpdir/$database.sql.gz" "$dir/monthly/$datestamp/$database.sql.gz" 2>&1 >> $LOGFILE
            else
              mkdir -p "$dir/monthly/$datestamp"
              cp "$dumpdir/$database.sql.gz" "$dir/monthly/$datestamp/$database.sql.gz" 2>&1 >> $LOGFILE
            fi
          elif [[ (( $hour == "00") && ($weekday == "1") && (( $schedule == "hourly" ) || ($schedule == "daily") || ($schedule == "weekly"))) ]]; then
            if [ $cpmethod == "s3" ]; then
              s3cmd --no-progress -c $S3CFG put "$dumpdir/$database.sql.gz" "$dir/weekly/$datestamp/$database.sql.gz" 2>&1 >> $LOGFILE
            else
              mkdir -p "$dir/weekly/$datestamp"
              cp "$dumpdir/$database.sql.gz" "$dir/weekly/$datestamp/$database.sql.gz" 2>&1 >> $LOGFILE
            fi
          elif [[ (( $hour == "00") && (( $schedule == "hourly" ) || ($schedule == "daily") )) ]]; then
            if [ $cpmethod == "s3" ]; then
              s3cmd --no-progress -c $S3CFG put "$dumpdir/$database.sql.gz" "$dir/daily/$datestamp/$database.sql.gz" 2>&1 >> $LOGFILE
            else
              mkdir -p "$dir/daily/$datestamp"
              cp "$dumpdir/$database.sql.gz" "$dir/daily/$datestamp/$database.sql.gz" 2>&1 >> $LOGFILE
            fi
          elif [ $schedule == "hourly" ]; then
            if [ $cpmethod == "s3" ]; then
              s3cmd --no-progress -c $S3CFG put "$dumpdir/$database.sql.gz" "$dir/hourly/$datestamp/$database.sql.gz" 2>&1 >> $LOGFILE
            else
              mkdir -p "$dir/hourly/$datestamp"
              cp "$dumpdir/$database.sql.gz" "$dir/hourly/$datestamp/$database.sql.gz" 2>&1 >> $LOGFILE
            fi
          fi

          [ $hours == "all" ] || prune "$dir" "hourly" $hours $cpmethod
          [ $days == "all" ] || prune "$dir" "daily" $days $cpmethod
          [ $weeks == "all" ] || prune "$dir" "weekly" $weeks $cpmethod
          [ $months == "all" ] || prune "$dir" "monthly" $months $cpmethod
          [ $years == "all" ] || prune "$dir" "annually" $years $cpmethod
  
          if [ -n "$outputfile" ]; then
            rm -f "$dumpdir/$database.sql.gz"
          fi
        else
          echo "Failed to perform mysqldump for $section" >> $LOGIFILE
        fi

      fi
    fi
  fi
done
