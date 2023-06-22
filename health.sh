#!/bin/bash
# Easy to use script to do a pretty print compilation of checks on a running linux machine.
# Author: Cory Casper

# *------ Nice to have general operating system info. ------*
hostname -f &> /dev/null && printf "Hostname : $(hostname -f)" || printf "Hostname : $(hostname -s)"
echo -en "\nOperating System : "
[ -f /etc/os-release ] && echo $(egrep -w "NAME|VERSION" /etc/os-release|awk -F= '{ print $2 }'|sed 's/"//g') || cat /etc/system-release
echo -e "Kernel Version :" $(uname -r)
printf "OS Architecture :"$(arch | grep x86_64 &> /dev/null) && printf " 64 Bit OS\n"  || printf " 32 Bit OS\n"

# Track the final result of all the checks.
FinalStatus=0

# *------ Status codes ------*
CRITICAL=1
WARNING=255
OK=0

HR="--------------------------------------------------------------------------"

# --------------------------------------------------
# Returns the value that should be set in the status tracking field.
#
# Example Usage:
#   STATUS=$(UpdateStatus $STATUS $?)
#   FinalStatus=$(UpdateStatus $FinalStatus $?)
# --------------------------------------------------
function UpdateStatus() {
  # If the saved status is critical, keep it critical.
  if [[ $1 -eq $CRITICAL ]]; then
    echo $CRITICAL; return 0
  fi
  # If the new status is critical, set it critical.
  if [[ $2 -ne $OK && $2 -ne $WARNING ]]; then
    echo $CRITIAL; return 0
  fi
  # If either status is warning, return warning.
  if [[ $1 -eq WARNING || $2 -eq $WARNING ]]; then
    echo $WARNING; return 0
  fi
  echo $OK
}

# --------------------------------------------------
# Add first line in bold indicating what is going to happen.
# --------------------------------------------------
function PrettyPrintHeader() {
  echo -ne "\e[1;37m$1\e[0m" | fold -s -w 80
}

# --------------------------------------------------
# Prints a message line wrapped to columns 0-70 and a colorful status (0:OK, <0:WARN, >0:FAIL) in columns 74-79
# --------------------------------------------------
function PrettyPrintStatus() {
  printf "\033[80G%s" " ["
  if [[ $1 -eq 0 ]]; then
    echo -ne "\e[1;32mOK\e[0m"
  elif [[ $1 -eq $WARNING ]]; then
    echo -ne "\e[1;33mWARNING\e[0m"
  else
    echo -ne "\e[1;31mCRITICAL\e[0m"
  fi
  printf "]\n"

  FinalStatus=$(UpdateStatus $FinalStatus $1)
}


# --------------------------------------------------
# Add additional details in standard color.
# --------------------------------------------------
function PrettyPrint() {
  echo -e "$1" | fold -s -w 80
}

# --------------------------------------------------
# Checks that the CPU usage is under 80%
# --------------------------------------------------
function CheckCpuUtilization() {
  USAGE=$(/usr/bin/cat /proc/loadavg | awk '{print $1}')
  printf "Current CPU Utilization is: %.2f%%\n", $USAGE
  if [[ $USAGE > 90 ]]; then
    return $CRITICAL
  fi
  if [[ $USAGE > 80 ]]; then
    return $WARNING
  fi

  echo "Top 10 (ps) processes consuming high  CPU:"
  echo "$HR"
  echo "$(ps -eo pcpu,pid,user,args | sort -k 1 -r | head -10)"
}

# --------------------------------------------------
# Check when the last update occurred.
# --------------------------------------------------
function CheckLastUpdate() {
  UPDATE=$(stat --format="%X" /var/cache/apt/pkgcache.bin)
  NOW=$(date +'%s')

  ((DIFF_DAYS=($UPDATE-$NOW)/60/60/24))

  echo "Last apt history log update was $DIFF_DAYS days ago."
  if [[ $DIFF_DAYS -gt 14 ]]; then
    return $CRITICAL
  fi
  if [[ $DIFF_DAYS -gt 7 ]]; then
    return $WARNING
  fi
}

# --------------------------------------------------
# Checks the health of BtrFS.
# --------------------------------------------------
function CheckBtrfsHealth() {
  STATUS=0
  MOUNT=$(mount|egrep -iw "btrfs"|grep -v "loop"|awk '{print $3}')
  for i in $(echo "$MOUNT"); do
  {
    sudo btrfs device stats -c $i
    STATUS=$(UpdateStatus $STATUS $?)
  }
  done 
  return $STATUS
}

