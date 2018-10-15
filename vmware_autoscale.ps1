###############################################################
#      The author of this script is Krishna Vasudevan         #
#  For any queries, shoot an email to kvasudevan@infoblox.com #
#           Copyright 2018 Krishna Vasudevan                  #
###############################################################

### The below function ignores self signed certificates. This is used while making the Infoblox WAPI calls ###
function Ignore-SelfSignedCerts
{
    try
   {
        #Write-Host "Adding TrustAllCertsPolicy type." -ForegroundColor White
        Add-Type -TypeDefinition  @"
        using System.Net;
        using System.Security.Cryptography.X509Certificates;
        public class TrustAllCertsPolicy : ICertificatePolicy
        {
             public bool CheckValidationResult(
             ServicePoint srvPoint, X509Certificate certificate,
             WebRequest request, int certificateProblem)
             {
                 return true;
            }
        }
"@
        #Write-Host "TrustAllCertsPolicy type added." -ForegroundColor White
      }
    catch
    {
        Write-Host $_ -ForegroundColor "Yellow"
    }
    [System.Net.ServicePointManager]::CertificatePolicy = New-Object TrustAllCertsPolicy
}

### The below function creates a random string with 5 characters (numbers/lowercase alphabets). This is appended to the name of the newly spun up grid member ###
function RandomStringGenerator
{
    return -join ((48..57) + (97..122) | Get-Random -Count 5 | % {[char]$_})
}

### This section takes in parameters required for the scripts ###
Write-Host "********** Grid details **********" -ForegroundColor Blue
$gridmaster = Read-Host "Grid Master IP address"
$gusername = Read-Host "Username for Grid Master"
$gpassword = Read-Host "Password for Grid Master" -AsSecureString
$dnsmember = Read-Host "IP address of the grid member you want to monitor"

Write-Host "********** Scaling details **********" -ForegroundColor Blue
$snmpstring = Read-Host "SNMP community string"
$frequency = Read-Host "Polling interval (in seconds)"
[int] $upthreshold = Read-Host "Scale-up limit for DNS QPS"
$upeval = Read-Host "Time interval (in seconds) to monitor DNS QPS before scaling up after threshold trigger"
$maxscaleup = Read-Host "Enter the maximum number of members that can be created while scaling up"
[int] $downthreshold = Read-Host "Scale-down limit for DNS QPS"
$downeval = Read-Host "Time interval (in seconds) to monitor DNS QPS before scaling down after threshold trigger"

Write-Host "********** vCenter details **********" -ForegroundColor Blue
$ova = Read-Host "The location of the OVA file to spin up new grid member from"
$vcenter = Read-Host "vCenter Server IP address/FQDN"
$vusername = Read-Host "Username for vCenter Server"
$vpasswordsecure = Read-Host "Password for vCenter Server" -AsSecureString

### This section connects to the vCenter server with the credentials provided above ###
$vcreds = New-Object -typename System.Management.Automation.PSCredential -argumentlist $vusername, $vpasswordsecure
$BSTR = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($vpasswordsecure)            
$vpassword = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto($BSTR)
Write-Host "[INFO] Connecting to $vcenter as $vusername" -ForegroundColor yellow

