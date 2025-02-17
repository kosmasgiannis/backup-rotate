#!/usr/bin/env bash
#
# backuprotate
#
# Author  : Giannis Kosmas <kosmasgiannis@gmail.com>
# Date    : 01 Sep 2017
# License : MIT
#
# Requirements : s3cmd, jq, node, toml2js, mysqldump, yaz-client

#set -x
debug=false

[ -h $0 ] && scriptname=`readlink $0` || scriptname=$0
scriptdir=$(dirname $scriptname)
scriptname=$(basename $scriptname .sh)
lockfile="/tmp/$scriptname.lock"
declare -A copies
declare -A acopy
copyno=-1

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
installed_mysqldump=$?

which yaz-client > /dev/null 2>&1
installed_yazclient=$?

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
  local cpmethod=$4
  local sshuser=$5
  local sshparams=$6
  local S3CFG=$7
  if [ $cpmethod == "s3" ]; then
    s3cmd -c $S3CFG ls "$base/$dir/" 2>&1 | sed 's/^ *DIR *//' > /tmp/.backuprotate.tmp
    grep '^ERROR' /tmp/.backuprotate.tmp 2>&1
    rc=$?
    if [ $rc != 0 ]; then
      if [ -s /tmp/.backuprotate.tmp ]; then
        while read f; do
          echo "Deleting $f" >> $LOGFILE
          s3cmd --no-progress -c $S3CFG rm --recursive "$f";
        done < <( cat /tmp/.backuprotate.tmp | sort -rn | awk " NR > $keep")
      fi
    else
      cat /tmp/.backuprotate.tmp >> $LOGIFLE
      echo "Fix the error and retry." >> $LOGFILE
    fi
    rm -f /tmp/.backuprotate.tmp
  elif [ $cpmethod == "scp" ]; then
    isdir=`ssh $sshparams "$sshuser" file "$base/$dir" | sed 's/.*: //'`
    if [ "$isdir" == "directory" ]; then
      ssh -n $sshparams "$sshuser" find "$base/$dir" -mindepth 1 -maxdepth 1 -type d | sort -rn | awk " NR > $keep" > /tmp/.backuprotate.tmp
      if [ -s /tmp/.backuprotate.tmp ]; then
        while read f; do
          echo "Deleting $f" >> $LOGFILE
          ssh -n $sshparams "$sshuser" rm -rf "$f";
        done < <( cat /tmp/.backuprotate.tmp )
      fi
      rm -f /tmp/.backuprotate.tmp
    fi
  else
    if [ -d "$base/$dir" ]; then
      while read f; do
        echo "Deleting $f" >> $LOGFILE
        rm -rf "$f";
      done < <( find "$base/$dir" -mindepth 1 -maxdepth 1 -type d | sort -rn | awk " NR > $keep" )
    fi
  fi
}

