# system setup scripts

These automation scripts are for my own homelab environment. Feel free to use them, although most of them are for specific use cases.

Ubuntu:

configure_server.sh : This script generates and updates locale and timezone settings. Installs chrony and syncs to timeserver. Installs auditd and sysmon with custom rules.

install_elastic_agent.sh : Installs Elastic Agent with fleet server configuration. Can input elastic sever address and enrollment token.