# --------------------------------------------------
# Checks the network throughput is < 4 MiB/s
# --------------------------------------------------
function CheckNetworkThroughput() {
  NICS=$(ip -br l | awk '$1 !~ "lo|vir|wl" { print $1}')
  for i in $(echo "$NICS"); do {
    R1=`cat /sys/class/net/$i/statistics/rx_bytes`
    T1=`cat /sys/class/net/$i/statistics/tx_bytes`
    sleep 1
    R2=`cat /sys/class/net/$i/statistics/rx_bytes`
    T2=`cat /sys/class/net/$i/statistics/tx_bytes`
    TBPS=`expr $T2 - $T1`
    RBPS=`expr $R2 - $R1`
    TKBPS=`expr $TBPS / 1024`
    RKBPS=`expr $RBPS / 1024`
    echo "tx $i: $TKBPS kB/s rx $i: $RKBPS kB/s"
    if [[ $TKBPS -gt 4096 || $RKBPS -gt 4096 ]]; then
      return $WARNING
    fi
  }
  done
}

# --------------------------------------------------
# Checks the server memory is <80% utilized
# --------------------------------------------------
function CheckMemoryFree() {
  musage=$(free | awk '/Mem/{printf("RAM Usage: %.2f%%\n"), $3/$2*100}' |  awk '{print $3}' | cut -d"." -f1)
  echo "Current Memory Usage: $musage%"
  if [ $musage -ge 90 ]; then
    return $CRITICAL
  elif [ $musage -ge 80 ]; then
    return $WARNING
  else
    echo "Memory usage is in under threshold"
    return $OK
  fi
}

# --------------------------------------------------
# Checks the swap memory is <25% utilized
# --------------------------------------------------
function CheckSwapFree() {
  susage=$(free| awk '/Swap/{printf("SWAP Usage: %.2f%%\n"), $3/$2*100}' |  awk '{print $3}' | cut -d"." -f1)
  echo "Current Swap Usage: $susage%"
  if [ $susage -ge 50 ]; then
    return $CRITICAL
  elif [ $susage -ge 25 ]; then
    return $WARNING
  else
    echo "Swap usage is in under threshold"
    return $OK
  fi
}

# --------------------------------------------------
# Checks that the specified process is running.
#
# Usage: CheckProcessRunning deluged
# --------------------------------------------------
function CheckProcessRunning() {
  INFO=$(pgrep -x "$1")
  STATUS=$?
  echo "pgrep info: $INFO"
  if [[ $STATUS -eq 0 ]]; then 
    echo "The process $1 is running"
  else
    echo "The process $1 is not running"
    return $CRITICAL
  fi
}

# --------------------------------------------------
# Checks the disk space <90% full.
# --------------------------------------------------
function CheckDiskSpace() {
  STATUS=0
  MOUNT=$(mount|egrep -iw "ext4|ext3|xfs|gfs|gfs2|btrfs"|grep -v "loop"|sort -u -t' ' -k1,2)
  FS_USAGE=$(df -PThl -x fuse -x tmpfs -x iso9660 -x devtmpfs -x squashfs|awk '!seen[$1]++'|sort -k6n|tail -n +2)
  IUSAGE=$(df -iPThl -x fuse -x tmpfs -x iso9660 -x devtmpfs -x squashfs|awk '!seen[$1]++'|sort -k6n|tail -n +2)

  echo -e "\nChecking For Read-only File System[s]"
  echo -e "$HR"
  echo "$MOUNT"| sed 's/remount-ro//'|grep -w ro && echo -e "\n.....Read Only file system[s] found"|| (echo -e ".....No read-only file system[s] found. " && STATUS=1)

  echo -e "\n\nChecking For Currently Mounted File System[s]"
  echo -e "$HR"
  echo "$MOUNT"|column -t

  echo -e "\n\nChecking For Disk Usage On Mounted File System[s]"
  echo -e "$HR"
  echo -e "( 0-90% = OK/HEALTHY,  91-94% = WARNING,  95-100% = CRITICAL )"
  echo -e "$HR"
  echo -e "Mounted File System[s] Utilization (Percentage Used):\n"

  DISKS=$(echo "$FS_USAGE"|awk '{print $1 " "$7}')
  VALUES=$(echo "$FS_USAGE"|awk '{print $6}'|sed -e 's/%//g')
  RESULTS=""

  for i in $(echo "$VALUES"); do {
    STATE="(??)"
    if [ $i -ge 95 ]; then
      STATE="CRITICAL"
      STATUS=$(UpdateStatus $STATUS $CRITICAL)
    elif [[ $i -gt 90 && $i -lt 95 ]]; then
      STATE="WARNING"
      STATUS=$(UpdateStatus $STATUS $WARNING)
    else
      STATE="OK"
    fi
    RESULTS="$(echo -e $i"% $STATE\n$RESULTS")"
  } done

  RESULTS=$(echo "$RESULTS"|sort -k1n)
  paste <(echo "$DISKS") <(echo "$RESULTS") -d' '|column -t
  return $STATUS
}

