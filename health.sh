#!/bin/bash
# Easy to use script to do a pretty print compilation of checks on a running linux machine.
# Author: Cory Casper

HR="--------------------------------------------------------------------------"

# *------ Nice to have general operating system info. ------*
echo $HR
HOSTNAME=$(hostname -f &> /dev/null && echo $(hostname -f) || echo $(hostname -s))
echo "Hostname : $HOSTNAME"
echo -n "Operating System : "
[ -f /etc/os-release ] && echo $(egrep -w "NAME|VERSION" /etc/os-release|awk -F= '{ print $2 }'|sed 's/"//g') || cat /etc/system-release
echo "Kernel Version :" $(uname -r)
echo -n "OS Architecture : " $(arch | grep x86_64 &> /dev/null) && echo "64 Bit OS"  || echo "32 Bit OS"
IP=$( ( ip route get 8.8.8.8 2> /dev/null ) | sed -n '/src/{s/.*src *\([^ ]*\).*/\1/p;q}')
echo "IP : $IP"
echo $HR

# Track the final result of all the checks.
FinalStatus=0

# *------ Status codes ------*
OK=0
CRITICAL=1
WARNING=254


# --------------------------------------------------
# Returns the value that should be set in the status tracking field.
#
# Example Usage:
#   STATUS=$(UpdateStatus $STATUS $?)
#   FinalStatus=$(UpdateStatus $FinalStatus $?)
# --------------------------------------------------
function UpdateStatus() {
  # If the saved status is critical, keep it critical.
  if [[ $1 -eq $CRITICAL || $2 -eq $CRITICAL ]]; then
    echo $CRITICAL; return 0
  fi
  # If the new status is not OK or WARNING, set it critical.
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
  STATUS=$OK
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
# Checks the Network Connectivity.
# --------------------------------------------------
function CheckNetworkConnectivity() {
  IP=$(ip route get 8.8.8.8)
  if [[ $? -ne 0 ]]; then
    return $CRITICAL;
  fi
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
# Checks to see if any disks are mounted read only which can indicate mounting problems.
# --------------------------------------------------
function CheckForReadOnlyDisks() {
  STATUS=$OK
  MOUNT=$(mount|egrep -iw "ext4|ext3|xfs|gfs|gfs2|btrfs" | egrep -iv "snap|loop" | sed 's/ /,/')

  echo "Checking for read-only disks"
  if ( echo $MOUNT | sed 's/remount-ro//g'|grep -w ro ); then
    echo "$MOUNT ... read only disk found"
    STATUS=$CRITICAL
  else 
    echo "... no read-only disks found. " 
  fi
  return $STATUS
}

function CheckDiskSpace() {
  STATUS=$OK

  # Get the disks one per line.
  DISK_INFO=$(df -PThl -x fuse -x iso9660 -x devtmpfs -x squashfs|tail -n +2)
  # Change to split by comma and sort by highest fullness first.
  DISK_INFO=$(echo "$DISK_USAGE" | tr -s ' ' ',' | sort -t',' -k6nr)

  # Print the header.
  echo "Checking disk usage on mounted disks"
  echo "$HR"
  INFO=$(echo $item | awk -F',' '{printf "%-20s %-30s %-10s \n", "Mount", "Device" , "Fullness"}')
  echo "$INFO Status"
  echo "$HR"

  for item in ${DISK_USAGE// /}; do {
    STATE="(??)"
    # Get the fullness from the csv line and remove the '%'.
    FULLNESS=$(echo $item | awk -F',' '{print $6}' | sed 's/%//')

    if [[ $FULLNESS -ge 95 ]]; then
      STATE="CRITICAL"
      STATUS=$(UpdateStatus $STATUS $CRITICAL)
      continue
    elif [[ $FULLNESS -gt 90 ]]; then
      STATE="WARNING"
      STATUS=$(UpdateStatus $STATUS $WARNING)
      continue
    else
      STATE="OK"
    fi

    INFO=$(echo $item | awk -F',' '{printf "%-20s %-30s %-10s \n", $7, $1, $6}')
    echo "$INFO $STATE"
  } done

  echo -e "$HR"
  return $STATUS
}

# --------------------------------------------------
# Checks the inode usage.
# --------------------------------------------------
function CheckInodeUsage() {
  STATUS=$OK
  # Get the disks one per line.
  INODE_INFO=$(df -iPThl -x overlay -x vfat -x btrfs -x fuse -x tmpfs -x iso9660 -x devtmpfs -x squashfs|tail -n +2)
  # Change to split by comma and sort by highest fullness first.
  INODE_INFO=$(echo "$INODE_INFO" | tr -s ' ' ',' | sort -t',' -k6nr)

  # Print the header.
  echo "Checking inode usage on mounted disks"
  echo "$HR"
  INFO=$(echo $item | awk -F',' '{printf "%-20s %-30s %-10s \n", "Mount", "Device" , "Fullness"}')
  echo "$INFO Status"
  echo "$HR"

  for item in ${INODE_INFO// /}; do {
    STATE="(??)"
    # Get the fullness from the csv line and remove the '%'.
    FULLNESS=$(echo $item | awk -F',' '{print $6}' | sed 's/%//')

    if [[ $FULLNESS -ge 95 ]]; then
      STATE="CRITICAL"
      STATUS=$(UpdateStatus $STATUS $CRITICAL)
      continue
    elif [[ $FULLNESS -gt 90 ]]; then
      STATE="WARNING"
      STATUS=$(UpdateStatus $STATUS $WARNING)
      continue
    else
      STATE="OK"
    fi

    INFO=$(echo $item | awk -F',' '{printf "%-20s %-30s %-10s \n", $7, $1, $6}')
    echo "$INFO $STATE"
  } done

  echo -e "$HR"
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
 BASEIP=`echo $IP | cut -d"." -f1-3`

 echo " ufw allow from $BASEIP.0/24"
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
# Checks if the hard drive host is seeing errors on i
# SATA SError expansion
# If any bits in the SATA SError register are set, the SError register contents will be expanded into its component bits, for example:

# SError: { PHYRdyChg CommWake }

# These bits are set by the SATA host interface in response to error conditions
# on the SATA link. Unless a drive hotplug or unplug operation occurred, it is
# generally not normal to see any of these bits set. If they are, it usually
# points strongly toward a hardware problem (often a bad SATA cable or a bad or
# inadequate power supply).
# --------------------------------------------------
function CheckSataHostInterface() {
  STATUS=$OK
  IN=$(dmesg |grep SError)
  if [[ $IN != "" ]]; then
    echo "SATA host link showing errors, likely due to a bad SATA cable or attachment"
    STATUS=$WARNING
    echo $HR
    echo "Host ada adapter to device mapping:"
    echo $HR
  #INODE_INFO=$(echo "$INODE_INFO" | tr -s ' ' ',' | sort -t',' -k6nr)
    OUT=$(find -L /sys/bus/pci/devices/*/ata*/host*/target* -maxdepth 3 -name "sd*" 2>/dev/null | egrep block |egrep --colour '(ata[0-9]*)|(sd.*)') # | tr -s ' ' ',')
    echo $OUT
  fi
  echo $HR
  echo $IN
  return $STATUS
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
  # Print the check name.
  PrettyPrintHeader "$1 ..."

  # Run the command and capture stdout and stderr.
  OUTPUT=$(${@:2} 2>&1)
  STATUS=$?

  # Print the resulting status.
  PrettyPrintStatus $STATUS

  # Only print the output logs for debugging/problem statuses.
  if [[ $STATUS -ne $OK || $DEBUG -eq 1 ]]; then
    # Print the output logs.
    PrettyPrint "$OUTPUT"
  fi

}

# --------------------------------------------------
# --------------------------------------------------
#
# Actually use the methods above to run the checks
#
# --------------------------------------------------
# --------------------------------------------------

Run "Check Sata Host Interface" CheckSataHostInterface
Run "Network Connection" CheckNetworkConnectivity
Run "Read Only Disks" CheckForReadOnlyDisks
Run "Disk Space" CheckDiskSpace
Run "Inode Usage" CheckInodeUsage

# Sometimes you may want to limit checks to certain hosts.
if [[ $HOSTNAME == "box" ]]; then
  Run "Deluge running" CheckProcessRunning deluged
fi

Run "Check SSH" /etc/init.d/ssh status;
Run "Cpu Utilization" CheckCpuUtilization
Run "Last Update" CheckLastUpdate
Run "Btrfs" CheckBtrfsHealth
Run "Memory" CheckMemoryFree
Run "Swap" CheckSwapFree
Run "Restart required" CheckRestartRequired
Run "CheckDistro End of Life" CheckDistroEndOfSupport
Run "Throughput" CheckNetworkThroughput
Run "Check Smartctl" CheckSmartCtl
Run "Firewall" CheckFirewall
Run "Fail2Ban" CheckFail2Ban 

# Print the final result of all the calls.
PrettyPrintHeader "\nFinal result ... "
PrettyPrintStatus $FinalStatus

exit $FinalStatus
