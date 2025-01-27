#!/bin/bash

# This script creates a RASPBERRY PI ACCESS POINT
# With user specified settings
clear
# Checks to verify that the script is running as sudo
if [[ $EUID -ne 0 ]]; then
   echo "THIS SCRIPT NEEDS TO BE RUN AS SUDO."
   echo "EX: sudo bash rpi-ap.sh"
   exit 1
fi


echo "

    ____        _       ___                            ____        _       __
   / __ \____  (_)     /   | _____________  __________/ __ \____  (_)___  / /_
  / /_/ / __ \/ /_____/ /| |/ ___/ ___/ _ \/ ___/ ___/ /_/ / __ \/ / __ \/ __/
 / _, _/ /_/ / /_____/ ___ / /__/ /__/  __(__  |__  ) ____/ /_/ / / / / / /_
/_/ |_/ .___/_/     /_/  |_\___/\___/\___/____/____/_/    \____/_/_/ /_/\__/
     /_/
    
    "

echo "+-----------------------------------------------+"
read -p "| What would you like the SSID to be?: " ssid
read -s -p "| What would you like the passphrase to be?: " pass
read -p "| Would you like to have a Web based portal? (y/n): " rpiapcp
read -p "| What channel would you like your network to run on? (ex: 1,6,11): " channel
read -p "| What network card would you like to use? (or press Enter for default: 'wlan0'): " wificard
read -p "| How many user's would you like to be able to join this network? (2-20): " allowed_ips
read -p "| Will this AP be used with a VPN? (Wireguard / OpenVPN) (y/n): " vpn
echo "+-----------------------------------------------+"

# use default value "wlan0" if the user presses Enter without typing anything
if [ -z "$wificard" ]; then
  wificard="wlan0"
fi
# use default value "no" if the user presses Enter without typing anything
if [ -z "$vpn" ]; then
  vpn="no"
fi
# Check if any variable is not answered, then exit the script
if [ -z "$ssid" ] || [ -z "$pass" ] || [ -z "$channel" ] || [ -z "$allowed_ips" ]; then
  echo "+----------------------------------------------------------+"
  echo "|Error: Please provide values for all variables. Exiting...|"
  echo "+----------------------------------------------------------+"
  exit 1
fi

# sets VPN settings based off users vpn cert location
if [ "$vpn" = "yes" ]; then
  echo "+--------------------------------------------------------+"
  read -p "| Please choose one of the following: 
| (1) Wireguard 
| (2) OpenVPN 
: " vpnchoice
  echo ""
  if [ "$vpnchoice" = 1 ]
  then
     vpnconf="/etc/wireguard/wg0.conf"
  elif [ "$vpnchoice" = 2 ]
     read -p "| Please specify full path for your VPN conf file. (ex: /home/user/user.ovpn): " vpnconf
  fi
fi

# Based off user input, the channel specifies the mode
if [[ $channel -ge 1 && $channel -le 11 ]]; then
  mode="g"
elif [[ $channel -ge 36 && $channel -le 196 ]]; then
  mode="a"
else
  echo "+--------------------------------------------------------+"
  echo "| Invalid channel number."
  echo "+--------------------------------------------------------+"
  exit 1
fi

clear
echo "+--------------------------------------------------------+"
echo "| This script is about to apply updates and install the 
| necessary applications to make this machine an access point."
echo "+--------------------------------------------------------+"
echo "| SSID: $ssid"
echo "| Password: $pass"
echo "| Wireless card: $wificard"
echo "| Mode and Channel: $mode $channel"
if [ "$vpn" = "yes" ]; then
  echo "| VPN: $vpnchoice"
  echo "| VPN conf location: $vpnconf"
fi
echo "+------------------------------------------------------------------------+"
echo " "
echo "| To modify Access Point settings, check the '/etc/hostapd/hostapd.conf' |"
echo " "
echo "+------------------------------------------------------------------------+"
read -n 1 -r -s -p $'Press enter to continue if the values above are correct. Otherwise "Ctrl + c" to reenter...\n'


echo "+------------------------------------------------------------------------+"
echo "| APPLYING UPDATES AND INSTALLING NECESSARY APPLICATIONS                 |"
echo "+------------------------------------------------------------------------+"
sleep 1
# Applies update then install required software for the application
apt-get update -y
apt-get install hostapd dnsmasq nmap arp-scan pip -y
pip install flask 
pip3 install flask --break-system-packages
DEBIAN_FRONTEND=noninteractive apt install -y netfilter-persistent iptables-persistent


#  installs and updates depending on choice
if [ "$vpn" = "yes" ]; then
echo "+--------------------------------------------------------+"
echo "| Installing and updating VPN                            |"
echo "+--------------------------------------------------------+"
   if [ "$vpnchoice" = 1 ]
   then   
      apt install wireguard -y && apt update wireguard -y
      ip route add default dev wg0
      echo "@reboot wg-quick up wg0" > /etc/cron.d/cronjob
   elif [ "$vpnchoice" = 2 ]
   then
     apt install openvpn -y && apt update openvpn -y
     ip route add default dev tun0
     echo "@reboot openvpn $vpnconf" > /etc/cron.d/cronjob
   fi
  