# --------------------------------------------------
# Checks the inode usage.
# --------------------------------------------------
function CheckInodeUsage() {
  STATUS=0
  IUSAGE=$(df -iPThl -x overlay -x vfat -x btrfs -x fuse -x tmpfs -x iso9660 -x devtmpfs -x squashfs|awk '!seen[$1]++'|tail -n +2|sort -k6n)

  echo -e "\nChecking INode Usage"
  echo -e "$HR"
  echo -e "( 0-84% = OK/HEALTHY,  85-95% = WARNING,  95-100% = CRITICAL )"
  echo -e "$HR"
  echo -e "INode Utilization (Percentage Used):\n"

  DISKS=$(echo "$IUSAGE"|awk '{print $1" "$7}')
  VALUES=$(echo "$IUSAGE"|awk '{print $6}'|sed -e 's/%//g')
  RESULTS=""

  for i in $(echo "$VALUES"); do {
    STATE="(??)"
    if ! [[ $i = *[[:digit:]]* ]]; then
      STATE="(unknown)"
    elif [ $i -ge 95 ]; then
      STATUS=$(UpdateStatus $STATUS $CRITICAL)
      STATE="CRITICAL"
    elif [[ $i -ge 85 && $i -lt 95 ]]; then
      STATUS=$(UpdateStatus $STATUS $WARNING)
      STATE="WARNING"
    else
      STATE="OK"
    fi
    RESULTS="$(echo -e $i"% $STATE\n$RESULTS")"
  } done

  RESULTS=$(echo "$RESULTS"|sort -k1n)
  paste  <(echo "$DISKS") <(echo "$RESULTS") -d' '|column -t

  return $STATUS
}

# --------------------------------------------------
# Checks the ufw firewall is running and configured.
# --------------------------------------------------
function CheckFirewall() {
 {
   echo $(netstat -ntlp | grep -vEe "\s+127[.]|::1" 2>&1) 2>&1
 } 2>&1
 UFW=$(sudo ufw status verbose)

 UFW_INACTIVE=$(echo $UFW | grep inactive)

 echo "Recommended rules:"
 echo " ufw show added # To see rules before enabling."
 echo " ufw allow ssh"
 echo " ufw default deny incoming"
 echo " ufw allow from 192.168.86.0/24"
 echo " ufw enable"

 # Is it enabled.
 if [[ $UFW_INACTIVE != "" ]]; then
   echo "CRITICAL: ufw not enabled: ufw enable"
   echo "$UFW"
   return $CRITICAL
 fi

 # Is default deny incoming set.
 if [[ $(echo $UFW | grep "deny (incoming)") == "" ]]; then
   echo "CRITICAL: ufw incoming not protected: ufw default deny incoming"
   echo 
   echo "$UFW"
   return $CRITICAL
 fi
}

# --------------------------------------------------
# Checks that fail2ban attack security is running and configured.
# --------------------------------------------------
function CheckFail2Ban() {
  IN=$(sudo fail2ban-client status)
  if ! [[ "$IN" = *sshd* ]]; then
    echo "Fail2Ban not running for ssh port"
    return $CRITICAL
  fi
}

# --------------------------------------------------
# Checks if linux is requiring a restart.
# --------------------------------------------------
function CheckRestartRequired() {
  if [ -f /var/run/reboot-required ]; then
    echo 'reboot required'
    return $CRITICAL
  fi
}