if ((Connect-VIServer $vcenter -Credential $vcreds).IsConnected)
{
    Write-Host "[INFO] Connected to $vcenter" -ForegroundColor Green

    ### This section checks if SNMP polling is working ###
    try 
    {
       $testsnmp = (Get-SnmpData -IP $dnsmember -Community $snmpstring -OID 1.3.6.1.4.1.7779.3.1.1.3.1.6.0 -Version V2 -WarningAction SilentlyContinue -WarningVariable warnsnmp).Data
       if ($warnsnmp)
       {
           throw "[ERROR] Cannot proceed. Unable to query SNMP! $warnsnmp"
       }
    }
    catch 
    {
       Write-Host $_ -ForegroundColor Red
    }

    if(!$warnsnmp)
    {
        Write-Host "[INFO] If the DNS QPS of $dnsmember is consistently above $upthreshold for a period of $upeval seconds, a new member will be spun up from $ova. A maximum of $maxscaleup member(s) will be spun up." -ForegroundColor yellow
        Write-Host "[INFO] If the DNS QPS of $dnsmember is consistently below $downthreshold for a period of $downeval seconds, the latest scaled up member will be deleted" -ForegroundColor Yellow

        ### This section inspects the gird environment in order to keep track of the exisiting environment that you are beginning with. This is to ensure the script does not scale down beyond the original environment. ###
        Ignore-SelfSignedCerts 
        $gmcreds = New-Object Management.Automation.PSCredential ($gusername,$gpassword)
        $members = (Invoke-WebRequest -Uri "https://$gridmaster/wapi/v2.7/member" -Method GET -Credential $gmcreds).Content | ConvertFrom-Json
        foreach ($member in $members)
        {
            [System.Collections.ArrayList]$memberlist += @($($member.host_name))
        }
        $numofmemberlist = $members.Count
    
        $scaleup = 0 ### Keeps track of number of members created during scale-up ###
        $scale=0
        $count = 0
        while($scale -eq 0)
        {
            ### Get the DNS queries per second of the member ($dnsmember) specified using the SNMP powershell module ###
	    [int] $dnsqps = (Get-SnmpData -IP $dnsmember -Community $snmpstring -OID 1.3.6.1.4.1.7779.3.1.1.3.1.6.0 -Version V2).Data
            Write-Host "[INFO] DNS QPS: $dnsqps; Scale-up threshold: $upthreshold; Scale-down threshold: $downthreshold" -ForegroundColor green

            ### The following section is executed if the DNS QPS exceeds the specified scale up threshold ($upthreshold) ###
	    if($dnsqps -gt $upthreshold)
	    {
                $members = (Invoke-WebRequest -Uri "https://$gridmaster/wapi/v2.7/member" -Method GET -Credential $gmcreds).Content | ConvertFrom-Json

                ### This condition ensures that the script does not scale up beyond the number of members specified as the $maxscaleup value. It compares the current number of scaled-up members and the scale up limit. ###
                if($scaleup -lt $maxscaleup)
                {
		            Write-Host "[WARNING] DNS QPS ($dnsqps) has crossed the threshold $upthreshold" -ForegroundColor red

                    ### The following section monitors the DNS QPS for a specified period of time ($upeval) to ensure that it is not just a temporary spike ###            
                    Write-Host "[INFO] Monitoring the DNS QPS for $upeval seconds to ensure this is not a temporary spike" -ForegroundColor Yellow
                    $pollcount = 0
                    $currenttime = Get-Date
                    $dnsqpspoll = 0
                    while ((Get-Date) -lt $currenttime.AddSeconds($upeval))
                    {
                        $pollcount ++
                        $currentdnsqps = (Get-SnmpData -IP $dnsmember -Community $snmpstring -OID 1.3.6.1.4.1.7779.3.1.1.3.1.6.0 -Version V2).Data
                        $dnsqpspoll += $currentdnsqps
                        Write-Host "[INFO] DNS QPS in the polling period: $currentdnsqps" -ForegroundColor Green
                        sleep 10
                    }
                    $dnsqpsavg = [math]::Round($dnsqpspoll/$pollcount)
                    Write-Host "[INFO] The average DNS QPS during the polling period was $dnsqpsavg" -ForegroundColor Yellow

                    ### The following section is executed if the average of the DNS QPS during the evaluation period exceeds the specified scale up threshold ($upthreshold) ###
                    if ($dnsqpsavg -gt $upthreshold)
                    {
                        Write-Host "[INFO] Scaling up" -ForegroundColor Yellow

                        ### This section specifies all the required details to spin up a new VM ###
                        ### Location in the vCenter Server where the new Virtual Machine needs to be created ###
                        ### NEEDS TO BE MODFIED WITH VALUES SPECIFIC TO YOUR ENVIRONMENT ###
                        $vmfolder = $vcenter+"\India\host\Compute\Resources\Autoscale-Testing-Krishna" 
		        $vmlocation = "vi://"+$vusername+":"+$vpassword+"@"+$vmfolder
                        ### The datastore the VM will reside on. You can run Get-Datastore command to get a list of all the datastores in your environment ###                
                        ### NEEDS TO BE MODFIED WITH VALUES SPECIFIC TO YOUR ENVIRONMENT ###
                        $datastore = "DS-ESX1-11B" 
                        ### the Distributed port group that the VM will be connected to. You can run Get-VDPortgroup to get a list of all the distirbuted port groups in your environment ###
                        ### NEEDS TO BE MODFIED WITH VALUES SPECIFIC TO YOUR ENVIRONMENT ###
                        $dportgroup = "Mgmt-Autoscale-Testing-Krishna"
                        ### Details of the member: name, IP address and the licenses that will be applied during cloud-init ###                                
                        ### Find the next available IP address within a range in the specified subnet ###
                        ### NEEDS TO BE MODFIED WITH VALUES SPECIFIC TO YOUR ENVIRONMENT ###
                        $range = @(@{method="GET"
                                   object="range"
                                   data=@{network="10.196.202.0/24"}
                                   assign_state=@{netw_ref="_ref"}
                                   discard=$true},
                                   @{method="POST"
                                   object="##STATE:netw_ref:##"
                                   args=@{_function="next_available_ip"}
                                   enable_substitution=$true}) |ConvertTo-json
                        $availableip = ((Invoke-WebRequest -Uri "https://$gridmaster/wapi/v2.7/request" -Method POST -Credential $gmcreds -ContentType 'application/json' -Body $range).Content |ConvertFrom-Json).ips
                
                        ### Random string to append to the name of the new member ###
                        $random = RandomStringGenerator 
                        ### NEEDS TO BE MODFIED WITH VALUES SPECIFIC TO YOUR ENVIRONMENT ###
                        $memberip = @{"address"=$availableip;"gateway"="10.196.202.1";"netmask"="255.255.255.0"}
                        $membername = "autojoin-"+$random+".autoscale.com"
                        $licenses = "enterprise,dns,dhcp,vnios"

		        ### This section uses the ovf tool to spin up a new VM and initializes the IP address and licenses using cloud-init (specified in the prop fields)###
                        Write-Host "[INFO] Spinning up a member $membername in $vmfolder" -ForegroundColor yellow
			### If applicable, change the location of the ovftool tool ###
		        & 'C:\Program Files\VMware\VMware OVF Tool\ovftool.exe' --noSSLVerify --name=$membername --acceptAllEulas --datastore=$datastore -dm="thin" --network=$dportgroup --powerOn --prop:remote_console_enabled=True --prop:temp_license=$licenses --prop:lan1-v4_addr=$($memberip.address) --prop:lan1-v4_netmask=$($memberip.netmask) --prop:lan1-v4_gw=$($memberip.gateway) $ova $vmlocation
                    
                        if((Get-VM $membername).PowerState -eq "PoweredOn")
                        {
                            ### This section waits for the VM to power on and get initialized with the IP address ###
                            while (!(Test-Connection -BufferSize 32 -Count 1 $($memberip.address) -Quiet))
		            {
			        Write-Host "[INFO] Waiting for member to come online" -ForegroundColor yellow
			        sleep 30
		            }
                
                            ### This section waits for the httpd service to start on the member ###
                            $pwd = ConvertTo-SecureString "infoblox" -AsPlainText -Force
		            $membercreds = New-Object Management.Automation.PSCredential ('admin', $pwd)
                            for ($continue=1;$continue -gt 0 -and $continue -lt 30)
                            {
                                try
                                {
                                    $memberstatus=Invoke-WebRequest -Uri "https://$($memberip.address)/wapi/v2.7/grid" -Method GET -Credential $membercreds
                                    $continue=0
                                }
                                catch
                                {
		                    Write-Host "[INFO] Waiting for httpd service to start (Attempt number $continue)" -ForegroundColor yellow
                                    $continue++
    		                    sleep 30
                                }
                            }
			    
			    if($continue -lt 30)
			    {
			    	### This section adds an entry for the new member in the Grid Master ###
				Write-Host "[INFO] Provisioning the member on the Grid Master" -ForegroundColor yellow
				$memberdetails = @{host_name=$membername
						   vip_setting=@{address=$($memberip.address)
						   subnet_mask=$($memberip.netmask)}
						   config_addr_type="IPV4"
						   platform="VNIOS"} | ConvertTo-Json
				$memberresult = Invoke-WebRequest -Uri "https://$gridmaster/wapi/v2.7/member?_return_as_object=1" -Method POST -Credential $gmcreds -ContentType 'application/json' -Body $memberdetails
				if($memberresult.StatusCode -eq 201)
				{
					Write-Host "[INFO] Entry for $($memberip.address) has been added to the grid $gridmaster" -ForegroundColor Green
				}
				
				### This section initiates a grid join from the member ###
				Write-Host "[INFO] Joining the member to the master" -ForegroundColor yellow
				### NEEDS TO BE MODFIED WITH VALUES SPECIFIC TO YOUR ENVIRONMENT ###
				$gridjoindetails = @{grid_name="Infoblox"
						     master=$gridmaster
						     shared_secret="test"} | ConvertTo-Json
				$joinresult = Invoke-WebRequest -Uri "https://$($memberip.address)/wapi/v2.7/grid?_function=join&_return_as_object=1" -Method POST -Credential $membercreds -ContentType 'application/json' -Body $gridjoindetails
				if($joinresult.StatusCode -eq 200)
				{
					Write-Host "[INFO] $($memberip.address) has joined the grid with Grid Master at $gridmaster" -ForegroundColor Green
				}

                                ### This section creates a fixed address entry for the newly joined member in the grid ###
                                ### This gets the MAC address of the VM from the vCenter server ###
                                $mac = Get-View -Viewtype VirtualMachine -Property Name, Config.Hardware.Device | where name -EQ $membername | Select name,@{n="MAC"; e={($_.Config.Hardware.Device | ?{($_ -is [VMware.Vim.VirtualEthernetCard])} | %{$_.MacAddress})}}
                                Write-Host "[INFO] Adding a fixed address entry to the Grid" -ForegroundColor yellow
				$fixedaddressdetails = @{ipv4addr=$($memberip.address)
							 mac=$($mac.MAC[0])
							 name=$membername} | ConvertTo-Json
				$fixedaddressresult = Invoke-WebRequest -Uri "https://$gridmaster/wapi/v2.7/fixedaddress?_return_as_object=1" -Method POST -Credential $gmcreds -ContentType 'application/json' -Body $fixedaddressdetails
				if($fixedaddressresult.StatusCode -eq 201)
				{ 
					Write-Host "[INFO] Fixed address entry for $($memberip.address) with MAC address $($mac.MAC[0]) has been added to the grid" -ForegroundColor Green
				} 

				### This section starts the DNS service on the member ###
                                Write-Host "[INFO] Enabling DNS and DHCP services" -ForegroundColor Yellow
				$memberdns = (Invoke-WebRequest -Uri "https://$gridmaster/wapi/v2.7/member:dns?host_name=$membername" -Method GET -Credential $gmcreds).Content |ConvertFrom-Json
				$enabledns = @{enable_dns=$true} |ConvertTo-Json
				if((Invoke-WebRequest -Uri "https://$gridmaster/wapi/v2.7/$($memberdns._ref)" -Method PUT -Credential $gmcreds -ContentType 'application/json' -Body $enabledns).StatusCode -eq 200)
				{
					Write-Host "[INFO] DNS service is enabled" -ForegroundColor Green
				}

				### This section starts the DHCP service on the member ###
				$memberdhcp = (Invoke-WebRequest -Uri "https://$gridmaster/wapi/v2.7/member:dhcpproperties?host_name=$membername" -Method GET -Credential $gmcreds).Content |ConvertFrom-Json
				$enabledhcp = @{enable_dhcp=$true} |ConvertTo-Json
				if((Invoke-WebRequest -Uri "https://$gridmaster/wapi/v2.7/$($memberdhcp._ref)" -Method PUT -Credential $gmcreds -ContentType 'application/json' -Body $enabledhcp).StatusCode -eq 200)
				{
					Write-Host "[INFO] DHCP service is enabled" -ForegroundColor Green
				}

				### This section adds the member as a grid secondary to the nameserver group called "default" ###
                                ### NEEDS TO BE MODFIED WITH VALUES SPECIFIC TO YOUR ENVIRONMENT ###
				$nsname = "default"
				$nsgroup = (Invoke-WebRequest -Uri "https://$gridmaster/wapi/v2.7/nsgroup?_return_fields%2B=grid_secondaries&name=$nsname" -Method GET -Credential $gmcreds).Content | ConvertFrom-Json
				Write-Host "[INFO] Adding member $membername to nameserver group $($nsgroup.name)" -ForegroundColor Yellow
                                ### This gets the list of all the existing grid secondaries in the namserver group ###
                                $gridsecondaries = $null
                                foreach ($secondary in ($nsgroup.grid_secondaries.name))
                                {
                                    $gridsecondaries+=@(@{name=$secondary})
                                }
                                if ($gridsecondaries)
                                {
                                    $gridsecondaries+=@(@{name=$membername})
                        
                                }
                                else
                                {
                                    $gridsecondaries=@(@{name=$membername})
                                }
                                $newsecondary = @{grid_secondaries=@($gridsecondaries)} |ConvertTo-Json
                                if((Invoke-WebRequest -Uri "https://$gridmaster/wapi/v2.7/$($nsgroup._ref)?_return_fields%2B=grid_primary,grid_secondaries" -Method PUT -Credential $gmcreds -ContentType 'application/json' -Body $newsecondary).StatusCode -eq 200)
                                {
                                    Write-Host "[INFO] Member $membername is added to nameserver group $($nsgroup.name)" -ForegroundColor Green
                                }					

				### Append this member to the list of members in the grid ###
				$memberlist += @($membername)
                                $scaleup++

				Write-Host "[INFO] Auto scale-up complete" -ForegroundColor green
                            }
                            else
                            {
                                Write-Host "[ERROR] There was an issue while deploying the Virtual Machine" -ForegroundColor Red
                            }
			}
			else
			{
				Write-Host "[ERROR] There was an issue while starting the httpd service. Scale-up failed" -ForegroundColor Red
			}
                    }
                    else
                    {
                        Write-Host "[INFO] Looks like it was a momentary spike.No need to scale up!!" -ForegroundColor Green
                    }
                }
                else
                {
                    Write-Host "[WARNING] We have already created $maxscaleup member(s) while scaling up. Cannot scale up any further!!" -ForegroundColor Yellow
                }
	}

	### The following section is executed if the DNS QPS is below the specified scale down threshold. The most recently scaled up member is removed ###
        elseif ($dnsqps -lt $downthreshold)
	{
		Write-Host "[WARNING] DNS QPS ($dnsqps) is lesser than the threshold $downthreshold" -ForegroundColor red

                ### This gets all the members in the grid currently ###
                $members = (Invoke-WebRequest -Uri "https://$gridmaster/wapi/v2.7/member" -Method GET -Credential $gmcreds).Content | ConvertFrom-Json

                ### This condition ensures that the script does not scale down beyond the original environment. It compares the curent number of members and the original number of members. ###
                if($members.Count -le $numofmemberlist -or $members.Count -eq 1 -or $scaleup -eq 0)
                {
                    Write-Host "[WARNING] No eligibile members to scale down" -ForegroundColor Yellow
                }
                else
                {
                    Write-Host "[INFO] Monitoring the DNS QPS for a cooldown period of $downeval seconds" -ForegroundColor Yellow
            
                    ### The following section monitors the DNS QPS for a specified period of time to ensure that it is not just a temporary slowdown ###            
                    $pollcount = 0
                    $currenttime = Get-Date
                    $dnsqpspoll = 0
                    while ((Get-Date) -lt $currenttime.AddSeconds($downeval))
                    {
                        $pollcount ++
                        $currentdnsqps = (Get-SnmpData -IP $dnsmember -Community $snmpstring -OID 1.3.6.1.4.1.7779.3.1.1.3.1.6.0 -Version V2).Data
                        $dnsqpspoll += $currentdnsqps
                        Write-Host "[INFO] DNS QPS in the polling period: $currentdnsqps" -ForegroundColor Green
                        sleep 10
                    }
                    $dnsqpsavg = [math]::Round($dnsqpspoll/$pollcount)
                    Write-Host "[INFO] The average DNS QPS during the cool-down period was $dnsqpsavg" -ForegroundColor Yellow

                    ### The following section is executed if the average of the DNS QPS during the cooldown period is less than the specified scale down threshold ###
                    if ($dnsqpsavg -lt $downthreshold)
                    {
                        Write-Host "[INFO] Scaling down" -ForegroundColor Yellow

                        ### Remove the member from the list of grid_secondaries in the nameservergroup "default" ###
                        ### NEEDS TO BE MODFIED WITH VALUES SPECIFIC TO YOUR ENVIRONMENT ###
                        $nsname = "default"
                        Write-Host "[INFO] Removing member $($memberlist[($memberlist.Count)-1]) from nameserver group $nsname" -ForegroundColor Yellow
                        $nsgroup = (Invoke-WebRequest -Uri "https://$gridmaster/wapi/v2.7/nsgroup?_return_fields%2B=grid_secondaries&name=$nsname" -Method GET -Credential $gmcreds).Content | ConvertFrom-Json
                    
                        ### This gets the list of all the grid secondaries in the namserver group without the most recently scaled up member ###
                        $gridsecondaries = $null
                        foreach ($secondary in ($nsgroup.grid_secondaries.name))
                        {
                            if($secondary -ne $($memberlist[($memberlist.Count)-1]))
                            {
                                $gridsecondaries+=@(@{name=$secondary})
                            }
                        }
                        if ($gridsecondaries)
                        {
                            $newsecondary = @{grid_secondaries=@($gridsecondaries)} |ConvertTo-Json
                        }
                        else
                        {
                            $newsecondary = @{grid_secondaries=@()} |ConvertTo-Json
                        }
                        if((Invoke-WebRequest -Uri "https://$gridmaster/wapi/v2.7/$($nsgroup._ref)?_return_fields%2B=grid_primary,grid_secondaries" -Method PUT -Credential $gmcreds -ContentType 'application/json' -Body $newsecondary).StatusCode -eq 200)
                        {
                            Write-Host "[INFO] Member $membername is removed from nameserver group $($nsgroup.name)" -ForegroundColor Green
                        }
            
                        ### Remove the entry from the Grid ###
                        Write-Host "[INFO] Removing member $($memberlist[($memberlist.Count)-1]) from the grid" -ForegroundColor Yellow
                        $membertodelete = (Invoke-WebRequest -Uri "https://$gridmaster/wapi/v2.7/member?host_name=$($memberlist[($memberlist.Count)-1])&_return_fields%2B=vip_setting" -Method GET -Credential $gmcreds).Content |ConvertFrom-Json
                        if((Invoke-WebRequest -Uri "https://$gridmaster/wapi/v2.7/$($membertodelete._ref)" -Method DELETE -Credential $gmcreds -ContentType 'application/json').StatusCode -eq 200)
                        {
                            Write-Host "[INFO] Member $membername is removed from the grid" -ForegroundColor Green
                        }

                        ### This section removes the fixed address entry of the member from the grid ###
                        Write-Host "[INFO] Removing the fixed address entry from the Grid" -ForegroundColor yellow
    			$fixedaddresstodelete = (Invoke-WebRequest -Uri "https://$gridmaster/wapi/v2.7/fixedaddress?ipv4addr=$($membertodelete.vip_setting.address)" -Method GET -Credential $gmcreds ).Content | ConvertFrom-Json
			if((Invoke-WebRequest -Uri "https://$gridmaster/wapi/v2.7/$($fixedaddresstodelete._ref)" -Method DELETE -Credential $gmcreds -ContentType 'application/json').StatusCode -eq 200)
			{
                            Write-Host "[INFO] Fixed address entry for $($membertodelete.vip_setting.address) has been deleted from the grid" -ForegroundColor Green
			} 

                        ### Power off and delete the VM from vCenter ###
                        Write-Host "[INFO] Shutting down and deleting the VM $($memberlist[($memberlist.Count)-1]) from vCenter" -ForegroundColor Yellow
                        if ((Stop-VM $($memberlist[($memberlist.Count)-1]) -Confirm:$false).PowerState -eq "PoweredOff")
			{
				Write-Host "[INFO] The VM $($memberlist[($memberlist.Count)-1]) has been shut down" -ForegroundColor Green
				Remove-VM $($memberlist[($memberlist.Count)-1]) -DeletePermanently -Confirm:$false
                            	Write-Host "[INFO] The VM $($memberlist[($memberlist.Count)-1]) has been deleted from the vCenter server" -ForegroundColor Green

				### Remove the member from the list of members in the grid ###
				$memberlist.Remove($($memberlist[($memberlist.Count)-1]))
                            	$scaleup--

				Write-Host "[INFO] Auto scale-down complete" -ForegroundColor green
			}
			else
			{
				Write-Host "[ERROR] There was error while shutting down the VM" -ForegroundColor Red
			}
                    }
                    else
                    {
                        Write-Host "[INFO] Looks like it was a momentary slow down.No need to scale down!!" -ForegroundColor Green
                    }
                }
            }
	    $count++
	    if($count -gt 1000)
	    {
	    	$scale = 1
	    }

            ### The monitoring is paused for the duration of the polling interval specified ###
	    sleep $frequency
        }
    }
}
else
{
    Write-Host "[ERROR] There was an error!" -ForegroundColor Red
}
