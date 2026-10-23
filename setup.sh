#!/bin/bash

#
# ‼️ SECURITY NOTES FOR MAINTAINERS:
#
# This app uses a visudo configuration that allows a background script running as
# an unprivileged user to execute battery management commands without requiring a
# user password. This requires careful installation and design to avoid potential
# privilege-escalation vulnerabilities.
#
# Rule of thumb:
# - Unprivileged users must not be able to modify, replace, or inject any code
#   that can be executed with root privileges.
#
# For this reason:
# - All battery-related binaries and scripts that can be executed via sudo,
#   including those that prompt for a user password, must be owned by root.
# - They must not be writable by group or others.
# - Their parent directories must also be owned by root and not be writable by
#   unprivileged users, to prevent the replacement of executables.
#

# Reset PATH to minimal safe defaults
PATH=/usr/bin:/bin:/usr/sbin:/sbin
set -e
set -o pipefail

# Resolve the project directory from this script's location, not the caller's cwd.
script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
local_mode=false
if [[ "$1" == "--local" ]]; then
	local_mode=true
	shift
fi
if [[ "$#" -gt 1 ]]; then
	echo "Usage: $0 [--local] [username]"
	exit 1
fi

# User welcome message
echo -e "\n####################################################################"
echo '# 👋 Welcome, this is the setup script for the battery CLI tool.'
echo -e "# Note: this script may ask for your password."
echo -e "####################################################################\n\n"

# Determine unprivileged user name
if [[ -n "$1" ]]; then
	calling_user="$1"
else
	if [[ -n "$SUDO_USER" ]]; then
		calling_user=$SUDO_USER
	else
		calling_user=$USER
	fi
fi
if [[ "$calling_user" == "root" ]]; then
	echo "❌ Failed to determine unprivileged username"
	exit 1
fi

# Set variables
binfolder=/usr/local/co.palokaj.battery
configfolder=/Users/$calling_user/.battery
pidfile=$configfolder/battery.pid
logfile=$configfolder/battery.log
launch_agent_plist=/Users/$calling_user/Library/LaunchAgents/battery.plist
path_configfile=/etc/paths.d/50-battery
native_label=co.palokaj.battery.charge-control
native_plist=/Library/LaunchDaemons/$native_label.plist
native_log=/var/log/batterykeeper-charge-control.log
install_native=false
if [[ "$(uname -s)" == Darwin ]]; then
	macos_version="$(sw_vers -productVersion)"
	if [[ "${macos_version%%.*}" -ge 27 ]]; then
		install_native=true
	fi
fi

# Ask for sudo once, in most systems this will cache the permissions for a bit
sudo echo "🔋 Starting battery installation"
echo "[  1 ] Superuser permissions acquired."

echo "[  2 ] Allocate temp folder"
tempfolder="$(mktemp -d)"
function cleanup() { rm -rf "$tempfolder"; }
trap cleanup EXIT

if [[ "$local_mode" == true ]]; then
	echo "[  3 ] Using local project source: $script_dir"
	batteryfolder="$script_dir"
	if [[ ! -f "$batteryfolder/battery.sh" || ! -f "$batteryfolder/dist/smc" ]]; then
		echo "❌ Local source is missing battery.sh or dist/smc"
		exit 1
	fi