function extractCopyParams () {
  local config=$1
  local section=$2
  mypath=""
  S3CFG=""
  bucket=""
  sshuser=""
  sshparams=""
  skip=""
  message=""
  cpmethod=`toml2js "$config" | jq -r -M "$section.cpmethod"`
  if [ $cpmethod == "null" ]; then
    skip="yes"
    message="copy method not defined"
  else
    mypath=`toml2js "$config" | jq -r -M "$section.path"`
    S3CFG=`toml2js "$config" | jq -r -M "$section.s3cfg"`
    bucket=`toml2js "$config" | jq -r -M "$section.bucket"`
    sshuser=`toml2js "$config" | jq -r -M "$section.sshuser"`
    sshparams=`toml2js "$config" | jq -r -M "$section.sshparams"`
    skip=`toml2js "$config" | jq -r -M "$section.skip"`
    message=""
    if [ $mypath == "null" ]; then
      skip="yes"
      message="path not set in $section"
    fi
    if [ "$sshparams" == "null" ]; then
      sshparams=""
    fi
    if [ $cpmethod == "s3" ]; then
      which s3cmd > /dev/null 2>&1

      if [ $? -ne 0 ]; then
        skip="yes"
        message="please install s3cmd or specify a different copy method"
      fi

      if [ $S3CFG == "null" ]; then
        skip="yes"
        message="please specify config file for s3cmd"
      fi

      if [ ! -r "$S3CFG" ]; then
        skip="yes"
        message="please specify a valid config file for s3cmd"
      fi

      if [ $bucket == "null" ]; then
        skip="yes"
        message="Bucket not set in $section"
      fi
    fi
  fi
  ((copyno++))
  acopy=()
  acopy["cpmethod"]=$cpmethod
  acopy["path"]="$mypath"
  acopy["bucket"]="$bucket"
  acopy["s3cfg"]="$S3CFG"
  acopy["sshuser"]="$sshuser"
  acopy["sshparams"]="$sshparams"
  acopy["skip"]="$skip"
  acopy["message"]="$message"
  for key in "${!acopy[@]}"; do
    if [ $debug == true ]; then
      echo "--> $key : " ${acopy[$key]} >> $LOGFILE
    fi
    copies[$copyno,$key]=${acopy[$key]}
  done
}

function copyDump () {
  local cpmethod=$1
  local outputfile=$2
  local outputbasefile=$3
  local destpath=$4
  local sshuser=$5
  local sshparams=$6
  local S3CFG=$7

  echo "Copying $outputfile using $cpmethod" >> $LOGFILE
  if [ $cpmethod == "s3" ]; then
    s3cmd --no-progress -c $S3CFG put "$outputfile" "$destpath/$outputbasefile" 2>&1 >> $LOGFILE
  elif [ $cpmethod == "scp" ]; then
    ssh -n $sshparams "$sshuser" mkdir -p "$destpath"
    scp $sshparams "$outputfile" "$sshuser":"$destpath/$outputbasefile" 2>&1 >> $LOGFILE
  else
    mkdir -p "$destpath"
    cp "$outputfile" "$destpath/$outputbasefile" 2>&1 >> $LOGFILE
  fi
}

