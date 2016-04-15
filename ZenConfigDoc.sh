#!/usr/bin/env python

# This script captures information about the Zenoss master, hubs and collectors.  It outputs a reStructured Text
#  report of the environment and some information about its health.


# Copyright 2016, Zenoss, Inc. 

from json import loads, dumps
from cookielib import CookieJar
import re
import tarfile
import argparse
import gzip
import os

from difflib import Differ

# Fix once I know what I actually need
import urllib2, base64, urllib
from urlparse import urlunparse
from pprint import pprint
from time import time, asctime


def convToUnits(number=0, divby=1024.0, unitstr="B"):
    """
    Convert a number to its human-readable form. ie: 4GB, 4MB, etc.

        >>> convToUnits() # Don't do this!
        '0.0B'
        >>> convToUnits(None) # Don't do this!
        ''
        >>> convToUnits(123456789)
        '117.7MB'
        >>> convToUnits(123456789, 1000, "Hz")
        '123.5MHz'

    @param number: base number
    @type number: number
    @param divby: divisor to use to convert to appropriate prefix
    @type divby: number
    @param unitstr: base unit of the number
    @type unitstr: string
    @return: number with appropriate units
    @rtype: string
    """
    units = map(lambda x:x + unitstr, ('','K','M','G','T','P'))
    try:
        numb = float(number)
    except Exception:
        return ''

    sign = 1
    if numb < 0:
        numb = abs(numb)
        sign = -1
    for unit in units:
        if numb < divby: break
        numb /= divby
    return "%.1f%s" % (numb * sign, unit)


def getAuthCookie(opener, headers, data, host, loginPage):
    url = urlunparse(('https', host, '/' + loginPage, '', '', ''))
    req = urllib2.Request(url, headers=headers, data=data)
    # Log in to the API and get the login cookie
    try:
        opener.open(req)
        return True
    except urllib2.URLError as e:
        if hasattr(e, 'reason'):
            print 'We failed to reach a server.'
            print 'Reason: ', e.reason
            return False
        elif hasattr(e, 'code'):
            print "The server couldn\'t fulfill the request."
            print 'Error code: ', e.code
            return False
    except:
        return False

def getObjectData(opener, headers, host, object):
    url = urlunparse(('https', host, '/' + object, '', '', ''))
    req = urllib2.Request(url, headers=headers)
    try:
        resp = opener.open(req)
        resp_data = loads(resp.read())
        return resp_data
    except urllib2.URLError as e:
        if hasattr(e, 'reason'):
            print 'We failed to reach a server.'
            print 'Reason: ', e.reason
        elif hasattr(e, 'code'):
            print "The server couldn\'t fulfill the request."
            print 'Error code: ', e.code

def parsePerfData(resp_data):
    metrics = {}
    for result in resp_data['results']:
        metricName = result['metric']
        if 'datapoints' in result:
            metricValue = result['datapoints'][0]['value']
        else:
            metricValue = 'N/A'
        metrics[metricName] = metricValue
    return metrics

