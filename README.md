# vmware-autoscale

This repository contains a Powershell script to automatically scale up or down the Infoblox grid, hosted on a VMWare environment based on DNS queries per second.

## Prerequisites

Ensure you have the following components in your environment:

 - Windows Powershell
 -  Powershell SNMP module
 - VMWare PowerCLI module for Powershell
 - ovftool
 - Connectivity to both, the vCenter Server and Infoblox Grid

Ensure the following configurations are enabled on the Infoblox grid
 - SNMP configuration
 - A reserved range defined within a subnet, from which IP addresses can be automatically assigned to the scaled-up members

Ensure that you modify the variables above which the comment "NEEDS TO BE MODIFIED WITH VALUES SPECIFIC TO YOUR ENVIRONMENT" is added, such as:

 - $vmfolder: Location in the vCenter Server where the new Virtual Machine needs to be created
 - $datastore: The datastore the VM will reside on. You can run Get-Datastore command to get a list of all the datastores in your environment
 - $dportgroup: The Distributed port group that the VM will be connected to. You can run Get-VDPortgroup to get a list of all the distirbuted port groups in your environment
 - $range: The range within which the next available IP address can be found to assign to a new member
 - $memberip: The gateway and subnet mask need to be changed
 - $gridjoindetails: This is the details of the existing grid that the new member needs to join
 - $nsname: The nameserver group that the new member will be added to.

## Inputs to be given to the script

 - The IP address of the grid master
 - The username and password that can be used to make WAPI calls to the grid master.
 - The IP address of the grid member whose DNS QPS you want to monitor
 - The SNMP community string that the script can use to get the data from the grid
 - The polling interval, that is the time interval at which the QPS is monitored
 - The scale-up limit, that is the threshold after which a new member will be spun up
 - The time interval during which the QPS is additionally monitored after the scale-up limit has reached, in order to ensure that this was not just a momentary spike.
 - The maximum number of members that can be automatically created while scaling up, beyond which even if the scale-up threshold is crossed, new members won't be spun up.
 - The scale-down limit, that is the threshold below which the most recently scaled up member will be deleted
 - The time interval during which the QPS in additionally monitored after the scale-down limit has reached, in order to ensure that this was not a momentary slow down.
 - The OVA file based off of which a new member will be spun up (any non-DDI image)
 - The vCenter Server IP address or FQDN
 - The username and password to access the vCenter Server

```
