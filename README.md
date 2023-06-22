# healthcheck
This is a very simple and easy to maintain Bash script that prints health check statuses about the host machine in a very pretty print way. Command output is only printed if the status is not OK to avoid unnecessary logging.

The purpose of this script is to have a nice way to periodically check on the health of your machine. Having something go wrong with your machine (Ubuntu or Debian desktop or server) and not be aware of this is painful. Nagios with nrpe is one way to cover your bases, but this is the most simple way that I find super reliable and easy to set up. Checking the return code of the script can also be used by borgcron to email messages to you.

This script is designed to be very fast to learn and read, and add your own checks either by calling other scripts or adding another function check in the file.

![Run Screenshot](https://github.com/ccasper/healthcheck/blob/52df49c8c09ce2f8b90fd0d86f03aef467e2893a/images/run_screenshot.png?raw=true
)

The core of the script is one main function that calls 3 simple helpers for readability:

- function **Run()**
  - ```Run "<display name>" <command with args to call>```
  - This calls PrettyPrintHeader to print the ```<display name>```
  - Then it calls PrettyPrintStatus to execute ```<command with args to call>``` and prints the [OK|WARNING|CRITICAL] status at the end of the line
  - Then it calls PrettyPrint with the command stderr and stdout combined if there was a problem.
    - For debugging, setting the variable DEBUG=1 before calling Run will print the output regardless of the problem.
      - Working Example: ```DEBUG=1; Run "Check SSH" /etc/init.d/ssh status; DEBUG=0```
   
Everything else in the file is mostly stand alone check functions that can be easily split out into new bash scripts or more added to the file.