def getHostStats(opener, headers, cchost, hostid, timedur=24, agg='max'):
    hostJson = '{' \
        '"start":"' + str(timedur + 1) + 'h-ago",' \
        '"end":"now",' \
        '"series":true,' \
        '"downsample":"'+str(timedur)+ 'h-' + str(agg)+'",' \
        '"tags":{"controlplane_host_id":["' + str(hostid) + '"]},' \
        '"returnset":"EXACT",' \
        '"metrics":[{' \
            '"metric":"cpu.user",' \
            '"rate":true,' \
            '"rateOptions":{"counter":true,"counterMax":null,"resetThreshold":1},' \
            '"aggregator":"sum",' \
            '"name":"CPU - User"},' \
            '{"metric":"cpu.system",' \
            '"rate":true,' \
            '"rateOptions":{"counter":true,"counterMax":null,"resetThreshold":1},' \
            '"aggregator":"sum",' \
            '"name":"CPU - System"},' \
            '{"metric":"cpu.nice",' \
            '"rate":true,' \
            '"rateOptions":{"counter":true,"counterMax":null,"resetThreshold":1},' \
            '"aggregator":"sum","name":"CPU - Nice"},' \
            '{"metric":"cpu.iowait",' \
            '"rate":true,' \
            '"rateOptions":{"counter":true,"counterMax":null,"resetThreshold":1},' \
            '"aggregator":"sum",' \
            '"name":"IOWait"},' \
            '{"metric":"cpu.irq",' \
            '"rate":true,' \
            '"rateOptions":{"counter":true,"counterMax":null,"resetThreshold":1},' \
            '"aggregator":"sum",' \
            '"name":"CPU - IRQ"},' \
            '{"metric":"cpu.steal",' \
            '"rate":true,' \
            '"rateOptions":{"counter":true,"counterMax":null,"resetThreshold":1},' \
            '"aggregator":"sum","name":"CPU - Steal"},' \
            '{"metric":"cpu.idle",' \
            '"rate":true,' \
            '"rateOptions":{"counter":true,"counterMax":null,"resetThreshold":1},' \
            '"aggregator":"sum","name":"CPU - Idle"},' \
            '{"metric":"storage.total",' \
            '"rate":false,' \
            '"aggregator":"sum","name":"DFS Storage - Total"},' \
            '{"metric":"storage.free",' \
            '"rate":false,' \
            '"aggregator":"sum","name":"DFS Storage - Free"},' \
            '{"metric":"load.avg1m",' \
            '"rate":false,' \
            '"aggregator":"sum","name":"Load Average - 1m"},' \
            '{"metric":"memory.actualused",' \
            '"rate":false,' \
            '"aggregator":"sum","name":"Memory - Used"},' \
            '{"metric":"memory.free",' \
            '"rate":false,' \
            '"aggregator":"sum","name":"Memory - Free"},' \
            '{"metric":"vmstat.pgmajfault",' \
            '"rate":true,' \
            '"aggregator":"sum","name":"Memory - Major Page Faults"}' \
        ']' \
    '}' 
    url = urlunparse(('https', cchost, '/metrics/api/performance/query/', '', '', ''))
    req = urllib2.Request(url, headers=headers, data=hostJson)
    try:
        resp = opener.open(req)
        resp_data = loads(resp.read())
        metrics = parsePerfData(resp_data)
        return metrics
    except urllib2.URLError as e:
        if hasattr(e, 'reason'):
            print 'We failed to reach a server.'
            print 'Reason: ', e.reason
        elif hasattr(e, 'code'):
            print "The server couldn\'t fulfill the request."
            print 'Error code: ', e.code
    pass
    
def getServiceStats(opener, headers, cchost, svcid, timedur=24, agg='max'):
    svcJson = '{' \
        '"start":"' + str(timedur + 1) + 'h-ago",' \
        '"end":"now",' \
        '"series":true,' \
        '"downsample":"'+str(timedur)+ 'h-' + str(agg)+'",' \
        '"tags":{"controlplane_service_id":["' + str(svcid) + '"]},' \
        '"returnset":"EXACT",' \
        '"metrics":[{' \
            '"metric":"cgroup.cpuacct.system",' \
            '"rate":true,' \
            '"rateOptions":{"counter":true,"counterMax":null,"resetThreshold":1},' \
            '"aggregator":"sum",' \
            '"name":"CPU - System"},' \
            '{"metric":"cgroup.cpuacct.user",' \
            '"rate":true,' \
            '"rateOptions":{"counter":true,"counterMax":null,"resetThreshold":1},' \
            '"aggregator":"sum",' \
            '"name":"CPU - User"},' \
            '{"metric":"cgroup.memory.totalrss",' \
            '"rate":false,' \
            '"aggregator":"sum","name":"Memory - Total RSS"},' \
            '{"metric":"cgroup.memory.cache",' \
            '"rate":false,' \
            '"aggregator":"sum","name":"Memory - Cache"}' \
        ']' \
    '}' 
    url = urlunparse(('https', cchost, '/metrics/api/performance/query/', '', '', ''))
    req = urllib2.Request(url, headers=headers, data=svcJson)
    try:
        resp = opener.open(req)
        resp_data = loads(resp.read())
        metrics = parsePerfData(resp_data)
        return metrics
    except urllib2.URLError as e:
        if hasattr(e, 'reason'):
            print 'We failed to reach a server.'
            print 'Reason: ', e.reason
        elif hasattr(e, 'code'):
            print "The server couldn\'t fulfill the request."
            print 'Error code: ', e.code


