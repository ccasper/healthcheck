# healthcheck
This is a very simple and easy to maintain Bash script that prints health check statuses about the host machine in a very pretty print way. Command output is only printed if the status is not OK to avoid unnecessary logging.

The purpose of this script is to have a nice way to periodically check on the health of your machine. Having something go wrong with your machine (Ubuntu or Debian desktop or server) and not be aware of this is painful. Nagios with nrpe is one way to cover your bases, but this is the most simple way that I find super reliable and easy to set up. Checking the return code of the script can also be used by borgcron to email messages to you.

This script is designed to be very fast to learn and read, and add your own checks either by calling other scripts or adding another function check in the file.

![Run Screenshot](https://github.com/ccasper/healthcheck/blob/52df49c8c09ce2f8b90fd0d86f03aef467e2893a/images/run_screenshot.png?raw=true
)

By default, this does require sudo permission, but you can change/remove check cases that need sudo privilege if this is undesired. This checks a wide range of aspects of your machine:
- CPU utilization
- last package update
- disk space
- Btrfs health
- memory/RAM usage
- swap usage
- inode usage
- restart required state
- firewall state (currently expects ufw)
- fail2ban (which also ensures SSH is in fail2ban rules)
- Distribution at end of life (currently covers Ubuntu/Debian, but can easily be extended to any distro)
- Network throughput is <4 MiB/s
- SmartCtl (hard drive firmware smart health)
- Check that a process is running using ```Run "Checking for process <name>" CheckProcessRunning <name_of_process>```
- _And more to add or come ... feel free to contribute!_

## Script Design

The core of the script is one main function that calls 3 simple helpers for readability:

- function **Run()**
  - ```Run "<display name>" <command with args to call>```
  - This calls PrettyPrintHeader to print the ```<display name>```
  - Then it calls PrettyPrintStatus to execute ```<command with args to call>``` and prints the [OK|WARNING|CRITICAL] status at the end of the line
  - Then it calls PrettyPrint with the command stderr and stdout combined if there was a problem.
    - For debugging, setting the variable DEBUG=1 before calling Run will print the output regardless of the problem.
      - Working Example: ```DEBUG=1; Run "Check SSH" /etc/init.d/ssh status; DEBUG=0```
   
Everything else in the file is mostly stand alone check functions that can be easily split out into new bash scripts or more added to the file.

### UpdateStatus

This is a very simple method designed to latch on to the worst case status.

For example, if you previously saw CRITICAL in your check, and you're still going through different iterations of devices and the latest device was OK, you want to maintain the status of CRITICAL for the individual check. This is also used to maintain the final status of the script based on all the checks that were run. This behavior is done like this:

```STATUS=$(UpdateStatus <current latched status ... usually $STATUS> <new status from command ... usually $?>)```

Examples will make this more clear hopefully:
 - STATUS=$WARNING when calling STATUS=$(UpdateStatus $WARNING $OK)
 - STATUS=$CRITICAL when calling STATUS=$(UpdateStatus $OK $CRITICAL)
 - STATUS=$CRITICAL when calling STATUS=$(UpdateStatus $WARNING $CRITICAL)
 - STATUS=$OK when calling STATUS=$(UpdateStatus $OK $OK)
   