else
	echo "[  3 ] Downloading latest version of battery CLI"
	# Note: github names zips by <reponame>-<branchname>.replace( '/', '-' )
	update_branch="main"
	in_zip_folder_name="battery-$update_branch"
	batteryfolder="$tempfolder/battery"
	rm -rf "$batteryfolder"
	mkdir -p "$batteryfolder"
	# The progress meter is not decoration. This archive is ~2.3 MB and on a
	# slow link it arrives at a crawl — measured at roughly 25 KB/s from a
	# mainland China connection, which puts the transfer past 90 seconds
	# before it finishes. -s took the meter with it, so a download that was
	# working perfectly looked exactly like a hang.
	#
	# The timeouts are the other half, and they exist to stop the opposite
	# failure: a route that black-holes the connection would otherwise wait
	# forever. Both sit well above what a healthy but slow transfer needs —
	# the TLS handshake alone took 11 seconds here — since a timeout that
	# fires on a download about to succeed is worse than no timeout at all.
	#
	# --fail covers a third: a 404 would otherwise be saved as repo.zip and
	# blow up later in unzip with no hint as to why.
	if ! curl -L --fail --connect-timeout 30 --max-time 300 \
		-o "$batteryfolder/repo.zip" \
		"https://github.com/actuallymentor/battery/archive/refs/heads/$update_branch.zip"; then
		echo "❌ Download failed."
		echo "   If GitHub is slow or unreachable from this network, install from this"
		echo "   checkout instead — it needs no network at all:"
		echo "     $script_dir/setup.sh --local"
		exit 1
	fi
	unzip -qq "$batteryfolder/repo.zip" -d "$batteryfolder"
	cp -r "$batteryfolder/$in_zip_folder_name"/* "$batteryfolder"
	rm "$batteryfolder/repo.zip"
fi

if [[ "$install_native" == true ]]; then
	# Build before touching the working installation. Old upstream archives do
	# not contain this backend; never fetch an unrelated executable as a fallback.
	if [[ ! -f "$batteryfolder/native/build.sh" || ! -f "$batteryfolder/native/$native_label.plist" ]]; then
		echo "❌ macOS 27 requires the native charging backend, which this source does not contain."
		echo "   Install from the complete BatteryKeeper checkout with: $script_dir/setup.sh --local"
		exit 1
	fi
	echo "[  3 ] Build the native charging backend"
	if [[ "$local_mode" == true && $EUID -eq 0 ]]; then
		sudo -u "$calling_user" bash "$batteryfolder/native/build.sh"
	else
		bash "$batteryfolder/native/build.sh"
	fi
	if [[ ! -x "$batteryfolder/native/build/charge-control" ]]; then
		echo "❌ Native charging backend build did not produce an executable."
		exit 1
	fi
	plutil -lint "$batteryfolder/native/$native_label.plist"
	if [[ -L "$native_log" ]]; then
		echo "❌ Refusing to use a symlink for the privileged charging log: $native_log"
		exit 1
	fi
	if [[ -x "$binfolder/charge-control" ]]; then
		# reset is synchronous and uses the old daemon; it must finish before bootout.
		echo "[  3 ] Restore charging policies before replacing the native backend"
		sudo "$binfolder/charge-control" reset
	fi
	if sudo launchctl print "system/$native_label" >/dev/null 2>&1; then
		if [[ ! -x "$binfolder/charge-control" ]]; then
			echo "❌ The existing charging daemon has no reset executable; repair it before updating."
			exit 1
		fi
		sudo launchctl bootout "system/$native_label"
	fi
fi

# Cleanup after versions 1_3_2 and below, once source validation has succeeded.
sudo rm -f /usr/local/bin/battery
sudo rm -f /usr/local/bin/smc

echo "[  4 ] Make sure $binfolder is recreated and owned by root"
sudo rm -rf "$binfolder" # start with an empty $binfolder and ensure there is no symlink or file at the path
sudo install -d -m 755 -o root -g wheel "$binfolder"

echo "[  5 ] Install prebuilt smc binary into $binfolder"
sudo install -m 755 -o root -g wheel "$batteryfolder/dist/smc" "$binfolder/smc"

echo "[  6 ] Install battery script into $binfolder"
sudo install -m 755 -o root -g wheel "$batteryfolder/battery.sh" "$binfolder/battery"
if [[ "$install_native" == true ]]; then
	sudo install -m 755 -o root -g wheel "$batteryfolder/native/build/charge-control" "$binfolder/charge-control"
	sudo install -m 644 -o root -g wheel "$batteryfolder/native/$native_label.plist" "$native_plist"
	sudo touch "$native_log"
	sudo chown root:wheel "$native_log"
	sudo chmod 644 "$native_log"
fi

echo "[  7 ] Make sure the PATH environment variable includes '$binfolder'"
if ! grep -qF "$binfolder" $path_configfile 2>/dev/null; then
	printf '%s\n' "$binfolder" | sudo tee "$path_configfile" >/dev/null
fi
sudo chown -h root:wheel $path_configfile
sudo chmod -h 644 $path_configfile
# Create a symlink for rare shells that do not initialize PATH from /etc/paths.d (including the current one)
sudo mkdir -p /usr/local/bin
sudo ln -sf "$binfolder/battery" /usr/local/bin/battery
sudo chown -h root:wheel /usr/local/bin/battery
# Create a link to smc as well to silence older GUI apps running with updated background executables
# (consider removing in the next releases)
sudo ln -sf "$binfolder/smc" /usr/local/bin/smc
sudo chown -h root:wheel /usr/local/bin/smc

echo "[  8 ] Set ownership and permissions for $configfolder"
mkdir -p $configfolder
sudo chown -hRP $calling_user $configfolder
sudo chmod -h 755 $configfolder

touch $logfile
sudo chown -h $calling_user $logfile
sudo chmod -h 644 $logfile

touch $pidfile
sudo chown -h $calling_user $pidfile
sudo chmod -h 644 $pidfile

# Fix permissions for 'create_daemon' action
echo "[  9 ] Fix ownership and permissions for $(dirname "$launch_agent_plist")"
mkdir -p "$(dirname "$launch_agent_plist")"
sudo chown -h $calling_user "$(dirname "$launch_agent_plist")"
sudo chmod -h 755 "$(dirname "$launch_agent_plist")"
if [[ -e "$launch_agent_plist" ]]; then
	sudo chown -h "$calling_user" "$launch_agent_plist"
fi

echo "[ 10 ] Setup visudo configuration"
sudo $binfolder/battery visudo

if [[ "$install_native" == true ]]; then
	echo "[ 10 ] Start the native charging daemon"
	sudo launchctl bootstrap system "$native_plist"
	sudo launchctl print "system/$native_label" >/dev/null
	native_ready=false
	for attempt in {1..10}; do
		if sudo "$binfolder/charge-control" status >/dev/null 2>&1; then
			native_ready=true
			break
		fi
		sleep 0.5
	done
	if [[ "$native_ready" != true ]]; then
		echo "❌ Native charging daemon did not become ready. See $native_log"
		exit 1
	fi
fi

echo "[ 11 ] Remove temp folder $tempfolder"
rm -rf $tempfolder

echo -e "\n🎉 Battery tool installed. Type \"battery help\" for instructions.\n"

exit 0