#  Need to accept a couple of arguments
#  Path to write output to - example "/tmp"
#  Customer - example "Zenoss, Inc."
#  Environment - example "Production"
#  IP of CC Master - example "10.1.1.1"
#  Username for CC - example "root"
#  Password for CC - example "zenoss"
#  
p = argparse.ArgumentParser(description='Generate a configuration document for a Zenoss 5.x system.  Customer name and environment will be used to name the file created.')
#  Path to write output to - example "/tmp"
p.add_argument("-O", "--OutputPath", action="store", dest="outputpath", default="/tmp", help="path for output; default is /tmp")
#  Customer - example "Zenoss, Inc."
p.add_argument("-c", "--customer", action="store", dest="customer", required=True, help="name of the customer this is being run for; no spaces or other special characters")
#  Environment - example "Production"
p.add_argument("-e", "--env", action="store", dest="environment", required=True, help="arbitrary name for the environment - examples would be Production or Staging; no spaces or other special characters")
#  IP of CC Master - example "10.1.1.1"
p.add_argument("-C", "--CChost", action="store", dest="cchost", required=True, help="Control Center hostname or IP address")
#  Username for CC - example "root"
p.add_argument("-u", "--user", action="store", dest="username", required=True, help="username with access to the CC UI")
#  Password for CC - example "zenoss"
p.add_argument("-p", "--password", action="store", dest="password", required=True, help="password for the CC UI")

args = p.parse_args()
outpath = args.outputpath
environ = args.environment
cust_name = args.customer
outfile = outpath + '/' + str(cust_name) + '.' + str(environ) + '.' + str(time())
# jsonout = outpath + '/' + str(cust_name) + '.' + str(environ) + '.' + str(time()) + '.json'
# txtout = outpath + '/' + str(cust_name) + '.' + str(environ) + '.' + str(time()) + '.rst'

# cchost = 'ms-europa1.zenoss.loc'
# cchost = '10.88.111.100'
cchost = args.cchost
top_level_url = urlunparse(('https', cchost, '', '', '', ''))
_cj = CookieJar()
# confMatch = re.compile('^\s*[^#|^\n].*$', re.MULTILINE)
confMatch2 = re.compile('^\+ (.*)')


differ = Differ()
deployments = {}
deployments['pools'] = {}
deployments['services'] = {}
linewidth = 80

# username = 'zenny'
# username = 'root'
# password = 'Z3n0ss'
# password = 'zenoss'
username = args.username
password = args.password
_creds = {"username": username, "password": password}
creds = dumps(_creds)
headers = {"Content-Type": "application/json"}

# opener = urllib2.build_opener(urllib2.HTTPSHandler(debuglevel=1), urllib2.HTTPCookieProcessor(_cj))
opener = urllib2.build_opener(urllib2.HTTPSHandler(), urllib2.HTTPCookieProcessor(_cj))