# --------------------------------------------------
# Checks if this version of linux is still supported.
# --------------------------------------------------
function CheckDistroEndOfSupport() {
  NAME=$(lsb_release --codename --short)
  STATUS=$(UpdateStatus $OK $?)
  echo "Distro: $NAME"
  EOL=0
  if [[ $NAME == "bullseye" ]]; then
    EOL=$(date -d "30 Jun 2026" +'%s')
  fi
  if [[ $NAME == "bookworm" ]]; then
    EOL=$(date -d "10 Jun 2028" +'%s')
  fi
  if [[ $NAME == "buster" ]]; then
    EOL=$(date -d "30 Jun 2024" +'%s')
  fi
  if [[ $NAME == "jammy" ]]; then
    EOL=$(date -d "01 Apr 2032" +'%s')
  fi
  if [[ $NAME == "focal" ]]; then
    EOL=$(date -d "01 Apr 2030" +'%s')
  fi
  if [[ $NAME == "bionic" ]]; then
    EOL=$(date -d "01 Apr 2028" +'%s')
  fi
  if [[ $NAME == "xenial" ]]; then
    EOL=$(date -d "01 Apr 2026" +'%s')
  fi
  if [[ $NAME == "kenetic" ]]; then
    EOL=$(date -d "01 Jul 2023" +'%s')
  fi
  if [[ $NAME == "lunar" ]]; then
    EOL=$(date -d "01 Jan 2024" +'%s')
  fi
  NOW=$(date +'%s')
  echo "NOW: $NOW"
  echo "EOL: $EOL"

  ((DIFF_DAYS=($EOL-$NOW)/60/60/24))

  echo "EoL in $DIFF_DAYS days."
  if [[ $DIFF_DAYS -le 0 ]]; then
    return $CRITICAL
  fi
  if [[ $DIFF_DAYS -lt 183 ]]; then
    return $WARNING
  fi
}

# --------------------------------------------------
# Checks if the disk internals are showing good health.
# --------------------------------------------------
function CheckSmartCtl() {
if sudo true
then
   true
else
   echo 'Root privileges required'
   return $CRITICAL
fi

for drive in /dev/sd[a-z] /dev/sd[a-z][a-z] /dev/nvme[0-9]n[0-9]
do
   if [[ ! -e $drive ]]; then continue ; fi

   echo -n "$drive "

   smart=$(
      sudo smartctl -H $drive 2>/dev/null |
      grep '^SMART overall\|^SMART Health Status' |
      rev | cut -d ' ' -f1 | rev
   )

   [[ "$smart" == "" ]] && smart='unavailable'

   echo "$smart"

done
}

# --------------------------------------------------
# Simple check for returning statuses easily for testing.
# Usage: CheckTest "Test critical" $CRITICAL
# --------------------------------------------------
function CheckTest() { echo "Dummy Test $1"; return $2; }

# --------------------------------------------------
# Executes the specified arguments for checking health.
#
# Note: This can run functions or shell commands, like nrpe.
# Note: To get debug output: DEBUG=1;Run "name" func; DEBUG=0
# --------------------------------------------------
function Run() {
  PrettyPrintHeader "$1 ..."
  OUTPUT=$(${@:2} 2>&1)
  STATUS=$?
  PrettyPrintStatus $STATUS

  # Make it easy to hide all the details for OK statuses.
  if [[ $STATUS -ne $OK || $DEBUG -eq 1 ]]; then
    PrettyPrint "$OUTPUT"
  fi

}

# --------------------------------------------------
# --------------------------------------------------
#
# Finally actually trigger all the applicable checks
#
# --------------------------------------------------
# --------------------------------------------------

if [[ $(hostname) == "box" ]]; then
  Run "Deluge running" CheckProcessRunning deluged
fi

Run "Check SSH" /etc/init.d/ssh status;
Run "Cpu Utilization" CheckCpuUtilization
Run "Last Update" CheckLastUpdate
Run "Disk Space" CheckDiskSpace
Run "Btrfs" CheckBtrfsHealth
Run "Memory" CheckMemoryFree
Run "Swap" CheckSwapFree
Run "Inode Usage" CheckInodeUsage
Run "Restart required" CheckRestartRequired
Run "Firewall" CheckFirewall 
Run "Fail2Ban" CheckFail2Ban 
Run "CheckDistro End of Life" CheckDistroEndOfSupport
Run "Check Smartctl" CheckSmartCtl
Run "Throughput" CheckNetworkThroughput

# Print the final result of all the calls.
PrettyPrintHeader "\nFinal result ... "
PrettyPrintStatus $FinalStatus
exit $FinalStatus