fi

# writes settings to /etc/dhcpcd.conf

tee -a /etc/dhcpcd.conf << EOF
interface $wificard
static ip_address=10.10.10.1/24
nohook wpa_supplicant
EOF

# writes routing settings for wireless to eth0

tee -a /etc/sysctl.d/routed-ap.conf << EOF
net.ipv4.ip_forward=1
EOF

# configures iptables to allow NAT
iptables -t nat -A POSTROUTING -o eth0 -j MASQUERADE
mkdir /etc/iptables
iptables-save > /etc/iptables/rpiap-tables

#iptables -t nat -A POSTROUTING -o eth0 -j MASQUERADE
#sh -c "iptables-save > /etc/iptables.ipv4.nat"

# enable IP forwarding on boot
sed -i '/^exit 0/ i iptables-restore < /etc/iptables/rpiap-tables' /etc/rc.local
echo "@reboot /sbin/iptables-restore < /etc/iptables/rpiap-tables" | sudo tee -a /var/spool/cron/crontabs/root > /dev/null

# writes settings to /etc/network/interfaces
tee -a /etc/network/interfaces << EOF
auto lo
iface lo inet loopback

auto eth0
allow-hotplug eth0
iface eth0 inet dhcp

auto $wificard
allow-hotplug $wificard
iface $wificard inet static
address 10.10.10.1
netmask 255.255.255.0
EOF

# writes settings to /etc/dnsmasq.conf

mv /etc/dnsmasq.conf /etc/dnsmasq.conf.old
tee -a /etc/dnsmasq.conf << EOF
interface=$wificard
dhcp-range=10.10.10.2,10.10.10.$allowed_ips,255.255.255.0,24h
domain=wlan
address=/rt.wlan/10.10.10.1
EOF

# Writes configs to "/etc/hostapd/hostapd.conf

tee -a /etc/hostapd/hostapd.conf << EOF
interface=$wificard
ssid=$ssid
hw_mode=$mode
channel=$channel
wmm_enabled=0
macaddr_acl=0
auth_algs=1
ignore_broadcast_ssid=0
wpa=2
wpa_passphrase=$pass
wpa_key_mgmt=WPA-PSK
wpa_pairwise=TKIP
rsn_pairwise=CCMP
EOF

# new settings ###########################
# if any issues, delete between these hashes
# updates hostapd configurations
sed -i 's/#DAEMON_CONF=""/DAEMON_CONF="\/etc\/hostapd\/hostapd.conf"/' /etc/default/hostapd

# enables IP forwarding
sh -c "echo 1 > /proc/sys/net/ipv4/ip_forward"
sed -i 's/#net.ipv4.ip_forward=1/net.ipv4.ip_forward=1/' /etc/sysctl.conf
sysctl -p


##########################################
# Starts required services and then reboots the machine

systemctl start hostapd
systemctl unmask hostapd.service
systemctl enable hostapd
systemctl start dnsmasq
systemctl enable dnsmasq
systemctl enable ssh


# Creating python flask service based off the user who runs this script
# that user will have permissions to modify settings through the webpage
################################################################################
if [ -z "$rpiapcp" ]; then
  rpiapcp="no"
elif [ "$rpiapcp" = "yes" ]; then
   
   echo "+--------------------------------------------------------+"
   echo "| Creating WebApp for RpiAP"
   

   rpiap=$(find / -name "rpiap.py" 2>/dev/null)
   rpidir=$(find / -name "rpiap.py" -exec dirname {} \; 2>/dev/null)


   # Get the username of the current user
   USERNAME=$(whoami)

   # Define the path where the service file will be created
   SERVICE_FILE="/etc/systemd/system/rpiap.service"

   # Create the service file
commos=$(cat << EOF 
[Unit]
Description=RaspberryPi Access Point
After=network.target

[Service]
User=root
Group=root
WorkingDirectory=$rpidir
ExecStart=/usr/bin/python3 $rpiap
Restart=always

[Install]
WantedBy=multi-user.target
EOF
)

echo $commos > "$SERVICE_FILE"

   # Reload systemd to pick up the changes
   systemctl daemon-reload
   systemctl enable rpiap.service

   echo "| Service file created at: $SERVICE_FILE"

   
   # After everythings done running, the PI will reboot
   echo ""
   echo "+-----------------------------------------------------------------------------------+"
   echo ""
   echo "| Once you're connected to '$ssid', Please open a Web-Browser and go to '10.10.10.1'"
   echo ""
   read -n 1 -r -s -p $'Press enter to reboot.\n'
   echo "+-----------------------------------------------------------------------------------+"
   reboot

   else
   echo "+-----------------------------------------------------------------------------------+"
   echo "| INVALID INPUT for WebApp"
   fi




# After everythings done running, the PI will reboot
echo "+-----------------------------------------------------------------------------------+"
echo ""
read -n 1 -r -s -p $'Press enter to reboot.\n'
echo ""
reboot