# Install the opener.
# Now all calls to urllib2.urlopen use our opener.
urllib2.install_opener(opener)
loginPage = 'login'
print "Attempting to login to CC"
if getAuthCookie(opener, headers, creds, cchost, loginPage):
    print "Logged in successfully"

    object = 'pools'
    print "Getting pool information"
    pools = getObjectData(opener, headers, cchost, object)
    for pool in pools:
        deployments['pools'][pool] = {}
        deployments['pools'][pool]['ID'] = pools[pool]['ID']
        deployments['pools'][pool]['Description'] = pools[pool]['Description']
        deployments['pools'][pool]['CoreCapacity'] = pools[pool]['CoreCapacity']
        deployments['pools'][pool]['MemoryCapacity'] = pools[pool]['MemoryCapacity']
        deployments['pools'][pool]['MemoryCommitment'] = pools[pool]['MemoryCommitment']
        deployments['pools'][pool]['VirtualIPs'] = pools[pool]['VirtualIPs']
    print "getting host information"
    hosts = getObjectData(opener, headers, cchost, 'hosts')
    for host in hosts:
        hostname = hosts[host]['Name']
        pool = hosts[host]['PoolID']
        if 'hosts' not in deployments['pools'][pool]:
            deployments['pools'][pool]['hosts'] = {}
        deployments['pools'][pool]['hosts'][hostname] = {}
        deployments['pools'][pool]['hosts'][hostname]['hostid'] = hosts[host]['ID']
        deployments['pools'][pool]['hosts'][hostname]['IP'] = hosts[host]['IPAddr']
        deployments['pools'][pool]['hosts'][hostname]['Cores'] = hosts[host]['Cores']
        deployments['pools'][pool]['hosts'][hostname]['Memory'] = hosts[host]['Memory']
        deployments['pools'][pool]['hosts'][hostname]['PrivateNetwork'] = hosts[host]['PrivateNetwork']
        deployments['pools'][pool]['hosts'][hostname]['RPCPort'] = hosts[host]['RPCPort']
        deployments['pools'][pool]['hosts'][hostname]['historicalPerf'] = {}
        print "Getting historical performance information for host %s" % hostname
        hostStats = getHostStats(opener, headers, cchost, hosts[host]['ID'], agg='max', timedur=24)
        deployments['pools'][pool]['hosts'][hostname]['historicalPerf']['max'] = hostStats
        hostStats = getHostStats(opener, headers, cchost, hosts[host]['ID'], agg='avg', timedur=24)
        deployments['pools'][pool]['hosts'][hostname]['historicalPerf']['avg'] = hostStats
    print "Getting default host alias"
    defaultHostAlias = getObjectData(opener, headers, cchost, 'hosts/defaultHostAlias')['hostalias']
    print "Getting services information"
    services = getObjectData(opener, headers, cchost, 'services')
    for service in services:
        if service['Startup'] and service['Startup'] != 'N/A':
            pool = service['PoolID']
            if pool == '':
                pool = 'Internal'
                if pool not in deployments['pools']:
                    deployments['pools'][pool] = {}
            servicename = service['Name']
            if 'services' not in deployments['pools'][pool]:
                deployments['pools'][pool]['services'] = {}
            deployments['pools'][pool]['services'][servicename] = {}
            deployments['pools'][pool]['services'][servicename]['ID'] = service['ID']
            deployments['pools'][pool]['services'][servicename]['RAMCommitment'] = service['RAMCommitment']
            deployments['pools'][pool]['services'][servicename]['ParentServiceID'] = service['ParentServiceID']
            deployments['pools'][pool]['services'][servicename]['HostPolicy'] = service['HostPolicy']
            deployments['pools'][pool]['services'][servicename]['Hostname'] = service['Hostname']
            deployments['pools'][pool]['services'][servicename]['Instances'] = service['Instances']
            deployments['pools'][pool]['services'][servicename]['Launch'] = service['Launch']
            deployments['pools'][pool]['services'][servicename]['DeploymentID'] = service['DeploymentID']
            deployments['pools'][pool]['services'][servicename]['Description'] = service['Description']
            deployments['pools'][pool]['services'][servicename]['CPUCommitment'] = service['CPUCommitment']
            deployments['pools'][pool]['services'][servicename]['Startup'] = service['Startup']
            configFiles = service['ConfigFiles']
            origConfigFiles = service['OriginalConfigs']
            if configFiles:
                for config in configFiles:
                    configName = config.split('/')[-1]
                    configFile = configFiles[config]['Content'].splitlines()
                        # confLines = confMatch.findall(configFile)
                        # if len(confLines):
                            # if 'configs' not in deployments['pools'][pool]['services'][servicename]:
                                # deployments['pools'][pool]['services'][servicename]['configs'] = {}
                            # deployments['pools'][pool]['services'][servicename]['configs'][configName] = confLines
                    origConfigFile = origConfigFiles[config]['Content'].splitlines()
                    diffText = differ.compare(origConfigFile, configFile)
                    changedConfig = [confMatch2.match(diffLine).group(1) for diffLine in diffText if confMatch2.match(diffLine) is not None]
                    if len(changedConfig):
                        if 'configs' not in deployments['pools'][pool]['services'][servicename]:
                            deployments['pools'][pool]['services'][servicename]['configs'] = {}
                        deployments['pools'][pool]['services'][servicename]['configs'][configName] = changedConfig
        print "Getting historical performance information for service %s" % servicename
        deployments['pools'][pool]['services'][servicename]['historicalPerf'] = {}
        svcStats = getServiceStats(opener, headers, cchost, service['ID'], agg='max', timedur=24)
        deployments['pools'][pool]['services'][servicename]['historicalPerf']['max'] = svcStats
        svcStats = getServiceStats(opener, headers, cchost, service['ID'], agg='avg', timedur=24)
        deployments['pools'][pool]['services'][servicename]['historicalPerf']['avg'] = svcStats
        if service.get('Endpoints'):
            for endpoint in service['Endpoints']:
                if endpoint['Purpose'] == 'export':
                    if endpoint['VHosts']:
                        # Add to vhosts for the pool (older 5.0 style)
                        for vhost in endpoint['VHosts']:
                            if 'VHostList' not in deployments['pools'][pool]:
                                deployments['pools'][pool]['VHostList'] = {}
                            deployments['pools'][pool]['VHostList'][vhost] = {}
                            if vhost.find('.') == -1:
                                deployments['pools'][pool]['VHostList'][vhost]['url'] = 'https://' + '.'.join((vhost, defaultHostAlias))
                            else:
                                deployments['pools'][pool]['VHostList'][vhost]['url'] = 'https://' + str(vhost)
                            deployments['pools'][pool]['VHostList'][vhost]['enabled'] = True
                            deployments['pools'][pool]['VHostList'][vhost]['service'] = servicename
                        pass
                    if 'VHostList' in endpoint and endpoint['VHostList']:
                        # Add to vhosts for the pool (newer 5.1 style)
                        for _vhost in endpoint['VHostList']:
                            vhost = _vhost['Name']
                            enabled = _vhost['Enabled']
                            if 'VHostList' not in deployments:
                                deployments['VHostList'] = {}
                            deployments['VHostList'][vhost] = {}
                            if vhost.find('.') == -1:
                                deployments['VHostList'][vhost]['url'] = 'https://' + '.'.join((vhost, defaultHostAlias))
                            else:
                                deployments['VHostList'][vhost]['url'] = 'https://' + str(vhost)
                            deployments['VHostList'][vhost]['enabled'] = enabled
                            deployments['VHostList'][vhost]['service'] = servicename
                    if 'PortList' in endpoint and endpoint['PortList']:
                        # Add to public ports for the pool (newer 5.1 style)
                        for _pport in endpoint['PortList']:
                            pport = _pport['PortAddr']
                            enabled = _pport['Enabled']
                            if 'PortList' not in deployments:
                                deployments['PortList'] = {}
                            deployments['PortList'][pport] = {}
                            deployments['PortList'][pport]['address'] = pport
                            deployments['PortList'][pport]['enabled'] = enabled
                            deployments['PortList'][pport]['endpoint'] = endpoint['Name']
                            deployments['PortList'][pport]['privateport'] = endpoint['PortNumber']
                            deployments['PortList'][pport]['service'] = servicename
                    if endpoint['AddressAssignment'].get('AssignmentType'):
                        # Add Address assignement to service
                        ip = endpoint['AddressAssignment']['IPAddr']
                        asgntype = endpoint['AddressAssignment']['AssignmentType']
                        port = endpoint['AddressAssignment']['Port']
                        name = endpoint['AddressAssignment']['EndpointName']
                        hostid = endpoint['AddressAssignment']['HostID']
                        if hostid:
                            for host in deployments['pools'][pool]['hosts']:
                                if hostid == deployments['pools'][pool]['hosts'][host]['hostid']:
                                    hostname = host
                                    break
                            else:
                                # Should never get here
                                hostname = 'Unkown'
                        else:
                            hostname = 'N/A'
                        if 'AddressAssignments' not in deployments['pools'][pool]['services'][servicename]:
                            deployments['pools'][pool]['services'][servicename]['AddressAssignments'] = {}
                        deployments['pools'][pool]['services'][servicename]['AddressAssignments'][name] = {}
                        deployments['pools'][pool]['services'][servicename]['AddressAssignments'][name]['AssignmentType'] = asgntype
                        deployments['pools'][pool]['services'][servicename]['AddressAssignments'][name]['IP'] = ip
                        deployments['pools'][pool]['services'][servicename]['AddressAssignments'][name]['Port'] = port
                        deployments['pools'][pool]['services'][servicename]['AddressAssignments'][name]['Host'] = hostname
    print "Creating temporary files:"
    print "%s.json" % outfile
    print "%s.rst" % outfile
    print "\n"
    jsonout = open(outfile + '.json', "w")
    txtout = open(outfile + '.rst', "w")
    jsonout.write(dumps(deployments))
    # pprint(deployments)
    jsonout.close()
    txtout.write('\n'.rjust(linewidth, '='))
    txtout.write('Architecture Document\n')
    txtout.write('\n'.rjust(linewidth, '='))
    txtout.write('\n\n')
    txtout.write('\n'.rjust(linewidth, '-'))
    txtout.write('Customer: %s\n' % cust_name)
    txtout.write('\n'.rjust(linewidth, '-'))
    txtout.write('\n'.rjust(linewidth, '-'))
    txtout.write('Environment: %s\n' % environ)
    txtout.write('\n'.rjust(linewidth, '-'))
    txtout.write('|\n\n')
    txtout.write('\n'.rjust(linewidth, '-'))
    txtout.write('Created on: %s\n' % asctime())
    txtout.write('\n'.rjust(linewidth, '-'))
    txtout.write('|\n|\n|\n|\n')
    txtout.write('\n\n')
    txtout.write('\n'.rjust(linewidth, '-'))
    txtout.write('Control Center Summary Information\n')
    txtout.write('\n'.rjust(linewidth, '-'))
    txtout.write('\n')
    
    for pool in deployments['pools']:
        txtout.write('Summary for pool %s\n' % pool)
        txtout.write('\n'.rjust(linewidth, '+'))
        txtout.write('\n')
        if 'CoreCapacity' in deployments['pools'][pool]:
            txtout.write(':Cores: %s\n' % deployments['pools'][pool]['CoreCapacity'])
            txtout.write(':RAM: %s\n' % convToUnits(deployments['pools'][pool]['MemoryCapacity']))
            txtout.write('\n')
        if 'hosts' in deployments['pools'][pool]:
            txtout.write('Hosts\n')
            txtout.write('\n'.rjust(linewidth, '*'))
            txtout.write('\n')
            for host in deployments['pools'][pool]['hosts']:
                hostinfo = deployments['pools'][pool]['hosts'][host]
                cores = hostinfo['Cores']
                memory = convToUnits(hostinfo['Memory'])
                txtout.write(':Host: %s\n' % host)
                txtout.write('\n')
                txtout.write('  :Cores: %s\n' % cores)
                txtout.write('  :Memory: %s\n' % memory)
                txtout.write('\n')
        txtout.write('\n')
        if 'services' in deployments['pools'][pool]:
            txtout.write('Services\n')
            txtout.write('\n'.rjust(linewidth, '*'))
            txtout.write('\n')
            txtout.write('========================= ===============\n')
            txtout.write('Service Name              RAM Commitment\n')
            txtout.write('========================= ===============\n')
            services = deployments['pools'][pool]['services'].keys()
            services.sort()
            for service in services:
                serviceinfo = deployments['pools'][pool]['services'][service]
                ramcommit = serviceinfo['RAMCommitment']
                # txtout.write(':Service: %s\n' % service)
                #txtout.write('\n')
                txtout.write(str(service).ljust(26))
                if ramcommit:
                    #txtout.write('  :RAM Commitment: %s\n' % ramcommit)
                    txtout.write('%sB\n' % ramcommit)
                else:
                    txtout.write('N/A\n')
                # txtout.write('------------------------- ---------------\n')
            txtout.write('========================= ===============\n')
            txtout.write('\n______\n\n|\n\n')
    txtout.write('\n\n')
    txtout.write('\n'.rjust(linewidth, '-'))
    txtout.write('Control Center Detail Information\n')
    txtout.write('\n'.rjust(linewidth, '-'))
    txtout.write('\n')

    if 'VHostList' in deployments:
        txtout.write('VHosts\n')
        txtout.write('\n'.rjust(linewidth, '+'))
        txtout.write('\n')
        for vhost in deployments['VHostList']:
            txtout.write(':Name: %s\n\n' % vhost)
            txtout.write('  :URL: %s\n' % deployments['VHostList'][vhost]['url'])
            txtout.write('  :Service: %s\n' % deployments['VHostList'][vhost]['service'])
            txtout.write('  :Enabled: %s\n' % str(deployments['VHostList'][vhost]['enabled']))
            txtout.write('\n')
        txtout.write('\n')
    if 'PortList' in deployments:
        txtout.write('Public Ports\n')
        txtout.write('\n'.rjust(linewidth, '+'))
        txtout.write('\n')
        for pport in deployments['PortList']:
            txtout.write(':Address: %s\n' % deployments['PortList'][pport]['address'])
            txtout.write(':Service: %s\n' % deployments['PortList'][pport]['service'])
            txtout.write(':Enabled: %s\n' % str(deployments['PortList'][pport]['enabled']))
            txtout.write('\n')
        txtout.write('\n')
    for pool in deployments['pools']:
        txtout.write('Detail information for pool %s\n' % pool)
        txtout.write('\n'.rjust(linewidth, '+'))
        txtout.write('\n')
        if 'Description' in deployments['pools'][pool] and deployments['pools'][pool]['Description']:
            txtout.write(':Description: %s\n' % deployments['pools'][pool]['Description'])
        else:
            txtout.write(':Description: *No description configured*\n')
        if 'CoreCapacity' in deployments['pools'][pool]:
            txtout.write(':Available Cores: %s\n' % deployments['pools'][pool]['CoreCapacity'])
        if 'MemoryCapacity' in deployments['pools'][pool]:
            txtout.write(':Total RAM: %s\n' % convToUnits(deployments['pools'][pool]['MemoryCapacity']))
        if 'MemoryCommitment' in deployments['pools'][pool] and deployments['pools'][pool]['MemoryCommitment']:
            txtout.write(':RAM Commitment: %s\n' % convToUnits(deployments['pools'][pool]['MemoryCommitment']))
        if 'VirtualIPs' in deployments['pools'][pool] and deployments['pools'][pool]['VirtualIPs']:
            virtualIPs = []
            for virtualip in deployments['pools'][pool]['VirtualIPs']:
                virtualIPs.append('%s: %s/%s' % (virtualip['BindInterface'], 
                                                 virtualip['IP'], 
                                                 virtualip['Netmask']))
            txtout.write(':Virtual IPs: %s\n' % '\n'.join(virtualIPs))
        txtout.write('\n')
        if 'hosts' in deployments['pools'][pool]:
            txtout.write('Hosts\n')
            txtout.write('\n'.rjust(linewidth, '*'))
            txtout.write('\n')
            for host in deployments['pools'][pool]['hosts']:
                hostinfo = deployments['pools'][pool]['hosts'][host]
                cores = hostinfo['Cores']
                memory = convToUnits(hostinfo['Memory'])
                hostid = hostinfo['hostid']
                ip = hostinfo['IP']
                rpcport = hostinfo['RPCPort']
                pnetwork = hostinfo['PrivateNetwork']
                txtout.write(':Host: %s\n' % host)
                txtout.write('\n')
                txtout.write('  :Host ID: %s\n' % hostid)
                txtout.write('  :IP Address: %s\n' % ip)
                txtout.write('  :CC Port (RPC): %s\n' % rpcport)
                txtout.write('  :Private Network: %s\n' % pnetwork)
                txtout.write('  :Cores: %s\n' % cores)
                txtout.write('  :Memory: %s\n' % memory)
                txtout.write('\n')
                metrics = hostinfo['historicalPerf']['max'].keys()
                metrics.sort()
                txtout.write('============================== ========== ==========\n')
                txtout.write('Metric Over Last 24H           Average    Maximum   \n')
                #txtout.write('------------------------- ---------------------\n')
                txtout.write('============================== ========== ==========\n')
                for metric in metrics:
                    avgValue = hostinfo['historicalPerf']['avg'][metric]
                    maxValue = hostinfo['historicalPerf']['max'][metric]
                    if maxValue != 'N/A':
                        if metric.startswith('CPU'):
                            avgValue = '%s%%' % str(round(avgValue, 2))
                            maxValue = '%s%%' % str(round(maxValue, 2))
                        elif metric.startswith('Memory'):
                            avgValue = convToUnits(avgValue)
                            maxValue = convToUnits(maxValue)
                        elif metric.startswith('DFS') and maxValue != 'N/A':
                            avgValue = convToUnits(avgValue * 1024)
                            maxValue = convToUnits(maxValue * 1024)
                        elif metric.startswith('Load Average'):
                            avgValue = str(round(avgValue, 2))
                            maxValue = str(round(maxValue, 2))
                        elif metric.startswith('IOWait'):
                            avgValue = '%s%%' % str(round(avgValue, 2))
                            maxValue = '%s%%' % str(round(maxValue, 2))
                        else:
                            pass
                        txtout.write('%s %s %s\n' % (metric.ljust(30), avgValue.ljust(10), maxValue))
                    # txtout.write('-------------------- ---------- ----------\n')
                txtout.write('============================== ========== ==========\n')
                txtout.write('\n______\n\n|\n\n')
        txtout.write('\n')
        if 'services' in deployments['pools'][pool]:
            txtout.write('Services\n')
            txtout.write('\n'.rjust(linewidth, '*'))
            txtout.write('\n')
            services = deployments['pools'][pool]['services'].keys()
            services.sort()
            for service in services:
                serviceinfo = deployments['pools'][pool]['services'][service]
                ramcommit = serviceinfo['RAMCommitment']
                cpucommit = serviceinfo['CPUCommitment']

                txtout.write(':Service: %s\n' % service)
                txtout.write('\n')
                txtout.write('  :Service ID: %s\n' % serviceinfo['ID'])
                txtout.write('  :Description: %s\n' % serviceinfo['Description'])
                if ramcommit:
                    txtout.write('  :RAM Commitment: %s\n' % ramcommit)
                if ramcommit:
                    txtout.write('  :CPU Commitment: %s\n' % cpucommit)
                txtout.write('  :Launch Option: %s\n' % serviceinfo['Launch'])
                txtout.write('  :Instances: %s\n' % serviceinfo['Instances'])
                txtout.write('  :Deployment ID: %s\n' % serviceinfo['DeploymentID'])
                txtout.write('  :Host Policy: %s\n' % serviceinfo['HostPolicy'])
                if 'AddressAssignments' in serviceinfo:
                    txtout.write('\n  Address Assignments\n\n')
                    for name in serviceinfo['AddressAssignments']:
                        asgntype = serviceinfo['AddressAssignments'][name]['AssignmentType']
                        ip = serviceinfo['AddressAssignments'][name]['IP']
                        port = serviceinfo['AddressAssignments'][name]['Port']
                        host = serviceinfo['AddressAssignments'][name]['Host']
                        txtout.write('    %s  %s assignment of %s:%s on host %s\n' % (name, asgntype, ip, port, host))
                    txtout.write('\n\n')
                if 'configs' in serviceinfo:
                    for config in serviceinfo['configs']:
                        txtout.write('\n|\n\n  Changed lines in config file %s::\n\n' % config)
                        # txtout.write('    ')
                        txtout.write('    %s' % '\n    '.join(serviceinfo['configs'][config]))
                        txtout.write('  \n')
                txtout.write('\n|\n\n')
                metrics = serviceinfo['historicalPerf']['max'].keys()
                metrics.sort()
                if len([val for val in serviceinfo['historicalPerf']['avg'].values() if val != 'N/A']):
                    txtout.write('============================== ========== ==========\n')
                    txtout.write('Metric Over Last 24H           Average    Maximum   \n')
                    #txtout.write('------------------------- ---------------------\n')
                    txtout.write('============================== ========== ==========\n')
                    for metric in metrics:
                        avgValue = serviceinfo['historicalPerf']['avg'][metric]
                        maxValue = serviceinfo['historicalPerf']['max'][metric]
                        if maxValue != 'N/A':
                            if metric.startswith('CPU'):
                                avgValue = '%s%%' % str(round(avgValue, 2))
                                maxValue = '%s%%' % str(round(maxValue, 2))
                            elif metric.startswith('Memory'):
                                avgValue = convToUnits(avgValue)
                                maxValue = convToUnits(maxValue)
                            else:
                                pass
                            txtout.write('%s %s %s\n' % (metric.ljust(30), avgValue.ljust(10), maxValue))
                        # txtout.write('-------------------- ---------- ----------\n')
                    txtout.write('============================== ========== ==========\n')
                txtout.write('\n______\n\n|\n\n')
        txtout.write('\n')
            
    
    txtout.close()
    # archive = tarfile.open(outfile + ".tgz", "w|gz")
    # archive.add(txtout.name, out.name.split('/').pop(), False)
    # archive.add(jsonout.name, jsonout.name.split('/').pop(), False)
    # archive.close()
    # print 'Output saved to:\n\t' + outfile + '.tgz'
    # os.remove(txtout.name)
    # os.remove(jsonout.name)

else:
    print "Couldn't log in"