#
# -- Main Loop
#
for section in `toml2js "$config" | jq -r -M 'keys' | jq -r -M '.[]'`; do
  if [ $section != "_backuprotate_" ]; then
    skipsection="no"
    copyno=-1
    copies=()
    skipme=`toml2js "$config" | jq -r -M ".$section.skip"`
    if [ "$skipme" == "yes" ]; then
      echo "Skipping $section..." >> $LOGFILE
      continue
    fi
    echo "Processing $section..." >> $LOGFILE

    copieslength=`toml2js "$config" | jq -r -M ".$section.copies | length"`
    extractCopyParams "$config" ".$section"

    if [ $cpmethod == "null" ]; then
      if [ $copieslength -eq 0 ]; then
        echo "Please specify method of copy (cpmethod)..." >> $LOGFILE
        skipsection="yes"
      fi
    fi

    if [ $copieslength -ne 0 ]; then
      ((copieslength--))
      for j in $(seq 0 $copieslength ); do
        extractCopyParams "$config" ".$section.copies[$j]"
      done
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
      skipsection="yes"
    fi

    if [ $debug == true ]; then
      echo "hours=$hours, days=$days, weeks=$weeks, months=$months, years=$years" >> $LOGFILE;
    fi

    type=`toml2js "$config" | jq -r -M ".$section.type"`
    case "$type" in
      'mysql')
              if [ $installed_mysqldump -ne 0 ]; then
                echo "Please install mysqldump. Skipping..."
                skipsection="yes"
              fi

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
                skipsection="yes"
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

      'zebra')
              if [ $installed_yazclient -ne 0 ]; then
                echo "Please install yaz-client. Skipping..."
                skipsection="yes"
              fi

              if [ "$(LC_ALL=C type -t zebradump)" != "function" ]; then
                function zebradump() {
                  zurl=$1
                  fname=$2
                  auth=$3
                  #basedir="${2:-.}"
                  #dir=$(date +%Y%m%d)
                  #mkdir -p "$basedir/$dir"
                  #fname="$basedir/$dir/${1/*\//}_$(date +%Y%m%d%H%M).mrc"
                  #rm -f $fname

                  if [ -n "$3" ]; then
                    authentication="authentication $auth\n"
                  else
                    authentication=""
                  fi

                  local x
                  local i

                  allrecs=`yaz-client $zurl <<< "${authentication}find @attr 1=_ALLRECORDS @attr 2=103 ''" | grep hits | sed 's/.*: //' | sed 's/,.*//'`

                  if [ -n "$allrecs" ]; then

                    s="${authentication}open $zurl\nfind @attr 1=_ALLRECORDS @attr 2=103 ''\n"

                    for i in `seq 1 1000 $allrecs`; do
                      x=$(($i+1000))
                      if [ $x -ge $allrecs ]; then
                        x=$(($allrecs-$i+1))
                      else
                        x=1000
                      fi
                      s="$s\nshow $i+$x"
                    done

                    s="$s\nquit\n"

                    echo -e $s | yaz-client -m $fname > /dev/null
                    gzip $fname
                    return 0
                  else
                    return 1
                  fi
                }

              fi

              port=`toml2js "$config" | jq -r -M ".$section.port"`
              if [ "x$port" == "xnull" ]; then
                port="210"
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

              database=`toml2js "$config" | jq -r -M ".$section.database"`
              if [ "x$database" == "xnull" ]; then
                echo "Database not set in $section, skipping..."
                skipsection="yes"
              fi
              if [ $debug == true ]; then
                echo "host=$host, username=$username, password=$password, database=$database, schedule=$schedule" >> $LOGFILE
              fi

      ;;

      *)
              skipsection="yes"
      ;;
    esac

    if [ $skipsection == "yes" ]; then
      continue
    fi

    #declare -p copies

    skipall="yes"
    for z in $(seq 0 $copyno); do
      if [ ${copies[$z,"skip"]} != "yes" ]; then
        skipall="no"
      else
        if [ $z -ne 0 ] && [ ${#copies[@]} -ne 1 ]; then
          echo "Skipping copy method : ${copies[$z,"cpmethod"]}, message: ${copies[$z,"message"]}"
        fi
      fi
    done


    if [ $skipall == "no" ]; then
      $debug && echo "Processing..." >> $LOGFILE
      outputfile=""

      if [[ ((($schedule == "hourly" ) && ($hour != "00")) || (( $hour == "00") && (( $schedule == "hourly" ) || ($schedule == "daily") || (($schedule == "weekly") && ($weekday == "1")) || (($schedule == "monthly") && ($day=="01")) || (($schedule == "annually") && ("$month/$day" == "01/01")) ))) ]]; then

        case "$type" in
            'mysql')
                    outputfile="$dumpdir/$database.sql.gz"
                    outputbasefile="$database.sql.gz"
                    rm -f "$outputfile"
		    mysqldump $extradumpparameters $MYSQLUSER $MYSQLPASS $MYSQLHOST $MYSQLPORT $database | gzip > "$outputfile"
                    rc=${PIPESTATUS[0]}
                    $debug && echo "mysqldump $extradumpparameters $MYSQLUSER $MYSQLPASS $MYSQLHOST $MYSQLPORT $database " >> $LOGFILE
                    if [ $rc -ne 0 ]; then
                      echo "mysqldump exited with code = $rc" >> $LOGFILE
                    else
                      echo "mysqldump completed successfully" >> $LOGFILE
                    fi
            ;;
            'zebra')
                    outputfile="$dumpdir/$database.mrc.gz"
                    outputfile2="$dumpdir/$database.mrc"
                    outputbasefile="$database.mrc.gz"
                    if [ -n "$username" ]; then
                       auth="$username/$password"
                    else
                       auth=""
                    fi
                    rm -f "$outputfile" "$outputfile2"
                    zebradump "$host:$port/$database" "$outputfile2" "$auth"
                    rc=$?
                    if [ $rc -ne 0 ]; then
                      echo "zebradump exited with code = $rc" >> $LOGFILE
                    else
                      echo "zebradump completed successfully" >> $LOGFILE
                    fi
            ;;
            *)
            ;;
        esac

        if [ $rc -eq 0 ]; then
          for z in $(seq 0 $copyno); do
            if [ ${copies[$z,"skip"]} == "yes" ]; then
              continue
            fi
            cpmethod=${copies[$z,"cpmethod"]}
            bucket=${copies[$z,"bucket"]}
            S3CFG=${copies[$z,"s3cfg"]}
            mypath=${copies[$z,"path"]}
            sshuser=${copies[$z,"sshuser"]}
            sshparams=${copies[$z,"sshparams"]}

            dir=`echo "/$mypath/" | sed 's/^\/\/*/\//' | sed 's/\/\/*$/\//'`
            if [ $cpmethod == "s3" ]; then
              dir="s3://$bucket/$dir$section"
            else
              dir=`echo "$mypath/" | sed 's/\/\/*$/\//'`
              dir="$dir$section"
            fi

            $debug && echo $dir >> $LOGFILE
            if [[ ((( $hour == "00") && ($day == "01") && ($month == "01") && (( $schedule == "hourly" ) || ($schedule == "daily") || ($schedule == "monthly") || ($schedule == "annually"))) ||
               (( $hour == "00") && ($month == "01") && ($weekday == "1") && ( $schedule == "weekly" ) && ($dday -lt 8))) ]]; then
              copyDump $cpmethod "$outputfile" "$outputbasefile" "$dir/annually/$datestamp" $sshuser "$sshparams" $S3CFG
            elif [[ ((( $hour == "00") && ($day == "01") && (( $schedule == "hourly" ) || ($schedule == "daily") || ($schedule == "monthly"))) ||
               (( $hour == "00") && ($weekday == "1") && ( $schedule == "weekly" ) && ($dday -lt 8))) ]]; then
              copyDump $cpmethod "$outputfile" "$outputbasefile" "$dir/monthly/$datestamp" $sshuser "$sshparams" $S3CFG
            elif [[ (( $hour == "00") && ($weekday == "1") && (( $schedule == "hourly" ) || ($schedule == "daily") || ($schedule == "weekly"))) ]]; then
              copyDump $cpmethod "$outputfile" "$outputbasefile" "$dir/weekly/$datestamp" $sshuser "$sshparams" $S3CFG
            elif [[ (( $hour == "00") && (( $schedule == "hourly" ) || ($schedule == "daily") )) ]]; then
              copyDump $cpmethod "$outputfile" "$outputbasefile" "$dir/daily/$datestamp" $sshuser "$sshparams" $S3CFG
            elif [ $schedule == "hourly" ]; then
              copyDump $cpmethod "$outputfile" "$outputbasefile" "$dir/hourly/$datestamp" $sshuser "$sshparams" $S3CFG
            fi

            [ $hours == "all" ] || prune "$dir" "hourly" $hours $cpmethod $sshuser "$sshparams" $S3CFG
            [ $days == "all" ] || prune "$dir" "daily" $days $cpmethod $sshuser "$sshparams" $S3CFG
            [ $weeks == "all" ] || prune "$dir" "weekly" $weeks $cpmethod $sshuser "$sshparams" $S3CFG
            [ $months == "all" ] || prune "$dir" "monthly" $months $cpmethod $sshuser "$sshparams" $S3CFG
            [ $years == "all" ] || prune "$dir" "annually" $years $cpmethod $sshuser "$sshparams" $S3CFG

          done
          if [ -n "$outputfile" ]; then
            rm -f "$dumpdir/$outputbasefile"
          fi
        else
          echo "Failed to perform dump for $section" >> $LOGFILE
        fi
      fi
    fi
  fi
done
